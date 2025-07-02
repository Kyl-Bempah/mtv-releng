#!/bin/bash

version=$1
target=$2
rhel=$3

# Print Usage if argument is missing
if [[ -z $1 || -z $2 ]]; then
    echo -e "Gets the latest successful release for specified version of forklift and the commits that the released images are built from, e.g. forklift-operator-2-9 rhel9 images release...\nIf [rhel] is omitted get the latest release without looking at the rhel version...\n\nNote: This does not get the commits in IIB but commits from images that were released to registry.\n"
    echo "Usage: ./latest_released_commits.sh <version> <target> [rhel], examples:"
    echo "./latest_released_commits.sh 2-9 stage 8"
    echo "./latest_released_commits.sh 2-9 prod"
    echo "./latest_released_commits.sh dev-preview prod 9"
    exit 0
fi


declare -A images

if [[ -z $3 ]]; then
    images=$(scripts/latest_release.sh $version $target | xargs scripts/snapshot_from_release.sh | xargs scripts/snapshot_content.sh | jq '.[].containerImage' | jq --slurp '@sh')
else
    images=$(scripts/latest_release.sh $version $target $rhel | xargs scripts/snapshot_from_release.sh | xargs scripts/snapshot_content.sh | jq '.[].containerImage' | jq --slurp '@sh')
fi

images=${images:1:-1}

for img in $images; do
    # Get component name
    IFS='@'
    read -a split <<< $img
    IFS='/'
    read -a cmp <<< $split
    IFS=''

    # Get commit
    commit=$(scripts/component.sh ${img:1:-1} | grep 'COMMIT')
    IFS=' '
    declare -a split 
    split=(echo $commit)
    IFS=''
    commit=${split[-1]}
    
    echo "${cmp[-1]}: $commit"
done