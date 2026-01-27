#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/util.sh"

# Send error notification to our slack errors channel

channel_id="C09DRKZRQ4U" #mtv-errors

function sanitize {
  echo "$@" | sed 's/\\*"/"/g' | sed 's/"/\\\"/g' 
}

log "Sending error message..."
msg=$(sanitize "$@")
tmpl=$(cat "$PROJECT_ROOT/templates/error_msg.json" | jq ".blocks[2].text.text |= \"\`\`\`$msg\`\`\`\"")
tmpl=$(echo $tmpl | jq ".channel |= \"$channel_id\"")

curl --header "Authorization: Bearer $slack_auth_token" --header "Content-Type: application/json" --request POST --data "$(echo $tmpl | jq -c '.')" https://slack.com/api/chat.postMessage
