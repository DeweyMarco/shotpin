# ShotPin

macOS shows a screenshot thumbnail in the bottom-right corner for about five seconds and
then it's gone. ShotPin replaces that thumbnail with one that stays put until you delete
it, and keeps the pending screenshot out of your normal save location.

Your capture keys don't change. ⌘⇧3, ⌘⇧4 and ⌘⇧5 keep the native macOS capture and
selection UI. While ShotPin is running, macOS writes captures into ShotPin's private
temporary workspace instead of the Desktop, and ShotPin restores your previous screenshot
location when it quits.

```
┌───────────────────────┐
│                       │   click  → open in the default app
│      screenshot       │   drag   → drop repeatedly into apps or Finder
│                       │   hover  → ✕ to delete
└───────────────────────┘   right-click → open, copy, reveal, delete, dismiss all
        bottom-right, no timer
```

ShotPin's thumbnails are excluded from screen capture, so pinned screenshots don't
appear inside later screenshots.

## Why not just use the built-in preference

macOS has an undocumented key that extends the native thumbnail's lifetime:

```bash
defaults write com.apple.screencaptureui thumbnailExpiration -float 600
killall screencaptureui
```

That works (verified on macOS 26.6), and if a longer-but-still-temporary thumbnail is all
you want, use it instead of this — no third-party code in your login items.

ShotPin preserves that temporary behavior for as long as you want. The screenshot is
backed by a file in a private temporary workspace so drag and drop works reliably across
apps, but it never appears in the Desktop or your configured screenshot folder. Clicking
the pin's ✕ deletes it immediately, and quitting ShotPin deletes every pending capture.

Compared to the full CleanShot X alternatives ([Capso](https://github.com/lzhgus/Capso),
[BetterShot](https://github.com/KartikLabhshetwar/better-shot),
[ScreenCap](https://github.com/8tp/ScreenCap), and others), which also pin but replace
the whole capture pipeline with their own hotkeys, editor and file handling, ShotPin does
one thing and leaves the native flow alone.

## Interactions

- **Click** the pin: opens the temporary file in its default app and keeps the pin.
- **Drag** the pin: drops the image into Slack, Messages, a browser, or another app and
  keeps the pin, so the same capture can be dragged more than once. Dropping into Finder
  creates a normal permanent copy there.
- **Hover** the pin: an ✕ appears in the top-left corner; click it to permanently delete
  the temporary screenshot and remove the pin.
- **Right-click**: Open, Copy Image, Reveal in Finder, Delete Screenshot, Dismiss,
  Dismiss All, Quit ShotPin.

Nothing dismisses itself on a timer. Several screenshots in a row stack upward from the
corner, oldest at the bottom, and pile up in place once the column runs out of room. Pins
float above other windows and follow you across Spaces and full-screen apps, but don't
appear in screenshots.

## Temporary capture storage

At launch, ShotPin remembers `com.apple.screencapture location`, redirects screenshots to
a private per-run directory, and watches that directory for new captures. A normal quit
restores the previous location and deletes the directory. If ShotPin was interrupted, its
next launch restores the saved setting and removes the stale workspace before starting a
new session. Screen recordings aren't pinned; when ShotPin exits, it moves them to the
original screenshot location instead of deleting them with the pending screenshots.

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

macOS posts a one-time notice that ShotPin can run in the background. The binary is ad-hoc
signed, not notarized, because it never leaves your machine.

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
