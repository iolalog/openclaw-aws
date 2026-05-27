# OpenClaw LLM cost traps

Two recurring patterns have caused unexpected Anthropic API credit burn on this instance. Both are documented here as a reference for future upgrades and new OpenClaw-written features.

---

## Pattern 1: OpenClaw uses LLM for tasks that don't need one

When asked to implement a periodic task, OpenClaw consistently reaches for an LLM `agentTurn` even when a deterministic shell script is the correct tool. This has been observed multiple times and should be treated as a known default behaviour to push back on.

**Canonical example — Hermes health check (May 2026):**
The request was: "add a heartbeat to check the Hermes instance." A correct implementation reads a heartbeat JSON file via SSM and checks whether the gateway process is running — two shell commands. OpenClaw instead created a cron job with `"kind": "agentTurn"` that sent the full question to Sonnet 4.6 every 30 minutes. This burned ~$91 in 1.5 days before being caught.

**What to check when OpenClaw proposes a new cron job or script:**
- Is the payload type `agentTurn`? If the task is purely informational (read a file, check a process, compare a timestamp), it should be a shell script, not an agent turn.
- Does any script call `openclaw` CLI, or make HTTP requests to an LLM API? If yes, question whether the LLM is actually needed.
- Could a `systemEvent` (fires a message into the main session) be replaced with a plain Slack webhook call for notifications?

**The fix pattern:** Replace `agentTurn` cron jobs with shell scripts that use the Slack API directly for alerts. See `infra/scripts/hermes-health-check.sh` and `openclaw-heartbeat-check` as reference implementations.

---

## Pattern 2: OpenClaw 2026.5.22 introduced default-on LLM features

The upgrade from 2026.4.15 → 2026.5.22 (performed 2026-05-25) silently enabled two new features that make real inference calls without asking for consent or documenting an off-switch.

### `agents.defaults.heartbeat` — DISABLED

A built-in agent heartbeat that sends a full Sonnet turn every 30 minutes to check gateway liveness. Neither feature existed in 2026.4.15; both appeared immediately after the upgrade.

**Cost at Sonnet 4.6 rates:** roughly $60/day if undetected. Combined with the Hermes health check above, the instance was burning ~$60/day until credits were exhausted.

**Current state:** Disabled via `agents.defaults.heartbeat.every: "0m"` in `~/.openclaw/openclaw.json`, applied 2026-05-27.

The correct off-switch is `{ "every": "0m" }`. Removing the key entirely does **not** disable it — OpenClaw falls back to the 30-minute default when the key is absent (this is what kept it running between 19:13 May 26 and the fix on May 27). `{ "enabled": false }` and a bare `false` are invalid schema and will be rejected on hot-reload.

After every future upgrade, confirm the key survived config migration:

```bash
# via SSM on the instance — should print {"every": "0m"}
python3 -c "import json; cfg=json.load(open('/root/.openclaw/openclaw.json')); print(json.dumps(cfg.get('agents',{}).get('defaults',{}).get('heartbeat','MISSING')))"
```

If an upgrade overwrites it, re-apply `{ "every": "0m" }` and file a bug with OpenClaw.

### `sidecars.model-prewarm` — startup sidecar, probably not recurring

The `sidecars.model-prewarm` phase (~2.6s) appeared in liveness logs and was initially suspected to be a separate recurring 30-minute cost driver. Based on upstream GitHub issues this is more likely a **one-time gateway startup sidecar** — a synchronous model warmup that runs shortly after each restart, not on a recurring schedule.

The liveness log entries that appeared ~30 minutes apart on May 25 are explained by the gateway restarting multiple times during the upgrade process that day; `recentPhases` reports what ran in the last liveness cycle, so a startup prewarm would show up in every post-restart liveness report.

**Likely cost:** A one-off small inference call per gateway restart. Not a recurring cost driver.

**Validation:** After re-enabling the Anthropic API key, monitor with:
```bash
journalctl -u openclaw-gateway -f | grep -Ei 'heartbeat|prewarm|embedded run agent'
```
If `model-prewarm` only appears within a few minutes of restarts and 30-minute LLM calls have stopped, the heartbeat fix was the complete solution.

---

## Monitoring recommendations

- Watch the Anthropic usage dashboard after every upgrade. Any new per-30-minute entries are a red flag.
- The `openclaw-heartbeat-check` script (runs every 10 min via `/etc/cron.d/openclaw-heartbeat`) is deterministic and does not use any LLM. It is safe.
- The `hermes-health-check.sh` script (runs hourly via root crontab) is deterministic and does not use any LLM. It is safe.
- The daily AI news brief (`91737c31` in OpenClaw cron) uses `anthropic/claude-haiku-4-5` explicitly and runs once daily. This is expected and intentional spend.
