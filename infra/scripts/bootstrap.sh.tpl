#!/bin/bash
set -eu
exec > /var/log/openclaw-bootstrap.log 2>&1

echo "[bootstrap] Starting at $(date)"

# ── 1. Install SSM agent ──────────────────────────────────────────────────────
# EC2 + instance profile: SSM works natively — no hybrid activation registration needed.
snap install amazon-ssm-agent --classic || true

sleep 5

systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service

echo "[bootstrap] SSM agent installed and started"

# ── 2. Install Node.js v22 via NodeSource ─────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl gnupg

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs

echo "[bootstrap] Node.js $(node --version) installed"

# ── 3. Install OpenClaw CLI ───────────────────────────────────────────────────
npm install -g openclaw --no-fund --no-audit

echo "[bootstrap] OpenClaw $(openclaw --version 2>/dev/null || echo '(version check failed)') installed"

# ── 4. Generate Ed25519 SSH keys ─────────────────────────────────────────────
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# deploy key: read/write access to openclaw-memory (workspace) repo
if [ ! -f /root/.ssh/openclaw_deploy ]; then
  ssh-keygen -t ed25519 -f /root/.ssh/openclaw_deploy -N "" -C "openclaw-memory-deploy"
fi

# infra key: read-only access to openclaw-aws (infra) repo
if [ ! -f /root/.ssh/openclaw_infra ]; then
  ssh-keygen -t ed25519 -f /root/.ssh/openclaw_infra -N "" -C "openclaw-infra-readonly"
fi

cat > /root/.ssh/config <<'SSHCONFIG'
Host github.com
  IdentityFile /root/.ssh/openclaw_deploy
  StrictHostKeyChecking accept-new

Host github-infra
  HostName github.com
  IdentityFile /root/.ssh/openclaw_infra
  StrictHostKeyChecking accept-new
SSHCONFIG

chmod 600 /root/.ssh/config

echo "[bootstrap] SSH keys generated"
echo "[bootstrap] MEMORY DEPLOY KEY (add to iolalog/openclaw-memory as deploy key, write access):"
cat /root/.ssh/openclaw_deploy.pub
echo "[bootstrap] INFRA READ KEY (add to iolalog/openclaw-aws as deploy key, read-only):"
cat /root/.ssh/openclaw_infra.pub

# ── 5. Configure OpenClaw via its native CLI ──────────────────────────────────
# AWS credentials are provided automatically by the EC2 instance role via IMDS.
# Only OPENROUTER_API_KEY is injected via EnvironmentFile — no AWS keys on disk.

openclaw config set channels.slack.accounts.default.botToken "${slack_bot_token}"
openclaw config set channels.slack.accounts.default.appToken "${slack_app_token}"
openclaw config set channels.slack.mode socket
# groupPolicy starts open so the first DM from the owner triggers the pairing prompt.
# openclaw pairing approve slack <CODE> writes the owner's user ID to:
#   /root/.openclaw/credentials/slack-default-allowFrom.json
# To tighten immediately after pairing: openclaw config set channels.slack.groupPolicy allowlist
openclaw config set channels.slack.groupPolicy open
# Reply in threads for channel messages (valid values: off, first, all).
# "first" = only the opening reply is threaded; "all" = every reply is threaded.
openclaw config set channels.slack.replyToModeByChatType.channel all
openclaw config set gateway.mode local
# Model must be a flat string; "primary"/"fallback" sub-keys are not valid here.
openclaw config set agents.defaults.model "anthropic/claude-sonnet-4.6"
# Enable memory search with Google embeddings (text-embedding-004).
openclaw config set agents.defaults.memorySearch.enabled true
openclaw config set agents.defaults.memorySearch.provider gemini

# ── Model allowlist ───────────────────────────────────────────────────────────
# Set agents.defaults.models to restrict which models can be used and provide
# short aliases for /model switching. Only EU/US-hosted providers are included.
#
# After deploy, apply via: openclaw config set agents.defaults.models '{...}'
# or edit ~/.openclaw/openclaw.json directly. Current allowlist (as of 2026-03-08):
#
#   sonnet  → openrouter/anthropic/claude-sonnet-4-6         (default: chat + coding)
#   codex   → openrouter/openai/gpt-5.3-codex                (agentic coding)
#   opus    → openrouter/anthropic/claude-opus-4.6           (deep research, design)
#   gemini  → openrouter/google/gemini-3.1-pro-preview       (document parsing, multimodal)
#   flash   → openrouter/google/gemini-3.1-flash-lite-preview (simple/cheap tasks)
#
# openclaw config set does not support nested JSON objects well — edit the JSON directly:
#   ~/.openclaw/openclaw.json → agents.defaults.models
# See: iolalog/openclaw-memory MEMORY.md for the current allowlist.

