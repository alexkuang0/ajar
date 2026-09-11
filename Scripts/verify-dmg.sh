#!/bin/bash
# Checks that the built disk image is only the app and the things the window
# needs: no Markdown, no sources beyond the shader the app compiles at runtime,
# no logs or caches, and nothing that names this machine or this checkout.
#
#   ./Scripts/verify-dmg.sh [path/to/Ajar-1.0.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-build/Ajar-1.0.dmg}"
[ -f "$DMG" ] || { echo "no such image: $DMG" >&2; exit 1; }

MOUNT="$(mktemp -d)/Ajar 1.0"
mkdir -p "$MOUNT"
hdiutil attach -readonly -noverify -noautofsck -mountpoint "$MOUNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT

status=0
note() { printf '%s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; status=1; }

note "contents"
find "$MOUNT" -mindepth 1 | sed "s|$MOUNT|<dmg>|" | sort | sed 's/^/  /'

note "app bundle"
for expected in Contents/Info.plist Contents/MacOS/Ajar Contents/Resources/AppIcon.icns \
                Contents/Resources/Shaders.metal Contents/_CodeSignature/CodeResources; do
    [ -e "$MOUNT/Ajar.app/$expected" ] || fail "missing Ajar.app/$expected"
done
for unexpected in Contents/Resources/Ajar_Ajar.bundle Contents/Resources/*.dSYM Contents/Resources/*.md; do
    case "$unexpected" in
        *\**) [ -e "$MOUNT/Ajar.app/$unexpected" ] && fail "unexpected Ajar.app/$unexpected" ;;
        *)    [ -e "$MOUNT/Ajar.app/$unexpected" ] && fail "unexpected Ajar.app/$unexpected" ;;
    esac
done

note "files that are not part of a shipped app"
found="$(find "$MOUNT" \( -name '*.md' -o -name '*.csv' -o -name '*.log' -o -name '*.dSYM' \
        -o -name '.git*' -o -name '*.xcuserstate' \) -print | sed "s|$MOUNT|<dmg>|" || true)"
found="$found$(find "$MOUNT" -name '*.swift' -print | sed "s|$MOUNT|<dmg>|" || true)"
if [ -n "$found" ]; then
    printf '%s\n' "$found" | sed 's/^/  /'
    fail "the image carries files that are not part of the app"
else
    note "  none"
fi

note "development traces in the contents"
traces="$(find "$MOUNT" -type f -exec strings -a {} \; 2>/dev/null \
          | grep -iE "(${HOME//\//\\/}|Users/|/Hobby/|\.build/)" || true)"
if [ -n "$traces" ]; then
    printf '%s\n' "$traces" | sort -u | head -20 | sed 's/^/  /'
    fail "the image names this machine or checkout"
else
    note "  none"
fi

note "signature"
if codesign --verify --strict "$MOUNT/Ajar.app" 2>/dev/null; then
    note "  Ajar.app verifies"
else
    fail "Ajar.app does not verify"
fi

note "volume icon"
case "$(GetFileInfo -a "$MOUNT" 2>/dev/null || echo)" in
    *C*) note "  .VolumeIcon.icns is marked as the volume's own" ;;
    *)   fail "the custom-icon flag is not set, so Finder will ignore .VolumeIcon.icns" ;;
esac

echo
[ "$status" = 0 ] && echo "ok: $DMG is only the app and its window" || echo "problems found in $DMG"
exit "$status"
