# Changelog

All notable changes to this project. Dates are release dates.

## v0.1.2 (unreleased)

### Fixed
- **A crash when the library could not be loaded.** If the request for the last-read chapters failed (for example
  right after the Wi-Fi woke up), the library loader returned no error message and the error dialog crashed
  KOReader (`attempt to concatenate local 'err' (a nil value)`, seen when going back to the library after the last
  chapter of a series). The real message is now passed on, and no error dialog can crash on a missing message.

Fixes the screen freezing for 10 to 40 seconds, often at the start of a new chapter, with nothing on screen. The
cause, found in a log from a real reading session: on PocketBook, waking the Wi-Fi up blocks the whole e-reader until
the connection is made (4 to 17 s measured), the e-reader turns its Wi-Fi off again within two minutes, so this
happened for almost every chapter; and a failed home test right after a wake-up could start the VPN tunnel, which
froze the screen for another 25 s.

### Changed
- **The Wi-Fi is woken up far less often.** Only when the chapters ready ahead run low (a third of the window or
  fewer), then the whole window is filled in one go. The default window grows from 3 to 6 chapters
  (`prefetch_ahead`). If the Wi-Fi is already on, the window is filled whatever its state.
- **A message explains the wait** ("Connecting to Wi-Fi to fetch the next chapters…") before the call that blocks.
- **Background checks never start the VPN tunnel**, and never wake the Wi-Fi up: a failed download is retried
  quietly, and a route that does not answer is checked again 10 s later. The checks of the server's downloads come
  after 10 s, then 20 s, then every 30 s.
- **The e-reader's connection is read with a cheap test** (`isConnected`) instead of `isOnline`, which also resolves
  a host name and blocks the screen when the DNS is slow.
- **Saving the reading progress at the end of a chapter** gives up after 3 s instead of 10 s when the Wi-Fi is half
  asleep (the progress is kept and sent later).
- Pending progress no longer wakes the Wi-Fi up by itself: it is sent when the Wi-Fi is on anyway, or when the
  library opens.
- **Away from home, the VPN tunnel starts when you need it**, with a message on screen: when the library opens, and
  when loading a series or downloading a chapter fails (the route is chosen again before the second try). Once open,
  the tunnel stays up and the background prefetching uses it, even if the Wi-Fi network changed.

### Added (VPN add-on)
- **The home network is recognised by its router** (address and hardware address read from the kernel, learned the
  first time the server is reached directly). On it the tunnel is never used, on any other network the home test is
  skipped. The diagnostic shows the router and the remembered home router.
- **The cost of the tunnel is measured**: the diagnostic, and the log line written when the tunnel stops, show how
  long it ran and the CPU time and memory it used.
- Tests for all of it (`prefetch_test.lua`, `vpn_route_test.lua`).

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
