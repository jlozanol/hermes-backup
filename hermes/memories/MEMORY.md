- 2026-09-21: MEMORY TEST - Added test entry to verify persistence across sessions. This should remain visible after session refresh if memory is working correctly.
§
not `/home/hermes/workspace/brain` (including any memory file beneath it).
§
Always use Composio CLI for any Google Drive or Google Docs create, edit, delete, or share actions per AGENTS.md. Do not use the Google Workspace skill for these operations.
§
Morning-brief cron job (Hermes cron runs on UTC): schedule '0 21 * * *' = 07:00 AEST next day ('0 20 * * *' during AEDT). The job must run the morning-brief SKILL, never a .sh script - a morning-brief.sh job failed with Script-not-found and was removed 2026-09-26. Briefs are labelled with the UTC date of the run, so a 21:00 UTC run on day N arrives 07:00 Melbourne on day N+1 labelled day N. Job ID as of Oct 2026: 89339061279a - always verify with cronjob_manage list before touching.
§
Email-fetch architecture (per current morning-brief skill): Gmail is fetched on the SERVER (hermes-email-fetch timer, hourly 06:30-22:30 Melbourne) into /workspace/emails.json; process_emails.py classifies it and prints the brief. The sandbox agent must NOT install, run or log in to Composio, must never run 'composio link', and must not fetch mail any other way - relinking is done by the user on the server.
§
Sandbox quirk: gateway restarts reset the environment - binaries can vanish from PATH, network can be briefly unreachable, and files outside the workspace are lost. Recheck state ('which <tool>') after any restart instead of assuming it persisted.
§
Jorge's Gmail jlozanol1104@gmail.com is the account behind the morning brief (Composio org jlozanol1104_workspace).