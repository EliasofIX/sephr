#!/usr/bin/env python3
"""Compile uBlock Origin network filter lists into WKContentRuleList JSON.

Parses the same default lists uBO ships with (uBlock filters, EasyList,
EasyPrivacy) and emits a Safari content-blocker JSON bundle for iOS.
Network-only — cosmetic/scriptlet rules are skipped (WKWebView has no
uBlock engine). Capped at 48k rules to stay under Apple's compile limit.
"""
from __future__ import annotations

import json
import pathlib
import re
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "sephr-ios" / "Resources" / "ublock-content-rules.json"

LIST_URLS = [
    "https://ublockorigin.github.io/uAssets/filters/filters.txt",
    "https://easylist.to/easylist/easylist.txt",
    "https://easylist.to/easylist/easyprivacy.txt",
    "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext",
]

# ||example.com^ or ||sub.example.com^
HOST_RULE = re.compile(r"^\|\|([a-z0-9][a-z0-9._-]*)\^", re.I)
# |http://example.com/ or |https://
URL_RULE = re.compile(r"^\|https?://([^/^|*]+)", re.I)


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Sephr/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read().decode("utf-8", errors="replace")


def domains_from_lists(text: str) -> set[str]:
    hosts: set[str] = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("!") or line.startswith("["):
            continue
        if line.startswith("@@"):
            continue
        m = HOST_RULE.match(line)
        if m:
            hosts.add(m.group(1).lower())
            continue
        m = URL_RULE.match(line)
        if m:
            hosts.add(m.group(1).lower())
    return hosts


def hosts_file_domains(text: str) -> set[str]:
    hosts: set[str] = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            hosts.add(parts[1].lower())
    return hosts


def main() -> int:
    all_hosts: set[str] = set()
    for url in LIST_URLS:
        print(f"[sephr] fetching {url} ...")
        body = fetch(url)
        if "hostformat=hosts" in url:
            all_hosts |= hosts_file_domains(body)
        else:
            all_hosts |= domains_from_lists(body)

    # WKContentRuleList compile limit — leave headroom for the cosmetic rule.
    max_rules = 48_000
    sorted_hosts = sorted(all_hosts)[:max_rules]
    print(f"[sephr] {len(sorted_hosts)} network block rules (of {len(all_hosts)} hosts)")

    rules: list[dict] = []
    for host in sorted_hosts:
        escaped = host.replace(".", "\\.")
        rules.append({
            "trigger": {
                "url-filter": (
                    f"^https?://([^/]*\\.)?{escaped}([:/].*)?$"
                ),
                "load-type": ["third-party", "first-party"],
            },
            "action": {"type": "block"},
        })

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(rules, separators=(",", ":")))
    print(f"[sephr] wrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
