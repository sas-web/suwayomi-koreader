# Tests

Three standalone Lua scripts, run with the LuaJIT shipped with KOReader. They need no device and no Suwayomi
server: every dependency (network, scheduler, file system, server) is replaced by a stand-in.

| Script | Checks |
| --- | --- |
| `prefetch_test.lua` | Prefetching: chaining, Wi-Fi wake-up, retries, pending progress sent when the Wi-Fi is on |
| `vpn_route_test.lua` | VPN add-on: home / tunnel route choice, tunnel reuse, profile handling |
| `i18n_test.lua` | Language selection, English fallback, every text has a French entry with the same `%` markers |

## Running them

You need a KOReader installation or build that contains its `luajit` and `setupkoenv.lua` (a Linux desktop build,
or the emulator build). From KOReader's base folder, with the plugin installed under `plugins/suwayomi.koplugin`
**and the VPN add-on's `suwayomi_vpn.lua` copied next to `main.lua`**:

```
./luajit /path/to/tests/prefetch_test.lua
./luajit /path/to/tests/vpn_route_test.lua
./luajit /path/to/tests/i18n_test.lua
```

Each script prints `OK` / `FAIL` per check and exits with a non-zero status if anything fails. They were written
and run inside a Docker container with an x86-64 KOReader build; any environment that provides KOReader's LuaJIT
works.

`i18n_test.lua` also reads the plugin's sources, so it fails when a text is added to the code without a French
translation (or the other way round): update `suwayomi_lang_fr.lua` together with the code.
