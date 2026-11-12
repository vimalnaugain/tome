#!/bin/sh
# KPM launch hook (`kpm launch tome`), used by the library item and KUAL.
# Runs Tome detached, so the launcher that started us can return at once.
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export TOME_HOME="${TOME_HOME:-${KINDLE_ROOT:-/mnt/us}/tome}"
mkdir -p "${TOME_HOME}"
cd "${SELF_DIR}" || exit 1
nohup /bin/sh "${SELF_DIR}/tome.sh" "$@" >> "${TOME_HOME}/crash.log" 2>&1 &
