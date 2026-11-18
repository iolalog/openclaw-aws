# OpenClaw operations: upgrades and cron

Runbook notes for operating OpenClaw on the instance. Cost-related config (heartbeat, dreaming, skills workshop) is in [`openclaw-costs.md`](openclaw-costs.md).

## Upgrades

- **Always upgrade via `/usr/local/bin/openclaw-upgrade`** — never `npm install -g openclaw` or `openclaw update` directly. Running npm while the gateway is live corrupts the package (node holds module files open; npm can't replace them). The wrapper does stop → install → cache clean → `doctor --fix` → start, and restarts the service even if install fails.
- **Node must be ≥24.16.** OpenClaw 2.0+ (v2026.8.1+) requires Node ≥24.16 <25 or ≥26.1. `npm install -g openclaw` on an older Node does **not** error — it silently resolves to the newest release still compatible with the installed Node (the `extended-stable` dist-tag), which can be many versions behind `latest`. If an upgrade doesn't move the version forward as expected, check `node --version` before anything else. Bootstrap installs Node 24 via `nodesource setup_24.x`.
- **`openclaw doctor --fix` needs `OPENCLAW_SERVICE_REPAIR_POLICY=external`.** Our systemd unit (`openclaw-gateway.service`) is hand-authored, not created by OpenClaw's own installer, so doctor's service-ownership check can't classify it as "owned" or "absent" and refuses to run maintenance with `Gateway service ownership or shutdown could not be verified`, even when the service is confirmed stopped. Set that env var (already in `openclaw-upgrade` and the systemd unit) to use the documented externally-managed-service escape hatch instead.
- **Always `export HOME=/root`** for any ad-hoc `openclaw` CLI invocation outside the systemd unit (e.g. over SSM) — without it, `openclaw` commands fail with `Missing HOME` or `gateway status failed`.
- **The prestart fail-safe can undo an in-progress fix.** `openclaw-prestart` reverts to `openclaw.known-good.json` after 3 consecutive failed starts. Mid-upgrade, a service crash-looping on a pending config/state migration burns through that budget fast and silently reverts your fix. Before running manual recovery steps (`doctor --fix`, manual config edits), reset the counter first: `echo 0 > /var/lib/openclaw/fail-count`.

### Post-upgrade checklist

1. Run `infra/scripts/post-upgrade-check.sh` (runs externally from a dev machine with Terraform state).
2. **Validate the config schema** — newer releases can stop auto-migrating old keys. Run `openclaw config schema >/dev/null` and keep `~/.openclaw/openclaw.json` aligned with the current schema.
3. **Re-check the recovery path** — run `/usr/local/bin/openclaw-save-known-good` after a successful Slack round-trip and verify `fail-count` resets to `0` and `openclaw.known-good.json` gets a fresh timestamp.
4. **Re-check Slack behavior** — gateway reconnects, typing indicators work, replies land in the intended thread after restart.
5. **Treat log markers as unstable** — the `openclaw-save-known-good` gate is compatibility-tuned for current OpenClaw logs. Re-verify it after upgrades instead of assuming old journal markers still exist.
6. **Verify the default-on LLM features are still off** — heartbeat `every: "0m"`, dreaming disabled, skills workshop `autonomous.mode=off`. See [`openclaw-costs.md`](openclaw-costs.md).

## Cron files

- **`/etc/cron.d/` commands must be single-line** — Vixie cron (Ubuntu) does not reliably support `\` line continuation in `/etc/cron.d/` files. The watchdog was silently broken for weeks because of this. Always write one complete command per line.
- **Root's personal crontab vs `/etc/cron.d/`** — OpenClaw sets up jobs in root's personal crontab (`crontab -e`). `/etc/cron.d/openclaw` is for system-level jobs only (update checker). Do not duplicate jobs between the two.
