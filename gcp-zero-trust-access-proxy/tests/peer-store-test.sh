#!/bin/bash
# Fixture-based tests for the peer store module. No root and no live
# WireGuard needed — the store reads/writes a throwaway wg0.conf.
# Usage: bash tests/peer-store-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$ROOT/../src/scripts/lib/wg-peer-store.sh"
[ -f "$LIB" ] || { echo "missing peer store: $LIB" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export WG_CONF="$TMP/wg0.conf"
export WG_SERVER_KEY="$TMP/server_public.key"
export WG_CLIENT_DIR="$TMP/clients"

printf 'pubkey-server\n' > "$WG_SERVER_KEY"
mkdir -p "$WG_CLIENT_DIR"
: > "$WG_CLIENT_DIR/phone1.conf"
: > "$WG_CLIENT_DIR/laptop.conf"

cat > "$WG_CONF" <<'EOF'
[Interface]
Address = 10.200.200.1/24
ListenPort = 51820
PrivateKey = xxxx

# client: phone1
[Peer]
PublicKey = P1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
PresharedKey = psk1
AllowedIPs = 10.200.200.2/32

# client: laptop
[Peer]
PublicKey = P2BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
PresharedKey = psk2
AllowedIPs = 10.200.200.3/32

# legacy
[Peer]
PublicKey = P3CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
PresharedKey = psk3
AllowedIPs = 10.200.200.5/32
EOF

# shellcheck source=../src/scripts/lib/wg-peer-store.sh
source "$LIB"

assert_eq() { # label expected actual
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    echo "ok - $label"
  else
    echo "FAIL - $label (expected '$expected', got '$actual')" >&2
    exit 1
  fi
}

assert_true() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok - $label"
  else
    echo "FAIL - $label" >&2
    exit 1
  fi
}

assert_false() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL - $label" >&2
    exit 1
  else
    echo "ok - $label"
  fi
}

assert_eq "next free IP skips .2/.3, fills .4 (legacy .5 stays used)" "10.200.200.4" "$(peer_next_ip)"
assert_eq "server public key read" "pubkey-server" "$(peer_server_public_key)"
assert_eq "listen port parsed" "51820" "$(peer_listen_port)"
assert_eq "subnet prefix parsed" "10.200.200" "$(peer_subnet_prefix)"

peer_load_names
assert_eq "name map: phone1" "phone1" "${PEER_NAMES[P1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=]:-}"
assert_eq "name map: laptop" "laptop" "${PEER_NAMES[P2BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=]:-}"
assert_eq "bare # comment maps too" "legacy" "${PEER_NAMES[P3CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=]:-}"

assert_true "valid name accepted" peer_validate_name "ok-name-1"
assert_false "invalid name rejected" peer_validate_name "bad name!"
assert_true "existing client detected" peer_exists "phone1"
assert_false "missing client not detected" peer_exists "nope"

peer_add newpeer CPRIV CPUB CPSK "10.200.200.6" "gcp-vpn.duckdns.org"
assert_eq "peer_add appends server block" "CPUB" "$(grep -A2 '^# client: newpeer$' "$WG_CONF" | grep 'PublicKey' | awk '{print $3}')"
assert_eq "client conf endpoint" "gcp-vpn.duckdns.org:51820" "$(grep '^Endpoint' "$WG_CLIENT_DIR/newpeer.conf" | cut -d' ' -f3)"
assert_true "client conf persisted to peer store dir" peer_exists "newpeer"

peer_remove laptop
assert_false "peer_remove deletes server block" grep -q "^# client: laptop$" "$WG_CONF"
assert_false "peer_remove deletes client file" test -e "$WG_CLIENT_DIR/laptop.conf"

echo "peer store: all tests passed"
