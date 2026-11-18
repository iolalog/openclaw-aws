# OpenClaw operations: upgrades and cron

Runbook notes for operating OpenClaw on the instance. Cost-related config (heartbeat, dreaming, skills workshop) is in [`openclaw-costs.md`](openclaw-costs.md).

## Upgrades

- **Always upgrade via `/usr/local/bin/openclaw-upgrade`** — never `npm install -g openclaw` or `openclaw update` directly. Running npm while the gateway is live corrupts the package (node holds module files open; npm can't replace them). The wrapper does stop → install → cache clean → `doctor --fix` → start, and restarts the service even if install fails.
- **Node must be ≥24.16.** OpenClaw 2.0+ (v2026.8.1+) requires Node ≥24.16 <25 or ≥26.1. `npm install -g openclaw` on an older Node does **not** error — it silently resolves to the newest release still compatible with the installed Node (the `extended-stable` dist-tag), which can be many versions behind `latest`. If an upgrade doesn't move the version forward as expected, check `node --version` before anything else. Bootstrap installs Node 24 via `nodesource setup_24.x`.
- **`openclaw doctor --fix` needs `OPENCLAW_SERVICE_REPAIR_POLICY=external`.** Our systemd unit (`openclaw-gateway.service`) is hand-authored, not created by OpenClaw's own installer, so doctor's service-ownership check can't classify it as "owned" or "absent" and refuses to run maintenance with `Gateway service ownership or shutdown could not be verified`, even when the service is confirmed stopped. Set that env var (already in `openclaw-upgrade` and the systemd unit) to use the documented externally-managed-service escape hatch instead.
- **Always `export HOME=/root`** for any ad-hoc `openclaw` CLI invocation outside the systemd unit (e.g. over SSM) — without it, `openclaw` commands fail with `Missing HOME` or `gateway status failed`.
- **The prestart fail-safe can undo an in-progress fix.** `openclaw-prestart` reverts to `openclaw.known-good.json` after 3 consecutive failed starts. Mid-upgrade, a service crash-looping on a pending config/state migration burns through that budget fast and silently reverts your fix. Before running manual recovery steps (`doctor --fix`, manual config edits), reset the counter first: `echo 0 > /var/lib/openclaw/fail-count`. The counter cycles 1 → 2 → 3 → restore → 0, so a crash loop restores known-good every 4th start indefinitely (2026-11-18: 176 restores in 4 h). If known-good has the same problem as live — e.g. both contain a key a new release retired — the restores achieve nothing; fix the config instead, then refresh known-good.
- **Run `doctor --fix` without `--non-interactive`/`--yes`.** Non-interactive mode deliberately leaves retired keys (e.g. `agents.defaults.heartbeat`) in place, so the config stays invalid. Over SSM, `openclaw doctor --fix </dev/null` completes the migration.
- **Every `openclaw` command except doctor/status/health/logs refuses to run on an invalid config** — including `plugins install/update`. That is why the upgrade wrapper runs doctor straight after the npm install.

### Recovering from a failed upgrade

What happened on 2026-11-18 (2026.10.3 → 2026.11.5): the release retired `agents.defaults.heartbeat` and `skills.workshop.approvalPolicy`, the old wrapper's plugin step failed on the now-invalid config, and the gateway crash-looped with exit status 78 (CONFIG) for 4 hours. Recovery, all over SSM with `HOME=/root` and `OPENCLAW_SERVICE_REPAIR_POLICY=external`:

1. `journalctl -u openclaw-gateway -n 80` — look for `OpenClaw config is invalid` and the key names.
2. Back up `~/.openclaw/openclaw.json`, `systemctl stop openclaw-gateway`, `echo 0 > /var/lib/openclaw/fail-count`.
3. `openclaw doctor --fix </dev/null`. If it waits 95 s and says it *could not enter maintenance … holder <PID> at unknown host*, the gateway state lock is stale: confirm the PID is not running (`ps -p <PID>`), then `openclaw gateway recover-lock --json` and `openclaw gateway recover-lock --confirm <confirmation>` from that output, and rerun doctor.
4. `openclaw config validate` must print `Config valid`. Check the heartbeat automation is still disabled (see [`openclaw-costs.md`](openclaw-costs.md)) **before** starting the service.
5. `systemctl reset-failed openclaw-gateway && systemctl start openclaw-gateway`; Slack messages queued during the outage are retried and answered.

**Start limit:** the unit gives up after 10 starts in 10 minutes (`StartLimitIntervalSec=600`, `StartLimitBurst=10`) and stays `failed` — it does not crash-loop indefinitely, and it does not recover from a transient startup problem on its own. `openclaw-heartbeat-check` DMs the owner while it is down. A plain `systemctl start` is refused in that state until `systemctl reset-failed openclaw-gateway`.

### Post-upgrade checklist

1. Run `infra/scripts/post-upgrade-check.sh` (runs externally from a dev machine with Terraform state).
2. **Validate the config** — newer releases can retire keys. `openclaw config validate` must print `Config valid`. (`openclaw config schema` only prints the schema and succeeds even with an invalid config.)
3. **Re-check the recovery path** — run `/usr/local/bin/openclaw-save-known-good` after a successful Slack round-trip and verify `fail-count` resets to `0` and `openclaw.known-good.json` gets a fresh timestamp.
4. **Re-check Slack behavior** — gateway reconnects, typing indicators work, replies land in the intended thread after restart.
5. **Treat log markers as unstable** — the `openclaw-save-known-good` gate is compatibility-tuned for current OpenClaw logs. Re-verify it after upgrades instead of assuming old journal markers still exist.
6. **Verify the default-on LLM features are still off** — `openclaw health` shows `Heartbeat interval: disabled`, dreaming disabled, skills workshop `autonomous.mode=off`. See [`openclaw-costs.md`](openclaw-costs.md).

## Secrets

All secrets live in SSM Parameter Store under `/openclaw/*` (SecureString). Nothing secret may be in `openclaw.json`: the file is copied to `openclaw.known-good.json` and, redacted, into the memory repo by the nightly `memory-backup.sh`. Until 2026-11-18 the Slack tokens were in it and reached the memory repo's git history (private repo), so both were rotated (see below).

- **Slack bot + app tokens:** exec SecretRefs in `openclaw.json` (`{"source":"exec","provider":"awsssm","id":"slack-bot-token"}`). Provider `secrets.providers.awsssm` runs `/usr/local/bin/openclaw-ssm-secrets`, which maps id `x` to `/openclaw/x` using the instance role.
- **Scripts and cron jobs** get a secret with `/usr/local/bin/openclaw-secret <name>` (e.g. `slack-bot-token`), never by parsing `openclaw.json`.
- **Anthropic API key (OpenClaw's own model calls):** exec SecretRef at `models.providers.anthropic.apiKey` → `/openclaw/anthropic-api-key`. Since 2026-11-18 there is no stored `anthropic:default` auth profile; `openclaw models status` shows `effective=… secretref-managed`. Don't use `openclaw models auth login`/`paste-api-key` for Anthropic — it stores the key in plaintext again.
- **OpenRouter / Gemini / Anthropic keys for scripts:** also written to `/etc/openclaw/env` (root, 0600) at bootstrap and loaded by the systemd unit.
- **Not moved:** `gateway.auth.token` (loopback-only gateway; redacted in backups). `openclaw secrets audit --check --allow-exec` should report only this one plaintext finding.

Rotate a Slack token (from a dev machine, then on the instance):

```bash
aws ssm put-parameter --region eu-north-1 --name /openclaw/slack-bot-token --type SecureString --overwrite --value "$NEW_TOKEN"
# on the instance (HOME=/root):
openclaw secrets reload && journalctl -u openclaw-gateway -n 30 | grep -i slack
```

If `secrets reload` doesn't reconnect Slack, `systemctl restart openclaw-gateway`. (Verified 2026-11-18: reload restarts the Slack channel with the new tokens; the gateway keeps using the old ones until you reload.)

**gitleaks on the instance:** root's global `core.hooksPath` is `/usr/local/lib/openclaw-git-hooks`; its `pre-commit` runs `gitleaks protect --staged` (apt package) and then any repo-local hook. When it blocks the nightly `memory-backup.sh` commit, the script pushes nothing and DMs the owner via `/usr/local/bin/openclaw-slack-dm`. The agent can bypass it with `--no-verify`, so it is a guard rail, not enforcement. A 2026-11-18 history scan of the memory repo found the old Slack bot token (rotated) and two gateway tokens in `backup/openclaw-config.json` (March commits); one of those was still the live `gateway.auth.token` — rotate it with a new random value (`openclaw config set gateway.auth.token "$(openssl rand -hex 32)"` + restart) if that hasn't been done. The agent runs as root with an instance role that can read `/openclaw/*`, so this keeps secrets out of files and git, not out of the agent's reach.

## Cron files

- **`/etc/cron.d/` commands must be single-line** — Vixie cron (Ubuntu) does not reliably support `\` line continuation in `/etc/cron.d/` files. The watchdog was silently broken for weeks because of this. Always write one complete command per line.
- **Root's personal crontab vs `/etc/cron.d/`** — OpenClaw sets up jobs in root's personal crontab (`crontab -e`). `/etc/cron.d/openclaw` is for system-level jobs only (update checker). Do not duplicate jobs between the two.
