#!/usr/bin/env python3
"""vpn-dashboard — multi-region VPN dashboard with QR code switching.

Shows all servers, generates WireGuard QR codes for instant switching.

Usage:
    python3 server.py [--port 8080]
"""

import argparse
import json
import os
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# ── Server configs (phone1 client for each region) ───────────────────────────

SERVERS = {
    "us-east1": {
        "flag": "\U0001f1fa\U0001f1f8", "label": "South Carolina", "country": "USA",
        "ts_host": "wireguard-vpn",
        "wg_conf": """[Interface]
PrivateKey = 0Gu8eeXz+s5+6cYe/JKq1lS3yQGtFxR5FYoGj2UXz2I=
Address = 10.200.200.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = lXsdf6xLPsHWpf8BVsXdrlbrgdh1urvwsOWmXepCPGI=
PresharedKey = IgcnOluFkJpUfahXQ3BStuzmC5FmTa+IdVl8ViKqPw4=
Endpoint = gcp-vpn.duckdns.org:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25""",
    },
    "us-west1": {
        "flag": "\U0001f1fa\U0001f1f8", "label": "Oregon", "country": "USA",
        "ts_host": "wireguard-vpn-w2",
        "wg_conf": """[Interface]
PrivateKey = IIDL6zQ5zBaIybt83M1gO0vMRaXi9TPsOikw4pkArFM=
Address = 10.200.1.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = GZF+j1V4XEeOP2GHU9oNuG5JdphQ0qqmGAMpsU486WA=
PresharedKey = Cc4/m4WGu+ES44U8oQRoAav0WgMRcgAHeAJ2zt7sOm0=
Endpoint = 136.67.124.77:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25""",
    },
    "asia-northeast1": {
        "flag": "\U0001f1ef\U0001f1f5", "label": "Tokyo", "country": "Japan",
        "ts_host": "wireguard-vpn-tokyo",
        "wg_conf": """[Interface]
PrivateKey = kAf5H/E4MWfkJTlFGtPgp0szfzzWNX9udZym7f8MF0k=
Address = 10.200.8.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = sY+IeZEcduugnuHx1DF5cMdZK9l0KAHLOlEmajhI0F0=
PresharedKey = qLvodYR8tZbUoSUfo5sn4vwgxu/3c1O2Fw1SPI7BwmQ=
Endpoint = 34.180.106.18:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25""",
    },
    "europe-west2": {
        "flag": "\U0001f1ec\U0001f1e7", "label": "London", "country": "UK",
        "ts_host": "wireguard-vpn-london",
        "wg_conf": """[Interface]
PrivateKey = wKu0MR5fL/I0MaKHwuSIykSPA5bXJLcRXWJhYBYqyW0=
Address = 10.200.7.2/24
DNS = 8.8.8.8

[Peer]
PublicKey = +XbYK4UcK51cNHxLx6ayJKOpSFp6zp/jBaXYpCwxaXE=
PresharedKey = 060QLK6Hm++RYgoXTSveyxm06m+fm93z5VQU5CN6PQk=
Endpoint = 34.105.159.76:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25""",
    },
}

def run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception:
        return -1, "", "timeout"

def get_public_ip():
    c, out, _ = run(["curl", "-sf", "--max-time", "3", "https://api.ipify.org"], timeout=5)
    return out if c == 0 else "unknown"

def get_tailscale_info():
    c, out, _ = run(["tailscale", "status", "--json"], timeout=5)
    if c != 0:
        return {"ts_ip": "", "exit_node_adv": False, "peers": []}
    try:
        data = json.loads(out)
        self_info = data.get("Self") or {}
        peers = []
        for pid, peer in (data.get("Peer") or {}).items():
            peers.append({
                "hostname": peer.get("HostName", ""),
                "ts_ip": peer.get("TailscaleIPs", [""])[0] if peer.get("TailscaleIPs") else "",
                "online": peer.get("Online", False),
                "is_exit_node": peer.get("ExitNode", False),
                "is_exit_node_adv": peer.get("ExitNodeOption", False),
            })
        # Add Self as a peer too so the dashboard can match it
        self_hostname = self_info.get("HostName", "")
        if self_hostname:
            peers.append({
                "hostname": self_hostname,
                "ts_ip": self_info.get("TailscaleIPs", [""])[0] if self_info.get("TailscaleIPs") else "",
                "online": True,
                "is_exit_node": self_info.get("ExitNode", False),
                "is_exit_node_adv": self_info.get("ExitNodeOption", False),
            })
        return {
            "ts_ip": self_info.get("TailscaleIPs", [""])[0] if self_info.get("TailscaleIPs") else "",
            "exit_node_adv": self_info.get("ExitNodeOption", False),
            "peers": peers,
        }
    except Exception:
        return {"ts_ip": "", "exit_node_adv": False, "peers": []}

def get_qr(conf_text):
    """Generate QR code as ANSI string using qrencode."""
    try:
        r = subprocess.run(
            ["qrencode", "-t", "ansiutf8"],
            input=conf_text, capture_output=True, text=True, timeout=5
        )
        return r.stdout if r.returncode == 0 else "QR error"
    except Exception:
        return "QR error"

def get_wg_ip(region):
    """Get the WireGuard tunnel IP for this region's client."""
    conf = SERVERS.get(region, {}).get("wg_conf", "")
    for line in conf.split("\n"):
        if line.strip().startswith("Address ="):
            return line.split("=")[1].strip().split("/")[0]
    return "unknown"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path in ("/", "/index.html"):
            self._html("index.html")
        elif path == "/api/status":
            ts = get_tailscale_info()
            ip = get_public_ip()
            servers_out = []
            for key, srv in SERVERS.items():
                peer = next((p for p in ts["peers"] if p["hostname"] == srv["ts_host"]), None)
                servers_out.append({
                    "key": key,
                    "flag": srv["flag"],
                    "label": srv["label"],
                    "country": srv["country"],
                    "ts_host": srv["ts_host"],
                    "wg_ip": get_wg_ip(key),
                    "online": peer["online"] if peer else False,
                    "is_exit_node": peer["is_exit_node"] if peer else False,
                    "is_exit_node_adv": peer["is_exit_node_adv"] if peer else False,
                    "ts_ip": peer["ts_ip"] if peer else "",
                })
            self._json({
                "public_ip": ip,
                "ts_ip": ts["ts_ip"],
                "exit_node_advertised": ts["exit_node_adv"],
                "servers": servers_out,
            })
        elif path.startswith("/api/qr/"):
            region = path.split("/api/qr/")[-1]
            if region in SERVERS:
                conf = SERVERS[region]["wg_conf"]
                qr = get_qr(conf)
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.end_headers()
                self.wfile.write(qr.encode())
            else:
                self.send_error(404)
        elif path.startswith("/api/config/"):
            region = path.split("/api/config/")[-1]
            if region in SERVERS:
                conf = SERVERS[region]["wg_conf"]
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Disposition", f'attachment; filename="vpn-{region}.conf"')
                self.end_headers()
                self.wfile.write(conf.encode())
            else:
                self.send_error(404)
        else:
            self.send_error(404)

    def _html(self, name):
        path = os.path.join(os.path.dirname(__file__), "templates", name)
        try:
            with open(path) as f:
                html = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(html.encode())
        except FileNotFoundError:
            self.send_error(404)

    def _json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    server = HTTPServer(("0.0.0.0", args.port), Handler)
    print(f"VPN Dashboard on http://0.0.0.0:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
