# Spaceman

A macOS menu bar app that shows your Spaces, lets you name them, and puts those names on the Spaces Bar in
Mission Control in place of "Desktop 1", "Desktop 2" and so on.

This is a private fork of [ruittenb/Spaceman](https://github.com/ruittenb/Spaceman), reshaped for one Mac. It
needs macOS 26 or later.

## What it does

- **Menu bar icon.** One box per space, showing its number or name, with the current space marked.
- **Names and colours.** Name and colour each space in Preferences → Spaces, or rename the current one with a
  shortcut. The names survive reboots, reordering in Mission Control, and displays coming and going.
- **Mission Control labels.** Each thumbnail on the Spaces Bar shows its space's name, drawn to match the
  native caption and following the bar as it opens, closes, expands on hover and reorders under a drag. How
  the labels work, and the approaches ruled out, is in [README-Mission-Control-Labels.md](README-Mission-Control-Labels.md).
- **Switching.** Click a space in the menu or menu bar, or use the shortcuts, to switch smoothly, fast or
  instantly.

## Setup

Spaceman needs these, all in System Settings → Privacy & Security:

1. **Accessibility** (Device Control and Data Access on macOS 27): for switching spaces and reading the Spaces
   Bar.
2. **Screen & System Audio Recording:** for drawing the labels to match the native captions.
3. **Automation:** for switching spaces through System Events.

Switching to a space by number also needs its shortcut turned on in System Settings → Keyboard → Keyboard
Shortcuts → Mission Control: "Switch to Desktop N" for each space, and "Move left/right a space".

## Scripting

Spaceman answers AppleScript, so other tools can read and switch spaces:

```sh
osascript -e 'tell application "Spaceman" to get current space name'
osascript -e 'tell application "Spaceman" to get space names'
osascript -e 'tell application "Spaceman" to switch to space "Mail"'
osascript -e 'tell application "Spaceman" to switch to space 3 using instant'
osascript -e 'tell application "Spaceman" to switch back'
```

The full dictionary is in `Spaceman/Scriptable.sdef`: `refresh`, `open preferences`, `switch to space` (by
number or name, optionally `on display` and `using`), `switch left/right/up/down/back`, and the properties
`current space number`, `current space name`, `current display number`, `display count` and `space names`.

## Building

Open `Spaceman.xcodeproj` in Xcode and run the Spaceman scheme, or run the tests from the command line:

```sh
xcodebuild test -project Spaceman.xcodeproj -scheme Spaceman -destination platform=macOS
```

The app uses private CoreGraphics and SkyLight calls, so it can't be sandboxed or shipped through the App
Store.

## Credits

Spaceman was written by [Sasindu Jayasinghe](https://github.com/Jaysce/Spaceman) and
[René Uittenbogaard](https://github.com/ruittenb/Spaceman), with contributions from many others, and is based
on [WhichSpace](https://github.com/gechr/WhichSpace). Its instant switching uses code from
[iss](https://github.com/joshuarli/iss) and [FasterSwiper](https://github.com/mgbowen/FasterSwiper). It uses
[LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin) and
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts). MIT licensed; see [LICENSE](LICENSE).
