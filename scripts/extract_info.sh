#!/bin/bash

# Get commit history from the specified IIB

iib_url=$1
version=$2

# Print Usage if IIB URL is missing 
if [[ -z $1 || -z $2 ]]; then
    echo "Usage: ./extract_info.sh <url to iib> <version>, examples:"
    echo "./extract_info.sh quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v418:on-pr-76657e65fa4e6ff445965976200aed1ad7adbb7d 2.9.0"
    echo "./extract_info.sh registry-proxy.engineering.redhat.com/rh-osbs/iib:985689 2.8.5"
    echo "./extract_info.sh registry.redhat.io/redhat/redhat-operator-index:v4.18 2.8.5"
    exit 0
fi

# get bundle image url present in the IIB
bundle_img=$(scripts/iib.sh $iib_url $version | tail -n 1)
echo -e "# Bundle image extracted from IIB #"
echo -e $bundle_img

# extract only url
IFS=' '
read -a split <<< $bundle_img
IFS=''
bundle_img=${split[-1]}

# try to replace registry with quay
bundle_img=$(scripts/replace_for_quay.sh $bundle_img $version)

# get components from bundle
cmps_lines=$(scripts/bundle.sh $bundle_img | tail -n 13 | grep IMAGE)
echo -e "\n# Component images extracted from bundle #"
echo -e $cmps_lines

# put lines into array
readarray -t cmps < <(echo $cmps_lines)

# component origins
origins='{"mtv-controller-rhel9": "forklift", "mtv-must-gather-rhel8": "forklift-must-gather", "mtv-validation-rhel9":"forklift", "mtv-api-rhel9":"forklift", "mtv-populator-controller-rhel9":"forklift", "mtv-rhv-populator-rhel8":"forklift", "mtv-virt-v2v-rhel9":"forklift", "mtv-openstack-populator-rhel9":"forklift", "mtv-console-plugin-rhel9":"forklift-console-plugin", "mtv-ova-provider-server-rhel9":"forklift", "mtv-vsphere-xcopy-volume-populator-rhel9":"forklift", "mtv-rhel9-operator":"forklift", "mtv-operator-bundle": "forklift"}'

declare -A commits

echo -e "\n# Commits from which components are built #"

# for each component image do commit extraction
for cmp in "${cmps[@]}"; do
  # split to only img url, ditch cmp key
  IFS=' '
  read -a split <<< $cmp
  IFS=''
  cmp=${split[-1]}
  cmp_name=${split[0]}

  # get only the image name
  IFS='/'
  read -a split_img <<< $cmp
  img=${split_img[-1]}
  IFS='@'
  read -a split_cmp <<< $img
  img=${split_cmp[0]}
  sha=${split_cmp[-1]}
  IFS=''

  # pair the prod cmp name with quay cmp name
  origin=$(echo $origins | jq ".\"$img\"")
  # strip quotes
  origin=${origin:1:-1}

  # try to replace for quay
  cmp=$(scripts/replace_for_quay.sh $cmp $version)

  # get commit from component image
  commit=$(scripts/component.sh $cmp | tail -n 1)

  # split to only commit sha
  IFS=' '
  read -a split <<< $commit
  IFS=''
  commit=${split[-1]}

  echo $cmp_name" "$commit

  commits+="{\"cmp\":\"$cmp\",\"commit\":\"$commit\",\"origin\":\"$origin\"} "
done

# pretty print also bundle commit
commit=$(scripts/component.sh $bundle_img | tail -n 1)
echo -e "BUNDLE_IMAGE: "$(echo $commit | cut -d ' ' -f 2)

# split commits into array
IFS=' '
read -a split_commits <<< $commits
IFS=''

# aggregate commits per origin
declare -A by_origin

for commit in ${split_commits[@]}; do
  # extract origins and shas
  origin=$(echo $commit | jq '.origin')
  sha=$(echo $commit | jq '.commit')

  # strip quotes
  origin=${origin:1:-1}
  sha=${sha:1:-1}

  if ! [[ ${by_origin[$origin]} == *"$sha"* ]]; then
    # group by origin
    by_origin[$origin]+="$sha " 
  fi
done

mkdir temp
cd temp

echo -e "\n# Latest commits per origin #"

for origin in ${!by_origin[@]}; do
  git init $origin &> /dev/null
  cd $origin
  # add origin fo the repo
  if [[ -n $(git remote -v | grep origin) ]]; then
    git remote remove origin
  fi

  git remote add origin https://github.com/kubev2v/$origin.git
  
  xy=$(echo $version | cut -d '.' -f 1).$(echo $version | cut -d '.' -f 2)

  if [[ $(curl -s https://raw.githubusercontent.com/kubev2v/$origin/refs/heads/release-$xy/build/release.conf) == *"404"* ]]; then
    branch=main
  else
    branch=release-$xy
  fi

  git fetch origin $branch &> /dev/null

  history=$(git --no-pager log --remotes --format=format:'%H%n' -n 200 origin/$branch) 

  readarray -t history_commits <<< $history

  # get the latest commits per origin
  latest_commit=""
  latest_commit_id=1000000

  for commits in ${by_origin[$origin]}; do
    IFS=' '
    read -a origin_commits <<< $commits
    IFS=''

    for commit in ${origin_commits[@]}; do
      declare -i idx=0
      for hist_commit in ${history_commits[@]}; do
        if [[ $commit == $hist_commit ]]; then
          if [[ $idx -lt $latest_commit_id ]]; then
            latest_commit=$hist_commit
            latest_commit_id=$idx
            break
          fi
        fi
        idx+=1
      done
    done
  done

  echo $origin": "$latest_commit
  cd ..
done

cd ..
rm -rf temp
