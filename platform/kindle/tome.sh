#!/bin/sh
# Tome launcher for jailbroken Kindles (FW 5.x). Installed as /mnt/us/tome/tome.sh
# and started from KUAL. Pauses the Kindle UI, runs Tome, then restores the UI.
#
#   tome.sh                    pause the status bar / window manager only
#   tome.sh --framework_stop   stop the whole Kindle framework (more RAM, slower exit)

TOME_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="${TOME_DIR}/crash.log"
STOP_FRAMEWORK="no"
[ "$1" = "--framework_stop" ] && STOP_FRAMEWORK="yes"

log() { echo "$(date '+%H:%M:%S') tome.sh: $*" >> "${LOG}"; }

# Upstart (most FW 5.x devices) or SysV (Kindle Touch / early FW)?
if [ -e /sbin/initctl ] || [ -e /etc/upstart ]; then INIT=upstart; else INIT=sysv; fi

AWESOME_STOPPED=no
PILLOW_DISABLED=no
if [ "${STOP_FRAMEWORK}" = "yes" ]; then
    log "stopping framework"
    if [ "${INIT}" = "upstart" ]; then
        trap "" TERM            # stopping lab126_gui also signals KUAL's children
        stop lab126_gui
        usleep 1250000
        trap - TERM
    else
        /etc/init.d/framework stop
    fi
else
    if [ "${INIT}" = "upstart" ]; then
        # Hide the status bar and freeze the window manager so the clock
        # doesn't draw over our pages.
        lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null && PILLOW_DISABLED=yes
        if killall -STOP awesome 2>/dev/null; then AWESOME_STOPPED=yes; fi
        # Tome lets the window manager run while asleep on Kindles with ads
        export AWESOME_STOPPED
    else
        killall -STOP cvm 2>/dev/null
    fi
fi

# Keep the device from mounting USB storage under us.
killall -STOP volumd 2>/dev/null && VOLUMD_STOPPED=yes

cd "${TOME_DIR}" || exit 1
log "starting"
./tome main.lua --kindle >> "${LOG}" 2>&1
RC=$?
log "exited with ${RC}"

[ "${VOLUMD_STOPPED}" = "yes" ] && killall -CONT volumd 2>/dev/null

if [ "${STOP_FRAMEWORK}" = "yes" ]; then
    log "restarting framework"
    if [ "${INIT}" = "upstart" ]; then cd / && start lab126_gui; else cd / && /etc/init.d/framework start; fi
else
    if [ "${INIT}" = "upstart" ]; then
        [ "${AWESOME_STOPPED}" = "yes" ] && killall -CONT awesome 2>/dev/null
        if [ "${PILLOW_DISABLED}" = "yes" ]; then
            lipc-set-prop com.lab126.pillow disableEnablePillow enable
        fi
        # Bring the home screen back and repaint it.
        lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home
    else
        killall -CONT cvm 2>/dev/null
        eips -c
    fi
fi
exit ${RC}
