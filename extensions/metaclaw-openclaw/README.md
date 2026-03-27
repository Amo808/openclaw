# MetaClaw Plugin

## One-Click Install

Download the zip, extract, enable — MetaClaw environment is set up automatically.

### macOS / Linux

```bash
curl -LO https://github.com/aiming-lab/MetaClaw/releases/download/v0.4.0/metaclaw-plugin.zip
unzip metaclaw-plugin.zip -d ~/.openclaw/extensions/metaclaw-openclaw
openclaw plugins enable metaclaw-openclaw
openclaw gateway restart
```

> **China users**: If GitHub downloads are slow or timeout, use a mirror:
> ```bash
> curl -LO https://ghfast.top/https://github.com/aiming-lab/MetaClaw/releases/download/v0.4.0/metaclaw-plugin.zip
> ```

### Windows (PowerShell)

```powershell
Invoke-WebRequest -Uri https://github.com/aiming-lab/MetaClaw/releases/download/v0.4.0/metaclaw-plugin.zip -OutFile metaclaw-plugin.zip
Expand-Archive metaclaw-plugin.zip -DestinationPath $env:USERPROFILE\.openclaw\extensions\metaclaw-openclaw
openclaw plugins enable metaclaw-openclaw
openclaw gateway restart
```

> **China users**: If GitHub downloads are slow or timeout, replace the download URL with:
> ```
> https://ghfast.top/https://github.com/aiming-lab/MetaClaw/releases/download/v0.4.0/metaclaw-plugin.zip
> ```

### Then run

```bash
metaclaw setup
metaclaw start
```

### What the plugin does automatically

- Creates an isolated Python virtual environment (`.venv`)
- Installs MetaClaw (`[rl,evolve,scheduler]`) via pip
- Auto-installs the official WeChat plugin (`@tencent-weixin/openclaw-weixin`) when enabled
- Installs `metaclaw` CLI wrapper and configures PATH (macOS / Linux / Windows)
- Patches outbound LLM `fetch` to inject `X-Session-Id` / `X-Turn-Type` headers

### Requirements

- Python ≥ 3.11
- OpenClaw (any version)
- macOS / Linux / Windows
- **RAM ≥ 4 GB recommended.** MetaClaw's dependencies (PyTorch, etc.) are heavy. On machines with ≤ 2 GB RAM, pip may get killed by the OS (OOM). Add swap space before installing:
  ```bash
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  ```

### Full auto mode (optional)

```bash
openclaw config set plugins.entries.metaclaw-openclaw.config.oneClickMetaclaw true
```

Enables: venv + pip + default config + `metaclaw start` on gateway load.

---

## Config

`~/.openclaw/openclaw.json`:

Minimal (**pip install** on gateway load; manual **`metaclaw setup`** + **`start`**):

```json
{
  "plugins": {
    "entries": {
      "metaclaw-openclaw": {
        "enabled": true
      }
    }
  }
}
```

Full auto (`oneClickMetaclaw`):

```json
{
  "plugins": {
    "entries": {
      "metaclaw-openclaw": {
        "enabled": true,
        "config": {
          "oneClickMetaclaw": true
        }
      }
    }
  }
}
```

| Key | Notes |
|-----|--------|
| `oneClickMetaclaw` | **Default `false`.** **`true`:** venv + pip + default `~/.metaclaw/config.yaml` if missing + **`metaclaw start`**. |
| `autoInstallMetaclaw` | **Default `true`.** **`false`** skips venv creation and pip (ignored when **`oneClickMetaclaw`** is **`true`**). |
| `autoStartMetaclaw` | **Default `false`**; **`true`** when **`oneClickMetaclaw`**. When enabled, runs metaclaw start from the venv after pip. |
| `pipPython` | Default `python3`. Used to create the venv. Use a **`python3.12`**-style command or an absolute interpreter path if **`python3`** is too old. |
| `pipInstallSpec` | Default `aiming-metaclaw[rl,evolve,scheduler]` from PyPI. |
| `pipExtraArgs` | Extra pip flags. |

---

## Plugin

On gateway load, the plugin:

- **Creates a Python virtual environment** (`.venv`) inside the plugin directory if one does not already exist.
- Installs MetaClaw into the venv via **`pip install`** (from PyPI, works with Chinese mirrors).
- Auto-installs the official WeChat plugin (`@tencent-weixin/openclaw-weixin`) when `wechat.enabled` is true.
- Creates a `metaclaw` wrapper script and auto-configures `PATH` (macOS / Linux / Windows) so you can run `metaclaw` directly.
- Patches `fetch` to inject `X-Session-Id` / `X-Turn-Type` on outbound LLM POSTs (`before_prompt_build` / `agent_end`).
- **`metaclaw setup`** / **`metaclaw start`** are up to you unless **`oneClickMetaclaw`** is **`true`**.

---

## Troubleshooting

| Issue | What to do |
|-------|------------|
| `plugin not found: metaclaw-openclaw` | Put the folder under **`~/.openclaw/extensions/metaclaw-openclaw`** or set **`plugins.load.paths`** to its absolute path. |
| `tinker` / Python version | `[rl,…]` needs **Python ≥ 3.11**. |
| venv creation fails | Install `python3-venv`: **`apt install python3-venv`** (Debian/Ubuntu) or ensure your Python has the `venv` module. |
| `pip install` fails in venv | Check `pipPython` points to Python **≥ 3.11**; use **`pipExtraArgs`** for custom pip flags. |
| `pip install` timeout (China) | pip defaults to PyPI which has Chinese mirrors. If still slow, set `pipExtraArgs` to `["-i", "https://pypi.tuna.tsinghua.edu.cn/simple"]`. |
| `spawn metaclaw ENOENT` | Only if **`autoStartMetaclaw`** — the plugin uses the venv's Python to run metaclaw. |
| Server freezes / pip killed during install | Not enough RAM. Add 4 GB swap: `sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`, then retry. |
