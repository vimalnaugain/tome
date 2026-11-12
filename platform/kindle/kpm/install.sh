#!/bin/sh
# KPM install hook. KPM has unpacked Tome into its package folder
# (/mnt/us/kmc/kpm/packages/tome) and runs this from there.
#   - adds a "Tome" item to the Kindle library (a scriptlet) to launch it
#   - adds a KUAL menu entry too, if KUAL is installed
#   - creates /mnt/us/tome for settings, keys and reading data (kept on upgrade)
set -eu
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT="${KINDLE_ROOT:-/mnt/us}"
HOME_DIR="${ROOT}/tome"

if [ ! -d "${ROOT}/documents" ]; then
    echo "The Kindle documents folder is not available" >&2
    exit 1
fi

chmod 755 "${SELF_DIR}/tome-luajit" "${SELF_DIR}/tome.sh" "${SELF_DIR}/launch.sh" "${SELF_DIR}/uninstall.sh"

mkdir -p "${HOME_DIR}"
cp -f "${SELF_DIR}/config.example.lua" "${HOME_DIR}/config.example.lua"
if [ ! -f "${HOME_DIR}/config.lua" ]; then
    cp "${SELF_DIR}/config.example.lua" "${HOME_DIR}/config.lua"
    echo "Created ${HOME_DIR}/config.lua - add your recap provider there."
fi

cp -f "${SELF_DIR}/assets/tome-icon.png" "${ROOT}/tome-icon.png"
cp -f "${SELF_DIR}/scriptlet/tome.sh" "${ROOT}/documents/Tome.sh"
chmod 755 "${ROOT}/documents/Tome.sh"

if [ -d "${ROOT}/extensions" ]; then
    mkdir -p "${ROOT}/extensions/tome"
    cp -f "${SELF_DIR}/kual/config.xml" "${SELF_DIR}/kual/menu.json" "${ROOT}/extensions/tome/"
fi

if [ "${1:-}" = "upgrade" ]; then
    echo "Tome upgraded. Your settings and books are unchanged."
else
    echo "Tome installed. Open 'Tome' from your Kindle library."
fi
