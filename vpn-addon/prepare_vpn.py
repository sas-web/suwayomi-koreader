"""
Prepares the WireGuard tunnel of the e-reader (to reach Suwayomi away from home).

From a WireGuard profile exported by your router or VPN server (one profile per device), this script writes
into KOReader's data folder, in a `suwayomi_vpn` sub-folder:
  - wireproxy       the program (the build matching the e-reader's CPU, e.g. linux arm), copied from --wireproxy;
  - wireproxy.conf  your profile + a [TCPClientTunnel] block that connects a local port of the e-reader
                    (127.0.0.1:4567) to the Suwayomi server at home, through the tunnel.

The profile contains a private key: this script never prints it and never copies it anywhere but the destination
you give.

Usage:
    python prepare_vpn.py profile.conf --server 192.168.1.10:4567 --koreader-dir E:\\applications\\koreader
    python prepare_vpn.py profile.conf --server nas.lan:4567 --output some_folder      # write elsewhere (tests)

Where is KOReader's data folder? It is the folder that contains `settings/` and `plugins/` once KOReader has run
(PocketBook: <storage>/applications/koreader, Kobo: .adds/koreader, Kindle: koreader, Android: see KOReader's
"About" dialog).
"""
import argparse
import ipaddress
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def parse_sections(text):
    """[(section_name, [lines]), ...] in order; lines before the first section are ignored."""
    sections, current = [], None
    for line in text.splitlines():
        m = re.match(r"^\s*\[(.+?)\]\s*$", line)
        if m:
            current = (m.group(1).strip(), [])
            sections.append(current)
        elif current is not None:
            current[1].append(line)
    return sections


def values(lines, key):
    out = []
    for line in lines:
        m = re.match(r"^\s*" + re.escape(key) + r"\s*=\s*(.*?)\s*(?:#.*)?$", line, re.I)
        if m:
            out.append(m.group(1))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("profile", help="WireGuard .conf file exported by your router / VPN server")
    ap.add_argument("--server", required=True,
                    help="address of Suwayomi on your home network, as host:port (e.g. 192.168.1.10:4567)")
    ap.add_argument("--koreader-dir", help="KOReader's data folder on the e-reader (see above)")
    ap.add_argument("--output", help="output folder (instead of <koreader-dir>/suwayomi_vpn)")
    ap.add_argument("--local-port", type=int, default=4567, help="local port of the tunnel on the e-reader (default 4567)")
    ap.add_argument("--wireproxy", default=str(HERE / "wireproxy"),
                    help="the wireproxy program for the e-reader's CPU (default: ./wireproxy, next to this script)")
    args = ap.parse_args()
    if not args.koreader_dir and not args.output:
        sys.exit("Give either --koreader-dir (the e-reader's KOReader folder) or --output.")

    raw = Path(args.profile).read_text(encoding="utf-8-sig")
    sections = parse_sections(raw)
    names = [n.lower() for n, _ in sections]
    problems = []
    if "interface" not in names:
        problems.append("no [Interface] section")
    if "peer" not in names:
        problems.append("no [Peer] section")
    iface = next((lines for n, lines in sections if n.lower() == "interface"), [])
    peers = [lines for n, lines in sections if n.lower() == "peer"]
    if not values(iface, "PrivateKey"):
        problems.append("[Interface] without PrivateKey")
    if not values(iface, "Address"):
        problems.append("[Interface] without Address")
    for i, peer in enumerate(peers, 1):
        if not values(peer, "PublicKey"):
            problems.append(f"[Peer] #{i} without PublicKey")
        if not values(peer, "Endpoint"):
            problems.append(f"[Peer] #{i} without Endpoint (address of your router / VPN server)")
    if problems:
        sys.exit("Unusable profile: " + "; ".join(problems))

    host, _, port = args.server.rpartition(":")
    if not host or not port.isdigit():
        sys.exit("--server must look like host:port, for example 192.168.1.10:4567")

    # The traffic to the server must go through the tunnel: its address must be covered by AllowedIPs.
    warning = None
    try:
        target_ip = ipaddress.ip_address(host)
        covered = False
        for peer in peers:
            for entry in ",".join(values(peer, "AllowedIPs")).split(","):
                entry = entry.strip()
                if entry and target_ip in ipaddress.ip_network(entry, strict=False):
                    covered = True
        if not covered:
            warning = f"AllowedIPs does not cover {host}: the tunnel would not reach the server."
    except ValueError:
        pass  # a machine name: cannot be checked

    # The original profile without any previous tunnel, then the [TCPClientTunnel] block
    kept = []
    for name, lines in sections:
        if name.lower() == "tcpclienttunnel":
            continue
        kept.append(f"[{name}]")
        kept.extend(line.rstrip() for line in lines)
    while kept and not kept[-1].strip():
        kept.pop()
    kept += ["", "[TCPClientTunnel]", f"BindAddress = 127.0.0.1:{args.local_port}", f"Target = {host}:{port}", ""]
    conf = "\n".join(kept)  # Unix line endings: the e-reader runs Linux

    if args.output:
        dest = Path(args.output)
    else:
        base = Path(args.koreader_dir)
        if not base.is_dir():
            sys.exit(f"KOReader folder not found: {base} (is the e-reader connected?)")
        dest = base / "suwayomi_vpn"

    binary = Path(args.wireproxy)
    if not binary.is_file():
        sys.exit(f"wireproxy program not found: {binary} (see vpn-addon/README.md for where to download it)")
    if binary.read_bytes()[:4] != b"\x7fELF":
        sys.exit(f"{binary} is not a Linux executable (did you copy the .tar.gz archive instead of the extracted program?)")

    dest.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(binary, dest / "wireproxy")
    (dest / "wireproxy.conf").write_bytes(conf.encode("ascii", "replace"))

    print("Profile checked (private key present, not displayed).")
    print(f"  peers: {len(peers)}; tunnel: 127.0.0.1:{args.local_port} -> {host}:{port}")
    if warning:
        print("  WARNING:", warning)
    print(f"Written to {dest}: wireproxy ({(dest / 'wireproxy').stat().st_size // 1024} KB) and wireproxy.conf")
    print("Eject the e-reader, copy suwayomi_vpn.lua next to the plugin's main.lua, restart KOReader.")


if __name__ == "__main__":
    main()
