import os
import socket
import time

import functions_framework
from google.cloud import monitoring_v3

from probe import probe_health, udp_port_reachable


def write_health_metric(project_id: str, instance: str, vpn_up: bool) -> None:
    """Write a custom VPN health metric to Cloud Monitoring."""
    client = monitoring_v3.MetricServiceClient()
    project_name = f"projects/{project_id}"
    series = monitoring_v3.TimeSeries()
    series.metric.type = "custom.googleapis.com/vpn/health"
    series.resource.type = "global"
    series.resource.labels["project_id"] = project_id
    series.metric.labels["instance"] = instance
    now = time.time()
    point = monitoring_v3.Point(
        interval=monitoring_v3.TimeInterval(
            end_time={"seconds": int(now), "nanos": int((now % 1) * 1e9)}
        ),
        value=monitoring_v3.TypedValue(double_value=1.0 if vpn_up else 0.0),
    )
    series.points = [point]
    client.create_time_series(request={"name": project_name, "time_series": [series]})


def resolve_internal_host(hostname: str) -> str | None:
    """Resolve a GCE internal hostname (instance.region.internal) to an IP."""
    try:
        return socket.gethostbyname(hostname)
    except socket.gaierror:
        return None


@functions_framework.http
def vpn_health(request):
    project_id = os.environ.get("PROJECT_ID")
    wg_port = int(os.environ.get("WG_PORT", "51820"))
    duckdns_hostname = os.environ.get("DUCKDNS_HOSTNAME", "")
    primary_host = os.environ.get("PRIMARY_HOST", "")
    region_hosts = os.environ.get("REGION_HOSTS", "")  # comma-separated
    region_keys = os.environ.get("REGION_KEYS", "")    # comma-separated

    results = {}

    # --- Probe primary via DuckDNS (if configured) ---
    if duckdns_hostname:
        primary = probe_health(duckdns_hostname, wg_port)
        results["primary"] = primary
        write_health_metric(project_id, "wireguard-vpn", primary["status"] == "UP")
        detail = f"dns={'ok' if primary['dns'] else 'fail'} wg={'ok' if primary['wg'] else 'fail'}"
        status = "UP" if primary["status"] == "UP" else "DOWN"
        print(f"[primary] {status}: {detail} (ip={primary['ip']})")
    elif primary_host:
        # Fallback: probe via internal hostname
        ip = resolve_internal_host(primary_host)
        if ip:
            wg_ok = udp_port_reachable(ip, wg_port)
            results["primary"] = {"status": "UP" if wg_ok else "DOWN", "ip": ip, "dns": True, "wg": wg_ok}
        else:
            results["primary"] = {"status": "DOWN", "ip": None, "dns": False, "wg": False}
        write_health_metric(project_id, "wireguard-vpn", results["primary"]["status"] == "UP")
        print(f"[primary] {results['primary']['status']}: ip={results['primary']['ip']}")

    # --- Probe all additional regions ---
    hosts = [h.strip() for h in region_hosts.split(",") if h.strip()]
    keys = [k.strip() for k in region_keys.split(",") if k.strip()]

    for key, host in zip(keys, hosts):
        if key in ("us-east1",):
            continue  # already probed as primary

        ip = resolve_internal_host(host)
        if ip:
            wg_ok = udp_port_reachable(ip, wg_port)
            result = {"status": "UP" if wg_ok else "DOWN", "ip": ip, "dns": True, "wg": wg_ok}
        else:
            result = {"status": "DOWN", "ip": None, "dns": False, "wg": False}

        results[key] = result
        write_health_metric(project_id, f"vpn-{key}", result["status"] == "UP")
        status = "UP" if result["status"] == "UP" else "DOWN"
        print(f"[{key}] {status}: ip={result['ip']}")

    # --- Summary ---
    up_count = sum(1 for r in results.values() if r["status"] == "UP")
    total = len(results)
    print(f"Health check complete: {up_count}/{total} regions UP")

    return results
