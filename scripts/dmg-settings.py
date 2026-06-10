# dmgbuild settings for the Seminarly installer window.
# Invoked by package-app.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=<App.app> -D bg=<background.png> "Seminarly" out.dmg
import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "UDZO"                       # compressed, read-only
files = [application]
symlinks = {"Applications": "/Applications"}

background = defines["bg"]
window_rect = ((300, 200), (660, 400))  # (position), (width, height)
default_view = "icon-view"
icon_size = 128
text_size = 13

# Top-left origin, y increases downward — app on the left, Applications on the right,
# lined up with the arrow baked into the background.
icon_locations = {
    appname: (180, 200),
    "Applications": (480, 200),
}
