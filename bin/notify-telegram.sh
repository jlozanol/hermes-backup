#!/usr/bin/env bash
# notify-telegram.sh: report each hermes-backup.service run to Telegram.
# Runs from systemd after every backup (ExecStopPost). Reads the bot token from ~/.hermes/.env.
set -uo pipefail
level="${TG_NOTIFY:-all}"            # all | changes | failures
chat="${TG_CHAT_ID:-}"
result="${SERVICE_RESULT:-unknown}"
[ -n "$chat" ] || { logger -t hermes-notify "TG_CHAT_ID not set"; exit 0; }
token=$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$HOME/.hermes/.env" | head -n1 | tr -d "\"' \r")
[ -n "$token" ] || { logger -t hermes-notify "TELEGRAM_BOT_TOKEN not found"; exit 0; }
sleep 1
last=$(journalctl --user -t hermes-backup -n 1 -o cat --no-pager 2>/dev/null)
if [ "$result" = success ]; then
  case "$last" in
    *"no changes"*) [ "$level" = all ] || exit 0; status="Hermes backup OK: no changes" ;;
    *pushed*)       [ "$level" = failures ] && exit 0; status="Hermes backup OK: $last" ;;
    *)              [ "$level" = all ] || exit 0; status="Hermes backup finished: $last" ;;
  esac
else
  status="Hermes backup FAILED ($result). Last log: $last"
fi
when=$(TZ=Australia/Melbourne date '+%a %d %b %H:%M')
printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$token" \
  | curl -fsS -m 15 --retry 3 -o /dev/null -K - \
      --data-urlencode "chat_id=$chat" \
      --data-urlencode "text=$status
$when Melbourne, $(hostname)" \
  || logger -t hermes-notify "Telegram notification failed"
exit 0
