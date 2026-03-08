# Messaging Channel for OpenClaw on AWS — Decision Summary

## Context

OpenClaw is being deployed on AWS Lightsail, following the architecture described at
https://awsfundamentals.com/blog/lightsail-openclaw

The reference architecture uses:
- Lightsail instance (Ubuntu 24.04, $5-7/mo)
- SSM (no open SSH port, only port 443)
- GitHub for config/skills/memory
- **Slack (Socket Mode)** as the messaging interface
- OpenClaw registered as a systemd daemon

The owner needs a messaging channel to interact with OpenClaw for tasks ranging from
OpenBanking / economy management to programming. The channel must support a mobile app
or browser client, is not latency-sensitive, and should be extensible to additional
users later if needed.

## Options Evaluated

### Slack (as per blog)
- Outbound Socket Mode — no inbound ports, fits the port-443-only firewall model
- Mature bot API, easy setup
- **No E2E encryption** — Slack stores messages in plaintext on their servers
- Free tier available; paid plans required for history/features at scale
- Suitable for abstracted commands, risky for passing sensitive data directly

### Telegram
- Popular bot API, easy setup
- Regular chats and all bot interactions are **server-side encrypted only** (not E2E)
- E2E encryption only in "Secret Chats", which bots cannot use
- Not recommended for OpenBanking or sensitive commands

### WhatsApp / Messenger
- Meta-owned, significant metadata harvesting
- No suitable bot/automation API for this use case
- Not recommended

### Discord
- No E2E encryption
- Data stored and analysed by Discord
- Not recommended for sensitive use

### Matrix / Element (self-hosted)
- **E2E encrypted by default**
- Excellent mobile (iOS/Android) and web client via Element
- Full-featured bot/webhook API
- Self-hosted Synapse on AWS gives full control
- Multi-user capable — rooms with granular permissions
- Requires a second Lightsail instance (~$5-7/mo) or managed hosting (~$5-10/mo)
- Outbound-only bot connection — compatible with port-443-only firewall

### Proton
- Swiss-hosted, strong privacy guarantees
- No real-time chat product suitable for bot interaction
- Best used as a secondary channel: alerts, reports, sensitive documents via Proton Mail

## Recommended Architecture

| Channel | Purpose |
|---------|---------|
| Matrix / Element (self-hosted or managed) | Primary OpenClaw interaction — commands, responses, logs |
| Proton Mail | Secondary — alerts, reports, sensitive documents |

### Matrix deployment options

**Option A — Self-hosted on a second Lightsail instance**
- Run Synapse on a separate nano instance (~$5/mo)
- OpenClaw runs a Matrix bot connecting outbound to that server
- Full control, no third-party dependency

**Option B — Managed Matrix hosting**
- Services such as Element Matrix Services or etke.cc host Synapse externally
- ~$5-10/mo, no AWS ops overhead
- Still E2E encrypted end-to-end

## Agreed Approach

**Start with Slack** (follow the blog as-is) to get OpenClaw running and verified quickly.
Migrating to Matrix later is a contained change — swap the Slack bot adapter for a Matrix
bot in OpenClaw's configuration once the core system is stable.

This gives the fastest path to a working system while keeping the more secure option open
as a straightforward migration.

## Owner Constraints / Preferences

- Mobile app or browser client required
- Not latency-sensitive
- Single user for now, multi-user support desirable later
- Has a Proton subscription
- Comfortable installing new services (e.g. Telegram, Matrix) if needed
- Lightsail instance as the primary compute platform
