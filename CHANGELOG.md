# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2026-11-28

Mission Control labels now stay correct on Spaces Bars with many desktops, where macOS magnifies thumbnails under the pointer.

✨ Added
- Labels on magnifying Spaces Bars — names appear under the hovered thumbnail, and follow it as thumbnails resize under the pointer.
- Caption looks and magnification settings are remembered between launches — the first Mission Control session after a launch is labelled from the first frame.
- Labels for desktops you never named in the spaces' colours style — every desktop now gets one.
- Clicking off the bars to close Mission Control now slides the labels up in step with the bar.

🔧 Changed
- Labels ride the bar's grow from names to thumbnails in step with macOS's own captions.
- Native-look labels no longer borrow a caption look captured at another bar height — this avoids mismatched text size and plate colour.
- Labels follow the dragged thumbnail and desktop add/remove more reliably, including for unlabelled desktops and repeated titles.
- Label windows are prepared when Mission Control starts, so labels reach the screen on time.

🐛 Fixed
- Fixed a deadlock that could hang the app when preferences changed while space names were being saved.
- Labels no longer appear off-position when a screen was captured while the bar was still moving.
- Mission Control now reopens with the bar of names, not the last grown thumbnails.
- Captions are re-read after switching to a space with a different wallpaper.

## [2.0.0] - 2026-11-25

Initial release.
