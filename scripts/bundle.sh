#/bin/bash

bundle_url=$1
PROT="docker://"

# Print Usage if bundle URL is missing 
if [[ -z $1 ]]; then
    echo "Usage: ./bundle.sh <url to bundle>, examples:"
    echo "./bundle.sh quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-operator-dev-preview/forklift-operator-bundle-dev-preview:c4c67a83863dfa85fd3d698e2c3c7834988567ef"
    exit 0
fi

# Prepend protocol to the URL
if [[ ${bundle_url:0:${#PROT}} != $PROT ]]; then
    bundle_url="${PROT}${bundle_url}"
fi

# Get image manifests
tmp_dir=$(mktemp -d)
echo "Using $tmp_dir directory for manifests"
bundle_commit=$(skopeo inspect -n $bundle_url | jq '.Labels | .["vcs-ref"]') 
echo "Pulling image metadata..."
skopeo copy $bundle_url "dir://${tmp_dir}"

# Get last layer from image
# It contains the csv layer
layer_sha=$(cat $tmp_dir/manifest.json | jq '.layers | last | .digest')
echo "Layer containing the csv: $layer_sha"

# Split the format "sha256:1234..." into ["sha256", "1234..."] and get only the hash
IFS=':'
read -a split_sha <<< $layer_sha
layer_sha=${split_sha[-1]}
# Strip trailing quote mark
layer_sha=${layer_sha:0:-1}

# Extract the layer tar
tar -xf "${tmp_dir}/${layer_sha}" -C $tmp_dir 

IFS=''
component_images=$(cat $tmp_dir/manifests/*.clusterserviceversion.yaml | yq '.spec.install.spec.deployments[0].spec.template.spec.containers[0].env | .[] | select(.value == "quay*" or .value == "registry*") | [.name:.value] | .[][][]')

operator_image=$(cat $tmp_dir/manifests/*.clusterserviceversion.yaml | yq '.spec.install.spec.deployments[0].spec.template.spec.containers[0].image')

echo "### RESULT ###"
echo $component_images
echo "OPERATOR_IMAGE: "$operator_image

# Remove created temporary directory
rm -rf $tmp_dir