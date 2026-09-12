#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# SwiftPM nests its own sandbox, which fails when this script already runs inside
# one (for example from an agent or CI sandbox). Compiler caches also stay in the
# repo so a read-only home directory cannot break the manifest build.
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/swift-cache"
mkdir -p .build/module-cache "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox --scratch-path .build \
    --cache-path .build/cache \
    -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache"
APP="$PWD/build/Ajar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Ajar/Rendering/Shaders.metal "$APP/Contents/Resources/Shaders.metal"
cp .build/release/Ajar "$APP/Contents/MacOS/Ajar"
cp LICENSE NOTICE "$APP/Contents/Resources/"

# The icon is kept as one square PNG in Assets/ and turned into an .icns here,
# so the repository carries the artwork rather than ten copies of it. Skipped
# quietly when the artwork is absent: a build without an icon still runs.
ICON_SOURCE="$PWD/Assets/AppIcon.png"
ICON_OUTPUT="$APP/Contents/Resources/AppIcon.icns"
# Only when the artwork changed: rewriting the icns changes the app's contents,
# and with an ad-hoc signature that is enough to invalidate a permission grant.
if [ -f "$ICON_SOURCE" ] && { [ ! -f "$ICON_OUTPUT" ] || [ "$ICON_SOURCE" -nt "$ICON_OUTPUT" ]; }; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size*2)) $((size*2)) "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICON_OUTPUT"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ajar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>dev.kuang.ajar</string>
<key>CFBundleName</key><string>Ajar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSCameraUsageDescription</key><string>Ajar samples the built-in camera once, when you ask it to, to estimate where your eyes are relative to the screen. Nothing is recorded or sent anywhere.</string>
<key>NSScreenCaptureUsageDescription</key><string>Ajar captures the built-in display locally so it can redraw the picture with the lid-driven effect. Nothing is recorded or sent anywhere.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"

# SwiftPM bakes the directory it was built in into the module, as the fallback
# path for `Bundle.module`. The app never takes that fallback — `build.sh` puts
# Shaders.metal in the bundle, and the renderer asks Bundle.main first — but the
# string still names this machine and this checkout. Mask it at the same length
# so nothing downstream shifts, before the signature is taken.
python3 - "$APP/Contents/MacOS/Ajar" "$PWD" <<'PY'
import sys
binary, root = sys.argv[1], sys.argv[2].encode()
data = bytearray(open(binary, "rb").read())
masked = b"/" + bytes(c if c == ord("/") else ord("x") for c in root[1:])
path_characters = b"/._-"
starts, at = [], data.find(root)
while at != -1:
    starts.append(at)
    at = data.find(root, at + 1)
for start in starts:
    data[start:start+len(root)] = masked
    # The rest of the string goes with it: these are the SwiftPM resource
    # bundle path and the source paths Swift prints in a trap, and each one
    # spells out the build layout. Stop at a NUL or at anything that is not a
    # path character, so a string that is not NUL-terminated cannot bleed.
    at = start + len(root)
    while at < len(data):
        byte = data[at]
        is_path = byte in path_characters or 48 <= byte <= 57 or 65 <= byte <= 90 or 97 <= byte <= 122
        if not is_path: break
        if byte != ord("/"): data[at] = ord("x")
        at += 1
open(binary, "wb").write(bytes(data))
print("masked %d build path(s)" % len(starts))
PY
if strings -a "$APP/Contents/MacOS/Ajar" | grep -qF "$(dirname "$PWD")"; then
    echo "error: the checkout path is still in the shipped binary" >&2
    exit 1
fi

# Signing is not cosmetic here. macOS records the Screen Recording grant against
# the app's code signature, and an ad-hoc signature is a hash of the binary: every
# rebuild produces a new one, so a grant stops matching the app it was given to
# and the window silently loses the permission. A stable identity (Apple
# Development from Xcode, or Developer ID for distribution) gives a signature
# that survives rebuilds, and the grant survives with it.
# `|| true` because an empty result is the normal case, and `set -e` with
# `pipefail` would otherwise abort the script the moment grep matches nothing.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -Eo '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    cat >&2 <<'NOTE'
Signed ad-hoc: no Apple Development or Developer ID identity is in the keychain.
Screen Recording permission is recorded against that ad-hoc signature, which
changes on every build, so after rebuilding run:

    ./Scripts/reset-screen-permission.sh

and grant it again when Ajar asks. To stop doing that, add an Apple ID in Xcode
(Settings > Accounts > Manage Certificates > + Apple Development) and rebuild:
the grant then survives rebuilds.
NOTE
fi
printf '%s\n' "$APP"
