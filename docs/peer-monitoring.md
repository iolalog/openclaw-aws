# Peer Monitoring

Two autonomous agents can watch each other for failures using AWS SSM — no shared network, no inbound ports, no dedicated monitoring service. Each agent periodically SSMs into the other, reads a heartbeat file, and confirms the gateway process is alive. If checks fail twice in a row, the monitoring agent DMs the human owner.

This repo (openclaw-aws) and [hermes-aws](https://github.com/iolalog/hermes-aws) implement this pattern for each other.

## How it works

```
OpenClaw (hourly cron)
  └─ aws ssm send-command → Hermes instance
       └─ cat /var/lib/hermes/heartbeat.json
          pgrep -f "gateway run"
  └─ if failures >= 2 → DM Olav on Slack
```

Hermes writes `/var/lib/hermes/heartbeat.json` every 30 minutes via its own cron:

```json
{"ts":"2026-05-25T13:00:01Z","status":"ok","pid":"203735"}
```

OpenClaw reads this file via SSM and checks two things:
- **Heartbeat freshness** — timestamp must be less than 65 minutes old (30-min cron + 35-min grace)
- **Gateway process** — `pgrep -f "gateway run"` must find a running process

State is tracked in `/var/lib/openclaw/hermes-health-state.json`:

```json
{"failures":0,"last_ok":"2026-05-25T13:21:49Z","alert_sent":false}
```

## Setup

### 1. Deploy both instances first

Both agents need to be running before you wire them together — you need the peer's instance ID.

### 2. Add peer vars to terraform.tfvars

In **openclaw-aws**:
```hcl
peer_instance_id    = "i-0abc1234567890def"   # Hermes instance ID
peer_aws_account_id = ""                        # leave empty if same account
```

In **hermes-aws** (for the reverse path):
```hcl
peer_instance_id    = "i-0abc1234567890def"   # OpenClaw instance ID
peer_aws_account_id = ""
```

### 3. Apply Terraform

```bash
cd infra && terraform apply
```

This creates an IAM inline policy (`openclaw-ssm-send-command`) on the instance role, scoped tightly:

| Action | Resource |
|---|---|
| `ssm:SendCommand` | specific peer EC2 instance + `AWS-RunShellScript` document only |
| `ssm:GetCommandInvocation` | SSM namespace in the account (`arn:aws:ssm:region:account:*`) |

### 4. Deploy the health check script on OpenClaw

```bash
PEER_INSTANCE="i-0abc1234567890def"   # replace with Hermes instance ID
REGION="eu-north-1"

B64=$(base64 -w0 infra/scripts/peer-health-check.sh)
CMD_ID=$(aws ssm send-command \
  --instance-ids <openclaw-instance-id> \
  --document-name AWS-RunShellScript \
  --parameters "{\"commands\":[\"mkdir -p /root/.openclaw/workspace/scripts && echo '$B64' | base64 -d | sed 's|PEER_INSTANCE_PLACEHOLDER|$PEER_INSTANCE|' > /root/.openclaw/workspace/scripts/hermes-health-check.sh && chmod +x /root/.openclaw/workspace/scripts/hermes-health-check.sh && echo DONE\"]}" \
  --region $REGION \
  --query 'Command.CommandId' --output text)
sleep 15
aws ssm get-command-invocation --command-id "$CMD_ID" \
  --instance-id <openclaw-instance-id> --region $REGION \
  --query 'StandardOutputContent' --output text
```

### 5. Add the hourly cron

```bash
aws ssm send-command \
  --instance-ids <openclaw-instance-id> \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["(crontab -l 2>/dev/null; echo \"0 * * * * /root/.openclaw/workspace/scripts/hermes-health-check.sh\") | crontab - && echo DONE"]}' \
  --region eu-north-1
```

### 6. Update HEARTBEAT.md on OpenClaw

OpenClaw reads `HEARTBEAT.md` at each heartbeat poll. Add this entry so it knows to check and alert:

```
- Check /var/lib/openclaw/hermes-health-state.json
  If failures >= 2 and alert_sent is false:
  -> DM <your-slack-user-id>: "Warning: Hermes down? failures=N, last_ok=<ts>, heartbeat_stale=<bool>, gateway_alive=<0|1>"
  -> Set alert_sent:true in the state file
```

### 7. Verify end-to-end

```bash
CMD_ID=$(aws ssm send-command \
  --instance-ids <openclaw-instance-id> \
  --document-name AWS-RunShellScript \
  --parameters '{"commands":["/root/.openclaw/workspace/scripts/hermes-health-check.sh && cat /var/lib/openclaw/hermes-health-state.json"]}' \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text)
sleep 75   # allow ~60s for the nested SSM poll loop to complete
aws ssm get-command-invocation --command-id "$CMD_ID" \
  --instance-id <openclaw-instance-id> --region eu-north-1 \
  --query 'StandardOutputContent' --output text
```

Expected: `{"failures":0,"last_ok":"...","alert_sent":false}`

## IAM design notes

- `ssm:SendCommand` is scoped to a **specific instance ID**, not `*` — an attacker who compromises the OpenClaw role cannot pivot to arbitrary EC2 instances
- `ssm:GetCommandInvocation` needs the SSM resource namespace (`arn:aws:ssm:region:account:*`) — it doesn't operate on EC2 instance ARNs
- The reverse path (Hermes→OpenClaw) is also wired up via `hermes-ssm-send-command` on the Hermes role, ready for symmetric monitoring

## Adapting to other agent pairs

The pattern is agent-framework-agnostic. Any two agents that:
- Run on EC2 with an instance role
- Write a timestamped heartbeat file
- Have a detectable gateway process

can use this setup. Replace the heartbeat path and `pgrep` pattern in `infra/scripts/peer-health-check.sh` as needed.
