# Changelog

All notable changes to this project. Dates are release dates.

## v0.1.1 (2026-11-03)

Opening a chapter that the Suwayomi server had not downloaded used to fail with an error (the server answers
HTTP 400 for such chapters). The plugin can now ask the server to download it.

### Added
- **Chapters the server lacks are requested from it.** The chapter goes to the front of the server's download
  queue, the server's download manager is started if it was stopped, and the plugin shows the progress and opens
  the chapter when it is ready. A tap on the message cancels the wait; the server carries on by itself.
- **The prefetcher does the same quietly** for the next chapters of its window: one grouped request for the missing
  ones, then it fetches the chapters that are ready and checks again every 30 seconds (at most 20 times per
  chapter read). It never wakes the Wi-Fi up just for that.
- A gear-menu line and the `server_download` setting turn the feature off. With it off, the plugin behaves as in
  v0.1.0.
- `suwayomi_serverdl.lua` (the waiting logic, testable without a server), `tests/serverdl_test.lua` and new
  prefetching scenarios in `tests/prefetch_test.lua`.

### Changed
- README: describes the new feature, and states that this build was also tried on the author's e-reader
  (PocketBook InkPad X, KOReader v2026.07.2) with a real Suwayomi server.

### How it was checked
Unit tests (prefetching, waiting for the server, VPN route choice, translations), the KOReader emulator against a
fake server (on demand, prefetching, cancelling, setting off), the exact GraphQL queries against a real Suwayomi
v2.4.2366 server (read-only), then a real run on the e-reader. The plugin zip attached to the release is
byte-identical, file by file, to what was run there. Other devices and other Suwayomi versions are not covered.

## v0.1.0 (2026-10-26)

First public release: library mosaic (or list) with categories and unread badges, series screen with *Resume*,
chapters downloaded as CBZ and opened in KOReader's own reader, chapter chaining, background prefetching (waking
the Wi-Fi up if the e-reader turned it off), reading progress kept in sync with Suwayomi (and kept on the device
while offline), long-press actions on chapters, gesture actions, English and French interface, an optional WireGuard
VPN add-on, and standalone tests.

`suwayomi_reader.lua` is adapted from `MangaReader.lua` of [Rakuyomi](https://github.com/hanatsumi/rakuyomi), so the
whole project is distributed under the AGPL-3.0.
