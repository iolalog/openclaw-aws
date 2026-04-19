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

# Pre-populate GitHub's published SSH host keys (avoids TOFU on first connect)
cat >> /root/.ssh/known_hosts <<'KNOWNHOSTS'
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshh1lmVE0eHZBFHvWMnq5lzd1jEJhEJHjLBSfY+1VGR+fGxEzLNMkIWjEVyAe3TGa0BPeGfvzwPjQKPkG8F8cJxqjgPiMOWHDq9J2jqGnkPjzpbN0CbhDOy1z8p8+1XHwEr1vP3a/2/aWvX6dKJR5KuqQgFwBqxB5z6E2K/2ZpIk1oVCi0Qn1LpUg3bXwuDkGk4e/bHH2rNnCR5P1L9gU0t7FQYF4r3EKuMQh0BIH0UiPgM38GhqRDIrVBHj0+HgzrGVPjKXhWdxZF2rqLMXNc3q4wBdCRibZlXA5PzXk3fS1vmpzQqLJNt4Gu2Nkk4mTXj/4CxKLtbp6EHaL7kxiPdlZ4KM4MNHRCc04B8i/Hp8zHtlT4pZA2FVz1O+SX/JOJRSMrHXGqz8WZXEkWFgH6lBTUH8PY81yiMd0T3MgzNb7M1WLKWkrAP+BqHHDKM7tJoH/d1EAmMxsMnBxUQaC3MH5y0FhS7FNq2Q8PBTZ+bCHRzM=
KNOWNHOSTS
chmod 600 /root/.ssh/known_hosts

cat > /root/.ssh/config <<'SSHCONFIG'
Host github.com
  IdentityFile /root/.ssh/openclaw_deploy
  StrictHostKeyChecking yes

Host github-infra
  HostName github.com
  IdentityFile /root/.ssh/openclaw_infra
  StrictHostKeyChecking yes
SSHCONFIG

chmod 600 /root/.ssh/config

echo "[bootstrap] SSH keys generated"
echo "[bootstrap] MEMORY DEPLOY KEY (add to YOUR_USERNAME/openclaw-memory as deploy key, write access):"
cat /root/.ssh/openclaw_deploy.pub
echo "[bootstrap] INFRA READ KEY (add to YOUR_USERNAME/openclaw-aws as deploy key, read-only):"
cat /root/.ssh/openclaw_infra.pub

# ── 5. Configure OpenClaw via its native CLI ──────────────────────────────────
# AWS credentials are provided automatically by the EC2 instance role via IMDS.
# All secrets are fetched from SSM Parameter Store — none are in user_data or Terraform state.

# ── Fetch all secrets from Parameter Store ────────────────────────────────────
# Instance role has ssm:GetParameter on /openclaw/*
_ssm() { aws ssm get-parameter --name "$1" --with-decryption \
  --query Parameter.Value --output text --region "${aws_region}" 2>/dev/null || echo ""; }
SLACK_BOT_TOKEN=$(_ssm /openclaw/slack-bot-token)
SLACK_APP_TOKEN=$(_ssm /openclaw/slack-app-token)
OPENROUTER_API_KEY=$(_ssm /openclaw/openrouter-api-key)
GEMINI_API_KEY=$(_ssm /openclaw/gemini-api-key)
ANTHROPIC_API_KEY=$(_ssm /openclaw/anthropic-api-key)
for v in SLACK_BOT_TOKEN SLACK_APP_TOKEN OPENROUTER_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY; do
  [ -z "$${!v}" ] && echo "[bootstrap] WARNING: could not fetch SSM param for $v"
done

openclaw config set channels.slack.accounts.default.botToken "$SLACK_BOT_TOKEN"
openclaw config set channels.slack.accounts.default.appToken "$SLACK_APP_TOKEN"
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
openclaw config set agents.defaults.model "anthropic/claude-sonnet-4-6"
# Enable memory search with Google embeddings (text-embedding-004).
openclaw config set agents.defaults.memorySearch.enabled true
openclaw config set agents.defaults.memorySearch.provider gemini

