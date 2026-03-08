# CLAUDE.md — Agent instructions for openclaw-aws

## What this repo is

Terraform infrastructure for an OpenClaw autonomous agent on AWS Lightsail. One instance, one agent, minimal IAM surface. See `docs/setup-plan.md` for full architecture.

## Key conventions

- **Terraform**: all config under `infra/`. Run `terraform fmt` before committing. State is local (`terraform.tfstate`, gitignored).
- **Secrets**: never committed. `infra/terraform.tfvars` is gitignored. `infra/terraform.tfvars.example` shows the shape with placeholder values.
- **Python tooling**: `uv sync` to install; `uv run pytest tests/smoke/` to run smoke tests; `uv run ruff format` to format.
- **No README.md removal**: the project README lives at the root — don't delete it.

## Important files

| File | Purpose |
|---|---|
| `infra/main.tf` | Lightsail instance, static IP, firewall, SSM activation |
| `infra/iam.tf` | SSM hybrid activation role + `openclaw-agent` IAM user |
| `infra/scripts/bootstrap.sh.tpl` | user_data — installs SSM agent, Node 22, OpenClaw, writes config |
| `infra/variables.tf` | All input variables (`sensitive = true` on secrets) |
| `tests/smoke/test_openclaw.py` | Post-deploy assertions (SSM, service, firewall, IAM scope) |
| `docs/setup.md` | Manual steps a human must do (Slack app, deploy key) |
| `docs/terraform-state.md` | State recovery procedures |

## Security constraints — do not relax without explicit instruction

- Port 22 must never appear in `aws_lightsail_instance_public_ports`
- IAM user `openclaw-agent` starts with Cost Explorer read-only only — expand per skill, deliberately
- No secrets in committed files — all injected via `templatefile()` at boot
- SSM hybrid activation is the only terminal access path (no SSH keys on the instance)

## Expanding IAM permissions

Add only when a specific skill requires it. Pattern to follow in `infra/iam.tf`:

```hcl
# Example: add S3 access for a storage skill
resource "aws_iam_user_policy" "openclaw_s3" {
  user   = aws_iam_user.openclaw.name
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject"]
      Resource = "arn:aws:s3:::YOUR-BUCKET/*"
    }]
  })
}
```

## Future S3 state migration

See `docs/terraform-state.md`. Do not add the S3 backend block until explicitly asked.
