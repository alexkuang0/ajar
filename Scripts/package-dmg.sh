#!/bin/bash
# Builds build/Ajar.dmg: the app plus a shortcut to /Applications, so installing
# is drag-and-drop. A DMG is used rather than a PKG because Ajar installs
# nothing outside its own bundle — no launch daemons, no receipts, no privileged
# steps — and a DMG can be opened and inspected without running an installer.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build.sh >/dev/null

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Ajar.app/Contents/Info.plist)
STAGE="build/dmg"
DMG="build/Ajar-$VERSION.dmg"

# A run that failed before its detach leaves this volume mounted, and Finder's
# `tell disk` would then decorate the leftover instead of the image just built —
# which is exactly how the window settings went missing once. Clear the way
# first, and take the volume down again however this run ends.
VOLUME="Ajar $VERSION"
mount | sed -n 's/^\([^ ]*\) on \(.*\) ([^)]*)$/\1|\2/p' | while IFS='|' read -r device point; do
    if [ "${point##*/}" = "$VOLUME" ]; then hdiutil detach "$device" >/dev/null 2>&1 || true; fi
done

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R build/Ajar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# The volume name is what the user sees in Finder; the file name carries the
# version so several builds can sit side by side.
#
# Built in the temporary directory rather than in the checkout: Finder records
# the path of the image it is showing inside the volume's .DS_Store, and a path
# under the checkout would ship the user name and the directory layout.
RW="${TMPDIR:-/tmp}/Ajar-rw.dmg"
ICNS="build/Ajar.app/Contents/Resources/AppIcon.icns"
# The picture behind the two icons, in Assets/, at 2× the window. Finder draws
# the background at its own pixel size rather than scaling it to the window, so
# what goes into the volume is a 1× copy at exactly the window's content size,
# with the artwork beside it as the @2× variant that makes it sharp on a retina
# display. The two slots in the artwork are 140 pt squares centred on (216, 234)
# and (551, 234) of that 768×512 content area, which is where the icons go.
BACKGROUND="Assets/DMGBackground.png"
WINDOW_WIDTH=768
WINDOW_HEIGHT=512
TITLE_BAR=28          # the only part of the window's bounds that is not content
ICON_SIZE=128
APP_ICON_AT="216, 234"
APPLICATIONS_ICON_AT="551, 234"
# Sized with room to spare: the background picture and .DS_Store are written
# after creation, so an image sized to the staged folder alone runs out of room.
# A UDZO conversion only stores what is used, so the slack costs nothing.
hdiutil create -volname "Ajar $VERSION" -srcfolder "$STAGE" -fs HFS+ \
    -size 24m -format UDRW -ov "$RW" >/dev/null
# Mounted at its own name, which is what Finder stores as the picture's
# location: /Volumes/Ajar 1.0 is where the volume lands on every other machine
# too, so the background resolves there and names nothing of this one. Built
# read-write because the window's settings and the volume icon are written into
# it below; `SetFile -a C` is what tells Finder the volume has a custom icon,
# and without the Xcode command line tools it is simply built without one.
MOUNT="/Volumes/$VOLUME"
hdiutil attach -readwrite -noverify -noautofsck "$RW" >/dev/null
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT
if [ ! -d "$MOUNT/Ajar.app" ]; then
    echo "error: $RW did not mount at $MOUNT" >&2
    exit 1
fi
# What the window looks like when someone opens it: the background picture, the
# icon size, and where the two icons sit. Finder keeps all of that in the
# volume's .DS_Store, which is why it has to be written onto the mounted
# read-write image rather than into the staged folder. The slots in
# Assets/DMGBackground.png are 140 pt squares centred on (216, 234) and
# (551, 234) of a 768×512 content area; the title bar is the only part of the
# bounds that is not content, hence 512 + 28.
if [ -f "$BACKGROUND" ]; then
    mkdir -p "$MOUNT/.background"
    cp "$BACKGROUND" "$MOUNT/.background/Background@2x.png"
    sips -z "$WINDOW_HEIGHT" "$WINDOW_WIDTH" "$BACKGROUND" \
        --out "$MOUNT/.background/Background.png" >/dev/null
    # Finder learns about a new volume asynchronously, and a script that runs too
    # early gets "can't get disk" rather than a window.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if osascript -e "tell application \"Finder\" to exists disk \"$VOLUME\"" | grep -q true; then break; fi
        sleep 0.5
    done
    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 160, $((200+WINDOW_WIDTH)), $((160+WINDOW_HEIGHT+TITLE_BAR))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:Background.png"
        set position of item "Ajar.app" of container window to {$APP_ICON_AT}
        set position of item "Applications" of container window to {$APPLICATIONS_ICON_AT}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
    # Finder writes the .DS_Store that holds all of the above lazily, so a
    # fixed sleep is a race: wait for the file itself, and complain rather than
    # quietly shipping a plain window if it never turns up.
    written=no
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        [ -f "$MOUNT/.DS_Store" ] && { written=yes; break; }
        sleep 0.5
    done
    [ "$written" = yes ] || echo "warning: Finder did not write .DS_Store; the window has no background or icon positions" >&2
    # The .DS_Store is a Finder file about this machine as much as about the
    # volume: if any path from here survives in it, the image would ship the
    # user name and checkout layout along with the app.
    if [ "$written" = yes ] && strings -a "$MOUNT/.DS_Store" | grep -qF "$HOME"; then
        echo "error: .DS_Store still names $HOME" >&2
        exit 1
    fi
else
    echo "note: no $BACKGROUND, building a plain drag-and-drop image" >&2
fi
# The volume icon is written last on purpose. Finder rewrites the icon of a
# volume whose custom-icon bit is set as it opens the window, and a file written
# before that step does not survive it — measured: present after `cp`, gone
# after the Finder script, and untouched when the order is reversed.
if [ -f "$ICNS" ]; then
    cp "$ICNS" "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT" 2>/dev/null || echo "note: SetFile unavailable, volume icon skipped" >&2
fi
sync
# macOS writes its event log into .fseventsd on any volume it mounts
# read-write. It is not part of the app, and a read-only image cannot grow it
# again, so it goes before the image is compressed.
rm -rf "$MOUNT/.fseventsd"
hdiutil detach "$MOUNT" >/dev/null
trap - EXIT
hdiutil convert "$RW" -format UDZO -o "$DMG" -ov >/dev/null
rm -f "$RW"

echo "$PWD/$DMG"
echo
echo "Unsigned local build: on another Mac, Gatekeeper will say it cannot be"
echo "opened. Right click the app and choose Open once, or sign and notarise it"
echo "with a Developer ID before handing it out."
