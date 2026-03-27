#!/bin/bash
set -e

# Configure OpenClaw directories
export HOME="/data"
export OPENCLAW_STATE_DIR="/data/.openclaw"
export OPENCLAW_WORKSPACE_DIR="/data/workspace"
mkdir -p "$OPENCLAW_STATE_DIR" "$OPENCLAW_WORKSPACE_DIR"

# Install kimi-claw plugin if bot-token is set and plugin not yet installed
if [ -n "$KIMI_BOT_TOKEN" ]; then
  PLUGIN_DIR="$OPENCLAW_STATE_DIR/extensions/kimi-claw"
  if [ ! -d "$PLUGIN_DIR" ]; then
    echo "[start] Installing kimi-claw plugin..."
    bash <(curl -fsSL https://cdn.kimi.com/kimi-claw/install.sh) \
      --bot-token "$KIMI_BOT_TOKEN" \
      --target-dir "$PLUGIN_DIR" \
      --log-enabled
    echo "[start] kimi-claw installed."
  else
    echo "[start] kimi-claw already installed, skipping."
  fi
fi

echo "[start] Starting OpenClaw gateway..."

# Write Moonshot API key to .env so OpenClaw picks it up
if [ -n "$MOONSHOT_API_KEY" ]; then
  sed -i '/^MOONSHOT_API_KEY=/d' "$OPENCLAW_STATE_DIR/.env" 2>/dev/null || true
  echo "MOONSHOT_API_KEY=$MOONSHOT_API_KEY" >> "$OPENCLAW_STATE_DIR/.env"
fi

# Set default model to moonshot
openclaw config set agents.defaults.model.primary "moonshot/kimi-k2-thinking" 2>/dev/null || true

# Allow Control UI on non-loopback bind
openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback --json true 2>/dev/null || true

# Skip device pairing for Control UI (headless deploy)
openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth --json true 2>/dev/null || true

# Fix: reset auth mode to token (undo previous auth.mode=none that was persisted to disk)
openclaw config set gateway.auth.mode token 2>/dev/null || true

exec node openclaw.mjs gateway --bind lan --port 8080 --allow-unconfigured
