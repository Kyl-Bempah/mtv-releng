#!/bin/bash
source scripts/util.sh

# Create a pull request with specified mtv versions and bundle shas

target=$1
version=$2
bundle_sha=$3
use_quay=$4

# Print Usage if argument is missing
if [[ -z $1 || -z $2 || -z $3 ]]; then
    echo "Usage: ./create_iib_pr.sh <target> <version> <bundle_sha> [use_quay_url]"
    echo "<target> - required, target branch for the FBC catalog repository"
    echo "<version> - required, MTV version for which bundle is built"
    echo "<bundle_sha> - required, bundle image sha to be put in the catalog"
    echo "[use_quay_url] - optional, if arg is not zero, then bundle url in the catalog will be from quay, arg value can be anything, e.g. 'yes', 'true', '1'..."
    echo "./create_iib_pr.sh main 2.9.3 92287b349c3b94574994d70d97b9f3e1c90ac8b629954836aaef21d424452e16"
    echo "./create_iib_pr.sh stage 2.10.0 92287b349c3b94574994d70d97b9f3e1c90ac8b629954836aaef21d424452e16 yes"
    exit 0
fi

# get what version is dev-preview
scripts/verify_versions.sh
dp_ver=$(r_output | jq '.forklift.main' -r)

# create temp dir
temp_dir

# prepare git
log "Preparing git FBC repository..."
git clone https://github.com/kubev2v/mtv-fbc.git .
git checkout $target
git pull

# set username and email
git config user.email "mtv-automation@redhat.com"
git config user.name "MTV Bot - IIB Automation"

# get opm cli tool
log "Downloading OPM tooling..."
source opm_utils.sh
download_opm_client

# construct bundle url
if [[ $version == $dp_ver ]]; then
  repository="mtv-candidate"
  is_dp="yes"
else
  repository="migration-toolkit-virtualization"
  is_dp="no"
fi

if [[ $target == "stage" ]]; then
  registry="registry.stage.redhat.io"
else
  # TODO: Temporary workaround for working with main
  registry="registry.stage.redhat.io"
fi

bundle_url="$registry/$repository/mtv-operator-bundle@sha256:$bundle_sha"

# replace for quay url in case the bundle is not released yet
if [[ -n $use_quay ]]; then
  bundle_url=$(../scripts/replace_for_quay.sh $bundle_url $version)
fi

