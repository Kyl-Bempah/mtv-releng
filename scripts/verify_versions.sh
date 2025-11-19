#!/usr/bin/env bash
source scripts/util.sh
# Print all the version configurations for our repositories

# the oldest version onboarded to konflux (2.8) or the oldest version to process
cutoff_ver="2.10"

declare -a repos=(
  "forklift"
  "forklift-console-plugin"
  "forklift-must-gather"
)

json="{}"

log "Getting MTV current versions..."
log "Cutoff version is set for $cutoff_ver"

for repo in "${repos[@]}"; do
  json=$(echo $json | jq ". += {\"$repo\": {}}")
  # get the dev-preview version
  ver=$(curl -s https://raw.githubusercontent.com/kubev2v/$repo/refs/heads/main/build/release.conf | grep VERSION= | cut -d '=' -f 2)

  # create supported version matrix
  newest_x=$(echo $ver | cut -d '.' -f 1)
  newest_y=$(($(echo $ver | cut -d '.' -f 2) - 1))
  oldest_x=$(echo $cutoff_ver | cut -d '.' -f 1)
  oldest_y=$(echo $cutoff_ver | cut -d '.' -f 2)
  supported_x=$(seq $oldest_x $newest_x)
  supported_y=$(seq $oldest_y $newest_y)

  branches="main "
  for x in ${supported_x[@]}; do
    for y in ${supported_y[@]}; do
      if ! [[ $branches == *"release-$x.$y"* ]]; then
        branches+="release-$x.$y "
      fi
    done
  done

  read -a split_branches <<<$branches

  for branch in "${split_branches[@]}"; do
    ver=$(curl -s https://raw.githubusercontent.com/kubev2v/$repo/refs/heads/$branch/build/release.conf | grep VERSION= | cut -d '=' -f 2)
    json=$(echo $json | jq ".\"$repo\" += {\"$branch\": \"$ver\"}")
  done
done

cl_output
w_output $(echo $json | jq)
