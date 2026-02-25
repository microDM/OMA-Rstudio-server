#!/usr/bin/env bash
# If not running under bash, re-exec with bash (arrays require bash)
if [ -z "${BASH_VERSINFO:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

set -euo pipefail

# -----------------------------------------------------------------------------
# RStudio Server launcher (Apptainer) — FIXED per-user port with collision-free
# allocation using atomic directory reservation (no shared lock file).
#
# Key behavior:
#   - Each USER gets a stable, unique port that does NOT change per session.
#   - First time a user runs this script, a port is allocated from 8800–8899
#     using atomic "mkdir" reservation (collision-free even under concurrency).
#   - The allocated port is saved to a per-user file and reused forever.
#   - If the saved port is in use, we fail fast (prevents landing on another session).
# -----------------------------------------------------------------------------

# --- Config ---------------------------------------------------------------
SIF="/media/volume/OMA_container/OMA-server/rstudio_server.sif"
MODE="${MODE:-single}"            # pam | single
SHARED_RO="${SHARED_RO:-/media/volume/project_2013220}"

# Per-user state + workspace (host paths)
: "${USER:=$(id -un)}"
WORK="$HOME/.local/share/rstudio-server"
USER_WS="${USER_WS:-/home/$USER}"

# RStudio Server binaries (inside the container)
RS_BIN="/usr/lib/rstudio-server/bin/rserver"
PAM_HELPER="/usr/lib/rstudio-server/bin/pam-helper"

# --- Port Allocation (stable per user, collision-free) ---------------------
PORT_MIN=8800
PORT_MAX=8899

# Persistent per-user port file
PORT_FILE="$WORK/conf/port"

# Shared port reservation registry (in /tmp)
PORT_REG_DIR="/tmp/rstudio-port-registry"

# Helper: check whether a port is free on localhost
is_port_free() {
  local p="$1"
  ! (echo >/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1
}

# Ensure registry exists and is usable by all users
ensure_port_registry() {
  # Create if missing
  if [[ ! -d "$PORT_REG_DIR" ]]; then
    mkdir -p "$PORT_REG_DIR" 2>/dev/null || true
  fi

  # Make it world-writable with sticky bit (like /tmp)
  # If we can't chmod (rare), we continue; allocation will fail with a clear message.
  chmod 1777 "$PORT_REG_DIR" 2>/dev/null || true

  if [[ ! -d "$PORT_REG_DIR" || ! -w "$PORT_REG_DIR" ]]; then
    echo "ERROR: Port registry directory is not writable: $PORT_REG_DIR" >&2
    echo "       Please ensure it exists and has permissions 1777." >&2
    exit 1
  fi
}

# Reserve a port atomically by mkdir. Returns 0 if reserved, 1 otherwise.
reserve_port() {
  local p="$1"
  local d="${PORT_REG_DIR}/${p}"

  # mkdir is atomic: only one user can create this directory.
  if mkdir "$d" 2>/dev/null; then
    # Record ownership info (best-effort; not required for locking correctness)
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

# Verify that the reserved port belongs to this user (best-effort safety)
reserved_by_me() {
  local p="$1"
  local owner_file="${PORT_REG_DIR}/${p}/owner"
  [[ -f "$owner_file" ]] && grep -q "^user=${USER}$" "$owner_file" 2>/dev/null
}

allocate_and_persist_port() {
  mkdir -p "$WORK/conf"

  # If PORT is explicitly set in environment, respect it and do NOT persist/reserve.
  if [[ -n "${PORT:-}" ]]; then
    return 0
  fi

  ensure_port_registry

  # If already assigned before, reuse it (stable across sessions)
  if [[ -f "$PORT_FILE" ]]; then
    PORT="$(cat "$PORT_FILE")"

    # Safety check: avoid landing on another user's active listener.
    if ! is_port_free "$PORT"; then
      echo "ERROR: Your assigned port $PORT (from $PORT_FILE) is already in use." >&2
      echo "       If this is your own running session, stop it first." >&2
      echo "       Otherwise contact admin to investigate the process using $PORT." >&2
      exit 1
    fi

    # Optional: ensure the reservation exists; if not, recreate it (best-effort).
    if [[ ! -d "${PORT_REG_DIR}/${PORT}" ]]; then
      reserve_port "$PORT" || true
    fi

    return 0
  fi

  # First-time user: allocate a new port safely.
  local p
  for p in $(seq "$PORT_MIN" "$PORT_MAX"); do
    # Only consider ports not currently listening
    if is_port_free "$p"; then
      # Atomically reserve it so no other user can take it at the same time
      if reserve_port "$p"; then
        PORT="$p"
        echo "$PORT" > "$PORT_FILE"
        chmod 600 "$PORT_FILE"
        break
      fi
    fi
  done

  if [[ -z "${PORT:-}" ]]; then
    echo "ERROR: No free ports available in range ${PORT_MIN}-${PORT_MAX}." >&2
    echo "       Increase the range or reduce concurrent sessions." >&2
    exit 1
  fi
}

# --- Prep ----------------------------------------------------------------
mkdir -p "$WORK"/{run,var-lib,tmp,conf} "$USER_WS"
if [[ ! -f "$WORK/conf/database.conf" ]]; then
  printf 'provider=sqlite\n' > "$WORK/conf/database.conf"
  chmod 600 "$WORK/conf/database.conf"
fi

# Allocate stable per-user PORT (unless PORT env var is set)
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

# Shared binds (host -> container)
COMMON_BINDS=( )
COMMON_BINDS+=( --bind "$WORK/run:/run" )                         # pid & sockets
COMMON_BINDS+=( --bind "$WORK/var-lib:/var/lib/rstudio-server" ) # state
COMMON_BINDS+=( --bind "$WORK/tmp:/tmp" )                         # temp dir
COMMON_BINDS+=( --bind "$WORK/conf/database.conf:/etc/rstudio/database.conf" )

# Per-user workspace
[[ -d "$USER_WS" ]] && COMMON_BINDS+=( --bind "$USER_WS:/home/$USER" )

# make sure some folder exists
mkdir -p "/media/volume/Workspaces/users/$USER"
mkdir -p "/media/volume/Exports/users/$USER"

# Workspace
if [[ -d "/media/volume/Workspaces/users/$USER" ]]; then
  COMMON_BINDS+=( --bind "/media/volume/Workspaces/users/$USER:/home/$USER/Workspace/" )
fi

# Exports
if [[ -d "/media/volume/Exports/users/$USER" ]]; then
  COMMON_BINDS+=( --bind "/media/volume/Exports/users/$USER:/home/$USER/Exports/" )
fi

# Shared project (read-only)
if [[ -d "/media/volume/project_2013220" ]]; then
  COMMON_BINDS+=( --bind "/media/volume/project_2013220/:/media/project_2013220/" )
fi

[[ -d "$SHARED_RO" ]] && COMMON_BINDS+=( --bind "$SHARED_RO:/home/$USER/shared_project:ro" )

# Identity DBs for username/group mapping (read-only)
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

if [[ "$MODE" == "pam" ]]; then
  open_url
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
  open_url
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