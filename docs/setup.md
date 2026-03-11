# Setup Guide

## Pre-flight: check for existing deployments

```bash
cd infra && terraform state list 2>/dev/null
```

- **Empty output** → proceed with this guide
- **Shows `aws_instance.*`** → you already have an EC2 deployment; run `terraform plan` to check drift
- **Shows `aws_lightsail_*`** → you have the old Lightsail deployment; see `docs/archive/lightsail-to-ec2-migration.md`

---

## 1. Slack App

Already completed if you have `xoxb-` and `xapp-` tokens. If not:

1. Go to api.slack.com/apps → Create New App → From scratch
2. Enable Socket Mode under **Settings → Socket Mode** → generate App-Level Token (`xapp-`) with `connections:write` scope
3. Under **OAuth & Permissions**, add Bot Token Scopes:
   - `chat:write`
   - `im:history`, `im:read`, `im:write`
   - `channels:history`, `groups:history`, `mpim:history`
   - `channels:read`, `groups:read`, `mpim:read`
   - `users:read`
   - `app_mentions:read`
   - `assistant:write` (enables typing indicators — also requires Agents & AI Apps feature, see step 7)
   - `reactions:read`, `reactions:write`
   - `pins:read`, `pins:write`
   - `emoji:read`
   - `commands`
   - `files:read`, `files:write`
   - `mpim:write`
4. Under **Event Subscriptions → Subscribe to bot events**, add:
   - `message.im`, `message.channels`, `message.groups`, `message.mpim`
   - `app_mention`
   - `reaction_added`, `reaction_removed`
   - `member_joined_channel`, `member_left_channel`
   - `channel_rename`
   - `pin_added`, `pin_removed`
5. Install app to workspace → copy Bot Token (`xoxb-`)
6. Under **App Home → Show Tabs**, enable **Messages Tab** and allow DMs
7. (Optional) Under **App Features**, enable **Agents & AI Apps** for typing indicators

> **After any scope or event changes: reinstall the app to the workspace.**

## 2. GitHub Repos

```bash
# Infrastructure repo (this one)
gh repo create openclaw-aws --private --description "OpenClaw AWS infrastructure"

# Memory repo — stores agent memory, config, and skills across deploys
gh repo create openclaw-memory --private --description "OpenClaw agent memory and config"
```

## 3. Populate `terraform.tfvars`

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
# Edit with your actual values
```

## 4. Deploy

```bash
cd infra
terraform init
terraform plan   # review what will be created
terraform apply
```

## 5. Add GitHub deploy keys (~3 min after apply)

The bootstrap generates fresh SSH keys. Get them via SSM:

```bash
# Instance ID from Terraform output
terraform output instance_id

# Open a session
aws ssm start-session --target i-XXXXXXXXXXXXXXXXX

# On the instance — two keys:
cat /root/.ssh/openclaw_deploy.pub   # add to openclaw-memory (write access)
cat /root/.ssh/openclaw_infra.pub    # add to openclaw-aws (read-only)
```

Add each key in GitHub → repo → **Settings → Deploy keys**.

Then on the instance, clone the memory repo if bootstrap couldn't (deploy key wasn't added yet):

```bash
git clone git@github.com:YOUR_USERNAME/openclaw-memory.git /var/lib/openclaw/memory
systemctl restart openclaw-gateway
```

## 6. Approve Slack pairing

Send a DM to the bot. It replies with a pairing code:

```
OpenClaw: access not configured.
Your Slack user id: UXXXXXXXXXX
Pairing code: XXXXXXXX
Ask the bot owner to approve with: openclaw pairing approve slack XXXXXXXX
```

Approve via SSM:

```bash
aws ssm send-command \
  --instance-id i-XXXXXXXXXXXXXXXXX \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["openclaw pairing approve slack <CODE>"]}' \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text
```

Then lock down to approved users only:

```bash
aws ssm send-command \
  --instance-id i-XXXXXXXXXXXXXXXXX \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["openclaw config set channels.slack.groupPolicy allowlist"]}' \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text
```

Config changes are hot-reloaded — no restart needed.

## 7. Allowlist Slack channels (optional)

By default OpenClaw only responds in DMs. To enable it in a channel, the channel must be explicitly allowlisted — it will not respond in channels that aren't configured, even if the bot is a member.

Get the channel ID from Slack (right-click the channel → **Copy link** — the ID is the `CXXXXXXXXXX` segment at the end), then:

```bash
# Replace C0123456789 with your channel ID
aws ssm send-command \
  --instance-id i-XXXXXXXXXXXXXXXXX \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["openclaw config set channels.slack.groups.C0123456789.enabled true"]}' \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text
```

Repeat for each channel. Config is hot-reloaded — no restart needed.

> **Thread replies in channels:** The bootstrap sets `replyToModeByChatType.channel = "all"` so the bot always replies in-thread in channels. `"first"` would only thread the opening reply; subsequent replies would go to the main channel. `"off"` disables threading entirely (including explicit `[[reply_to_*]]` tags).

## 8. Verify

```bash
# Smoke tests (from repo root)
uv run pytest tests/smoke/ -v

# On the instance
journalctl -u openclaw-gateway -f
```

## 9. Teardown

```bash
cd infra && terraform destroy
```

Fully reproducible — `terraform apply` gives a clean slate. Memory and config in the `openclaw-memory` GitHub repo survive teardown.
