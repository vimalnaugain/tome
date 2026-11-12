#!/bin/sh
# KPM uninstall hook: remove what install.sh added. Settings, API keys and
# reading data in /mnt/us/tome are kept; delete that folder to remove them.
ROOT="${KINDLE_ROOT:-/mnt/us}"
SCRIPTLET="${ROOT}/documents/Tome.sh"
if [ -f "${SCRIPTLET}" ] && grep -q '^# tome-managed-scriptlet-v1$' "${SCRIPTLET}"; then
    rm -f "${SCRIPTLET}"
fi
rm -f "${ROOT}/tome-icon.png"
if [ -f "${ROOT}/extensions/tome/menu.json" ] && grep -q 'packages/tome/launch.sh' "${ROOT}/extensions/tome/menu.json"; then
    rm -rf "${ROOT}/extensions/tome"
fi
echo "Tome removed. Your settings and reading data are still in ${ROOT}/tome."