# ── Heartbeat config ──────────────────────────────────────────────────────────
# target "last" routes heartbeat output to the last used external channel (Slack DM).
# directPolicy "allow" permits DM-style delivery.
# lightContext true prevents prompt bloat — heartbeat context must stay small.
openclaw config set agents.defaults.heartbeat.every "30m"
openclaw config set agents.defaults.heartbeat.target "last"
openclaw config set agents.defaults.heartbeat.directPolicy "allow"
openclaw config set agents.defaults.heartbeat.lightContext true

# ── Model allowlist ───────────────────────────────────────────────────────────
# Set agents.defaults.models to restrict which models can be used and provide
# short aliases for /model switching. Only EU/US-hosted providers are included.
#
# After deploy, apply via: openclaw config set agents.defaults.models '{...}'
# or edit ~/.openclaw/openclaw.json directly. Current allowlist (as of 2026-03-08):
#
#   sonnet  → anthropic/claude-sonnet-4-6                     (default: chat + coding)
#   codex   → openrouter/openai/gpt-5.3-codex                (agentic coding)
#   opus    → anthropic/claude-opus-4-6                       (deep research, design)
#   gemini  → openrouter/google/gemini-3.1-pro-preview       (document parsing, multimodal)
#   flash   → openrouter/google/gemini-3.1-flash-lite-preview (simple/cheap tasks)
#
# openclaw config set does not support nested JSON objects well — edit the JSON directly:
#   ~/.openclaw/openclaw.json → agents.defaults.models
# See: YOUR_USERNAME/openclaw-memory MEMORY.md for the current allowlist.

# Write systemd EnvironmentFile — non-secret values only in the heredoc.
# Secrets are appended from shell variables fetched above from Parameter Store.
# AWS credentials are NOT written here — they come from the instance role via IMDS.
mkdir -p /etc/openclaw /var/tmp/openclaw-compile-cache
cat > /etc/openclaw/env <<ENVFILE
OPENCLAW_INFRA_REPO=${github_infra_repo}
OPENCLAW_MEMORY_REPO=${github_memory_repo}
NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
OPENCLAW_NO_RESPAWN=1
ENVFILE
# Append secrets from shell variables (not exposed in user_data or Terraform state)
printf 'OPENROUTER_API_KEY=%s\nGEMINI_API_KEY=%s\nANTHROPIC_API_KEY=%s\n' \
  "$OPENROUTER_API_KEY" "$GEMINI_API_KEY" "$ANTHROPIC_API_KEY" >> /etc/openclaw/env
chmod 600 /etc/openclaw/env

echo "[bootstrap] OpenClaw config written"

# ── 5b. Config snapshots and recovery scripts ────────────────────────────────
# Save a "safe" copy of the bootstrap config (never overwritten after this point)
# and an initial "known-good" copy (refreshed by cron when service is healthy).
mkdir -p /var/lib/openclaw
cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.safe.json
cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.known-good.json
chmod 600 /root/.openclaw/openclaw.safe.json /root/.openclaw/openclaw.known-good.json

# Model ID normalizer: convert dot-notation version suffixes to dash.
# e.g. "anthropic/claude-sonnet-4.6" -> "anthropic/claude-sonnet-4-6"
# Anchored to end-of-string so Gemini names (gemini-3.1-flash) and
# OpenAI names (gpt-5.3-codex) are untouched — only trailing -N.M is fixed.
cat > /usr/local/bin/openclaw-normalize-models <<'NORMALIZE'
#!/usr/bin/env python3
import json, re, sys, shutil

def normalize(s):
    if '/' not in s:
        return s
    return re.sub(r'(-\d+)\.(\d+)$', r'\1-\2', s)

def walk(obj):
    if isinstance(obj, str): return normalize(obj)
    if isinstance(obj, list): return [walk(i) for i in obj]
    if isinstance(obj, dict): return {k: walk(v) for k, v in obj.items()}
    return obj

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
out = walk(cfg)
if out != cfg:
    shutil.copy(path, path + '.prenorm-bak')
    with open(path, 'w') as f:
        json.dump(out, f, indent=2)
    print(f'[openclaw-prestart] Normalized dot-notation model IDs in {path}')
