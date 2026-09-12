#!/bin/bash
# Clears Ajar's Screen Recording record so the next launch asks again.
#
# Why this is needed: macOS stores the grant against the app's code signature.
# A build signed ad-hoc gets a new signature every time the binary changes, so
# after a rebuild the recorded grant belongs to a signature that no longer
# exists: System Settings still lists the app, often with the switch on, while
# the running app is refused. Removing the stale record lets the prompt appear
# again. Signing with a stable identity (see Scripts/build.sh) avoids the churn
# altogether.
set -euo pipefail

BUNDLE_ID="dev.kuang.ajar"

if ! command -v tccutil >/dev/null; then
    echo "tccutil not found" >&2
    exit 1
fi

tccutil reset ScreenCapture "$BUNDLE_ID"
cat <<'NOTE'

Done. Now:
  1. Quit Ajar if it is running (menu bar item > Quit Ajar).
  2. Open it again: open build/Ajar.app
  3. Right click the menu bar icon to turn the effect on — macOS will ask for
     Screen Recording. Grant it, then use "Quit and reopen Ajar" in the setup
     window, because a grant does not apply to a process that is already running.
NOTE
