#!/bin/sh
# Tome launcher for jailbroken Kindles (FW 5.x). Started from the library
# item (KPM install) or KUAL. Pauses the Kindle UI, runs Tome, restores the UI.
#
#   tome.sh                    pause the status bar / window manager only
#   tome.sh --framework_stop   stop the whole Kindle framework (more RAM, slower exit)
#
# Updates: any tome*.kpkg found in $TOME_HOME/update (copied over USB, or
# downloaded by Settings > Check for updates) is installed before Tome starts.
# Tome exits with code 85 to ask for "apply update and restart".

# Run from a copy in /tmp, so an update can replace this file safely.
if [ -z "${TOME_RUNNING_COPY}" ]; then
    TOME_DIR="$(cd "$(dirname "$0")" && pwd)"
    export TOME_DIR
    export TOME_RUNNING_COPY=1
    cp "$0" /tmp/tome-launcher.sh && exec /bin/sh /tmp/tome-launcher.sh "$@"
fi

# Settings, keys and reading data. Defaults to the app folder (USB install);
# the KPM package sets TOME_HOME=/mnt/us/tome so upgrades never touch it.
TOME_HOME="${TOME_HOME:-${TOME_DIR}}"
UPDATE_DIR="${TOME_HOME}/update"
mkdir -p "${TOME_HOME}" "${UPDATE_DIR}"
LOG="${TOME_HOME}/crash.log"
STOP_FRAMEWORK="no"
[ "$1" = "--framework_stop" ] && STOP_FRAMEWORK="yes"

log() { echo "$(date '+%H:%M:%S') tome.sh: $*" >> "${LOG}"; }
say() { eips 1 38 "$1                                   " >/dev/null 2>&1; }

# Install the newest update package in UPDATE_DIR, if any. Settings, keys
# and books live elsewhere and are not touched.
apply_update() {
    for PKG in $(ls -t "${UPDATE_DIR}"/tome*.kpkg 2>/dev/null); do
        if install_package "${PKG}"; then
            rm -f "${UPDATE_DIR}"/tome*.kpkg
            return 0
        fi
    done
    return 1
}

install_package() {
    PKG="$1"
    log "applying update ${PKG}"
    say "Updating Tome..."
    WORK="/tmp/tome-update.$$"
    rm -rf "${WORK}" && mkdir -p "${WORK}"
    if tar -xzf "${PKG}" -C "${WORK}" 2>>"${LOG}" \
        && grep -q '"id": *"tome"' "${WORK}/manifest.json" 2>/dev/null \
        && [ -f "${WORK}/tome-luajit" ] && [ -f "${WORK}/main.lua" ]; then
        cp -rf "${WORK}/." "${TOME_DIR}/" \
            && chmod 755 "${TOME_DIR}/tome-luajit" "${TOME_DIR}"/*.sh 2>/dev/null
        # KPM install: refresh the library item, icon and KUAL entry too
        case "${TOME_DIR}" in
            */kmc/kpm/packages/*) (cd "${TOME_DIR}" && sh ./install.sh upgrade >> "${LOG}" 2>&1) ;;
        esac
        VERSION="$(tr -d '\n' < "${WORK}/VERSION" 2>/dev/null)"
        log "updated to ${VERSION}"
        say "Tome updated to ${VERSION}"
        rm -rf "${WORK}"
        return 0
    fi
    log "update package ${PKG} is not valid; moved aside"
    say "Update failed: not a Tome package"
    mv -f "${PKG}" "${PKG}.invalid"
    rm -rf "${WORK}"
    return 1
}

apply_update

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

while true; do
    cd "${TOME_DIR}" || exit 1
    log "starting"
    ./tome-luajit main.lua --kindle --home "${TOME_HOME}" >> "${LOG}" 2>&1
    RC=$?
    log "exited with ${RC}"
    # 85: Tome downloaded an update and asked to restart into it
    [ "${RC}" = "85" ] && apply_update && continue
    break
done

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