NORMALIZE
chmod +x /usr/local/bin/openclaw-normalize-models

# ExecStartPre hook: normalizes model IDs, counts consecutive failures, restores known-good after 3.
cat > /usr/local/bin/openclaw-prestart <<'PRESTART'
#!/bin/bash
FAIL_COUNT_FILE=/var/lib/openclaw/fail-count
KNOWN_GOOD=/root/.openclaw/openclaw.known-good.json
LIVE=/root/.openclaw/openclaw.json

# ── Model ID normalization ────────────────────────────────────────────────────
# Runs on every start so openclaw self-upgrades that change API format cannot break us.
normalize_model_ids() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 /usr/local/bin/openclaw-normalize-models "$cfg"
}

normalize_model_ids "$LIVE"

# ── Fail count and known-good restoration ─────────────────────────────────────
count=0
if [ -f "$FAIL_COUNT_FILE" ]; then
  count=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fi

if [ "$count" -ge 3 ]; then
  echo "[openclaw-prestart] 3+ failures — restoring known-good config"
  if [ -f "$KNOWN_GOOD" ]; then
    cp "$KNOWN_GOOD" "$LIVE"
    echo "[openclaw-prestart] Restored $KNOWN_GOOD -> $LIVE"
    # Normalize the restored config too — known-good may pre-date a format change
    normalize_model_ids "$LIVE"
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

# Promote current live config to known-good (only when service is proven healthy)
cat > /usr/local/bin/openclaw-save-known-good <<'SAVESCRIPT'
#!/bin/bash
LIVE=/root/.openclaw/openclaw.json
KNOWN_GOOD=/root/.openclaw/openclaw.known-good.json
FAIL_COUNT_FILE=/var/lib/openclaw/fail-count
MIN_UPTIME_SECS=90

if ! systemctl is-active --quiet openclaw-gateway; then
  echo "ERROR: openclaw-gateway is not active — refusing to promote a potentially broken config" >&2
  exit 1
fi

# ── Health gate: require proof the current config actually works ───────────────
# "Active" only means the process is running — it doesn't mean requests succeed.
# After upgrades the service can appear healthy while every primary-model request
# silently falls back to the last-resort fallback (seen twice: OOM recovery and
# 2026.3.24 upgrade). We require two signals before promoting:
#
#   1. At least one Slack dialogue was processed since this process started.
#      (Confirms the Slack integration is live and a real message was handled.)
#
#   2. Zero model_not_found errors since start.
#      (model_not_found means the primary model is broken; requests fall through
#      to the last fallback. This is the exact failure mode we've seen.)
#
# Newer OpenClaw builds no longer emit the old Slack dialogue marker reliably.
# We therefore use a layered gate:
#
#   - Prefer explicit "real traffic" markers when present.
#   - Otherwise, allow promotion after a short stable window if there are no
#     known bad signals (model_not_found, overloads, stuck typing TTL).

START_TS=$(systemctl show openclaw-gateway --property=ActiveEnterTimestamp --value 2>/dev/null \
  | sed 's/ UTC$//')
ACTIVE_ENTER_SECS=$(systemctl show openclaw-gateway --property=ActiveEnterTimestampMonotonic --value 2>/dev/null || echo 0)
NOW_SECS=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)

if [ -z "$START_TS" ]; then
  echo "ERROR: could not determine service start time — skipping promotion" >&2
  exit 1
fi

LOG_SINCE_START=$(journalctl -u openclaw-gateway --since "$START_TS" --no-pager -q 2>/dev/null || true)
UPTIME_SECS=0
if [ -n "${ACTIVE_ENTER_SECS:-}" ] && [ "${ACTIVE_ENTER_SECS:-0}" -gt 0 ] 2>/dev/null; then
  UPTIME_SECS=$((NOW_SECS - (ACTIVE_ENTER_SECS / 1000000)))
fi

