# Messaging Channel Decision

## Context

OpenClaw is deployed on AWS EC2 (eu-north-1), accessible only via SSM Session Manager (no open ports). The messaging channel must support a mobile app or browser client, is not latency-sensitive, and should be extensible to additional users later.

For financial data (bank transactions, account numbers, credentials): treat any channel as a command interface only. Route sensitive outputs to Proton Mail instead.

## Options Evaluated

### Slack
- Outbound Socket Mode — no inbound ports, fits the outbound-only firewall model perfectly
- Mature bot API, easy setup, good mobile app
- **No E2E encryption** — Slack stores messages in plaintext on their servers
- Free tier available; paid for history/features at scale

### Telegram
- Easy bot setup, good mobile app
- Regular chats and all bot interactions are **server-side encrypted only** (not E2E)
- E2E only in Secret Chats, which bots cannot use
- Not suitable for sensitive data

### WhatsApp / Messenger
- Meta-owned, significant metadata harvesting
- No usable bot API for this purpose

### Discord
- No E2E encryption
- Data stored and analysed by Discord

### Matrix / Element (self-hosted)
- **E2E encrypted by default**
- Excellent mobile (iOS/Android) and desktop client via Element
- Full-featured bot API
- Self-hosted Synapse gives full control — a second small EC2 or Lightsail instance (~$5-7/mo)
- Or managed hosting via Element Matrix Services / etke.cc (~$5-10/mo, no AWS ops overhead)
- Outbound-only bot connection — compatible with the outbound-only security group
- Multi-user with granular room permissions

### Proton Mail
- Swiss-hosted, strong privacy
- No real-time chat product suitable for bot interaction
- Best as a secondary channel: alerts, reports, sensitive documents

## Current setup and migration path

**Phase 1 (current): Slack** — fastest path to a working system, Socket Mode fits the architecture exactly.

**Phase 2 (under consideration): Matrix/Element** — genuine upgrade for E2E encryption, especially for financial monitoring use cases. Migration is a contained change: swap the Slack adapter for a Matrix bot adapter in OpenClaw config, add a Synapse instance. Core EC2 infrastructure unchanged.

**Always: Proton Mail** as a secondary channel for sensitive outputs regardless of which primary channel is in use.

## Owner constraints

- Mobile app or browser client required
- Not latency-sensitive
- Single user for now, multi-user support desirable later
- Has a Proton subscription
- Comfortable installing new services if needed
