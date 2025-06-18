#/bin/bash

component_url=$1
PROT="docker://"

# Print Usage if component URL is missing 
if [[ -z $1 ]]; then
    echo "Usage: ./component.sh <url to component>, examples:"
    echo "./component.sh quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-operator-dev-preview/forklift-operator-bundle-dev-preview:c4c67a83863dfa85fd3d698e2c3c7834988567ef"
    exit 0
fi

# Prepend protocol to the URL
if [[ ${component_url:0:${#PROT}} != $PROT ]]; then
    component_url="${PROT}${component_url}"
fi

sha=$(skopeo inspect -n --format "{{.Digest}}" $component_url)
echo "### RESULT ###"
echo $sha