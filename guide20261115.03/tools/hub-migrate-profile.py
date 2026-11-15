#!/usr/bin/env python3
"""Migrate the Hub's published profile to a new approved profile.

Use this after a PVF / client EXE change: the launcher trusts the *signed bootstrap*
published by the Hub, so updating the published profile lets existing launchers adopt
new PvfSha256/ExeSha256 without rebuilding PurpleMagic.exe.

What it does (gateway must be stopped):
  1. copies the new profile to <selfhost>/private/player-profile.json (the Hub's
     approved profile used at startup);
  2. rewrites <selfhost>/hub/state.json:
       published.profile  = new profile
       published.sequence = old + 1        (monotonic, launchers reject rollback)
       published.content  = null           (content of the old PVF no longer applies)
     news / launcher bundle / sources are preserved;
  3. keeps a timestamped backup of state.json.

Usage:
  python3 hub-migrate-profile.py --selfhost /srv/dnf/PurpleMagic/runtime/selfhost \
                                 --profile /srv/dnf/PurpleMagic/runtime/launcher-input/profile.json
  python3 hub-migrate-profile.py ... --dry-run
"""
import argparse
import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

REQUIRED = ("ApiUrl", "GameHost", "BootstrapPort", "ChannelServerId", "CertificateSha256",
            "UpdatePublicKey", "ExeSha256", "PvfSha256")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selfhost", type=Path, required=True)
    ap.add_argument("--profile", type=Path, required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    selfhost = args.selfhost.resolve()
    state_path = selfhost / "hub" / "state.json"
    private_profile = selfhost / "private" / "player-profile.json"
    for p in (state_path, private_profile):
        if not p.is_file():
            print(f"missing {p}", file=sys.stderr)
            return 1

    new_profile = json.loads(args.profile.read_text(encoding="utf-8-sig"))
    lack = [k for k in REQUIRED if not new_profile.get(k)]
    if lack:
        print(f"profile missing fields: {lack}", file=sys.stderr)
        return 1
    if new_profile["ApiUrl"].rstrip("/") != json.loads(private_profile.read_text())["ApiUrl"].rstrip("/"):
        print("refusing: new profile ApiUrl differs from the deployed Hub origin; "
              "connection changes belong to the GM 连接配置 page", file=sys.stderr)
        return 1

    state = json.loads(state_path.read_text(encoding="utf-8"))
    published = state.get("published") or {}
    old_profile = published.get("profile") or {}
    old_pvf = old_profile.get("PvfSha256", "")
    new_pvf = new_profile["PvfSha256"]
    old_seq = int(published.get("sequence") or 0)

    print(f"old PvfSha256: {old_pvf}")
    print(f"new PvfSha256: {new_pvf}")
    print(f"sequence: {old_seq} -> {old_seq + 1}")
    if old_pvf == new_pvf:
        print("profile already up to date; nothing to migrate")
        return 0

    if args.dry_run:
        print("dry-run: no files written")
        return 0

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = state_path.with_name(f"state.json.bak-{stamp}")
    shutil.copy2(state_path, backup)
    print(f"backup: {backup}")

    published["profile"] = new_profile
    published["sequence"] = old_seq + 1
    published["content"] = None
    state["published"] = published

    tmp = state_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.chmod(0o600)
    tmp.replace(state_path)

    private_profile.write_text(json.dumps(new_profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    private_profile.chmod(0o600)
    print("state.json and private/player-profile.json updated; restart the gateway")
    return 0


if __name__ == "__main__":
    sys.exit(main())
