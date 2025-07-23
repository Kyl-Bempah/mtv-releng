#!/bin/bash

# Print all the version configurations for our repositories

declare -a branches=(
    "main"
    "release-2.9"
    "release-2.8"
)

declare -a repos=(
    "forklift"
    "forklift-console-plugin"
    "forklift-must-gather"
)
for repo in "${repos[@]}"
do
    echo $repo
    for branch in "${branches[@]}"
    do
        ver=$(curl -s https://raw.githubusercontent.com/kubev2v/$repo/refs/heads/$branch/build/release.conf | grep VERSION= | cut -d '=' -f 2)
        echo -e "  $branch = $ver"
    done
done