# Write secrets as a systemd EnvironmentFile.
# AWS credentials are NOT written here — they come from the instance role via IMDS.
mkdir -p /etc/openclaw /var/tmp/openclaw-compile-cache
cat > /etc/openclaw/env <<ENVFILE
OPENROUTER_API_KEY=${openrouter_api_key}
GEMINI_API_KEY=${gemini_api_key}
OPENCLAW_INFRA_REPO=${github_infra_repo}
OPENCLAW_MEMORY_REPO=${github_memory_repo}
NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
OPENCLAW_NO_RESPAWN=1
ENVFILE

# Fetch Anthropic API key from Parameter Store (requires ssm:GetParameter on /openclaw/*)
ANTHROPIC_API_KEY=$(aws ssm get-parameter \
  --name "/openclaw/anthropic-api-key" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region eu-north-1 2>/dev/null || echo "")
if [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" >> /etc/openclaw/env
else
  echo "[bootstrap] WARNING: could not fetch /openclaw/anthropic-api-key from Parameter Store"
fi
chmod 600 /etc/openclaw/env

echo "[bootstrap] OpenClaw config written"

# ── 5b. Config snapshots and recovery scripts ────────────────────────────────
# Save a "safe" copy of the bootstrap config (never overwritten after this point)
# and an initial "known-good" copy (refreshed by cron when service is healthy).
mkdir -p /var/lib/openclaw
cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.safe.json
cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.known-good.json
chmod 600 /root/.openclaw/openclaw.safe.json /root/.openclaw/openclaw.known-good.json

# ExecStartPre hook: counts consecutive failures; restores known-good after 3.
cat > /usr/local/bin/openclaw-prestart <<'PRESTART'
#!/bin/bash
FAIL_COUNT_FILE=/var/lib/openclaw/fail-count
KNOWN_GOOD=/root/.openclaw/openclaw.known-good.json
LIVE=/root/.openclaw/openclaw.json

count=0
if [ -f "$FAIL_COUNT_FILE" ]; then
  count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fi

if [ "$count" -ge 3 ]; then
  echo "[openclaw-prestart] 3+ failures — restoring known-good config"
  if [ -f "$KNOWN_GOOD" ]; then
    cp "$KNOWN_GOOD" "$LIVE"
    echo "[openclaw-prestart] Restored $KNOWN_GOOD -> $LIVE"
  else
    echo "[openclaw-prestart] WARNING: known-good not found, cannot restore"
  fi
  echo 0 > "$FAIL_COUNT_FILE"
else
  echo $((count + 1)) > "$FAIL_COUNT_FILE"
  echo "[openclaw-prestart] fail-count now $((count + 1))"
fi

exit 0
PRESTART
chmod +x /usr/local/bin/openclaw-prestart

# Manual recovery: openclaw-recover [known-good|safe]
cat > /usr/local/bin/openclaw-recover <<'RECOVER'
#!/bin/bash
MODE="$${1:-known-good}"
LIVE=/root/.openclaw/openclaw.json
FAIL_COUNT_FILE=/var/lib/openclaw/fail-count

case "$MODE" in
  known-good) BACKUP=/root/.openclaw/openclaw.known-good.json ;;
  safe)       BACKUP=/root/.openclaw/openclaw.safe.json ;;
  *)
    echo "Usage: openclaw-recover [known-good|safe]" >&2
    exit 1
    ;;
esac

if [ ! -f "$BACKUP" ]; then
  echo "ERROR: backup not found: $BACKUP" >&2
  exit 1
fi

echo "[openclaw-recover] Restoring $MODE config..."
cp "$BACKUP" "$LIVE"
echo 0 > "$FAIL_COUNT_FILE"
echo "[openclaw-recover] Restarting openclaw-gateway..."
systemctl restart openclaw-gateway
sleep 3
echo "[openclaw-recover] Last 40 journal lines:"
journalctl -u openclaw-gateway -n 40 --no-pager
RECOVER
chmod +x /usr/local/bin/openclaw-recover

# Diagnostics: service state, fail counter, config file inventory, recent logs
cat > /usr/local/bin/openclaw-status <<'STATUS'
#!/bin/bash
FAIL_COUNT_FILE=/var/lib/openclaw/fail-count

