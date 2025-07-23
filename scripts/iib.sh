#!/bin/bash
source scripts/util.sh

iib_url=$1
version=$2
operator_pkg="mtv-operator"
PROT="docker://"

# Print Usage if IIB URL is missing 
if [[ -z $1 || -z $2 ]]; then
    echo "Usage: ./iib.sh <url to iib> <version>, examples:"
    echo "./iib.sh quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v418:on-pr-76657e65fa4e6ff445965976200aed1ad7adbb7d 2.9.0"
    echo "./iib.sh registry-proxy.engineering.redhat.com/rh-osbs/iib:985689 2.8.5"
    echo "./iib.sh registry.redhat.io/redhat/redhat-operator-index:v4.18 2.8.5"
    exit 0
fi

# Prepend protocol to the URL
if [[ ${iib_url:0:${#PROT}} != $PROT ]]; then
    iib_url="${PROT}${iib_url}"
fi

# Get image manifests
tmp_dir=$(mktemp -d)
log "Getting IIB $iib_url..."
log "Using $tmp_dir directory for manifests"
log "Pulling image metadata..."
skopeo copy $iib_url "dir://${tmp_dir}"

# Get last layer from image
# It contains the catalog layer
layer_sha=$(cat $tmp_dir/manifest.json | jq '.layers | last | .digest' -r)
log "Layer containing the catalog: $layer_sha"

# Split the format "sha256:1234..." into ["sha256", "1234..."] and get only the hash
layer_sha=${layer_sha#*\:}

# Extract the layer tar
tar -xf "${tmp_dir}/${layer_sha}" -C $tmp_dir

# Parse the bundle image URL
bundle_img=$(cat $tmp_dir/configs/$operator_pkg/catalog.json | jq -r ". | select(.name == \"${operator_pkg}.v${version}\") | .image")

if [[ -z $bundle_img ]]; then
    log "Could not find bundle image in specified IIB for specified version."
else
    # clear output file
    cl_output
    log "### RESULT ###"
    # Don't know if it's still necessary to remove the trailing char
    w_output $(ytj "BUNDLE_IMAGE: ${bundle_img:1:-1}")
fi

# Remove created temporary directory
rm -rf $tmp_dir
