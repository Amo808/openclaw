#!/bin/bash
# NOTE: no set -e — non-critical failures (disk full, pip) must not kill the gateway

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

# Configure Moonshot provider with baseUrl and models
openclaw config set models.mode "merge" 2>/dev/null || true
openclaw config set models.providers.moonshot --json '{
  "baseUrl": "https://api.moonshot.ai/v1",
  "apiKey": "${MOONSHOT_API_KEY}",
  "api": "openai-completions",
  "models": [
    {"id": "kimi-k2-thinking", "name": "Kimi K2 Thinking", "reasoning": true, "input": ["text"], "contextWindow": 256000, "maxTokens": 8192},
    {"id": "kimi-k2.5", "name": "Kimi K2.5", "reasoning": false, "input": ["text"], "contextWindow": 256000, "maxTokens": 8192}
  ]
}' 2>/dev/null || true

# NOTE: default model is set AFTER plugins are enabled (see below)

# Allow Control UI on non-loopback bind
openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback --json true 2>/dev/null || true

# Skip device pairing for Control UI (headless deploy)
openclaw config set gateway.controlUi.dangerouslyDisableDeviceAuth --json true 2>/dev/null || true

# Fix: reset auth mode to token (undo previous auth.mode=none that was persisted to disk)
openclaw config set gateway.auth.mode token 2>/dev/null || true

# Point skill loader to /app/skills so bundled skills (like human-analytics) are discovered
openclaw config set skills.load.extraDirs --json '["/app/skills"]' 2>/dev/null || true
echo "[start] Skill extra dirs set to /app/skills."

# Clean up old logs and temp files to free disk space
find /data -name "*.log" -size +5M -delete 2>/dev/null || true
find /data -name "*.log.*" -delete 2>/dev/null || true
find /tmp -type f -mtime +1 -delete 2>/dev/null || true

# Pre-bootstrap MetaClaw venv with pip (Docker image lacks ensurepip in venvs)
# Run in BACKGROUND so gateway starts quickly and Render sees the port
METACLAW_VENV="/app/extensions/metaclaw-openclaw/.metaclaw"
(
  echo "[metaclaw-bg] Preparing MetaClaw Python venv..."
  if [ ! -f "$METACLAW_VENV/bin/python" ]; then
    python3 -m venv "$METACLAW_VENV" 2>/dev/null || true
  fi
  if ! "$METACLAW_VENV/bin/python" -c "import pip" 2>/dev/null; then
    echo "[metaclaw-bg] pip missing in venv, bootstrapping via get-pip.py..."
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$METACLAW_VENV/bin/python" 2>/dev/null || true
  fi
  if "$METACLAW_VENV/bin/python" -c "import pip" 2>/dev/null; then
    "$METACLAW_VENV/bin/python" -m pip install --quiet "aiming-metaclaw[rl,evolve,scheduler]" 2>/dev/null || true
    echo "[metaclaw-bg] MetaClaw Python packages installed."
  else
    echo "[metaclaw-bg] WARNING: pip still unavailable, MetaClaw RL features will be limited."
  fi
) &
METACLAW_PID=$!

# Enable MetaClaw plugin (already bundled, no need for install -l which causes duplicate warning)
openclaw plugins enable metaclaw-openclaw 2>/dev/null || true
echo "[start] MetaClaw plugin enabled."

# Re-enable kimi-claw plugin (may get disabled after config changes)
openclaw plugins enable kimi-claw 2>/dev/null || true
echo "[start] kimi-claw plugin enabled."

# Trust kimi-claw to silence provenance warnings
openclaw config set plugins.allow --json '["kimi-claw"]' 2>/dev/null || true

# Set default model AFTER plugins (kimi-claw may override it)
openclaw config set agents.defaults.model.primary "moonshot/kimi-k2-thinking" 2>/dev/null || true
# Also set per-agent model to be sure
openclaw config set agents.main.model.primary "moonshot/kimi-k2-thinking" 2>/dev/null || true
echo "[start] Default model set to moonshot/kimi-k2-thinking."

exec node openclaw.mjs gateway --bind lan --port 8080 --allow-unconfigured
