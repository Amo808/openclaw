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

# Ensure all directories exist (volume may be fresh / owned by root)
for d in "$OPENCLAW_STATE_DIR" "$OPENCLAW_WORKSPACE_DIR" "$TMPDIR" "/data/metaclaw-venv"; do
  mkdir -p "$d" 2>/dev/null || true
done

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
  touch "$OPENCLAW_STATE_DIR/.env" 2>/dev/null || true
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
  channels: {
    telegram: {
      enabled: true,
      allowFrom: ["220308429", "393388021"],
      groupPolicy: "open"
    }
  },
  plugins: {
    allow: ["kimi-claw", "telegram", "metaclaw-openclaw"]
  }
};

// Restore kimi-claw config with bot token if available
if (process.env.KIMI_BOT_TOKEN) {
  patch.plugins.entries = patch.plugins.entries || {};
  patch.plugins.entries["kimi-claw"] = {
    enabled: true,
    config: {
      botToken: process.env.KIMI_BOT_TOKEN,
      log: { enabled: true }
    }
  };
}

// Configure metaclaw-openclaw plugin with our pre-installed venv
patch.plugins.entries = patch.plugins.entries || {};
patch.plugins.entries["metaclaw-openclaw"] = {
  enabled: true,
  config: {
    autoInstallMetaclaw: false,
    autoStartMetaclaw: false,
    venvPath: "/data/metaclaw-venv"
  }
};

deep(cfg, patch);
// Remove stale keys left by previous deploys or kimi-claw installer
if (cfg.agents) delete cfg.agents.main;
// Clean up stale entries from kimi-claw installer or doctor
if (cfg.plugins?.entries?.telegram?.config) {
  // Remove invalid telegram plugin config (schema violation), keep the entry itself
  delete cfg.plugins.entries.telegram.config;
}
// Ensure metaclaw-openclaw load path points to compiled dist
if (!cfg.plugins?.load?.paths) {
  cfg.plugins = cfg.plugins || {};
  cfg.plugins.load = cfg.plugins.load || {};
  cfg.plugins.load.paths = cfg.plugins.load.paths || [];
}
if (!cfg.plugins.load.paths.includes("/app/dist/extensions/metaclaw-openclaw")) {
  cfg.plugins.load.paths.push("/app/dist/extensions/metaclaw-openclaw");
}
// Also keep telegram load path
if (!cfg.plugins.load.paths.includes("/app/dist/extensions/telegram")) {
  cfg.plugins.load.paths.push("/app/dist/extensions/telegram");
}
// Remove stale npm install records that break plugin resolution
// (telegram and weixin were installed via npm but should use bundled versions)
if (cfg.plugins?.installs) {
  delete cfg.plugins.installs.telegram;
  delete cfg.plugins.installs["openclaw-weixin"];
  if (Object.keys(cfg.plugins.installs).length === 0) delete cfg.plugins.installs;
}
// Remove openclaw-weixin entry (auto-added by kimi-claw installer)
if (cfg.plugins?.entries?.["openclaw-weixin"]) {
  delete cfg.plugins.entries["openclaw-weixin"];
}
fs.writeFileSync(process.argv[2], JSON.stringify(cfg, null, 2) + "\n");
console.log("[start] Config written successfully.");
' "$EXISTING" "$CONFIG_FILE"

# (cleanup moved to top of script)

