#!/usr/bin/env bash
source scripts/util.sh

# Waits until all konflux builds running for PR finish

pr_url=$1
ocps=$2

# Print Usage if argument is missing
if [[ -z $1 || -z $2 ]]; then
    echo "Usage: ./wait_for_pr.sh <pr_url> <ocp_versions>"
    echo "<pr_url> - required, PR url created in mtv-fbc repository"
    echo "./wait_for_pr.sh https://github.com/kubev2v/mtv-fbc/pull/123 \"v4.17 v4.18 v4.19\""
    exit 0
fi

# wait for the builds to finish
log "Waiting for builds in the PR $pr_url to finish..."

declare -i attempt=1
declare -i limit=4

while true; do
  declare -i finished=0
  for ocp in ${ocps[@]}; do
    # modify ocp in from 'v4.18' to 'v418-on'
    status=$(gh pr checks --json=name,state $pr_url | jq ".[] | select(.name | contains (\"${ocp//./}-on\"))")
    state=$(echo $status | jq '.state' -r)
    case $state in
      "SUCCESS")
        log "Pipeline for $ocp finished..."
        finished+=1
        ;;
      "FAILED")
        if (( $attempt >= $limit )); then
          log "Pipelines failed to build after $attempt retries... Please investigate..."

          # send error message to slack
          scripts/error_notify.sh "*IIB build failure* $ocp\n Please check $pr_url for the failed pipeline..."
          exit 1
        else
          attempt+=1
          log "Pipeline for $ocp failed. Will try rerunning. Attempt $attempt/$limit"

          gh pr comment $pr_url --body "/retest forklift-fbc-comp-prod-${ocp//./}-on-pull-request"
        fi
        ;;
      "QUEUED")
        log "Pipeline for $ocp is queued..."
        ;;
      "IN_PROGRESS")
        log "Pipeline for $ocp is still running..."
        ;;
      "CANCELLED")
        log "Pipeline for $ocp was cancelled..."
        ;;
      *)
        log "Unknown state: $state for $ocp OCP pipeline..."
        ;;
    esac
  done

  # check if all pipelines finished
  if [[ $finished == $(echo $ocps | wc -w) ]]; then
    log "All pipelines finished..."
    break
  fi

  sleep 60
done