# get bundle metadata
log "Getting bundle metadata..."
bundle_metadata=$(skopeo inspect docker://$bundle_url)
bundle_entry="{\"schema\": \"olm.bundle\",\"image\": \"$bundle_url\"}"

# get OCP versions for bundle used
ocp_label=$(echo -e $bundle_metadata | jq '.Labels."com.redhat.openshift.versions"')
ocp_label=${ocp_label:1:-1}
log "Found $ocp_label OCP version for processing..."

# example for "v4.18-v4.20" label
start_version=${ocp_label%-*} # result: v4.18
end_version=${ocp_label#*-} # result: v4.20
prefix=${start_version%.*} # result: v4
start_number=${start_version##*.} # result: 18
end_number=${end_version##*.} # result: 20

# get operator channel
channel=$(echo -e $bundle_metadata | jq '.Labels."operators.operatorframework.io.bundle.channels.v1"')
channel=${channel:1:-1}
log "Found operator target channel: $channel..."

declare -a versions

for ((i=start_number; i<=end_number; i++)); do
  versions+=("$prefix.$i")
done

# check if branch for MTV version exists, if not create it
if [[ -n $(git branch -a | grep remotes/origin/$version) ]]; then
  log "Branch for $version exists on remote, using it..."
  git fetch origin $version
  git checkout $version
else
  log "Could not find the branch for $version on remote, creating new one..."
  git checkout -b $version
fi

# get number of previous commits for MTV $version, will later be used as suffix for commit message, e.g. $version-$iib_ver
iib_ver=$(($(git --no-pager log -n 100 --format=format:%H --grep $version -F | wc -w)+1))

# figure out the previous IIB
# if there are commits mentioning the MTV version, then we can assume that the latest commit was resposible for the latest IIB
if [[ $iib_ver > 1 ]]; then
  old_commit=$(git --no-pager log -n 100 --format=format:%H --grep $version -F | head -n 1)
  prev_iib="quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-${versions[0]//./}:on-pr-$old_commit"
  prev_version="$version"
  prev_ver_suffix="$version-$(($iib_ver-1))"
  log "Found previous build ($prev_ver_suffix) for $version..."
else
  # if we don't find any commits associated with the current MTV version, then we try to use GA content from previous version, e.g. if current = 2.9.3, previous would resolve to 2.9.2 GA build.
  if [[ $is_dp == "yes" ]]; then
    # current build is for the first z-stream version e.g. 2.10.0
    # we don't really have any previous IIB build to do the diff with, so proceed without the diff
    # this happens right after branching and only affects the very first build of target version after branching
    prev_version="$version"
    prev_iib="none"
    log "This is the first $version Z-stream build for a new Y-stream version..."
  else
    prev_iib="registry.redhat.io/redhat/redhat-operator-index:${versions[0]}"
    declare -i prev_z=$(echo $version | cut -d '.' -f 3)
    if [[ $prev_z > 0 ]]; then
      # z stream is bigger than .0 so we can use previous Z-stream version
      prev_z+=-1
      prev_version="${version%.*}.$prev_z"
      prev_ver_suffix="$prev_version-GA"
      log "First $version Z-stream build, will use previous $prev_version GA build for diff..."
    else
      # current build is for the first z-stream version e.g. 2.10.0
      # we don't really have any previous IIB build to do the diff with, so proceed without the diff
      # this happens right after branching and only affects the very first build of target version after branching
      prev_version="$version"
      prev_iib="none"
      log "This is the first $version Z-stream build for a new Y-stream version..."
    fi
  fi
fi

json="""{
  \"$version\":{
    \"ocp_versions\":\"\",
    \"pr_url\":\"\",
    \"current_iib\":\"\",
    \"prev_iib\":\"$prev_iib\",
    \"prev_version\":\"$prev_version\",
    \"ver_suffix\":\"\",
    \"prev_ver_suffix\":\"$prev_ver_suffix\"
  }
}"""

function process_catalog {
  ocp_ver=$1
  log "Processing $ocp_ver catalog..."

  # if ocp version is missing from fbc repo, create it
  fresh=0
  if [[ -z $(ls | grep $ocp_ver) ]]; then
    log "Initializing catalog for new OCP version $ocp_ver..."
    ./generate-fbc.sh --init $ocp_ver 2> errors.log
    if (( $? != 0 )); then
      log "Generating failed, trying once again..."
      ./generate-fbc.sh --init $ocp_ver 2> errors.log
      if (( $? != 0 )); then
        log "Catalog generation failed..."
        scripts/error_notify.sh "Failed to init the $ocp_ver catalog for $version. \n$(cat errors.log)"
        exit 1
      fi
    fi
    fresh=1
  fi

  # check if bundle entry is already in catalog and if not, add it
  if [[ -z $(cat "$ocp_ver/catalog-template.json" | grep $bundle_sha) ]]; then
    # check is the catalog was just regenerated, if not, regenerate it
    log "Bundle $bundle_url not found in the catalog, adding it..."
    if [[ $fresh == 0 ]]; then
      log "Regenerating the catalog $ocp_ver..."
      ./generate-fbc.sh --init $ocp_ver 2> errors.log
      if (( $? != 0 )); then
        log "Generating failed, trying once again..."
        ./generate-fbc.sh --init $ocp_ver 2> errors.log
        if (( $? != 0 )); then
          log "Catalog generation failed..."
          scripts/error_notify.sh "Failed to init the $ocp_ver catalog for $version. \n$(cat errors.log)"
          rm errors.log
          exit 1
        fi
      fi
    fi

    # check for bundle presence again in case it was added
    if [[ -n $(cat "$ocp_ver/catalog-template.json" | grep $bundle_sha) ]]; then
      log """Skip adding already present bundle to catalog:
  Catalog: $ocp_ver
  Version: $version
  Bundle SHA: $bundle_sha"""
      return
    fi

    channel_query=".entries | map(select(.schema==\"olm.channel\")) | map(select(.name==\"$channel\")).[]"

    # check if the target channel exists, if not, create it, if yes, add the new version to it
    if [[ -z $(cat $ocp_ver/catalog-template.json | jq "$channel_query") ]]; then
      # Channel does not exist in the catalog, create the channel entry and also version entry
      log "Channel $channel does not exit in the catalog, creating it..."
      new_channel="{\"entries\": [{\"name\": \"mtv-operator.v$version\",\"skipRange\": \">=0.0.0 <$version\"}],\"name\": \"$channel\",\"package\": \"mtv-operator\",\"schema\": \"olm.channel\"}"
      jq ".entries += [$new_channel]" $ocp_ver/catalog-template.json > $ocp_ver/catalog-template.json.new
      mv $ocp_ver/catalog-template.json.new $ocp_ver/catalog-template.json

      # add the bundle entry to the end
      log "Adding bundle to the catalog..."
      jq ".entries[.entries | length] |= . + $bundle_entry" "$ocp_ver/catalog-template.json" > $ocp_ver/catalog-template.json.new 
      mv -f $ocp_ver/catalog-template.json.new $ocp_ver/catalog-template.json
    else
      # Channel already exists in the catalog, create just version entry if the entry does not exist
      if [[ -z $(cat "$ocp_ver/catalog-template.json" | jq ".entries.[] | select(.name==\"$channel\") | .entries.[] | select(.name==\"mtv-operator.v$version\")") ]]; then
        log "Channel $channel found in catalog, creating new version entry..."
        prev_version="${version%.*}.$(($(echo $version | rev | cut -d '.' -f 1 | rev)-1))"
        new_version="{\"name\": \"mtv-operator.v$version\",\"replaces\": \"mtv-operator.v$prev_version\",\"skipRange\": \">=0.0.0 <$version\"}"
        jq "(.entries[] | select(.name == \"$channel\").entries) |= . + [$new_version]" $ocp_ver/catalog-template.json > $ocp_ver/catalog-template.json.new
        mv -f $ocp_ver/catalog-template.json.new $ocp_ver/catalog-template.json

        # add the bundle entry to the end
        log "Adding bundle to the catalog..."
        jq ".entries[.entries | length] |= . + $bundle_entry" "$ocp_ver/catalog-template.json" > $ocp_ver/catalog-template.json.new 
        mv -f $ocp_ver/catalog-template.json.new $ocp_ver/catalog-template.json
      else
        # version entry already exists in channel, check for bundle which is for the version
        log "Version $version already present in channel $channel, finding corresponding bundle..."
        for bundle in $(cat $ocp_ver/catalog-template.json | jq '.entries.[] | select(.schema=="olm.bundle").image' -r); do
          ver=$(skopeo inspect docker://$bundle | jq '.Labels.version' -r)
          # If bundle entry version is equal to processed version, remove the bundle entry
          if [[ $ver == $version ]]; then
            log "Found old bundle $bundle for version $version, removing it..."
            cat $ocp_ver/catalog-template.json | jq "del (.entries.[] | select(.schema=="olm.bundle") | select(.image==\"$bundle\")) | ." > $ocp_ver/catalog-template.json.new 
            mv -f $ocp_ver/catalog-template.json.new $ocp_ver/catalog-template.json
            break
          fi
        done
        # add the bundle entry to the end
        log "Adding bundle to the catalog..."
        jq ".entries[.entries | length] |= . + $bundle_entry" "$ocp_ver/catalog-template.json" > $ocp_ver/catalog-template.json.new 
        mv -f $ocp_ver/catalog-template.json.new $ocp_ver/catalog-template.json
      fi
    fi
    log "Generating final $ocp_ver catalog..."
    ./generate-fbc.sh --render-template $ocp_ver 2> errors.log
    if (( $? != 0 )); then
      log "Catalog generation failed..."
      scripts/error_notify.sh "Failed to render the $ocp_ver catalog for $version. \n$(cat errors.log)"
      rm errors.log
      exit 1
    fi
  else
    log "Skip adding already present bundle to catalog:
  Catalog: $ocp_ver
  Version: $version
  Bundle SHA: $bundle_sha"""
  fi
}

for ocp_ver in ${versions[@]}; do
  process_catalog $ocp_ver
  # sleep to avoid pulling catalogs too fast if we don't add anything to the catalog
  sleep 10
done

rm errors.log

# if there are changes to the catalogs, commit them
if [[ -n $(git status -s) ]]; then
  git add .
  log "Commiting changes with msg: $version-$iib_ver"
  git commit -sm "$version-$iib_ver"
  git push origin $version -f

  commit=$(git log -n 1 --format=format:%H)
  current_iib="quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-${versions[0]//./}:on-pr-$commit"

  json=$(echo $json | jq ".\"$version\".ver_suffix = \"$version-$iib_ver\"")
  json=$(echo $json | jq ".\"$version\".current_iib = \"$current_iib\"")

  # check if pR already exists
  pr_url=$(gh pr list --head "$version" --label "automation" --json url | jq '.[].url' -r)
  if [[ -z $pr_url ]]; then
    pr_url=$(gh pr create --title "$version" --base main --body "" --label "automation")
  fi
  json=$(echo $json | jq ".\"$version\".ocp_versions = \"$(echo "${versions[@]}")\"")
  json=$(echo $json | jq ".\"$version\".pr_url = \"$pr_url\"")
fi

cl_output
w_output $json

# cleanup temp dir
rm_temp_dir


# installation for DNF4, which ise default for UBI10
#dnf install 'dnf-command(config-manager)' git
#dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
#dnf install gh --repo gh-cli

### Create IIB PR pseudo code ###
# for each OCP version
#   check main for bundle sha
#
#   if bundle sha found:
#     skip processing of the catalog
#   else bundle sha not found:
#     check PR for version
#
#     if PR found:
#       fetch the branch with version
#     else PR not found:
#       create branch
#
#     check if channel for MTV version exists
#
#     if channel found:
#       check for version entry
#
#       if version entry found:
#         inspect bundle entries for MTV version
#
#         if bundle entry matches MTV version:
#           replace bundle sha for that entry
#         else bundle entry does not match:
#           error? - this case should not happen
#
#       else version entry not found:
#         add version entry
#         add bundle entry
#
#     else channel not found:
#       create channel
#       add version entry
#       add bundle entry
#
#     git commit with <MTV version> as commit message
#     git push origin <MTV version> -f
