#!/usr/bin/env bash
# If not running under bash, re-exec with bash (arrays require bash)
if [ -z "${BASH_VERSINFO:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

set -euo pipefail

# -----------------------------------------------------------------------------
# RStudio Server launcher (Apptainer)
#
# Goals:
#   A) Unique stable port per user (saved in ~/.local/share/rstudio-server/conf/port)
#      - Collision-free allocation (atomic mkdir registry)
#      - Auto-heal if the assigned port is already in use
#
#   B) Stop RStudio from filling $HOME with huge session state:
#      - RStudio writes to ~/.local/share/rstudio (sessions, state, etc.)
#      - We bind-mount /home/$USER/.local/share inside the container to a
#        per-user directory on /media/volume/Workspaces.
#      - This avoids symlinks (RStudio can choke on symlinks) and is robust.
#
#   C) Migration:
#      - If user already has data in $HOME/.local/share/rstudio, migrate it
#        to the new storage location (ONE TIME), but ONLY when no rserver/rsession
#        is running for that user (safe).
# -----------------------------------------------------------------------------

# --- Config ---------------------------------------------------------------
SIF="/media/volume/OMA_container/OMA-server/rstudio_server.sif"
MODE="${MODE:-single}"            # pam | single
SHARED_RO="${SHARED_RO:-/media/volume/project_2013220}"

: "${USER:=$(id -un)}"

# Launcher state for rserver (keep in HOME to avoid breaking existing users)
WORK="$HOME/.local/share/rstudio-server"
USER_WS="${USER_WS:-/home/$USER}"

# RStudio Server binaries (inside the container)
RS_BIN="/usr/lib/rstudio-server/bin/rserver"
PAM_HELPER="/usr/lib/rstudio-server/bin/pam-helper"

# --- Per-user storage for ~/.local/share (heavy) --------------------------
# This will become /home/$USER/.local/share inside the container
LOCAL_SHARE_BASE="/media/volume/Workspaces/users/$USER/.local_share"
LOCAL_SHARE_DIR="$LOCAL_SHARE_BASE/share"
RSTUDIO_DIR="$LOCAL_SHARE_DIR/rstudio"   # where ~/.local/share/rstudio will live

user_has_running_rstudio() {
  pgrep -u "$USER" -f rserver  >/dev/null 2>&1 && return 0
  pgrep -u "$USER" -f rsession >/dev/null 2>&1 && return 0
  return 1
}

prepare_local_share_if_safe() {
  # Ensure destination exists
  mkdir -p "$LOCAL_SHARE_DIR" "$RSTUDIO_DIR" || true

  # If rserver/rsession running, do NOT migrate (avoid corruption)
  if user_has_running_rstudio; then
    echo "INFO: RStudio seems to be running for $USER; skipping migration of existing ~/.local/share/rstudio."
    return 0
  fi

  # If there is old data in HOME, migrate it ONCE (contents only)
  if [[ -d "$HOME/.local/share/rstudio" && -n "$(ls -A "$HOME/.local/share/rstudio" 2>/dev/null || true)" ]]; then
    echo "INFO: Migrating $HOME/.local/share/rstudio -> $RSTUDIO_DIR"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --remove-source-files "$HOME/.local/share/rstudio"/ "$RSTUDIO_DIR"/
      find "$HOME/.local/share/rstudio" -type d -empty -delete 2>/dev/null || true
    else
      # Fallback migration (best-effort)
      mv "$HOME/.local/share/rstudio"/*     "$RSTUDIO_DIR"/ 2>/dev/null || true
      mv "$HOME/.local/share/rstudio"/.[!.]* "$RSTUDIO_DIR"/ 2>/dev/null || true
      mv "$HOME/.local/share/rstudio"/..?*   "$RSTUDIO_DIR"/ 2>/dev/null || true
    fi
  fi
}

# --- Port Allocation (stable per user, collision-free) ---------------------
PORT_MIN=8800
PORT_MAX=8899

PORT_FILE="$WORK/conf/port"
PORT_REG_DIR="/tmp/rstudio-port-registry"

is_port_free() {
  local p="$1"
  ! (echo >/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1
}

port_listener_pid() {
  local p="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true
    return 0
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | awk -v port=":$p" '
      $0 ~ port && $0 ~ /pid=/ {
        match($0, /pid=([0-9]+)/, m);
        if (m[1] != "") { print m[1]; exit }
      }' || true
  fi
}

pid_owner() {
  local pid="$1"
  ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}' || true
}

ensure_port_registry() {
  if [[ ! -d "$PORT_REG_DIR" ]]; then
    mkdir -p "$PORT_REG_DIR" 2>/dev/null || true
  fi
  chmod 1777 "$PORT_REG_DIR" 2>/dev/null || true

  if [[ ! -d "$PORT_REG_DIR" || ! -w "$PORT_REG_DIR" ]]; then
    echo "ERROR: Port registry directory is not writable: $PORT_REG_DIR" >&2
    echo "       Please ensure it exists and has permissions 1777." >&2
    exit 1
  fi
}

reserve_port() {
  local p="$1"
  local d="${PORT_REG_DIR}/${p}"
  if mkdir "$d" 2>/dev/null; then
    {
      echo "user=$USER"
      echo "uid=$(id -u)"
      echo "host=$(hostname 2>/dev/null || true)"
      echo "time=$(date -Is 2>/dev/null || date)"
    } > "${d}/owner" 2>/dev/null || true
    return 0
  fi
  return 1
}

release_reservation_best_effort() {
  local p="$1"
  rm -rf "${PORT_REG_DIR:?}/${p}" 2>/dev/null || true
}

allocate_new_port_and_persist() {
  mkdir -p "$WORK/conf"

  local p
  for p in $(seq "$PORT_MIN" "$PORT_MAX"); do
    if is_port_free "$p" && reserve_port "$p"; then
      PORT="$p"
      echo "$PORT" > "$PORT_FILE"
      chmod 600 "$PORT_FILE"
      return 0
    fi
  done

  echo "ERROR: No free ports available in range ${PORT_MIN}-${PORT_MAX}." >&2
  exit 1
}

allocate_and_persist_port() {
  mkdir -p "$WORK/conf"

  if [[ -n "${PORT:-}" ]]; then
    return 0
  fi

  ensure_port_registry

  if [[ -f "$PORT_FILE" ]]; then
    PORT="$(cat "$PORT_FILE")"

    if ! is_port_free "$PORT"; then
      local pid owner
      pid="$(port_listener_pid "$PORT")"
      owner=""
      [[ -n "${pid:-}" ]] && owner="$(pid_owner "$pid")"

      if [[ -n "${owner:-}" && "$owner" == "$USER" ]]; then
        echo "INFO: Port $PORT is in use by your existing process (pid=$pid). Stopping old session..."
        pkill -u "$USER" -f rserver  2>/dev/null || true
        pkill -u "$USER" -f rsession 2>/dev/null || true
        sleep 1

        if ! is_port_free "$PORT"; then
          echo "ERROR: Port $PORT still in use after stopping processes." >&2
          exit 1
        fi

        [[ ! -d "${PORT_REG_DIR}/${PORT}" ]] && reserve_port "$PORT" || true
        return 0
      fi

      echo "WARN: Assigned port $PORT is in use (pid=${pid:-unknown}, owner=${owner:-unknown}). Re-allocating..."
      release_reservation_best_effort "$PORT"
      allocate_new_port_and_persist
      return 0
    fi

    [[ ! -d "${PORT_REG_DIR}/${PORT}" ]] && reserve_port "$PORT" || true
    return 0
  fi

  allocate_new_port_and_persist
}

# --- Prep ----------------------------------------------------------------
# 1) Move old RStudio state out of HOME if safe
prepare_local_share_if_safe

# 2) Ensure launcher state exists (do not change to avoid breaking users)
mkdir -p "$WORK"/{run,var-lib,tmp,conf} "$USER_WS"
if [[ ! -f "$WORK/conf/database.conf" ]]; then
  printf 'provider=sqlite\n' > "$WORK/conf/database.conf"
  chmod 600 "$WORK/conf/database.conf"
fi

# 3) Stable port selection
allocate_and_persist_port

# Sanity checks
if [[ ! -f "$SIF" ]]; then
  echo "ERROR: SIF not found: $SIF" >&2; exit 1
fi
if ! apptainer exec "$SIF" test -x "$RS_BIN"; then
  echo "ERROR: $RS_BIN not found inside SIF. Was RStudio Server installed?" >&2
  exit 1
fi

echo "RStudio Server launcher"
echo "  SIF:        $SIF"
echo "  MODE:       $MODE"
echo "  PORT:       $PORT"
echo "  WORKSPACE:  $USER_WS"
[[ -d "$SHARED_RO" ]] && echo "  SHARED_RO:  $SHARED_RO (mounted read-only)"

# --- Binds ---------------------------------------------------------------
COMMON_BINDS=( )
COMMON_BINDS+=( --bind "$WORK/run:/run" )
COMMON_BINDS+=( --bind "$WORK/var-lib:/var/lib/rstudio-server" )
COMMON_BINDS+=( --bind "$WORK/tmp:/tmp" )
COMMON_BINDS+=( --bind "$WORK/conf/database.conf:/etc/rstudio/database.conf" )

# Bind user's home
[[ -d "$USER_WS" ]] && COMMON_BINDS+=( --bind "$USER_WS:/home/$USER" )

# Ensure local-share directory exists (host)
mkdir -p "$LOCAL_SHARE_DIR" "$RSTUDIO_DIR" || true

# Critical: bind the ENTIRE ~/.local/share to Workspaces location
COMMON_BINDS+=( --bind "$LOCAL_SHARE_DIR:/home/$USER/.local/share" )

# Make sure some shared folders exist
mkdir -p "/media/volume/Workspaces/users/$USER"
mkdir -p "/media/volume/Exports/users/$USER"

# Workspace mount
COMMON_BINDS+=( --bind "/media/volume/Workspaces/users/$USER:/home/$USER/Workspace/" )

# Exports mount
[[ -d "/media/volume/Exports/users/$USER" ]] && COMMON_BINDS+=( --bind "/media/volume/Exports/users/$USER:/home/$USER/Exports/" )

# Shared project
[[ -d "/media/volume/project_2013220" ]] && COMMON_BINDS+=( --bind "/media/volume/project_2013220/:/media/project_2013220/" )

# Optional shared RO
[[ -d "$SHARED_RO" ]] && COMMON_BINDS+=( --bind "$SHARED_RO:/home/$USER/shared_project:ro" )

# Identity DBs
COMMON_BINDS+=( --bind /etc/passwd:/etc/passwd:ro --bind /etc/group:/etc/group:ro )

# --- Launch --------------------------------------------------------------
BROWSER_CMD="${BROWSER_CMD:-firefox}"
open_url() {
  local url="http://localhost:${PORT}"
  if command -v "$BROWSER_CMD" >/dev/null 2>&1; then
    ( sleep 1; "$BROWSER_CMD" "$url" >/dev/null 2>&1 ) &
  elif command -v xdg-open >/dev/null 2>&1; then
    ( sleep 1; xdg-open "$url" >/dev/null 2>&1 ) &
  fi
}

open_url

if [[ "$MODE" == "pam" ]]; then
  exec apptainer exec \
    --no-mount cwd \
    --pwd "/home/$USER" \
    "${COMMON_BINDS[@]}" \
    "$SIF" "$RS_BIN" \
      --www-address=0.0.0.0 \
      --www-port "$PORT" \
      --auth-none=0 \
      --auth-pam-helper-path="$PAM_HELPER" \
      --server-user="$USER" \
      --server-daemonize=0
else
  exec apptainer exec \
    --no-mount cwd \
    --pwd "/home/$USER" \
    "${COMMON_BINDS[@]}" \
    "$SIF" "$RS_BIN" \
      --www-address=0.0.0.0 \
      --www-port "$PORT" \
      --auth-none=1 \
      --server-user="$USER" \
      --server-daemonize=0
fi