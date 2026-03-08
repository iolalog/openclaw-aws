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
| `infra/iam.tf` | EC2 instance role + profile (SSM + Cost Explorer); DLM role |
| `infra/scripts/bootstrap.sh.tpl` | user_data — installs SSM agent, Node 22, OpenClaw, writes config |
| `infra/variables.tf` | All input variables (`sensitive = true` on secrets) |
| `tests/smoke/test_openclaw.py` | Post-deploy assertions (SSM online, service active, security group, IAM scope) |
| `docs/setup.md` | Full setup guide including pre-flight check |
| `docs/terraform-state.md` | State recovery procedures |
| `docs/archive/` | Legacy Lightsail docs and one-time migration guide — not needed for fresh installs |

## Security constraints — do not relax without explicit instruction

- Security group `openclaw-sg` must have zero ingress rules — no inbound traffic
- Port 22 must never appear in the security group ingress rules
- EC2 instance role starts with Cost Explorer read-only only — expand per skill, deliberately
- No secrets in committed files — all injected via `templatefile()` at boot
- SSM Session Manager is the only terminal access path

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

## Future S3 state migration

See `docs/terraform-state.md`. Do not add the S3 backend block until explicitly asked.
