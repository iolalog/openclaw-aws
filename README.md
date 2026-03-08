# openclaw-aws

AWS infrastructure for an always-on [OpenClaw](https://openclaw.dev) autonomous AI agent — Lightsail + Slack + OpenRouter, ~$7/month.

## What this is

A single Lightsail instance (`micro_3_0`, Ubuntu 24.04) running the OpenClaw gateway as a systemd service. The agent is reachable via Slack DM (Socket Mode — no inbound ports). Access to the instance is via AWS SSM Session Manager (no SSH, no open port 22).

## Quickstart

```bash
# 1. Copy and fill in secrets
cp infra/terraform.tfvars.example infra/terraform.tfvars

# 2. Deploy
cd infra && terraform init && terraform apply

# 3. After ~2 min, add the GitHub deploy key (see docs/setup.md)

# 4. Run smoke tests
uv run pytest tests/smoke/ -v
```

## Docs

- [`docs/setup.md`](docs/setup.md) — full manual steps (Slack app, deploy key, verification)
- [`docs/setup-plan.md`](docs/setup-plan.md) — architecture, cost breakdown, design decisions
- [`docs/terraform-state.md`](docs/terraform-state.md) — state management and recovery
- [`docs/messaging-channel-decision.md`](docs/messaging-channel-decision.md) — why Slack now, Matrix later

## Cost

| Component | Cost |
|---|---|
| Lightsail micro_3_0 | $7/month |
| OpenRouter (background tasks) | ~$0–1/month |
| Everything else | Free |
