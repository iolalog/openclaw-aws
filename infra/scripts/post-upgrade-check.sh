#!/bin/bash
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REGION="${AWS_REGION:-$(terraform -chdir="$ROOT_DIR/infra" output -raw aws_region 2>/dev/null || echo eu-north-1)}"
INSTANCE_ID="${1:-$(terraform -chdir="$ROOT_DIR/infra" output -raw instance_id)}"

COMMANDS_JSON=$(cat <<'JSON'
{
  "commands": [
    "export HOME=/root",
    "echo '=== version ==='",
    "openclaw --version || true",
    "echo '=== config validate ==='",
    "openclaw config validate || true",
    "echo '=== plugins ==='",
    "openclaw channels list || true",
    "openclaw plugins list 2>&1 | grep -i slack || true",
    "echo '=== service ==='",
    "systemctl is-active openclaw-gateway",
    "echo '=== watchdog ==='",
    "cat /etc/cron.d/openclaw-watchdog",
    "echo '=== health (heartbeat must say disabled) ==='",
    "openclaw health 2>&1 | grep -iE 'heartbeat|slack|delivery queue' || true",
    "echo '=== cost features (dreaming enabled=false, workshop mode=off) ==='",
    "jq -c '{dreaming: .plugins.entries[\"memory-core\"].config.dreaming, workshop: .skills.workshop}' /root/.openclaw/openclaw.json || true",
    "echo '=== enabled automations ==='",
    "openclaw automations list 2>&1 || true",
    "echo '=== known-good ==='",
    "/usr/local/bin/openclaw-save-known-good || true",
    "ls -l --time-style=long-iso /root/.openclaw/openclaw.json /root/.openclaw/openclaw.known-good.json /root/.openclaw/openclaw.safe.json",
    "echo '=== fail-count ==='",
    "cat /var/lib/openclaw/fail-count 2>/dev/null || echo 0",
    "echo '=== recent-journal ==='",
    "journalctl -u openclaw-gateway -n 60 --no-pager"
  ]
}
JSON
)

COMMAND_ID=$(
  aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "$COMMANDS_JSON" \
    --region "$REGION" \
    --query 'Command.CommandId' \
    --output text
)

echo "CommandId: $COMMAND_ID"
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION"
