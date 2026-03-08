# OpenClaw Use Cases

## Initial testing (low-risk, verify setup)

1. **Round-trip check** — "Echo back this message" / "What time is it?" Confirms Slack -> agent -> Slack works.
2. **AWS cost query** — "What's my AWS bill this month?" Exercises the Cost Explorer IAM permission already in place.
3. **GitHub PR summary** — "Summarize open PRs in repo X." Read-only, easy to verify correctness.
4. **Web research** — "What's the latest Node.js LTS version?" Tests web fetch capability.

## Personal productivity

- **Inbox triage** — autonomously scan, categorize, unsubscribe, and clear email backlog
- **Meeting transcription** — pick up audio files, transcribe via Whisper, extract action items
- **Scheduled digests** — daily/weekly summaries of GitHub activity, news, or custom feeds pushed to Slack

## Developer / DevOps

- **Background coding tasks** — code generation, refactoring, CI automation
- **Shell and file automation** — execute commands, manage files, automate browser operations
- **CloudWatch log tail** — read recent EC2/SSM logs for ops visibility (read-only, no new IAM needed)

## Financial monitoring

- **AWS spend alerts** — already possible with existing Cost Explorer permission; alert on budget thresholds
- **Bank transaction feed** — see notes below on Open Banking access

### Open Banking / DNB

Direct access to DNB's PSD2 API requires an AISP license and a QWAC eIDAS certificate — not feasible for personal use.

The practical path is via an aggregator that holds the license itself:

| Option | Notes |
|---|---|
| **Tink** (Visa) | Covers Norway + DNB; free sandbox; production is per-call pricing |
| **Aiia** (Mastercard) | Nordic-focused, explicitly supports DNB; B2B sign-up but works for personal projects |
| Direct DNB API | Requires AISP license from Finanstilsynet + QWAC cert — not a hobbyist path |

Suggested approach: authenticate once via Tink or Aiia OAuth, store the token securely, and have OpenClaw poll for new transactions on a schedule and push summaries to Slack.

## Content and research

- **SEO content pipelines** — keyword research, draft, publish, unattended
- **Competitive monitoring** — watch specified pages or RSS feeds and summarize changes

## IAM expansion pattern

Before enabling any new capability that requires AWS access, add a scoped policy following the pattern in `infra/iam.tf`. See `CLAUDE.md` for the template. Keep permissions minimal and expand deliberately per skill.
