# ShotPin

macOS shows a screenshot thumbnail in the bottom-right corner for about five seconds and
then it's gone. ShotPin replaces that thumbnail with one that stays put until you
actually do something with it.

Your capture keys don't change. ⌘⇧3, ⌘⇧4 and ⌘⇧5 keep working exactly as they do now,
files keep landing in the same folder with the same names, and ShotPin never touches the
capture itself. It watches the screenshot folder and pins whatever appears.

```
┌───────────────────────┐
│                       │   click  → open in the default app
│      screenshot       │   drag   → drop the file into any app
│                       │   hover  → ✕ to dismiss
└───────────────────────┘   right-click → open, copy, reveal, trash, dismiss all
        bottom-right, no timer
```

## Why not just use the built-in preference

macOS has an undocumented key that extends the native thumbnail's lifetime:

```bash
defaults write com.apple.screencaptureui thumbnailExpiration -float 600
killall screencaptureui
```

That works (verified on macOS 26.6), and if a longer-but-still-temporary thumbnail is all
you want, use it instead of this — no third-party code in your login items.

There's a catch that pushed me to write ShotPin: **while the native thumbnail is on
screen, the screenshot does not exist on disk yet.** macOS only writes the file once the
thumbnail expires or you dismiss it. Set the expiration to an hour and every screenshot
sitting in your corner is unsaved; kill `screencaptureui`, log out, or reboot and it's
gone. I tested exactly that, and the pending capture was lost.

ShotPin works the other way around. The file is written first, by the normal macOS path,
and the pin is just a view onto a file that already exists safely on disk. Dismissing a
pin never destroys anything except the pin.

Compared to the full CleanShot X alternatives ([Capso](https://github.com/lzhgus/Capso),
[BetterShot](https://github.com/KartikLabhshetwar/better-shot),
[ScreenCap](https://github.com/8tp/ScreenCap), and others), which also pin but replace
the whole capture pipeline with their own hotkeys, editor and file handling, ShotPin does
one thing and leaves the native flow alone.

## Interactions

- **Click** the pin: opens the file in its default app, then the pin clears.
- **Drag** the pin: drags the real file into Slack, Notion, a browser, a Finder window.
  The pin clears once the drop lands.
- **Hover** the pin: an ✕ appears in the top-left corner.
- **Right-click**: Open, Copy Image, Reveal in Finder, Move to Trash, Dismiss,
  Dismiss All, Quit ShotPin.

Nothing dismisses itself on a timer. Several screenshots in a row stack upward from the
corner, oldest at the bottom, and pile up in place once the column runs out of room. Pins
float above other windows and follow you across Spaces and full-screen apps.

## What gets pinned

The watched folder is whatever `com.apple.screencapture location` points at, falling back
to `~/Desktop`. A new image file is pinned when Spotlight marks it
`kMDItemIsScreenCapture`, so an image you save from a browser to the Desktop is ignored.
If Spotlight metadata is delayed or unavailable, ShotPin only falls back to fresh files
whose names match macOS' generated screenshot naming convention. Arbitrarily named
`screencapture` CLI output may therefore be skipped. Screen recordings are skipped.

## Install

Requires macOS 13 or later and the Xcode command line tools (`xcode-select --install`)
for `swiftc`.

```bash
git clone https://github.com/DeweyMarco/shotpin.git
cd shotpin
./install.sh
```

That compiles `ShotPin.app` into `~/Applications`, turns off the native thumbnail
(`com.apple.screencapture show-thumbnail`, since it would fight for the same corner and
delay the file write), and loads a LaunchAgent so ShotPin runs at login. Choosing Quit
stops ShotPin for the rest of the login session; it starts again at the next login or
when you run the `kickstart` command below.

Two prompts to expect on first run: macOS asks whether ShotPin may access your Desktop
folder, and it posts a notice that ShotPin can run in the background. Both are one-time.
The binary is ad-hoc signed, not notarized, because it never leaves your machine.

## Manage

```bash
launchctl kickstart -k gui/$UID/com.shotpin.agent   # restart, also clears all pins
launchctl bootout gui/$UID/com.shotpin.agent        # stop until next login
rm ~/Library/LaunchAgents/com.shotpin.agent.plist   # stop for good
defaults write com.apple.screencapture show-thumbnail -bool true   # restore native thumbnail
```

Logs are at `/tmp/shotpin.out.log` and `/tmp/shotpin.err.log`. After editing
`Sources/main.swift`, run `./build.sh` and then the `kickstart` line.

## Tuning

The constants at the top of `Sources/main.swift`: `maxDimension` (220pt thumbnail),
`screenMargin` (18pt from the screen edges), `stackSpacing`, `corner` radius.

## License

MIT
