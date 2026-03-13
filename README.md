# openclaw-aws

AWS infrastructure for an always-on [OpenClaw](https://openclaw.dev) autonomous AI agent — EC2 + Slack + Anthropic API + OpenRouter, ~$14/month.

## What this is

A single EC2 t4g.small instance (Ubuntu 24.04 arm64, 2GB RAM) running the OpenClaw gateway as a systemd service. Reachable via Slack DM (Socket Mode — no inbound ports). Access via AWS SSM Session Manager (no SSH, no open port 22). AWS credentials via EC2 instance role — no access keys on disk.

## Quickstart

```bash
# 1. Check for existing deployments first
cd infra && terraform state list 2>/dev/null

# 2. Copy and fill in secrets
cp infra/terraform.tfvars.example infra/terraform.tfvars

# 3. Deploy
terraform init && terraform apply

# 4. Add GitHub deploy key, approve Slack pairing (see docs/setup.md)

# 5. Run smoke tests
cd .. && uv run pytest tests/smoke/ -v
```

## Docs

- [`docs/setup.md`](docs/setup.md) — full setup guide (includes pre-flight check)
- [`docs/terraform-state.md`](docs/terraform-state.md) — state management and recovery
- [`docs/messaging-channel-decision.md`](docs/messaging-channel-decision.md) — why Slack now, Matrix later
- [`docs/use-cases.md`](docs/use-cases.md) — capabilities and IAM expansion pattern
- [`docs/archive/`](docs/archive/) — legacy Lightsail docs and one-time migration guide

## Cost

| Component | Cost |
|---|---|
| EC2 t4g.small (2GB RAM, arm64) | ~$13/month |
| EBS gp3 8GB root | ~$0.70/month |
| DLM daily AMI snapshots (7-day retain) | ~$0.40/month |
| Anthropic API (haiku/sonnet/opus — same price as OpenRouter) | ~$0–2/month |
| OpenRouter (codex, gemini, flash fallbacks) | ~$0/month |
| **Total** | **~$14/month** |

1-year reserved t4g.small: ~$8.50/month → ~$9.50/month total.
