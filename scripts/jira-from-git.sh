#!/usr/bin/env bash

set -euo pipefail

# Parse command line arguments
FORMAT="table"
COMMIT_RANGE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --format)
      FORMAT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--format table|json] [COMMIT_RANGE]"
      echo ""
      echo "Examples:"
      echo "  $0                    # Scan all commits"
      echo "  $0 main..HEAD         # Scan commits between main and HEAD"
      echo "  $0 v1.0..v2.0         # Scan commits between two tags"
      echo "  $0 abc123..def456     # Scan commits between two hashes"
      echo "  $0 --format json HEAD~10..HEAD  # Last 10 commits in JSON"
      exit 0
      ;;
    *)
      if [[ -z "$COMMIT_RANGE" ]]; then
        COMMIT_RANGE="$1"
        shift
      else
        echo "Unknown option: $1" >&2
        echo "Usage: $0 [--format table|json] [COMMIT_RANGE]" >&2
        exit 1
      fi
      ;;
  esac
done

# Validate format
if [[ "$FORMAT" != "table" && "$FORMAT" != "json" ]]; then
  echo "Error: format must be 'table' or 'json'" >&2
  exit 1
fi

# Temporary arrays to store results
declare -a COMMITS=()
declare -a TICKETS=()
declare -a SUMMARIES=()
declare -a STATUSES=()

# Determine git log range
if [[ -n "$COMMIT_RANGE" ]]; then
  GIT_RANGE="$COMMIT_RANGE"
else
  GIT_RANGE="--all"
fi

# Get all commits with "Resolves: MTV-" in the message
while IFS='|' read -r commit_hash commit_message; do
  # Extract MTV ticket IDs from the commit message
  # Look for pattern "Resolves: MTV-XXXX"
  if [[ "$commit_message" =~ Resolves:\ *(MTV-[0-9]+) ]]; then
    ticket_id="${BASH_REMATCH[1]}"

    # Query Jira for ticket information using --raw flag for JSON output
    if jira_output=$(jira issue view "$ticket_id" --raw 2>&1); then
      # Parse JSON to extract summary and status using jq
      summary=$(echo "$jira_output" | jq -r '.fields.summary // "N/A"' 2>/dev/null)
      status=$(echo "$jira_output" | jq -r '.fields.status.name // "N/A"' 2>/dev/null)

      # Check if jq parsing succeeded
      if [[ -z "$summary" || "$summary" == "null" ]]; then
        summary="N/A"
      fi
      if [[ -z "$status" || "$status" == "null" ]]; then
        status="N/A"
      fi

      # Store results
      COMMITS+=("$commit_hash")
      TICKETS+=("$ticket_id")
      SUMMARIES+=("$summary")
      STATUSES+=("$status")
    else
      # Jira query failed, still record it
      COMMITS+=("$commit_hash")
      TICKETS+=("$ticket_id")
      SUMMARIES+=("ERROR: Could not fetch ticket")
      STATUSES+=("N/A")
    fi
  fi
done < <(git log "$GIT_RANGE" --pretty=format:'%h|%s %b' | grep -i "Resolves: MTV-" || true)

# Count results
COMMIT_COUNT="${#COMMITS[@]}"

# Output results
if [[ "$FORMAT" == "json" ]]; then
  # JSON output
  echo "["
  if [[ $COMMIT_COUNT -gt 0 ]]; then
    for i in "${!COMMITS[@]}"; do
      if [[ $i -gt 0 ]]; then
        echo ","
      fi
      cat << EOF
  {
    "commit": "${COMMITS[$i]}",
    "ticket": "${TICKETS[$i]}",
    "summary": $(echo "${SUMMARIES[$i]}" | jq -R .),
    "status": $(echo "${STATUSES[$i]}" | jq -R .)
  }
EOF
    done
    echo ""
  fi
  echo "]"
else
  # Table output
  if [[ $COMMIT_COUNT -eq 0 ]]; then
    echo "No commits found with 'Resolves: MTV-XXXX' pattern."
    exit 0
  fi

  # Print header
  printf "%-12s %-15s %-50s %-15s\n" "COMMIT" "TICKET" "SUMMARY" "STATUS"
  printf "%-12s %-15s %-50s %-15s\n" "------" "------" "-------" "------"

  # Print data
  for i in "${!COMMITS[@]}"; do
    # Truncate summary if too long
    summary="${SUMMARIES[$i]}"
    if [[ ${#summary} -gt 47 ]]; then
      summary="${summary:0:44}..."
    fi

    printf "%-12s %-15s %-50s %-15s\n" \
      "${COMMITS[$i]}" \
      "${TICKETS[$i]}" \
      "$summary" \
      "${STATUSES[$i]}"
  done

  echo ""
  echo "Total: $COMMIT_COUNT commit(s) found"
fi
