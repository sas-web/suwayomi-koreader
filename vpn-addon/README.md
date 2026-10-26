# VPN add-on: Suwayomi away from home

Optional add-on for the Suwayomi plugin. When the e-reader is not on your home network (for instance on a
phone's hotspot, whose VPN is not shared with the e-reader), the plugin can start its own WireGuard tunnel to
your home network with [`wireproxy`](https://github.com/windtf/wireproxy): a small WireGuard client that needs no
root access and no network interface, and opens a local port connected to your server through the tunnel.

The plugin works without this add-on. It is only useful if your Suwayomi server is reachable from the internet
through a WireGuard server that you run (a router with a WireGuard/VPN server, a Raspberry Pi, a NAS...).

## What you need

- A WireGuard server on your home network, and a **new profile (`.conf`) for the e-reader**. One profile serves one
  device at a time: do not reuse your phone's. The file contains a private key: share it with nobody and keep it
  out of version control.
- The `wireproxy` program built for your e-reader's CPU (most e-readers are 32-bit ARM: `linux_arm`). It is a
  separate project with its own license and is **not included** here. Download the release archive from its
  [releases page](https://github.com/windtf/wireproxy/releases), extract the `wireproxy` executable, and check the
  license in its repository before redistributing it. Version tested: v1.1.3, `wireproxy_linux_arm.tar.gz`
  (SHA-256 of the archive: `19bbc5571f8f7a00e35f6f0d653201f25de2ce1a25659e4a45fb9e00929c954c`, matching the
  release's `checksums.txt`).
- Python 3 on your computer, for `prepare_vpn.py`.

## Installation (once)

1. Put the extracted `wireproxy` executable next to `prepare_vpn.py` (or point to it with `--wireproxy`).
2. Connect the e-reader to your computer and run:

   ```
   python prepare_vpn.py profile.conf --server 192.168.1.10:4567 --koreader-dir E:\applications\koreader
   ```

   `--server` is the address of Suwayomi **on your home network**; `--koreader-dir` is KOReader's data folder
   on the e-reader (the one that contains `settings/` and `plugins/`). The script checks the profile, copies
   `wireproxy` and writes `wireproxy.conf` into a `suwayomi_vpn` sub-folder (the private key is never displayed).
   It warns you if the profile's `AllowedIPs` does not cover the server's address.
3. Copy `suwayomi_vpn.lua` (this folder) next to `main.lua` inside the plugin's folder
   (`plugins/suwayomi.koplugin/`), then restart KOReader.
4. In the gear menu of the library, the line **"VPN away from home"** should now say "on".

## How it works

- When the library opens, the plugin looks at the e-reader's address. If it is in the same /24 network as the
  server (e.g. 192.168.1.x), it tests Suwayomi at its home address (3 s at most); if it answers, nothing else
  happens (and a tunnel left over is stopped). In another network it skips that test and goes straight to the
  tunnel.
- It then starts the tunnel (a second or two, up to ten the first time) and talks to Suwayomi through
  `127.0.0.1:4567`. While the network does not change and the tunnel answers, the next openings reuse it without
  any other test. If the tunnel fails, the home address is still tried before giving up.
- The tunnel is stopped when KOReader closes. Its log is `suwayomi_vpn/wireproxy.log`.
- It can be turned off from the same gear menu line, and "Network diagnostic (VPN)" reports the e-reader's
  interfaces and addresses.

## PocketBook: the loopback interface

The tunnel opens a port on the e-reader's `127.0.0.1`. PocketBook's firmware never brings that interface (`lo`)
up, but its `/etc/sudoers` lets the applications run `/sbin/ifconfig` as root without a password, so the add-on
brings it up itself with `/ebrmain/bin/sudo -n /sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up` before starting
the tunnel (checked on firmware 6.5.2920; the diagnostic shows what happens on yours). On other e-readers the
loopback is already up and that command is never run.

## Troubleshooting

- "The VPN tunnel does not answer": the Wi-Fi network blocks UDP, the profile is wrong, or your home server is not
  reachable from that network. Test the profile first with the WireGuard app on a phone.
- "The wireproxy program does not start": read `suwayomi_vpn/wireproxy.log` on the e-reader (over USB). Make sure
  the program matches the e-reader's CPU architecture.
- Several tunnels: `wireproxy.conf` can hold several `[TCPClientTunnel]` blocks; the add-on picks the one whose
  `Target` has the server's port, and adds a block for a new target by itself when needed.
