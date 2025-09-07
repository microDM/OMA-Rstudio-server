#!/usr/bin/env bash
set -euo pipefail

SIF="${SIF:-$PWD/rstudio_server.sif}"
PORT="${PORT:-8787}"
MODE="${MODE:-pam}"          # pam | single
SHARED_RO="${SHARED_RO:-/media/volume/project_2013220}"

# Per-user state + workspace
WORK="$HOME/.local/share/rstudio-server"
USER_WS="/home/dattatray/Desktop/temp_OMA/$USER"

mkdir -p "$WORK"/{run,var-lib,conf} "$USER_WS"
if [[ ! -f "$WORK/conf/database.conf" ]]; then
  printf 'provider=sqlite\n' > "$WORK/conf/database.conf"
  chmod 600 "$WORK/conf/database.conf"
fi

echo "RStudio Server launcher"
echo "  SIF:        $SIF"
echo "  MODE:       $MODE"
echo "  PORT:       $PORT"
echo "  WORKSPACE:  $USER_WS"
[[ -d "$SHARED_RO" ]] && echo "  SHARED_RO:  $SHARED_RO (mounted read-only)"

COMMON_BINDS=(
  --bind "$WORK/run:/run"
  --bind "$WORK/var-lib:/var/lib/rstudio-server"
  --bind "$WORK/conf/database.conf:/etc/rstudio/database.conf"
  --bind "$USER_WS:/home/$USER"
)
[[ -d "$SHARED_RO" ]] && COMMON_BINDS+=( --bind "$SHARED_RO:/home/dattatray/Desktop/temp_OMA/shared_project:ro" )

if [[ "$MODE" == "pam" ]]; then
  # Try PAM login (may not work without sudo on some systems)
  apptainer exec \
    "${COMMON_BINDS[@]}" \
    --bind /etc/passwd:/etc/passwd:ro \
    --bind /etc/group:/etc/group:ro \
    "$SIF" rserver \
      --server-user "$USER" \
      --www-address=0.0.0.0 \
      --www-port "$PORT" \
      --auth-none=0 \
      --server-daemonize=0
else
  # Single-user, no login page
  apptainer exec \
    "${COMMON_BINDS[@]}" \
    "$SIF" rserver \
      --server-user "$USER" \
      --auth-none=1 \
      --www-address=0.0.0.0 \
      --www-port "$PORT" \
      --server-daemonize=0
fi
