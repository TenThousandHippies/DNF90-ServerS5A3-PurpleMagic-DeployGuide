#!/usr/bin/env python3
"""Apply the local deployment patches to freshly cloned ServerS5A3 / PurpleMagic.

Why this exists: the no-domain (IP) deployment needs three small upstream changes
(GOPROXY for builds, a LAN-visible bootstrap port, and IP-aware certificate
checks).  A fresh `git clone` does not have them, so run this after every pull:

    python3 apply-local-patches.py --server /srv/dnf/ServerS5A3 \
                                   --purplemagic /srv/dnf/PurpleMagic

Idempotent: already-patched files are left alone.  `--check` only reports.
Exit code 0 = all patches present, 1 = something is missing or an anchor moved.
"""
import argparse
import sys
from pathlib import Path

RESULTS = []


def patch(path: Path, name: str, old: str, new: str, marker: str, check_only: bool):
    if not path.is_file():
        RESULTS.append((False, name, f"missing file: {path}"))
        return
    text = path.read_text(encoding="utf-8")
    if marker in text:
        RESULTS.append((True, name, "already patched"))
        return
    if old not in text:
        RESULTS.append((False, name, "anchor not found (upstream changed?)"))
        return
    if check_only:
        RESULTS.append((False, name, "missing"))
        return
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    RESULTS.append((True, name, "patched"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", type=Path, help="ServerS5A3 checkout")
    ap.add_argument("--purplemagic", type=Path, help="PurpleMagic checkout")
    ap.add_argument("--check", action="store_true", help="report only, do not write")
    args = ap.parse_args()
    if not args.server and not args.purplemagic:
        ap.error("give --server and/or --purplemagic")

    if args.server:
        root = args.server.resolve()
        dockerfile = root / "deploy/docker/Dockerfile"
        manage = root / "deploy/docker/manage.py"

        patch(dockerfile, "server: Dockerfile GOPROXY",
              "FROM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS build",
              "FROM golang:1.26.5-alpine@sha256:0178a641fbb4858c5f1b48e34bdaabe0350a330a1b1149aabd498d0699ff5fb2 AS build\n"
              "ENV GOPROXY=https://goproxy.cn,direct GOSUMDB=off",
              "ENV GOPROXY", args.check)

        patch(manage, "manage.py: proxy secret + public bootstrap + advertise_ip defaults",
              '            "admin_token": secrets.token_hex(32), "joust_event_enabled": True,',
              '            "admin_token": secrets.token_hex(32), "player_proxy_secret": secrets.token_hex(32),\n'
              '            "joust_event_enabled": True, "public_bootstrap": False, "advertise_ip": "",',
              "player_proxy_secret", args.check)

        patch(manage, "manage.py: DNFBRIDGE_PLAYER_PROXY_SECRET",
              '    if game_token:\n        env["DNFBRIDGE_PLAYER_ADMIN_SECRET"] = game_token',
              '    proxy_secret = c.get("player_proxy_secret", "")\n'
              '    if proxy_secret:\n'
              '        if not isinstance(proxy_secret, str) or not re.fullmatch(r"[0-9a-f]{32,128}", proxy_secret):\n'
              '            raise ValueError("player_proxy_secret must be a generated hex secret of at least 32 characters")\n'
              '        env["DNFBRIDGE_PLAYER_PROXY_SECRET"] = proxy_secret\n'
              '    if game_token:\n        env["DNFBRIDGE_PLAYER_ADMIN_SECRET"] = game_token',
              "DNFBRIDGE_PLAYER_PROXY_SECRET", args.check)

        patch(manage, "manage.py: public bootstrap port binding",
              '"ports": [f"127.0.0.1:{p}:{p}/tcp" for p in (7001, 17002, 18111)] +',
              '"ports": [f"{bootstrap_bind}:7001:7001/tcp", "127.0.0.1:17002:17002/tcp",\n'
              '                                 "127.0.0.1:18111:18111/tcp"] +',
              ":7001:7001/tcp", args.check)

        patch(manage, "manage.py: bootstrap_bind variable",
              '    logging = {"driver": "json-file"',
              '    bootstrap_bind = c["host_ip"] if c.get("public_bootstrap", False) else "127.0.0.1"\n'
              '    logging = {"driver": "json-file"',
              "bootstrap_bind = c[", args.check)

        patch(manage, "manage.py: advertise_ip overrides DNFBRIDGE_SERVER_IP",
              '"DNFBRIDGE_GAME_LISTEN_HOST": c["server_ip"], "DNFBRIDGE_SERVER_IP": c["host_ip"],',
              '"DNFBRIDGE_GAME_LISTEN_HOST": c["server_ip"], "DNFBRIDGE_SERVER_IP": (c.get("advertise_ip") or c["host_ip"]),',
              'c.get("advertise_ip")', args.check)

        patch(manage, "manage.py: allow public --host-ip (DNF_ALLOW_PUBLIC_HOST=1)",
              '''    if not any(address in ipaddress.ip_network(n) for n in
               ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("Use an RFC1918 private LAN IPv4 for this local profile")''',
              '''    if os.environ.get("DNF_ALLOW_PUBLIC_HOST") != "1" and not any(
            address in ipaddress.ip_network(n) for n in
            ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("Use an RFC1918 private LAN IPv4 (or set DNF_ALLOW_PUBLIC_HOST=1)")''',
              "DNF_ALLOW_PUBLIC_HOST", args.check)

    if args.purplemagic:
        root = args.purplemagic.resolve()
        dockerfile = root / "deploy/selfhost/Dockerfile"
        prepare = root / "deploy/selfhost/prepare.py"

        patch(dockerfile, "PM: Dockerfile GOPROXY",
              "FROM golang:1.26.5-bookworm AS build",
              "FROM golang:1.26.5-bookworm AS build\nENV GOPROXY=https://goproxy.cn,direct GOSUMDB=off",
              "ENV GOPROXY", args.check)

        patch(dockerfile, "PM: Debian mirror for final stage",
              "RUN apt-get update",
              "RUN sed -i 's/deb.debian.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list.d/debian.sources && apt-get update",
              "mirrors.tuna", args.check)

        patch(prepare, "PM: prepare.py IP-aware certificate check",
              "if b'does match certificate' not in openssl('x509', '-in', inputs[cert], '-noout', '-checkhost', hostname):",
              "if b'does match certificate' not in openssl('x509', '-in', inputs[cert], '-noout', _check_host_flag(hostname), hostname):",
              "_check_host_flag(hostname), hostname", args.check)

        # helper + import (two small insertions, guarded by the same marker)
        if prepare.is_file() and "def _check_host_flag" not in prepare.read_text(encoding="utf-8"):
            if args.check:
                RESULTS.append((False, "PM: prepare.py helper", "missing"))
            else:
                text = prepare.read_text(encoding="utf-8")
                if "import ipaddress" not in text:
                    text = text.replace("import hashlib\n", "import hashlib\nimport ipaddress\n", 1)
                helper = ('def _check_host_flag(hostname):\n'
                          '    """No-domain mode: verify IP literals with -checkip, host names with -checkhost."""\n'
                          '    try:\n'
                          '        ipaddress.ip_address(hostname)\n'
                          '        return \'-checkip\'\n'
                          '    except ValueError:\n'
                          '        return \'-checkhost\'\n\n\n')
                text = text.replace("def prepare(settings, output", helper + "def prepare(settings, output", 1)
                prepare.write_text(text, encoding="utf-8")
                RESULTS.append((True, "PM: prepare.py helper", "patched"))
        elif prepare.is_file():
            RESULTS.append((True, "PM: prepare.py helper", "already patched"))

    print("\nLocal deployment patches")
    print("-" * 60)
    for ok, name, detail in RESULTS:
        print(f"  [{'OK' if ok else '!!'}] {name:<52} {detail}")
    missing = [r for r in RESULTS if not r[0]]
    print("-" * 60)
    print(f"{len(RESULTS) - len(missing)}/{len(RESULTS)} patches present")
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
