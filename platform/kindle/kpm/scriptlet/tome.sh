#!/bin/sh
# Name: Tome
# Author: Tome
# Icon: /mnt/us/tome-icon.png
# tome-managed-scriptlet-v1
# Opens the Tome reader (installed with KPM). Starts Tome's launch script
# directly rather than via `kpm launch`, so KPM's banner isn't shown.
LAUNCH=/mnt/us/kmc/kpm/packages/tome/launch.sh
if [ -f "${LAUNCH}" ]; then
    exec /bin/sh "${LAUNCH}" >/dev/null 2>&1
fi
exec /var/local/kmc/bin/kpm launch tome
