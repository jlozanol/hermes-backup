---
name: morning-brief
description: Create a short Telegram brief of the user's Gmail inbox.
category: productivity
---

# Morning brief

Produce a short, scannable briefing of the user's inbox and send it to this Telegram chat. Never dump raw email bodies. The whole brief must fit in one Telegram message.

## Prerequisites (check once, then remember)

1. Composio CLI is installed: `composio --version`. If missing, install with `curl -fsSL https://composio.dev/install | bash` (no sudo needed, installs to the home directory).
2. Logged in: `composio whoami` returns an org and project.
3. Gmail is linked. If a fetch below fails with an auth error, run `composio link gmail --no-wait`, send the redirect_url to the chat as a clickable link, wait for the user to confirm they approved it, then retry.

## Steps

1. Fetch the last 24 hours of inbox mail:

   ```
   composio execute GMAIL_FETCH_EMAILS --data '{"query":"in:inbox newer_than:1d","max_results":25}'
   ```

   If the parameters are rejected, run `composio execute GMAIL_FETCH_EMAILS --help` and adapt. If the slug is not found, run `composio search "fetch emails"` and use the best Gmail match.

2. Triage every message into exactly one bucket:

   - **NEEDS REPLY**: a real person is waiting on the user (clients, colleagues, collaborators, business contacts).
   - **MONEY**: invoices, bills, payment confirmations, anything financial.
   - **FYI**: newsletters, receipts, notifications, anything with no action.

3. Summarize each NEEDS REPLY and MONEY item in one line: sender, what they want, and any deadline. FYI gets a single combined line with a count and the few notable senders.

4. Send the brief to this chat in the format below. Do not send anything else.

## Output format

Morning brief for {date}

Needs reply ({n})
- {sender}: {one line ask} {deadline if any}

Money ({n})
- {sender}: {amount and what it is}

FYI: {count} others ({notable senders})

Rules: plain text only, no markdown tables, no links unless the user needs one to act, skip any empty section, and if there is nothing at all say "Quiet inbox, nothing needs you today."

## Failure handling

- Auth expired: relink with `composio link gmail --no-wait`, send the link to the chat, wait, retry once.
- Any other error: send one short line saying the brief failed and why. Never fail silently, and never retry more than twice.

## Scheduling

When the user asks to schedule this, prefer the built-in scheduler if this harness has one. Otherwise add a crontab entry for the server user (no sudo) that invokes this skill non-interactively at the requested time, and confirm the schedule back to the chat including the server timezone. Default when unspecified: 07:00 daily in the user's local timezone.