# Pre-bootstrap MetaClaw venv with pip in BACKGROUND (disk: 10GB)
# Use persistent disk so venv survives redeploys
METACLAW_VENV="/data/metaclaw-venv"
(
  echo "[metaclaw-bg] Preparing MetaClaw Python venv at $METACLAW_VENV..."
  
  # Check if metaclaw is already installed from a previous deploy
  if "$METACLAW_VENV/bin/python" -c "import metaclaw" 2>/dev/null; then
    echo "[metaclaw-bg] MetaClaw already installed, skipping."
    exit 0
  fi

  if [ ! -f "$METACLAW_VENV/bin/python" ]; then
    python3 -m venv "$METACLAW_VENV" 2>&1 || true
  fi
  if ! "$METACLAW_VENV/bin/python" -c "import pip" 2>/dev/null; then
    echo "[metaclaw-bg] pip missing in venv, bootstrapping via get-pip.py..."
    curl -fsSL https://bootstrap.pypa.io/get-pip.py | "$METACLAW_VENV/bin/python" 2>&1 || true
  fi
  if "$METACLAW_VENV/bin/python" -c "import pip" 2>/dev/null; then
    echo "[metaclaw-bg] Installing aiming-metaclaw (this may take a few minutes)..."
    "$METACLAW_VENV/bin/python" -m pip install "aiming-metaclaw[rl,evolve,scheduler]" 2>&1 || true
    echo "[metaclaw-bg] pip install finished."
    # Verify
    if "$METACLAW_VENV/bin/python" -c "import metaclaw; print('MetaClaw version:', metaclaw.__version__)" 2>&1; then
      echo "[metaclaw-bg] ✅ MetaClaw Python packages installed and verified!"
    else
      echo "[metaclaw-bg] ⚠️ pip install ran but import metaclaw failed."
    fi
  else
    echo "[metaclaw-bg] WARNING: pip still unavailable."
  fi
) &

# ── Create plugin runtime shim ──
# The Docker build bundles src/plugins/runtime/index.ts into auth-profiles-*.js
# but the plugin loader expects a standalone file at dist/plugins/runtime/index.js.
# Create a thin ES module shim that re-exports createPluginRuntime from the bundle.
echo "[start] Creating plugin runtime shim..."
AUTH_BUNDLE=$(ls /app/dist/auth-profiles-*.js 2>/dev/null | head -1)
if [ -n "$AUTH_BUNDLE" ]; then
  AUTH_BASE=$(basename "$AUTH_BUNDLE")
  # Export line in bundle: "createPluginRuntime as Zt" — extract the minified name (Zt)
  ALIAS=$(grep -oP '\bcreatePluginRuntime\b as \w+' "$AUTH_BUNDLE" | head -1 | awk '{print $3}')
  if [ -n "$ALIAS" ]; then
    mkdir -p /app/dist/plugins/runtime
    cat > /app/dist/plugins/runtime/index.js << SHIMEOF
export { ${ALIAS} as createPluginRuntime } from "../../${AUTH_BASE}";
SHIMEOF
    echo "[start] Plugin runtime shim created (alias=${ALIAS}, bundle=${AUTH_BASE})."
  else
    echo "[start] WARNING: Could not find createPluginRuntime export in ${AUTH_BASE}"
  fi
else
  echo "[start] WARNING: No auth-profiles bundle found in /app/dist/"
fi

# ── Fix reasoning auto-enable by kimi-bridge ──
# kimi-bridge applies reasoning=on at startup for thinking models.
# This causes the Telegram channel to send "Reasoning:" text to users.
# After a delay, reset reasoningLevel to "off" in the session store.
# Note: kimi-bridge sets reasoning=on asynchronously after startup,
# so we need a longer delay and a retry loop to catch it.
(
  for attempt in 1 2 3; do
    sleep 60
    SESSIONS_DIR="$OPENCLAW_STATE_DIR/agents/main/sessions"
    if [ -f "$SESSIONS_DIR/sessions.json" ]; then
      node -e '
        const fs = require("fs");
        const f = process.argv[1];
        try {
          const d = JSON.parse(fs.readFileSync(f, "utf8"));
          let changed = false;
          for (const k in d) {
            if (d[k].reasoningLevel && d[k].reasoningLevel !== "off") {
              d[k].reasoningLevel = "off";
              changed = true;
            }
          }
          if (changed) {
            fs.writeFileSync(f, JSON.stringify(d, null, 2));
            console.log("[reasoning-fix] Set reasoningLevel=off in session store (attempt " + process.argv[2] + ")");
          }
        } catch (e) {
          console.log("[reasoning-fix] Skip:", e.message);
        }
      ' "$SESSIONS_DIR/sessions.json" "$attempt"
    fi
  done
) &

echo "[start] Launching gateway..."
exec node openclaw.mjs gateway --bind lan --port 8080 --allow-unconfigured
