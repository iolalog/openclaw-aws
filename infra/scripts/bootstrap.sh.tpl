#!/bin/bash
set -eu
exec > /var/log/openclaw-bootstrap.log 2>&1

echo "[bootstrap] Starting at $(date)"

# ── 0. Add swap (npm install needs it on 1GB RAM instances) ───────────────────
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "[bootstrap] 1GB swap created"
fi

# ── 1. Install SSM agent and register with hybrid activation ──────────────────
snap install amazon-ssm-agent --classic || true

# Wait for snap to finish
sleep 5

/snap/amazon-ssm-agent/current/amazon-ssm-agent \
  -register \
  -code "${ssm_activation_code}" \
  -id   "${ssm_activation_id}" \
  -region "${region}" \
  || echo "[bootstrap] SSM register returned non-zero (may already be registered)"

systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service

echo "[bootstrap] SSM agent registered and started"

# ── 2. Install Node.js v22 via NodeSource ─────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl gnupg

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs

echo "[bootstrap] Node.js $(node --version) installed"

# ── 3. Install OpenClaw CLI ───────────────────────────────────────────────────
npm install -g openclaw --no-fund --no-audit

echo "[bootstrap] OpenClaw $(openclaw --version 2>/dev/null || echo '(version check failed)') installed"

# ── 4. Generate Ed25519 deploy key for openclaw-memory repo ──────────────────
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ ! -f /root/.ssh/openclaw_deploy ]; then
  ssh-keygen -t ed25519 -f /root/.ssh/openclaw_deploy -N "" -C "openclaw-memory-deploy"
fi

cat > /root/.ssh/config <<'SSHCONFIG'
Host github.com
  IdentityFile /root/.ssh/openclaw_deploy
  StrictHostKeyChecking accept-new
SSHCONFIG

chmod 600 /root/.ssh/config

echo "[bootstrap] Deploy key generated at /root/.ssh/openclaw_deploy.pub"
echo "[bootstrap] PUBLIC KEY (add to GitHub repo as deploy key with write access):"
cat /root/.ssh/openclaw_deploy.pub

# ── 5. Configure OpenClaw via its native CLI ──────────────────────────────────
# openclaw stores config in ~/.openclaw/openclaw.json (managed via `openclaw config set`).
# The --config flag does not exist; write to native config instead.

openclaw config set channels.slack.accounts.default.botToken "${slack_bot_token}"
openclaw config set channels.slack.accounts.default.appToken "${slack_app_token}"
openclaw config set channels.slack.mode socket
# Start open so the first DM triggers the pairing prompt.
# After running `openclaw pairing approve slack <CODE>`, tighten to allowlist:
#   openclaw config set channels.slack.groupPolicy allowlist
# The approved user ID is stored in /root/.openclaw/credentials/slack-default-allowFrom.json
openclaw config set channels.slack.groupPolicy open
openclaw config set gateway.mode local
# Model must be a flat string; "primary"/"fallback" sub-keys are not valid.
openclaw config set agents.defaults.model "openrouter/anthropic/claude-sonnet-4-6"

# Write API keys as a systemd EnvironmentFile (kept outside the openclaw config for clarity)
mkdir -p /etc/openclaw
cat > /etc/openclaw/env <<ENVFILE
OPENROUTER_API_KEY=${openrouter_api_key}
AWS_ACCESS_KEY_ID=${aws_access_key_id}
AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
AWS_DEFAULT_REGION=${region}
ENVFILE
chmod 600 /etc/openclaw/env

echo "[bootstrap] OpenClaw config written"

# ── 6. Clone openclaw-memory repo ────────────────────────────────────────────
mkdir -p /var/lib/openclaw

if [ ! -d /var/lib/openclaw/memory/.git ]; then
  # First-time clone — will fail until deploy key is added to GitHub.
  # The service will retry on start.
  git clone "${github_memory_repo}" /var/lib/openclaw/memory 2>&1 \
    && echo "[bootstrap] Memory repo cloned" \
    || echo "[bootstrap] WARNING: Memory repo clone failed — add deploy key to GitHub, then: git clone ${github_memory_repo} /var/lib/openclaw/memory"
else
  echo "[bootstrap] Memory repo already present, pulling latest"
  git -C /var/lib/openclaw/memory pull
fi

# ── 7. Create and enable openclaw-gateway systemd service ─────────────────────
cat > /etc/systemd/system/openclaw-gateway.service <<SERVICE
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/node --max-old-space-size=800 /usr/bin/openclaw gateway run
Restart=on-failure
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
