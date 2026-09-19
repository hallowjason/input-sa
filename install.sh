#!/bin/bash
# Verify a staged replacement before stopping the installed app; retain a backup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_APP="$SCRIPT_DIR/build/Input-sa.app"
INSTALL_DIR="$HOME/Applications"
SKIP_BUILD=0
LAUNCH=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --no-launch) LAUNCH=0; shift ;;
        --source) [ "$#" -ge 2 ] || exit 2; BUILD_APP="$2"; shift 2 ;;
        --install-dir) [ "$#" -ge 2 ] || exit 2; INSTALL_DIR="$2"; shift 2 ;;
        --help) echo "Usage: bash install.sh [--skip-build] [--no-launch] [--source APP] [--install-dir DIR]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
if [ "$SKIP_BUILD" = 0 ]; then bash "$SCRIPT_DIR/build.sh"; fi
[ -f "$BUILD_APP/Contents/MacOS/Input-sa" ] || { echo "Missing built app: $BUILD_APP" >&2; exit 1; }
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
DESTINATION="$INSTALL_DIR/Input-sa.app"
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.inputsa-install.XXXXXX")"
STAGED_APP="$STAGING_DIR/Input-sa.app"
BACKUP_DIR="$INSTALL_DIR/.inputsa-backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP_APP="$BACKUP_DIR/Input-sa.app"
OLD_MOVED=0
NEW_INSTALLED=0
FINISHED=0
cleanup() {
    if [ "$FINISHED" = 0 ]; then
        if [ "$NEW_INSTALLED" = 1 ] && [ -e "$DESTINATION" ]; then
            mv "$DESTINATION" "$STAGING_DIR/failed.app"
        fi
        if [ "$OLD_MOVED" = 1 ] && [ -e "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$DESTINATION"
            echo "Restored the previous installation: $DESTINATION" >&2
        fi
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
ditto "$BUILD_APP" "$STAGED_APP"
xattr -rd com.apple.quarantine "$STAGED_APP" 2>/dev/null || true
bash "$SCRIPT_DIR/tools/sign-app.sh" "$STAGED_APP"
if [ -e "$DESTINATION" ]; then
    previous_requirement=$(codesign -d -r- "$DESTINATION" 2>&1 | sed -n 's/^designated => //p')
    if [ -n "$previous_requirement" ]; then
        codesign --verify --strict --deep -R "=$previous_requirement" "$STAGED_APP"
    fi
fi
# Names only produce candidates: verify the full executable path before SIGTERM.
installed_executable="$DESTINATION/Contents/MacOS/Input-sa"
for pid in $(pgrep -x 'Input-sa' || true); do
    process_path=$(ps -ww -p "$pid" -o comm= 2>/dev/null || true)
    if [ "$process_path" = "$installed_executable" ]; then
        kill -TERM "$pid"
        attempts=0
        while [ "$attempts" -lt 50 ]; do
            process_path=$(ps -ww -p "$pid" -o comm= 2>/dev/null || true)
            [ "$process_path" = "$installed_executable" ] || break
            sleep 0.1
            attempts=$((attempts + 1))
        done
        if [ "$process_path" = "$installed_executable" ]; then
            echo "Installed Input-sa did not exit; its installation was preserved." >&2
            exit 1
        fi
    fi
done
if [ -e "$DESTINATION" ]; then
    mkdir -p "$BACKUP_DIR"
    mv "$DESTINATION" "$BACKUP_APP"
    OLD_MOVED=1
fi
mv "$STAGED_APP" "$DESTINATION"
NEW_INSTALLED=1
codesign --verify --deep --strict --verbose=2 "$DESTINATION"
if [ "$LAUNCH" = 1 ]; then
    if ! open "$DESTINATION"; then
        echo "Launch failed; rolling back the installation." >&2
        exit 1
    fi
fi
FINISHED=1
echo "Installed: $DESTINATION"
if [ "$OLD_MOVED" = 1 ]; then echo "Previous version retained: $BACKUP_APP"; fi
echo "Existing preferences, models, Keychain items, and privacy permissions were preserved."
