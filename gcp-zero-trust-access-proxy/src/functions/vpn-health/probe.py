"""VPN health probe — the "is the VPN up" invariant, isolated behind a seam.

The invariant is: VPN is up = the DuckDNS hostname resolves AND the WireGuard
UDP port accepts traffic. Kept here, pure and dependency-free, so it can be
tested with stub resolver/prober in test_probe.py and reused wherever the
same question is asked.
"""

import socket
from typing import Callable, Optional

Resolver = Callable[[str], Optional[str]]
Prober = Callable[[str, int], bool]


def resolve_hostname(hostname: str) -> Optional[str]:
    try:
        return socket.gethostbyname(hostname)
    except socket.gaierror:
        return None


def udp_port_reachable(ip: str, port: int, timeout: float = 3.0) -> bool:
    """Best-effort UDP reachability: sending is enough unless the host
    answers with an ICMP unreachable (surfaced as an OSError)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(timeout)
            sock.sendto(b"\x00", (ip, port))
            return True
    except OSError:
        return False


def probe_health(hostname: str, port: int,
                 resolver: Resolver = resolve_hostname,
                 prober: Prober = udp_port_reachable) -> dict:
    ip = resolver(hostname) if hostname else None
    dns_ok = ip is not None
    wg_reachable = prober(ip, port) if dns_ok else False
    return {
        "status": "UP" if (dns_ok and wg_reachable) else "DOWN",
        "ip": ip,
        "dns": dns_ok,
        "wg": wg_reachable,
    }
