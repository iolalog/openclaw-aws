# AGENTS.md — openclaw-aws

Terraform for one OpenClaw agent on one EC2 instance (t4g.small), minimal IAM, no inbound network. Human overview in `README.md`.

Runs: local only, because Terraform state is local and gitignored (`infra/terraform.tfstate`) and deploys/smoke tests need the owner's AWS credentials.

## Commands

- `cd infra && terraform fmt && terraform plan` — always `terraform fmt` before committing
- `uv sync` — install Python tooling
- `uv run pytest tests/smoke/` — post-deploy smoke tests (hit live AWS)
- `uv run ruff format`
- `infra/scripts/post-upgrade-check.sh` — after any OpenClaw upgrade

## Read first

- `infra/main.tf`, `infra/iam.tf` — instance, security group, IAM role
- `infra/scripts/bootstrap.sh.tpl` — user_data; fetches all secrets from Parameter Store
- `docs/openclaw-operations.md` — **before any upgrade, SSM session, or cron change**
- `docs/openclaw-costs.md` — **before approving any cron job or script OpenClaw proposes**
- `docs/setup.md`, `docs/terraform-state.md` — setup and state recovery
- `docs/archive/` — legacy Lightsail; ignore for current work

## Rules

Security — do not relax without explicit instruction:
- Security group `openclaw-sg` has zero ingress rules; port 22 never appears.
- SSM Session Manager is the only terminal access path. IMDSv2 required (`http_tokens = "required"`).
- No secrets in committed files. All secrets come from Parameter Store `/openclaw/*` at boot; `infra/terraform.tfvars` is gitignored (shape in `.example`).
- Instance role is Cost Explorer read + Parameter Store read on `/openclaw/*`. Expand only per skill, deliberately — template in `docs/use-cases.md`.

Repo:
- Don't delete the root `README.md`.
- Don't add an S3 backend block until explicitly asked (`docs/terraform-state.md`).

OpenClaw (details in `docs/openclaw-operations.md` / `docs/openclaw-costs.md`):
- Upgrade only via `/usr/local/bin/openclaw-upgrade`, never `npm install -g openclaw` or `openclaw update`. Node must be ≥24.16 or npm silently installs an old release.
- Ad-hoc `openclaw` CLI over SSM needs `export HOME=/root`; `doctor --fix` needs `OPENCLAW_SERVICE_REPAIR_POLICY=external` and no `--non-interactive`/`--yes`. Reset `/var/lib/openclaw/fail-count` to 0 before manual recovery.
- Check config with `openclaw config validate`, not `config schema` (which passes on an invalid config).
- After every upgrade, verify these stay off: the `heartbeat-main` automation (`openclaw health` → `Heartbeat interval: disabled`; enabled = 30-min Sonnet turns, ~$60/day), memory-core `dreaming`, `skills.workshop.autonomous.mode=off`.
- Reject `agentTurn` cron jobs or scripts that call an LLM when a shell check would do.
- `/etc/cron.d/` lines must be single-line (no `\`). OpenClaw jobs live in root's crontab; `/etc/cron.d/openclaw` is system jobs only.

## Accepted risks

- Runs as root (`HOME=/root` required); single-purpose host, no inbound, SSM-only.
- `ignore_changes = [user_data, ami]` is intentional: to apply bootstrap changes, taint the instance and re-apply.
- Bootstrap pulls NodeSource and `openclaw` unpinned as root on first boot. Accepted for a rarely re-provisioned host; switch to a pre-baked AMI if re-provisioning becomes frequent.
