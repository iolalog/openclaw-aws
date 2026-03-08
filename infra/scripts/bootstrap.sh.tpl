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
openclaw config set gateway.mode local
# Model must be a flat string; "primary"/"fallback" sub-keys are not valid here.
openclaw config set agents.defaults.model "openrouter/anthropic/claude-sonnet-4-6"
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
chmod 600 /etc/openclaw/env

echo "[bootstrap] OpenClaw config written"

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
ExecStart=/usr/bin/openclaw gateway run
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
