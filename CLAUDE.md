# CLAUDE.md — Agent instructions for openclaw-aws

## What this repo is

Terraform infrastructure for an OpenClaw autonomous agent on EC2. One instance, one agent, minimal IAM surface. EC2 instance role provides auto-rotating credentials via IMDS — no access keys on disk. See `docs/setup.md` for the full setup guide.

## Key conventions

- **Terraform**: all config under `infra/`. Run `terraform fmt` before committing. State is local (`terraform.tfstate`, gitignored).
- **Secrets**: never committed. `infra/terraform.tfvars` is gitignored. `infra/terraform.tfvars.example` shows the shape with placeholder values.
- **Python tooling**: `uv sync` to install; `uv run pytest tests/smoke/` to run smoke tests; `uv run ruff format` to format.
- **No README.md removal**: the project README lives at the root — don't delete it.

## Important files

| File | Purpose |
|---|---|
| `infra/main.tf` | VPC, EC2 instance (t4g.small), security group (no inbound), EIP, DLM snapshot policy |
| `infra/iam.tf` | EC2 instance role + profile (SSM + Cost Explorer + Parameter Store read on `/openclaw/*`); DLM role |
| `infra/scripts/bootstrap.sh.tpl` | user_data — installs SSM agent, Node 22, OpenClaw, writes config; fetches all secrets from Parameter Store |
| `infra/variables.tf` | Non-secret input variables (GitHub repo URLs, AWS region) |
| `tests/smoke/test_openclaw.py` | Post-deploy assertions (SSM online, service active, security group, IAM scope) |
| `docs/setup.md` | Full setup guide including pre-flight check |
| `docs/terraform-state.md` | State recovery procedures |
| `docs/archive/` | Legacy Lightsail docs and one-time migration guide — not needed for fresh installs |

## Security constraints — do not relax without explicit instruction

- Security group `openclaw-sg` must have zero ingress rules — no inbound traffic
- Port 22 must never appear in the security group ingress rules
- EC2 instance role has Cost Explorer read-only + SSM Parameter Store read on `/openclaw/*` — expand per skill, deliberately
- No secrets in committed files — all secrets (Slack, OpenRouter, Gemini, Anthropic) fetched from Parameter Store at boot; none in `terraform.tfvars` or user_data
- SSM Session Manager is the only terminal access path
- IMDSv2 is required (`http_tokens = "required"`) — protects against SSRF credential theft

## Accepted risks

- **Runs as root**: OpenClaw requires `HOME=/root`; this is a single-purpose host with no other users or services. Mitigation: no inbound network access, SSM-only terminal access.
- **`ignore_changes = [user_data, ami]`**: Intentional. Bootstrap changes require instance replacement or manual intervention — they are not silently applied on `terraform apply`. To apply bootstrap changes: taint the instance and re-apply.
- **Unpinned bootstrap dependencies**: `curl … | bash -` from nodesource.com and `npm install -g openclaw` run as root at instance creation with no version pinning or checksum verification. This is a supply-chain exposure on first boot. Accepted because: (a) this is a single-purpose, long-lived host that is rarely re-provisioned; (b) pinning NodeSource's setup script is impractical without maintaining a fork; (c) the exposure window is only at bootstrap time, not ongoing. If re-provisioning becomes frequent, replace with a pre-baked AMI.

## Expanding IAM permissions

Add only when a specific skill requires it. Pattern to follow in `infra/iam.tf`:

```hcl
resource "aws_iam_role_policy" "openclaw_s3" {
  name = "openclaw-s3"
  role = aws_iam_role.openclaw.id
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "arn:aws:s3:::YOUR-BUCKET/*"
    }]
  })
}
```

## Cron file gotchas

- **`/etc/cron.d/` commands must be single-line** — Vixie cron (Ubuntu) does not reliably support `\` line continuation in `/etc/cron.d/` files. The watchdog was silently broken for weeks because of this. Always write one complete command per line.
- **Root's personal crontab vs `/etc/cron.d/`** — OpenClaw sets up jobs in root's personal crontab (`crontab -e`). `/etc/cron.d/openclaw` is for system-level jobs only (update checker). Do not duplicate jobs between the two.

## Future S3 state migration

See `docs/terraform-state.md`. Do not add the S3 backend block until explicitly asked.
