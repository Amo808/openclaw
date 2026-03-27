#!/bin/bash
# NOTE: no set -e — non-critical failures (disk full, pip) must not kill the gateway

# Configure OpenClaw directories
export HOME="/data"
export OPENCLAW_STATE_DIR="/data/.openclaw"
export OPENCLAW_WORKSPACE_DIR="/data/workspace"
# Redirect /tmp usage to persistent disk to avoid Render's 2GB tmpfs limit
export TMPDIR="/data/tmp"
export TEMP="/data/tmp"
export TMP="/data/tmp"
mkdir -p "$OPENCLAW_STATE_DIR" "$OPENCLAW_WORKSPACE_DIR" "$TMPDIR" 2>/dev/null || true

# ── AGGRESSIVE CLEANUP first — disk may be full ──
echo "[start] Cleaning disk..."
rm -rf /data/.kimi/kimi-claw/log/* 2>/dev/null || true
rm -rf /data/tmp/* 2>/dev/null || true
rm -rf /tmp/openclaw* 2>/dev/null || true
find /data -name "*.log" -delete 2>/dev/null || true
find /data -name "*.log.*" -delete 2>/dev/null || true
find /data -name "*.bak*" -delete 2>/dev/null || true
# Clear pip cache from previous installs
rm -rf /data/.cache/pip 2>/dev/null || true
echo "[start] Cleanup done. Disk: $(df -h /data 2>/dev/null | tail -1 | awk '{print $4}') free"

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

# Write Moonshot API key to .env so OpenClaw picks it up
if [ -n "$MOONSHOT_API_KEY" ]; then
  sed -i '/^MOONSHOT_API_KEY=/d' "$OPENCLAW_STATE_DIR/.env" 2>/dev/null || true
  echo "MOONSHOT_API_KEY=$MOONSHOT_API_KEY" >> "$OPENCLAW_STATE_DIR/.env"
fi

# ── Write entire config as JSON in one shot (avoids 11 slow `openclaw config set` calls) ──
CONFIG_FILE="$OPENCLAW_STATE_DIR/openclaw.json"
echo "[start] Writing config to $CONFIG_FILE..."

# Read existing config or start fresh
if [ -f "$CONFIG_FILE" ]; then
  EXISTING=$(cat "$CONFIG_FILE")
else
  EXISTING="{}"
fi

# Merge our settings into existing config using node (available in image)
node -e '
const fs = require("fs");
let cfg = {};
try { cfg = JSON.parse(process.argv[1]); } catch {}

// Deep merge helper
function deep(target, source) {
  for (const key of Object.keys(source)) {
    if (source[key] && typeof source[key] === "object" && !Array.isArray(source[key])) {
      if (!target[key] || typeof target[key] !== "object") target[key] = {};
      deep(target[key], source[key]);
    } else {
      target[key] = source[key];
    }
  }
  return target;
}

const patch = {
  models: {
    mode: "merge",
    providers: {
      moonshot: {
        baseUrl: "https://api.moonshot.ai/v1",
        apiKey: "${MOONSHOT_API_KEY}",
        api: "openai-completions",
        models: [
          {id: "kimi-k2-thinking", name: "Kimi K2 Thinking", reasoning: true, input: ["text"], contextWindow: 256000, maxTokens: 8192},
          {id: "kimi-k2.5", name: "Kimi K2.5", reasoning: false, input: ["text"], contextWindow: 256000, maxTokens: 8192}
        ]
      }
    }
  },
  agents: {
    defaults: { model: { primary: "moonshot/kimi-k2-thinking" } }
  },
  gateway: {
    auth: { mode: "token" },
    controlUi: {
      dangerouslyAllowHostHeaderOriginFallback: true,
      dangerouslyDisableDeviceAuth: true
    }
  },
  skills: {
    load: { extraDirs: ["/app/skills"] }
  },
  plugins: {
    allow: ["kimi-claw"]
  }
};

deep(cfg, patch);
// Remove stale keys left by previous deploys
if (cfg.agents) delete cfg.agents.main;
// Remove manually-installed metaclaw entry (it is bundled — duplicate causes warning spam)
if (cfg.plugins && cfg.plugins.entries) delete cfg.plugins.entries["metaclaw-openclaw"];
fs.writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2) + "\n");
console.log("[start] Config written successfully.");
' "$EXISTING" "$CONFIG_FILE"

# (cleanup moved to top of script)

# Pre-bootstrap MetaClaw venv with pip in BACKGROUND (disk: 10GB)
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
    echo "[metaclaw-bg] WARNING: pip still unavailable."
  fi
) &

echo "[start] Launching gateway..."
exec node openclaw.mjs gateway --bind lan --port 8080 --allow-unconfigured
