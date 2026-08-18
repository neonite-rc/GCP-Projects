#!/usr/bin/env bash
# install.sh — set up vpn CLI on your machine
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vpn-service"

echo ""
echo "  Installing vpn CLI…"
echo ""

# 1. Create install dir
mkdir -p "$INSTALL_DIR"

# 2. Symlink the binary
if [[ -L "$INSTALL_DIR/vpn" ]]; then
  rm "$INSTALL_DIR/vpn"
fi
ln -s "$SCRIPT_DIR/bin/vpn" "$INSTALL_DIR/vpn"
chmod +x "$SCRIPT_DIR/bin/vpn"
echo "  ✓ $INSTALL_DIR/vpn → $SCRIPT_DIR/bin/vpn"

# 3. Check PATH
if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
  echo ""
  echo "  ⚠  $INSTALL_DIR is not in your PATH."
  echo "     Add to ~/.bashrc or ~/.zshrc:"
  echo ""
  echo '     export PATH="$HOME/.local/bin:$PATH"'
  echo ""
fi

# 4. Set up config
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/config.sh" ]]; then
  cp "$SCRIPT_DIR/config.example.sh" "$CONFIG_DIR/config.sh"
  echo "  ✓ Config: $CONFIG_DIR/config.sh"
  echo ""
  echo "  ► Edit: ${EDITOR:-nano} $CONFIG_DIR/config.sh"
else
  echo "  ✓ Config exists: $CONFIG_DIR/config.sh"
fi

# 5. Check dependencies
echo ""
echo "  Dependencies:"
MISSING=()
for dep in gcloud terraform jq tailscale fping; do
  if command -v "$dep" &>/dev/null; then
    echo "    ✓ $dep"
  else
    echo "    ✗ $dep  ← MISSING"
    MISSING+=("$dep")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  echo "  Install missing:"
  for dep in "${MISSING[@]}"; do
    case "$dep" in
      jq)        echo "    brew install jq" ;;
      fping)     echo "    brew install fping" ;;
      tailscale) echo "    brew install --cask tailscale" ;;
      gcloud)    echo "    https://cloud.google.com/sdk/docs/install" ;;
      terraform) echo "    brew install terraform" ;;
    esac
  done
fi

echo ""
echo "  Done! Try:  vpn help"
echo ""
