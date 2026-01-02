#!/usr/bin/env bash
# Run an R script inside the same Apptainer SIF with the same user binds as the rserver launcher.
# Usage:
#   ./apptainer_r_run.sh path/to/script.R [-- arg1 arg2 ...]
#   ./apptainer_r_run.sh --expr 'print(sessionInfo())'
#   ./apptainer_r_run.sh -- Rscript -e 'print("hi")'   # run any command inside container

if [ -z "${BASH_VERSINFO:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set -euo pipefail

SIF="/media/volume/OMA_container/OMA-rserver/rstudio_server.sif"
SHARED_RO="${SHARED_RO:-/media/volume/project_2013220}"

: "${USER:=$(id -un)}"
WORK="$HOME/.local/share/rstudio-server"
USER_WS="${USER_WS:-/home/$USER}"

# Container defaults
R_BIN_DEFAULT="Rscript"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$SIF" ]] || die "SIF not found: $SIF"

# --- Prep (matches your rserver launcher layout) ---
mkdir -p "$WORK"/{run,var-lib,tmp,conf} "$USER_WS"
if [[ ! -f "$WORK/conf/database.conf" ]]; then
  printf 'provider=sqlite\n' > "$WORK/conf/database.conf"
  chmod 600 "$WORK/conf/database.conf"
fi

# make sure some folder exists (same as your launcher)
mkdir -p "/media/volume/Workspaces/users/$USER"
mkdir -p "/media/volume/Exports/users/$USER"

# --- Binds (same idea as rserver launcher) ---
COMMON_BINDS=( )
COMMON_BINDS+=( --bind "$WORK/run:/run" )
COMMON_BINDS+=( --bind "$WORK/var-lib:/var/lib/rstudio-server" )
COMMON_BINDS+=( --bind "$WORK/tmp:/tmp" )
COMMON_BINDS+=( --bind "$WORK/conf/database.conf:/etc/rstudio/database.conf" )

[[ -d "$USER_WS" ]] && COMMON_BINDS+=( --bind "$USER_WS:/home/$USER" )

if [[ -d "/media/volume/Workspaces/users/$USER" ]]; then
  COMMON_BINDS+=( --bind "/media/volume/Workspaces/users/$USER:/home/$USER/Workspace/" )
fi

if [[ -d "/media/volume/Exports/users/$USER" ]]; then
  COMMON_BINDS+=( --bind "/media/volume/Exports/users/$USER:/home/$USER/Exports/" )
fi

if [[ -d "/media/volume/project_2013220" ]]; then
  COMMON_BINDS+=( --bind "/media/volume/project_2013220/:/media/project_2013220/" )
fi

[[ -d "$SHARED_RO" ]] && COMMON_BINDS+=( --bind "$SHARED_RO:/home/$USER/shared_project:ro" )

COMMON_BINDS+=( --bind /etc/passwd:/etc/passwd:ro --bind /etc/group:/etc/group:ro )

# --- Run modes ---
# 1) --expr '...'
if [[ "${1:-}" == "--expr" ]]; then
  shift
  [[ $# -ge 1 ]] || die "Missing expression after --expr"
  EXPR="$1"; shift || true
  exec apptainer exec \
    --no-mount cwd \
    --pwd "/home/$USER" \
    "${COMMON_BINDS[@]}" \
    "$SIF" "$R_BIN_DEFAULT" -e "$EXPR" "$@"
fi

# 2) -- <any command...>   (advanced escape hatch)
if [[ "${1:-}" == "--" ]]; then
  shift
  [[ $# -ge 1 ]] || die "Missing command after --"
  exec apptainer exec \
    --no-mount cwd \
    --pwd "/home/$USER" \
    "${COMMON_BINDS[@]}" \
    "$SIF" "$@"
fi

# 3) script.R [-- args...]
SCRIPT="${1:-}"
[[ -n "$SCRIPT" ]] || die "Usage: $0 script.R [-- arg1 arg2 ...] | --expr '...' | -- <cmd...>"

shift || true

# Pass args to the R script (optional separator)
# - if user includes --, drop it (common convention)
if [[ "${1:-}" == "--" ]]; then shift; fi

# Make script path available inside container:
# - If script is under /home/$USER or /media/... it will already be visible via binds above.
# - Otherwise bind the script's directory to /tmp/rscript_mount and run from there.
SCRIPT_ABS="$(readlink -f "$SCRIPT" 2>/dev/null || echo "$SCRIPT")"
if apptainer exec "$SIF" test -e "$SCRIPT_ABS" >/dev/null 2>&1; then
  # already visible (rarely true)
  SCRIPT_IN="$SCRIPT_ABS"
else
  HOST_DIR="$(cd "$(dirname "$SCRIPT_ABS")" && pwd)"
  BASENAME="$(basename "$SCRIPT_ABS")"
  COMMON_BINDS+=( --bind "$HOST_DIR:/tmp/rscript_mount:ro" )
  SCRIPT_IN="/tmp/rscript_mount/$BASENAME"
fi

exec apptainer exec \
  --no-mount cwd \
  --pwd "/home/$USER" \
  "${COMMON_BINDS[@]}" \
  "$SIF" "$R_BIN_DEFAULT" "$SCRIPT_IN" "$@"
