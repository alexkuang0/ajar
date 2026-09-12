# Ajar

Ajar makes the MacBook screen behave like a pane that stays where it was put. Move the lid and the picture frosts and holds the pose it had when the movement started; hold the lid still and it catches up and sharpens over a couple of seconds. What you see tilting is the angle you actually turned the lid through.

It lives in the menu bar and draws on the built-in display. Nothing is recorded and nothing is sent anywhere.

## Install

1. Open **Ajar-1.0.dmg** and drag **Ajar** onto the **Applications** shortcut.
2. Open Ajar from Applications. macOS refuses it the first time, because the build is not notarised: **right-click the app and choose Open**, then confirm.
3. Ajar shows a short checklist — the lid angle sensor, the built-in display, Screen Recording permission, and optionally the camera. The first three are required, and each row tells you what is missing and takes you to it.

There is no Dock icon; Ajar appears in the menu bar.

## Using it

- **Left-click the menu bar icon** for the menu: turn the effect on or off, open Settings, run setup again, quit. When something is missing, the menu says what.
- **Right-click (or Control-click) the icon** to toggle the effect without opening the menu.
- The effect is **on by default** once setup is finished, and it remembers whichever way you leave it.
- While the effect is up it covers the whole panel — menu bar and Dock included — and your Mac stays usable underneath, clicks and all.
- **Settings (⌘,)** holds the camera position: how far back and how high you sit, which decides how much of the picture's height survives a tilt. **Detect where I'm sitting** measures it for you — about a second of the built-in camera, with a preview of the frames it is looking at, nothing recorded — and you can still drag the dot afterwards.
- Move the lid the way you normally would. Opening and closing it gently is all the effect needs.

## What you need

- **macOS 14 or later.**
- **A MacBook with the lid angle sensor**: MacBook Pro 16-inch (2019), MacBook Pro 14/16-inch (2021 and later), MacBook Air M2 (2022) and later. Setup says plainly if yours does not answer.
- **The built-in display in use.** If it goes away — clamshell with an external monitor — the effect turns itself off and tells you so in a notification.
- **Screen Recording permission**, because the effect draws the screen back over itself.

## When something is not right

| What you see | What it means |
| --- | --- |
| The menu bar icon is greyed out | The effect is off. Left-click for the reason if you did not turn it off yourself. |
| "Waiting for the hinge…" | The sensor is not answering. Open and close the lid once, and try again. |
| Nothing happens when you move the lid | The built-in display has to be the screen in use, and the effect has to be on. |
| The picture stops catching up | Move the lid a little and let go: it sharpens about two seconds after the lid stops. |
| macOS asks for Screen Recording again after an update | Each build has its own identity, so the permission has to be granted again. |
| The effect turned itself off with a notification | The built-in display went away. Plug nothing in and reopen the lid; it comes back if you had it on. |

## Limits

- **Not notarised**, which is why the first launch needs a right-click. There is no Developer ID signature behind this build.
- Version 1.0 is an experiment, not a product: no auto-update, no App Store build, and the menus and settings are still moving.
- The effect is for the built-in display only.

## License

Ajar is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE). Noncommercial use, modification, and distribution are permitted under its terms. Commercial use requires a separate written license from Ning Kuang.

## Building it yourself

`Scripts/build.sh` builds the app, `Scripts/package-dmg.sh` builds the disk image, `Scripts/verify-dmg.sh` checks that the image contains nothing but the app, and `swift test` runs the tests.
