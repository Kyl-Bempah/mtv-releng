#!/bin/bash

version=$1

# Print Usage if argument is missing
if [[ -z $1 ]]; then
    echo "Usage: "
    echo "./rebuild_bundle.sh 2-9"
    echo "./rebuild_bundle.sh dev-preview"
    exit 0
fi

oc annotate components/forklift-operator-bundle-$version build.appstudio.openshift.io/request=trigger-pac-build