echo "=== Service state ==="
systemctl is-active openclaw-gateway && echo "STATUS: active" || echo "STATUS: $(systemctl is-failed openclaw-gateway 2>/dev/null || echo inactive)"
systemctl status openclaw-gateway --no-pager -l 2>/dev/null | head -5

echo ""
echo "=== Fail counter ==="
if [ -f "$FAIL_COUNT_FILE" ]; then
  echo "fail-count: $(cat $FAIL_COUNT_FILE)"
else
  echo "fail-count: 0 (file not found)"
fi

echo ""
echo "=== Config files ==="
for f in /root/.openclaw/openclaw.json \
          /root/.openclaw/openclaw.known-good.json \
          /root/.openclaw/openclaw.safe.json; do
  if [ -f "$f" ]; then
    echo "  EXISTS  $(stat -c '%y' "$f" | cut -d. -f1)  $f"
  else
    echo "  MISSING $f"
  fi
done

echo ""
echo "=== Last 30 journal lines ==="
journalctl -u openclaw-gateway -n 30 --no-pager
STATUS
chmod +x /usr/local/bin/openclaw-status

# Promote current live config to known-good (only when service is healthy)
cat > /usr/local/bin/openclaw-save-known-good <<'SAVESCRIPT'
#!/bin/bash
LIVE=/root/.openclaw/openclaw.json
KNOWN_GOOD=/root/.openclaw/openclaw.known-good.json
FAIL_COUNT_FILE=/var/lib/openclaw/fail-count

if ! systemctl is-active --quiet openclaw-gateway; then
  echo "ERROR: openclaw-gateway is not active — refusing to promote a potentially broken config" >&2
  exit 1
fi

cp "$LIVE" "$KNOWN_GOOD"
echo 0 > "$FAIL_COUNT_FILE"
echo "[openclaw-save-known-good] Promoted live config to known-good"
SAVESCRIPT
chmod +x /usr/local/bin/openclaw-save-known-good

echo "[bootstrap] Recovery scripts installed"

# ── 6. Clone openclaw-memory repo ────────────────────────────────────────────
mkdir -p /root/.openclaw

if [ ! -d /root/.openclaw/workspace/.git ]; then
  # First-time clone — will fail until deploy key is added to GitHub.
  # After adding the key, run: git clone <repo> /root/.openclaw/workspace && systemctl start openclaw-gateway
  git clone "${github_memory_repo}" /root/.openclaw/workspace 2>&1 \
    && echo "[bootstrap] Memory repo cloned to /root/.openclaw/workspace" \
    || echo "[bootstrap] WARNING: Memory repo clone failed — add deploy key to GitHub, then: git clone ${github_memory_repo} /root/.openclaw/workspace && systemctl start openclaw-gateway"
else
  echo "[bootstrap] Memory repo already present, pulling latest"
  git -C /root/.openclaw/workspace pull
fi

# ── 7. Create and enable openclaw-gateway systemd service ─────────────────────
cat > /etc/systemd/system/openclaw-gateway.service <<SERVICE
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/.openclaw/workspace
Environment=HOME=/root
ExecStartPre=/usr/local/bin/openclaw-prestart
ExecStart=/usr/bin/node --max-old-space-size=1500 /usr/bin/openclaw gateway run
Restart=always
RestartSec=10
EnvironmentFile=-/etc/openclaw/env
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl start  openclaw-gateway

echo "[bootstrap] openclaw-gateway service enabled and started"

# ── 7b. Watchdog cron: refresh known-good every 5 min when service is healthy ─
cat > /etc/cron.d/openclaw-watchdog <<'CRON'
*/5 * * * * root systemctl is-active --quiet openclaw-gateway && \
  cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.known-good.json && \
  echo 0 > /var/lib/openclaw/fail-count
CRON
chmod 644 /etc/cron.d/openclaw-watchdog

echo "[bootstrap] Watchdog cron job installed"

# ── 8. Harden OS ──────────────────────────────────────────────────────────────
# Disable SSH password auth (access is via SSM Session Manager only)
if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
  echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi

# Enable UFW: deny all inbound, allow all outbound
# All connections are outbound (SSM, Slack Socket Mode, OpenRouter, GitHub)
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

echo "[bootstrap] OS hardening applied (UFW active, SSH password auth disabled)"
echo "[bootstrap] Done at $(date)"
