import os
import functions_framework
from google.cloud import compute_v1


@functions_framework.http
def wake_vpn(request):
    token = request.args.get("token") or request.headers.get("X-Wake-Token")
    if token != os.environ.get("WAKE_TOKEN"):
        return ("Unauthorized", 403, {"Content-Type": "text/plain"})

    client = compute_v1.InstancesClient()
    operation = client.start(
        project=os.environ["PROJECT_ID"],
        zone=os.environ["ZONE"],
        instance=os.environ["INSTANCE_NAME"],
    )
    operation.result()

    return (
        "VM starting. Wait ~1 min for DuckDNS to update, then connect via WireGuard.",
        200,
        {"Content-Type": "text/plain"},
    )
