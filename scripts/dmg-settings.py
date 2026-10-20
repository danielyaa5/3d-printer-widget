"""dmgbuild layout. All build/signing inputs are passed by the release script."""
from pathlib import Path

app = Path(defines['app'])
files = [str(app), defines['marker']]
symlinks = {'Applications': '/Applications'}
hide = ['.print-progress-installer.json']
# FinderInfo on the signed .app makes codesign --strict reject the payload.
# Keep the bundle untouched; Finder already treats it as an application.
hide_extensions = []
icon_locations = {'Print Progress.app': (175, 210), 'Applications': (505, 210)}
window_rect = ((200, 120), (680, 430))
icon_size = 106
text_size = 14
background = defines['background']
icon = str(app / 'Contents/Resources/AppIcon.icns')
format = 'UDZO'
filesystem = 'HFS+'
show_status_bar = False
show_toolbar = False
show_sidebar = False
include_icon_view_settings = True
include_list_view_settings = False
