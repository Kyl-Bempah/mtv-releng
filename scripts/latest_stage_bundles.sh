#!/usr/bin/env bash
source scripts/util.sh

# Gets the latest released stage bundle sha for each MTV version
# If the bundle is missing for latest version, it will not be included in the output
# Versions are gathered with verify_versions.sh script

# If "./latest_stage_bundles.sh 2.9.1" then only get stage bundle for that version
filter_version=$1

scripts/verify_versions.sh
versions=$(r_output)

declare -A shas

json="{}"

branches=$(echo "$versions" | jq ".forklift | keys.[]" -r)
for branch in ${branches[@]}; do
  if [[ $branch == "main" ]]; then
    registry="mtv-candidate"
  else
    registry="migration-toolkit-virtualization"
  fi
  version=$(echo "$versions" | jq ".forklift.\"$branch\"" -r)
  # if version was psecified, filter only that version
  if [[ -n $filter_version ]]; then
    if [[ $version != $filter_version ]]; then
      log "Skipping version $version as the filter version was $filter_version"
      continue
    fi
  fi
  log "Getting stage bundle sha for version $version..."
  bundle_sha=$(skopeo inspect docker://registry.stage.redhat.io/$registry/mtv-operator-bundle:$version | jq '.Digest')
  if [[ -z $bundle_sha ]]; then
    log "Could not find released stage bundle for $version"
    continue
  fi
  bundle_sha=${bundle_sha:1:-1}
  sha=$(echo $bundle_sha | cut -d ':' -f 2)
  if [[ -n $sha ]]; then
    shas[$version]=$sha
  fi
done

for version in "${!shas[@]}"; do
  json=$(echo $json | jq ". += {\"$version\": \"${shas[$version]}\"}")
done

cl_output
w_output $json
