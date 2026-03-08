# OpenClaw on AWS — Secure Sandbox Setup

> **Inspired by:** [Running OpenClaw on AWS Lightsail](https://awsfundamentals.com/blog/lightsail-openclaw) (awsfundamentals.com) — the reference architecture this setup is based on.

## Context

Always-on OpenClaw autonomous AI agent on AWS Lightsail, with strict control over what it can access and do. Follows the hardened Lightsail pattern from the article above. User has an OpenRouter API key and AWS CLI access.

### Messaging channel decision

No messaging platform supports E2E encryption for bots (Telegram's Secret Chats explicitly exclude bots; Slack, Discord, WhatsApp all store messages server-side). The security analysis in `docs/messaging-channel-decision.md` concludes:

- **Phase 1**: Slack (Socket Mode) — no inbound ports, follows the reference architecture exactly, fastest path to working system
- **Phase 2** (future migration): Self-hosted Matrix/Synapse on a second Lightsail instance for E2E encryption — a contained swap in OpenClaw config
- **Secondary channel**: Proton Mail for sensitive alerts/reports/documents (user has Proton subscription)

For financial data (bank transactions etc.), treat the Slack channel as a command interface only — don't pass raw account numbers or credentials through it. Sensitive outputs should be routed to Proton Mail.

### OpenRouter vs Bedrock: Why OpenRouter wins here

- User already has the key; zero extra AWS IAM setup for LLM access
- Gemini 2.5 Flash Lite at $0.075/$0.30 per M tokens — ~10x cheaper than Haiku on Bedrock for background tasks
- Free Gemma 3 tier for heartbeat/routine background tasks
- 300+ models, easy switching, no AWS vendor lock-in for the LLM layer
- Bedrock only wins at heavy Haiku usage with strict AWS compliance requirements — not relevant here

---

## Architecture

```
Your phone/desktop (Slack)
        |
  Slack servers (Socket Mode — outbound only, no inbound)
        |
  [Lightsail micro_3_0 — $7/month, Ubuntu 24.04]
  OpenClaw daemon
        |
  ┌─────┴──────┐
  OpenRouter   GitHub private repo (memory/config/skills)
  (LLM API)

  AWS SSM Session Manager ← your terminal access (no SSH, no open port 22)
```

**Security controls:**
- Port 443 only — port 22 never opened
- SSM Session Manager replaces SSH entirely
- IAM policy scoped to minimum needed (starts with Cost Explorer read-only only)
- GitHub deploy key scoped to one private repo
- Slack Socket Mode — OpenClaw dials out, no inbound webhook URL
- No secrets hardcoded — all injected via Terraform templatefile at boot
- Fully reproducible: `terraform destroy && terraform apply` gives a clean slate

---

## Cost

| Component | Cost |
|---|---|
| Lightsail micro_3_0 (1GB RAM, 2 vCPU, 40GB SSD) | $7/month |
| OpenRouter (Gemini Flash Lite, background tasks) | ~$0–1/month |
| OpenRouter (Sonnet 4.6 for complex tasks) | Pay per use |
| GitHub private repo (`openclaw-memory`) | Free |
| Slack free workspace | Free |
| **Total baseline** | **~$7/month** |

Note: `nano_3_0` ($5/month, 512MB RAM) is available but may be tight for OpenClaw + Node.js. Start with micro, downgrade if memory headroom allows.

---

## Repo Structure

Good developer practices throughout: infrastructure isolated under `infra/`, smoke tests under `tests/`, docs preserved in `docs/`, Python tooling uses `uv` + `.venv`.

```
openclaw-aws/                     # this repo
├── .gitignore                    # *.tfvars, .terraform/, *.tfstate*, .venv/, __pycache__/
├── .python-version               # e.g. 3.12 (used by uv)
├── pyproject.toml                # uv project — test deps (pytest, boto3, paramiko)
├── uv.lock
│
├── infra/                        # all Terraform
│   ├── main.tf                   # Lightsail instance, static IP, firewall, SSM activation
│   ├── iam.tf                    # IAM roles + least-privilege policies
│   ├── variables.tf              # all input vars (sensitive = true for secrets)
│   ├── outputs.tf                # SSM instance ID, static IP, instructions
│   ├── terraform.tfvars          # GITIGNORED — actual secret values
│   ├── terraform.tfvars.example  # committed template (no real values)
│   └── scripts/
│       └── bootstrap.sh.tpl     # user_data template (templatefile vars injected by TF)
│
├── tests/
│   ├── smoke/                    # post-deploy smoke tests (pytest + boto3)
│   │   ├── conftest.py           # reads terraform output, sets up SSM session
│   │   └── test_openclaw.py      # assert service running, Slack connectivity, IAM limits
│   └── infra/                    # optional: Terratest (Go) or checkov policy checks
│       └── checkov.yaml          # security policy rules (e.g. no open port 22)
│
└── docs/
    ├── messaging-channel-decision.md   # already exists
    ├── setup-plan.md                   # this plan (copied from ~/.claude/plans/)
    ├── setup.md                        # manual steps (Slack app, GitHub deploy key)
    └── skills/                         # notes on OpenClaw skills as they're added
```

### Key conventions
- **Terraform**: all state is local for now (`terraform.tfstate` gitignored); move to S3 backend when stable
- **Secrets**: never committed — `terraform.tfvars` is gitignored, `terraform.tfvars.example` shows shape with placeholder values
- **Python tooling**: `uv sync` to install; `uv run pytest tests/smoke/` to run smoke tests
- **Formatting**: `terraform fmt` before committing infra changes; `uv run ruff format` for Python

---

## Implementation Steps

### Step 0: Prerequisites (pre-Terraform, manual)

**GitHub infra repo** — create and initialise this repo as a private GitHub repo:
```bash
gh repo create openclaw-aws --private --description "OpenClaw AWS infrastructure (Terraform + docs)"
cd /home/olav/github/openclaw-aws
git init
git remote add origin git@github.com:olav/openclaw-aws.git
```
Copy the plan into the repo as a committed document:
```bash
cp ~/.claude/plans/pure-exploring-mango.md docs/setup-plan.md
git add docs/setup-plan.md
git commit -m "docs: add initial setup plan"
git push -u origin main
```

**GitHub memory repo** — create via `gh` CLI:
```bash
gh repo create openclaw-memory --private --description "OpenClaw agent memory and config"
```

**Slack app** (already done):
- Socket Mode enabled, App-Level Token (`xapp-...`) generated with `connections:write` scope
- Bot Token (`xoxb-...`) with scopes: `chat:write`, `im:history`, `im:read`, `im:write`, `users:read`
- Messages Tab enabled in App Home settings

### Step 1: Initialise the Python tooling

```bash
uv init --no-workspace          # creates pyproject.toml, .python-version
uv add --dev pytest boto3 ruff  # test + lint deps
echo '.venv/' >> .gitignore
uv sync
```

### Step 2: Populate `infra/terraform.tfvars`

```hcl
openrouter_api_key = "sk-or-..."
slack_bot_token    = "xoxb-..."
slack_app_token    = "xapp-..."
github_memory_repo = "git@github.com:olav/openclaw-memory.git"
aws_region         = "eu-west-1"
```

### Step 3: Terraform resources

**`infra/variables.tf`** — declare all vars with descriptions and `sensitive = true` for secrets.

**`infra/main.tf`:**

```hcl
resource "aws_lightsail_instance" "openclaw" {
  name              = "openclaw"
  availability_zone = "${var.aws_region}a"
  blueprint_id      = "ubuntu_24_04"
  bundle_id         = "micro_3_0"
  user_data         = templatefile("${path.module}/scripts/bootstrap.sh.tpl", local.bootstrap_vars)
  lifecycle { ignore_changes = [user_data] }
}

resource "aws_lightsail_instance_public_ports" "openclaw" {
  instance_name = aws_lightsail_instance.openclaw.name
  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
  }
  # Port 22 intentionally absent
}

resource "aws_lightsail_static_ip" "openclaw" { name = "openclaw-ip" }
resource "aws_lightsail_static_ip_attachment" "openclaw" {
  static_ip_name = aws_lightsail_static_ip.openclaw.name
  instance_name  = aws_lightsail_instance.openclaw.name
}
```

**`infra/iam.tf`** — SSM hybrid activation (Lightsail can't use IAM instance profiles):

```hcl
resource "aws_iam_role" "ssm_hybrid" {
  name = "openclaw-ssm-hybrid"
  assume_role_policy = jsonencode({
    Statement = [{ Effect = "Allow", Principal = { Service = "ssm.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_hybrid.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_ssm_activation" "openclaw" {
  name               = "openclaw-activation"
  iam_role           = aws_iam_role.ssm_hybrid.name
  registration_limit = 1
}

# Scoped IAM user for OpenClaw skills — expand deliberately as skills are added
resource "aws_iam_user" "openclaw" { name = "openclaw-agent" }
resource "aws_iam_user_policy" "openclaw_minimal" {
  user = aws_iam_user.openclaw.name
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["ce:Get*", "ce:Describe*", "ce:List*"]
      Resource = "*"
    }]
  })
}
resource "aws_iam_access_key" "openclaw" {
  user = aws_iam_user.openclaw.name
}
```

**`infra/outputs.tf`:**
```hcl
output "static_ip"    { value = aws_lightsail_static_ip.openclaw.ip_address }
output "ssm_role_arn" { value = aws_iam_role.ssm_hybrid.arn }
# After apply: find managed instance ID with:
# aws ssm describe-instance-information --query 'InstanceInformationList[*].InstanceId'
```

### Step 4: Bootstrap script (`infra/scripts/bootstrap.sh.tpl`)

Template vars injected by Terraform: `ssm_activation_id`, `ssm_activation_code`, `region`, `openrouter_api_key`, `slack_bot_token`, `slack_app_token`, `github_memory_repo`, `aws_access_key_id`, `aws_secret_access_key`.

Operations (idempotent):
1. Install SSM agent → register with hybrid activation
2. Install Node.js v22 via NodeSource
3. Install OpenClaw: `npm install -g @openclaw/cli`
4. Generate Ed25519 deploy key → `/root/.ssh/openclaw_deploy.pub` (user adds to GitHub manually)
5. Write `/etc/openclaw/openclaw.json` (see below)
6. Clone `openclaw-memory` repo to `/var/lib/openclaw/memory`
7. Enable + start `openclaw-gateway` systemd service

### Step 5: OpenClaw config (written by bootstrap)

```json
{
  "env": {
    "OPENROUTER_API_KEY": "${openrouter_api_key}"
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openrouter/google/gemini-2.5-flash-lite-preview",
        "fallback": "openrouter/anthropic/claude-sonnet-4-6"
      }
    }
  },
  "channels": {
    "slack": {
      "botToken": "${slack_bot_token}",
      "appToken": "${slack_app_token}"
    }
  },
  "memory": {
    "path": "/var/lib/openclaw/memory"
  }
}
```

---

## Verification

```bash
# 1. Lint and validate
cd infra && terraform fmt -check && terraform validate

# 2. Review plan
terraform init && terraform plan

# 3. Apply
terraform apply

# 4. Confirm SSM registration (~2 min after apply)
aws ssm describe-instance-information \
  --query 'InstanceInformationList[*].[InstanceId,PingStatus]'

# 5. Drop into the instance (no SSH needed)
aws ssm start-session --target mi-xxxxxxxx

# 6. On instance — check service
sudo systemctl status openclaw-gateway
sudo journalctl -u openclaw-gateway -f

# 7. Add GitHub deploy key
sudo cat /root/.ssh/openclaw_deploy.pub
# → paste into github.com/olav/openclaw-memory → Settings → Deploy keys (write access)

# 8. Send a DM to the Slack bot — OpenClaw should respond

# 9. Run smoke tests
cd .. && uv run pytest tests/smoke/ -v
```

**`tests/smoke/test_openclaw.py`** will assert:
- SSM instance is online (`PingStatus == "Online"`)
- `openclaw-gateway` systemd unit is active
- The IAM user cannot call APIs beyond its policy (negative test via boto3)
- The instance has no open port 22 (check Lightsail firewall rules via boto3)

---

## Future: Matrix migration path

When ready for E2E encryption:
1. Provision a second Lightsail nano ($5/month) running Synapse (self-hosted Matrix homeserver)
2. Swap the Slack adapter for a Matrix bot adapter in `openclaw.json`
3. No changes to the core Lightsail/SSM/IAM/GitHub infrastructure
4. Proton Mail secondary channel remains regardless

## Expanding IAM Permissions Over Time

Start locked, expand deliberately — add only when a specific skill requires it:
- Bank transaction monitoring → OAuth via OpenBanking provider (no AWS IAM needed)
- S3 file storage → `s3:GetObject`, `s3:PutObject` scoped to a specific bucket ARN
- SES for email → `ses:SendEmail` scoped to a specific identity ARN
