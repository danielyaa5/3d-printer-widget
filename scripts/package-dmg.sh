#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
app="${1:?Pass a notarized Developer ID-signed app}"
output="${2:-$repo_root/build/Distribution.noindex/Print-Progress.dmg}"
app="$(cd "$app" && pwd -P)"
mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd -P)/$(basename "$output")"
work="$repo_root/build/DMGPackaging.noindex"
mkdir -p "$work"
codesign --verify --deep --strict "$app"
# A development signature can work locally but is not a usable public release.
spctl --assess --type execute "$app"
xcrun stapler validate "$app"
python3 - "$app" "$work/.print-progress-installer.json" <<'PY'
import json, plistlib, sys
from pathlib import Path
p = plistlib.load(open(Path(sys.argv[1]) / 'Contents/Info.plist', 'rb'))
Path(sys.argv[2]).write_text(json.dumps({'bundleID':p['CFBundleIdentifier'], 'version':p['CFBundleShortVersionString'], 'build':p['CFBundleVersion']}))
PY
swift "$repo_root/scripts/InstallerBackground.swift" "$work/background.png"
dmgbuild_command="${PRINT_DMGBUILD:-$repo_root/build/DMGTools.noindex/bin/dmgbuild}"
if [[ ! -x "$dmgbuild_command" ]]; then
    printf 'Install release/requirements-dmg.txt into build/DMGTools.noindex first.\n' >&2
    exit 1
fi
"$dmgbuild_command" -s "$repo_root/scripts/dmg-settings.py" \
    -D "app=$app" -D "marker=$work/.print-progress-installer.json" \
    -D "background=$work/background.png" 'Print Progress' "$output"
hdiutil verify "$output"
mount_plist="$work/verify-mount.plist"
hdiutil attach -nobrowse -readonly -plist "$output" > "$mount_plist"
mount_point="$(python3 - "$mount_plist" <<'PY'
import plistlib, sys
p=plistlib.load(open(sys.argv[1],'rb'))
print(next(x['mount-point'] for x in p['system-entities'] if 'mount-point' in x))
PY
)"
cleanup_verify_mount() { hdiutil detach "$mount_point" >/dev/null || true; }
trap cleanup_verify_mount EXIT
codesign --verify --deep --strict "$mount_point/Print Progress.app"
spctl --assess --type execute "$mount_point/Print Progress.app"
xcrun stapler validate "$mount_point/Print Progress.app"
hdiutil detach "$mount_point" >/dev/null
trap - EXIT
(cd "$(dirname "$output")" && shasum -a 256 "$(basename "$output")" > SHA256SUMS.txt)
printf 'Created %s\n' "$output"
