#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_app="${1:-$repo_root/build/Mac.noindex/Build/Products/Debug/Print Progress.app}"
target_app="${2:-/Applications/Print Progress.app}"
target_parent="$(cd "$(dirname "$target_app")" && pwd -P)"
target_app="$target_parent/$(basename "$target_app")"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
plistbuddy="/usr/libexec/PlistBuddy"

if [[ ! -f "$source_app/Contents/MacOS/Print Progress" ]]; then
    printf 'Build the PrintProgressMac scheme before installing.\n' >&2
    exit 1
fi
source_app="$(cd "$source_app" && pwd -P)"
if [[ "$source_app" == "$target_app" ]]; then
    printf 'Pass the built app, rather than the installed copy.\n' >&2
    exit 1
fi
source_id="$("$plistbuddy" -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")"
if [[ -d "$target_app" ]]; then
    target_id="$("$plistbuddy" -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")"
    if [[ "$source_id" != "$target_id" ]]; then
        printf 'The installed app has a different bundle identifier; installation stopped.\n' >&2
        exit 1
    fi
fi
codesign --verify --deep --strict "$source_app"

# Stage a complete bundle. Merging with ditto can retain old signed resources
# when switching between Debug and Release, invalidating the widget signature.
install_stage="$(mktemp -d "$target_parent/.PrintProgress-install.XXXXXX")"
cleanup_install() {
    if [[ ! -d "$target_app" && -d "$install_stage/previous.app" ]]; then
        mv "$install_stage/previous.app" "$target_app"
    fi
    rm -rf -- "$install_stage"
}
trap cleanup_install EXIT
ditto "$source_app" "$install_stage/current.app"
codesign --verify --deep --strict "$install_stage/current.app"
killall 'Print Progress' 2>/dev/null || true
if [[ -d "$target_app" ]]; then mv "$target_app" "$install_stage/previous.app"; fi
mv "$install_stage/current.app" "$target_app"
codesign --verify --deep --strict "$target_app"
# ditto can preserve the old bundle date. Icon Services uses it to invalidate
# cached artwork, so replacing AppIcon.icns alone can leave the old Dock icon.
touch "$target_app"
"$lsregister" -f "$target_app"

source_widget="$source_app/Contents/PlugIns/Print Progress Widget.appex"
if [[ -d "$source_widget" ]]; then
    pluginkit -r "$source_widget" 2>/dev/null || true
fi
"$lsregister" -u "$source_app" 2>/dev/null || true

# Remove generated bundle copies so only the installation appears in Spotlight.
if [[ "$source_app" == "$repo_root"/build/*.noindex/*/Print\ Progress.app ]]; then
    source_products="$(dirname "$source_app")"
    rm -rf -- "$source_app" "$source_products/Print Progress Widget.appex"
fi
pluginkit -a "$target_app/Contents/PlugIns/Print Progress Widget.appex"
killall 'Print Progress Widget' chronod NotificationCenter Dock 2>/dev/null || true
open -a "$target_app"
codesign --verify --deep --strict "$target_app"
version="$("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$target_app/Contents/Info.plist")"
printf 'Installed Print Progress %s, refreshed its Dock icon, and reopened the app.\n' "$version"
