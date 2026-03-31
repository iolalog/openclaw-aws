#!/bin/bash
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
REGION="${AWS_REGION:-$(terraform -chdir="$ROOT_DIR/infra" output -raw aws_region 2>/dev/null || echo eu-north-1)}"
INSTANCE_ID="${1:-$(terraform -chdir="$ROOT_DIR/infra" output -raw instance_id)}"

COMMANDS_JSON=$(cat <<'JSON'
{
  "commands": [
    "echo '=== version ==='",
    "openclaw --version || true",
    "echo '=== schema ==='",
    "openclaw config schema >/dev/null && echo schema-ok",
    "echo '=== service ==='",
    "systemctl is-active openclaw-gateway",
    "echo '=== watchdog ==='",
    "cat /etc/cron.d/openclaw-watchdog",
    "echo '=== heartbeat ==='",
    "sed -n '/\"heartbeat\"/,/^[[:space:]]*}/p' /root/.openclaw/openclaw.json || true",
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
