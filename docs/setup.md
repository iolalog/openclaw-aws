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
# Edit with your GitHub repo SSH URLs and region (no secrets — those go in SSM, see step 3b)
```

## 3b. Store all secrets in Parameter Store

All secrets are fetched from AWS SSM Parameter Store at boot — **none** are in `terraform.tfvars`. Store them once before deploying:

```bash
aws ssm put-parameter \
  --name "/openclaw/anthropic-api-key" \
  --value "sk-ant-YOUR_KEY_HERE" \
  --type SecureString \
  --region eu-north-1

aws ssm put-parameter \
  --name "/openclaw/slack-bot-token" \
  --value "xoxb-YOUR_TOKEN_HERE" \
  --type SecureString \
  --region eu-north-1

aws ssm put-parameter \
  --name "/openclaw/slack-app-token" \
  --value "xapp-YOUR_TOKEN_HERE" \
  --type SecureString \
  --region eu-north-1

aws ssm put-parameter \
  --name "/openclaw/openrouter-api-key" \
  --value "sk-or-YOUR_KEY_HERE" \
  --type SecureString \
  --region eu-north-1

aws ssm put-parameter \
  --name "/openclaw/gemini-api-key" \
  --value "AIza-YOUR_KEY_HERE" \
  --type SecureString \
  --region eu-north-1
```

The instance role is granted `ssm:GetParameter` on `/openclaw/*` by Terraform. The bootstrap fetches all secrets at first boot and writes them into `/etc/openclaw/env`.

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
git clone git@github.com:YOUR_USERNAME/openclaw-memory.git /root/.openclaw/workspace
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

## 9. Recovery (break-glass)

OpenClaw can modify its own gateway config. If it sets an invalid value the gateway crashes into a restart loop and becomes unreachable via Slack. Three recovery tiers are available — pick the first one that applies.

### Tier 1 — Automatic (no human needed)

The service has a self-healing loop built in:

- `Restart=always` — systemd restarts on any exit
- `ExecStartPre=/usr/local/bin/openclaw-prestart` — counts consecutive failures; after **3 failed starts** it automatically restores the known-good config and resets the counter
- A cron job (`/etc/cron.d/openclaw-watchdog`) refreshes the known-good snapshot every 5 minutes while the service is healthy

In most cases the service heals itself within 30–60 seconds. No action needed — just wait.

### Tier 2 — Mobile (AWS app, ~3 taps)

If the automatic recovery doesn't fire or you want to force it immediately:

1. Open the **AWS Console mobile app**
2. Hamburger menu → **Systems Manager** → **Run Command** → **Create command**
3. Search for `OpenClawStatus` → select instance `i-0f94c1bdc56033056` (or by tag `Name=openclaw`) → **Run** → check output to diagnose
4. If recovery is needed: repeat with `OpenClawRecover`, leave **Mode** as `known-good` → **Run**
5. Follow up with `OpenClawStatus` to confirm the service came up

**Which Mode to pick:**
- `known-good` — last config that was running without errors (refreshed by cron every 5 min while healthy). Use this first.
- `safe` — factory config written at bootstrap time. Use this if known-good is also broken (e.g. a bad model string was saved before the cron refreshed).

### Tier 3 — SSM shell (laptop fallback)

**Via Run Command (non-interactive):**

```bash
# Check status
aws ssm send-command \
  --instance-id i-0f94c1bdc56033056 \
  --document-name "OpenClawStatus" \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text

# Recover (known-good is default)
aws ssm send-command \
  --instance-id i-0f94c1bdc56033056 \
  --document-name "OpenClawRecover" \
  --parameters '{"Mode":["known-good"]}' \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text

# Recover with safe config (if known-good is also broken)
aws ssm send-command \
  --instance-id i-0f94c1bdc56033056 \
  --document-name "OpenClawRecover" \
  --parameters '{"Mode":["safe"]}' \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text
```

**Via interactive shell:**

```bash
aws ssm start-session --target i-0f94c1bdc56033056 --region eu-north-1

# Then on the instance:
openclaw-status           # diagnose
openclaw-recover          # restore known-good and restart
openclaw-recover safe     # restore bootstrap config and restart
```

### Manual checkpoint: promote current config to known-good

After intentional config changes that are confirmed working, lock in the current state:

```bash
aws ssm send-command \
  --instance-id i-0f94c1bdc56033056 \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["/usr/local/bin/openclaw-save-known-good"]}' \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text
```

This is also done automatically by the watchdog cron every 5 minutes while the service is healthy.

## 11. Teardown

```bash
cd infra && terraform destroy
```

Fully reproducible — `terraform apply` gives a clean slate. Memory and config in the `openclaw-memory` GitHub repo survive teardown.
