# Manual Setup Steps

These steps must be done once before or alongside `terraform apply`.

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
   - `assistant:write` (enables typing indicators — also requires Agents & AI Apps feature, see step 6)
   - `reactions:read`, `reactions:write`
   - `pins:read`, `pins:write`
   - `emoji:read`
   - `commands`
   - `files:read`, `files:write`
   - `mpim:write`
4. Under **Event Subscriptions → Subscribe to bot events**, add:
   - `message.im` — direct messages to the bot
   - `message.channels`, `message.groups`, `message.mpim` — channel/group messages
   - `app_mention` — mentions in channels
   - `reaction_added`, `reaction_removed`
   - `member_joined_channel`, `member_left_channel`
   - `channel_rename`
   - `pin_added`, `pin_removed`
5. Install app to workspace → copy Bot Token (`xoxb-`)
6. Under **App Home → Show Tabs**, enable **Messages Tab** and allow DMs
7. (Optional, for streaming/typing indicators) Under **App Features**, enable **Agents & AI Apps**

> **After any changes to scopes or event subscriptions, reinstall the app to the workspace** (Settings → Install App → Reinstall to Workspace) for changes to take effect.

## 2. GitHub Repos

```bash
# Infrastructure repo (this one)
gh repo create openclaw-aws --private --description "OpenClaw AWS infrastructure"

# Memory repo
gh repo create openclaw-memory --private --description "OpenClaw agent memory and config"
```

## 3. Populate terraform.tfvars

```bash
cp infra/terraform.tfvars.example infra/terraform.tfvars
# Edit infra/terraform.tfvars with your actual values
```

## 4. Deploy

```bash
cd infra
terraform init
terraform plan
terraform apply
```

## 5. Add GitHub Deploy Key (~2 min after apply)

Once the instance is up and the bootstrap script has run:

```bash
# Get managed instance ID
aws ssm describe-instance-information \
  --query 'InstanceInformationList[*].InstanceId' --output text

# Open a session
aws ssm start-session --target mi-XXXXXXXXXXXXXXXXX

# On the instance:
sudo cat /root/.ssh/openclaw_deploy.pub
```

Copy the public key and add it to:
`github.com/YOUR_USERNAME/openclaw-memory` → **Settings → Deploy keys**
(enable **Allow write access**)

> **Note:** GitHub will suggest using a GitHub App instead. For a single private repo this deploy key is fine. A GitHub App would give shorter-lived tokens and finer-grained permissions, but requires more setup. Consider it if you later add more repos or tighter security requirements.

Then on the instance:
```bash
git clone git@github.com:YOUR_USERNAME/openclaw-memory.git /var/lib/openclaw/memory
sudo systemctl restart openclaw-gateway
```

## 6. Approve Slack Pairing and Lock Down Access

Send a DM to the bot. It will reply with a pairing code:

```
OpenClaw: access not configured.
Your Slack user id: UXXXXXXXXXX
Pairing code: XXXXXXXX
Ask the bot owner to approve with: openclaw pairing approve slack XXXXXXXX
```

Approve from your machine via SSM:

```bash
aws ssm send-command \
  --instance-id mi-XXXXXXXXXXXXXXXXX \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["openclaw pairing approve slack <PAIRING_CODE>"]}' \
  --query 'Command.CommandId' --output text
```

After approval, tighten access so only approved users can interact (the approved user ID is written to `/root/.openclaw/credentials/slack-default-allowFrom.json` by the pairing step):

```bash
aws ssm send-command \
  --instance-id mi-XXXXXXXXXXXXXXXXX \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["openclaw config set channels.slack.groupPolicy allowlist"]}' \
  --query 'Command.CommandId' --output text
```

The config change is picked up live — no restart needed. Verify with another DM.

## 7. Verify

```bash
# On the instance
sudo systemctl status openclaw-gateway
sudo journalctl -u openclaw-gateway -f

# From your machine (after instance is SSM-registered)
uv run pytest tests/smoke/ -v
```

## Teardown

```bash
cd infra && terraform destroy
```

This gives a completely clean slate. All state is local (`terraform.tfstate`, gitignored).
