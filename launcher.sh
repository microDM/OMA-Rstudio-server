#!/usr/bin/env bash
# If not running under bash, re-exec with bash (arrays require bash)
if [ -z "${BASH_VERSINFO:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

set -euo pipefail

# --- Config ---------------------------------------------------------------
pick_port() { for p in $(seq 8800 8899); do (echo >/dev/tcp/127.0.0.1/$p) >/dev/null 2>&1 || { echo "$p"; return; }; done; }
SIF="/media/volume/OMA_container/OMA-server/rstudio_server.sif"
PORT="${PORT:-$(pick_port)}"
MODE="${MODE:-single}"            # pam | single
SHARED_RO="${SHARED_RO:-/media/volume/project_2013220}"

# Per-user state + workspace (host paths)
: "${USER:=$(id -un)}"
WORK="$HOME/.local/share/rstudio-server"
USER_WS="${USER_WS:-/home/$USER}"

# RStudio Server binaries (inside the container)
RS_BIN="/usr/lib/rstudio-server/bin/rserver"
PAM_HELPER="/usr/lib/rstudio-server/bin/pam-helper"

# --- Prep ----------------------------------------------------------------
mkdir -p "$WORK"/{run,var-lib,tmp,conf} "$USER_WS"
if [[ ! -f "$WORK/conf/database.conf" ]]; then
  printf 'provider=sqlite\n' > "$WORK/conf/database.conf"
  chmod 600 "$WORK/conf/database.conf"
fi

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
if [[ "$MODE" == "pam" ]]; then
  # --- open browser on the picked port (non-blocking) ---
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
  # PAM login (unprivileged -> effectively only current user); for real multi-user you need root.
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

  # Single-user, no login page
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
