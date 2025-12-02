#!/usr/bin/env bash
source scripts/util.sh

# Get commit history from the specified iibs

new_iib=$1
new_version=$2
old_iib=$3
old_version=$4

# Print Usage if IIB URLs is missing 
if [[ -z $1 || -z $2 || -z $3 || -z $4 ]]; then
    echo "Usage: ./extract_diff.sh <url to new iib> <new version> <url to old iib> <old version>, examples:"
    echo "./extract_diff.sh quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v418:on-pr-76657e65fa4e6ff445965976200aed1ad7adbb7d 2.9.0"
    echo "./extract_diff.sh registry-proxy.engineering.redhat.com/rh-osbs/iib:985689 2.8.5"
    echo "./extract_diff.sh registry.redhat.io/redhat/redhat-operator-index:v4.18 2.8.5"
    exit 0
fi

scripts/extract_info.sh $new_iib $new_version
new_iib_info=$(r_output)

scripts/extract_info.sh $old_iib $old_version
old_iib_info=$(r_output)

new_iib_info=$(echo $new_iib_info | jq '. += {"diffs": {}}')

for origin in $(echo $new_iib_info | jq '.latest_commits | keys.[]' -r); do
  new_iib_info=$(echo $new_iib_info | jq ".diffs += {\"$origin\": {}}")
  xy=$(echo $new_version | cut -d '.' -f 1).$(echo $new_version | cut -d '.' -f 2)

  # check if the version is on main or release branch
  if [[ $(curl -s https://raw.githubusercontent.com/kubev2v/$origin/refs/heads/release-$xy/build/release.conf) == *"404"* ]]; then
    branch=main
  else
    branch=release-$xy
  fi
  echo -e "\n$origin commits:"
  scripts/commit_history.sh $origin $branch $(echo $old_iib_info | jq ".latest_commits.\"$origin\"" -r) $(echo $new_iib_info | jq ".latest_commits.\"$origin\"" -r)
  new_iib_info=$(echo $new_iib_info | jq ".diffs.\"$origin\" += $(r_output | jq -c)")
done

cl_output
w_output $(echo $new_iib_info | jq)
