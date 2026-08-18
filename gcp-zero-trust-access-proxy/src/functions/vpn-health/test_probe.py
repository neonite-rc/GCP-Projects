"""Fixture-based tests for the health probe. No GCP, no network.
Run: python3 src/functions/vpn-health/test_probe.py
"""

from probe import probe_health


def fake_resolver(hostname):
    return "203.0.113.10"


def dead_resolver(hostname):
    return None


def open_prober(ip, port):
    return True


def closed_prober(ip, port):
    return False


CASES = [
    (probe_health("vpn.duckdns.org", 51820, fake_resolver, open_prober),
     {"status": "UP", "ip": "203.0.113.10", "dns": True, "wg": True},
     "dns ok + port open -> UP"),
    (probe_health("vpn.duckdns.org", 51820, dead_resolver, open_prober),
     {"status": "DOWN", "ip": None, "dns": False, "wg": False},
     "dns fails -> DOWN, probe skipped"),
    (probe_health("vpn.duckdns.org", 51820, fake_resolver, closed_prober),
     {"status": "DOWN", "ip": "203.0.113.10", "dns": True, "wg": False},
     "dns ok + port closed -> DOWN"),
    (probe_health(None, 51820, fake_resolver, open_prober),
     {"status": "DOWN", "ip": None, "dns": False, "wg": False},
     "no hostname -> DOWN"),
]


def main() -> int:
    failures = 0
    for actual, expected, label in CASES:
        if actual == expected:
            print(f"ok - {label}")
        else:
            failures += 1
            print(f"FAIL - {label}: got {actual}, want {expected}")
    if failures:
        print(f"{failures} probe test(s) failed")
        return 1
    print("all probe tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
