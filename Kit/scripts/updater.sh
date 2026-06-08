#!/bin/bash
set -eu

DMG_PATH="$HOME/Downloads/Stats.dmg"
MOUNT_PATH="/tmp/Stats"
APPLICATION_PATH="/Applications/"
LAUNCH_UID=""

STEP=""

while [[ "$#" -gt 0 ]]; do case "$1" in
  -s|--step) STEP="$2"; shift;;
  -d|--dmg) DMG_PATH="$2"; shift;;
  -a|--app) APPLICATION_PATH="$2"; shift;;
  -m|--mount) MOUNT_PATH="$2"; shift;;
  -u|--user) LAUNCH_UID="$2"; shift;;
  *) echo "Unknown parameter passed: $1"; exit 1;;
esac; shift; done

APP_DST="${APPLICATION_PATH%/}/Stats.app"
APP_SRC="${MOUNT_PATH%/}/Stats.app"

# When the script runs as root (admin auth path) but a target UID was passed,
# launch the new app back as the original user so it doesn't run as root.
launch_app() {
    if [[ -n "$LAUNCH_UID" && "$(id -u)" == "0" ]]; then
        /bin/launchctl asuser "$LAUNCH_UID" /usr/bin/sudo -u "#$LAUNCH_UID" "$@"
    else
        "$@"
    fi
}

# Replace the installed app with the one from the mounted DMG.
# Use `ditto` (not `cp -rf`) so the bundle's symlinks/extended attributes are
# preserved intact — `cp` can mangle them and break the code signature. Then
# strip the quarantine flag the DMG inherited from being downloaded, otherwise
# Gatekeeper reports the freshly-copied app as "damaged and can't be opened".
install_app() {
    rm -rf "$APP_DST"
    /usr/bin/ditto "$APP_SRC" "$APP_DST"
    /usr/bin/xattr -dr com.apple.quarantine "$APP_DST" 2>/dev/null || true
}

if [[ "$STEP" == "2" ]]; then
    install_app

    launch_app "$APP_DST/Contents/MacOS/Stats" --dmg "$DMG_PATH"

    echo "New version started"
elif [[ "$STEP" == "3" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_PATH"
    /bin/rm -rf "$MOUNT_PATH"
    /bin/rm -rf "$DMG_PATH"

    echo "Done"
else
    install_app

    launch_app "$APP_DST/Contents/MacOS/Stats" --dmg-path "$DMG_PATH" --mount-path "$MOUNT_PATH"

    echo "New version started"
fi
