#!/bin/bash
# Removes a WireGuard client (peer) from the server.
# Usage: sudo ./remove-client.sh <client-name>
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo)"; exit 1; }
[ $# -eq 1 ] || { echo "Usage: $0 <client-name>"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/wg-peer-store.sh
if [ -f /usr/local/sbin/wg-peer-store.sh ]; then
  source /usr/local/sbin/wg-peer-store.sh
else
  source "$SCRIPT_DIR/lib/wg-peer-store.sh"
fi

NAME="$1"
peer_validate_name "$NAME" || { echo "Client name must be 1-32 chars: letters, digits, - or _"; exit 1; }
peer_exists "$NAME" || { echo "Client '$NAME' not found"; exit 1; }

peer_remove "$NAME"
wg syncconf wg0 <(wg-quick strip wg0)

echo "Client '$NAME' removed and key revoked."
