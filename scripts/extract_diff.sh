#!/bin/bash

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

# redirect cmd output to stdout and variable
{ new_iib_info=$(scripts/extract_info.sh $new_iib $new_version | tee /dev/fd/5); } 5>&1
new_iib_info=$(echo "$new_iib_info" | tail -n 3)
{ old_iib_info=$(scripts/extract_info.sh $old_iib $old_version | tee /dev/fd/5); } 5>&1
old_iib_info=$(echo "$old_iib_info" | tail -n 3)

declare -A new_commits
declare -A old_commits
declare -a origins

IFS=$'\n'
for origin in ${new_iib_info[@]}; do
  new_commit=$(echo $origin | cut -d ' ' -f 2)
  new_origin=$(echo $origin | cut -d ':' -f 1)
  new_commits[$new_origin]=$new_commit
  if [[ ! " ${origins[*]} " =~ [[:space:]]${new_origin}[[:space:]] ]]; then
    origins+=($new_origin)
  fi
done

for origin in ${old_iib_info[@]}; do
  old_commit=$(echo $origin | cut -d ' ' -f 2)
  old_origin=$(echo $origin | cut -d ':' -f 1)
  old_commits[$old_origin]=$old_commit
  if [[ ! " ${origins[*]} " =~ [[:space:]]${old_origin}[[:space:]] ]]; then
    origins+=($old_origin)
  fi
done
IFS=''

for origin in ${origins[@]}; do
  xy=$(echo $new_version | cut -d '.' -f 1).$(echo $new_version | cut -d '.' -f 2)

  if [[ $(curl -s https://raw.githubusercontent.com/kubev2v/$origin/refs/heads/release-$xy/build/release.conf) == *"404"* ]]; then
    branch=main
  else
    branch=release-$xy
  fi
  echo -e "\n$origin commits:"
  scripts/commit_history.sh $origin $branch "${old_commits[$origin]}" "${new_commits[$origin]}"
done