SLACK_ACTIVITY=$(
  printf '%s\n' "$LOG_SINCE_START" \
    | grep -E -c 'lane=session:agent:main:slack:channel:|embedded run agent end|typing TTL reached' || true
)

MODEL_NOT_FOUND=$(printf '%s\n' "$LOG_SINCE_START" | grep -c 'reason=model_not_found' || true)
OVERLOADED=$(printf '%s\n' "$LOG_SINCE_START" | grep -c 'overloaded_error\|error=The AI service is temporarily overloaded' || true)
TYPING_TTL=$(printf '%s\n' "$LOG_SINCE_START" | grep -c 'typing TTL reached' || true)

if [ "${MODEL_NOT_FOUND:-0}" -gt 0 ]; then
  echo "[openclaw-save-known-good] Skipping: $MODEL_NOT_FOUND model_not_found error(s) since start — primary model is broken"
  exit 0
fi

if [ "${OVERLOADED:-0}" -gt 0 ]; then
  echo "[openclaw-save-known-good] Skipping: $OVERLOADED overload error(s) since start"
  exit 0
fi

if [ "${SLACK_ACTIVITY:-0}" -eq 0 ]; then
  if [ "${UPTIME_SECS:-0}" -lt "$MIN_UPTIME_SECS" ]; then
    echo "[openclaw-save-known-good] Skipping: no explicit Slack activity markers yet and uptime is only ${UPTIME_SECS}s"
    exit 0
  fi
  echo "[openclaw-save-known-good] No explicit Slack activity markers found; promoting after ${UPTIME_SECS}s of stable uptime with zero known model errors"
elif [ "${TYPING_TTL:-0}" -gt 0 ]; then
  echo "[openclaw-save-known-good] Skipping: saw $TYPING_TTL typing TTL event(s) since start — at least one Slack run stalled"
  exit 0
fi

cp "$LIVE" "$KNOWN_GOOD"
echo 0 > "$FAIL_COUNT_FILE"
echo "[openclaw-save-known-good] Promoted live config to known-good (slack_activity=$SLACK_ACTIVITY, model_errors=0, overload_errors=0, uptime=${UPTIME_SECS}s)"
SAVESCRIPT
chmod +x /usr/local/bin/openclaw-save-known-good

echo "[bootstrap] Recovery scripts installed"

# Upgrade wrapper: stops the service, installs latest openclaw, cleans npm cache, restarts.
# OpenClaw must always use this instead of running npm install -g directly — upgrading
# in-flight corrupts the package because node holds the module files open while npm
# tries to replace them.
cat > /usr/local/bin/openclaw-upgrade <<'UPGRADE'
#!/bin/bash
set -uo pipefail

trap 'echo "[openclaw-upgrade] ERROR — restarting service with existing install"; systemctl start openclaw-gateway.service || true' ERR

echo "[openclaw-upgrade] stopping service..."
systemctl stop openclaw-gateway.service
echo "[openclaw-upgrade] installing latest openclaw..."
npm install -g openclaw
echo "[openclaw-upgrade] cleaning npm cache..."
npm cache clean --force
echo "[openclaw-upgrade] version: $(openclaw --version 2>&1 | head -1)"
echo "[openclaw-upgrade] starting service..."
systemctl start openclaw-gateway.service
echo "[openclaw-upgrade] done."
UPGRADE
chmod +x /usr/local/bin/openclaw-upgrade

echo "[bootstrap] Upgrade wrapper installed"

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
*/5 * * * * root /usr/local/bin/openclaw-save-known-good
CRON
chmod 644 /etc/cron.d/openclaw-watchdog

echo "[bootstrap] Watchdog cron job installed"

# Weekly npm cache clean — prevents disk buildup between openclaw upgrades
printf '# Weekly npm cache clean to prevent disk buildup between openclaw upgrades\n0 3 * * 0  root  npm cache clean --force\n' > /etc/cron.d/npm-cache-clean
chmod 644 /etc/cron.d/npm-cache-clean

echo "[bootstrap] npm cache clean cron installed"

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
