#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { printf 'Install ffmpeg first.\n' >&2; exit 1; }
xcodegen generate
xcodebuild -project PrintProgress.xcodeproj -scheme PrintProgressMedia \
  -destination 'platform=macOS' -derivedDataPath build/MediaBuild.noindex \
  CODE_SIGNING_ALLOWED=NO build > build/media-build.log 2>&1
build/MediaBuild.noindex/Build/Products/Debug/PrintProgressMedia
mkdir -p docs/media
cp build/Media.noindex/overview.png docs/media/overview.png
cp build/Media.noindex/menu-bar.png docs/media/menu-bar.png
cp build/Media.noindex/widget-small.png docs/media/widget-small.png
cp build/Media.noindex/widget-medium.png docs/media/widget-medium.png
ffmpeg -hide_banner -loglevel error -y -framerate 6 -i build/Media.noindex/frame-%03d.png \
  -vf 'scale=1100:700,fps=30' -c:v libx264 -crf 20 -pix_fmt yuv420p -movflags +faststart \
  docs/media/demo.mp4
ffmpeg -hide_banner -loglevel error -y -framerate 6 -i build/Media.noindex/frame-%03d.png \
  -filter_complex '[0:v]scale=880:-1,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a' \
  -loop 0 docs/media/demo.gif
printf 'Demo screenshots, GIF and MP4 saved in docs/media.\n'
