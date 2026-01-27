#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/util.sh"

component_url=$1
PROT="docker://"

# Print Usage if component URL is missing
if [[ -z $1 ]]; then
  echo "Usage: ./component.sh <url to component>, examples:"
  echo "./component.sh quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-operator-dev-preview/vsphere-xcopy-volume-populator-dev-preview@sha256:f075ac0c73cc466a84e840ca9ca3541565d2834c58d3915ff6696d761f8ea4ed"
  exit 0
fi

# Prepend protocol to the URL
if [[ ${component_url:0:${#PROT}} != $PROT ]]; then
  component_url="${PROT}${component_url}"
fi

log "Getting commit from $component_url..."
metadata=$(skopeo inspect -n $component_url)
commit=$(echo $metadata | jq -r '.Labels.revision')

# clear cmd output file
cl_output

if [[ $commit == "null" ]]; then
  log "Commit hash not found. Image is probably missing 'revision' label."
  log "Trying with 'vcs-ref' label. WARN: This may not indicate the correct build commit for OPERATOR_IMAGE"

  commit=$(echo $metadata | jq -r '.Labels."vcs-ref"')
  if [[ $commit == "null" ]]; then
    log "Commit not found even with 'vcs-ref' label."
  else
    log "### RESULT ###"
    w_output $(ytj "COMMIT: $commit")
  fi
else
  log "### RESULT ###"
  w_output $(ytj "COMMIT: $commit")
fi
