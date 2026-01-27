#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/util.sh"

# Send notification about new IIB to our slack channel

date=$(date +%d.%m.%Y -u)
time=$(date +%H:%M -u)

channel_id="C09DS44AQ65" # solenoci-test C09BUM6ATBR, mtv-builds C09DS44AQ65

# env variable examples, all of these need to be set for this script to work

#iib_version="2.8.8-1"

#ocp_urls='''{
#  "v4.16": "quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v416:on-pr-a4278dac6f1587ca56270f8158aca3a4cb54cbf6",
#  "v4.17": "quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v417:on-pr-a4278dac6f1587ca56270f8158aca3a4cb54cbf6",
#  "v4.18": "quay.io/redhat-user-workloads/rh-mtv-1-tenant/forklift-fbc-prod-v418:on-pr-a4278dac6f1587ca56270f8158aca3a4cb54cbf6"
#}'''
#
#bundle_url="registry.redhat.io/migration-toolkit-virtualization/mtv-operator-bundle@sha256:8ab1d701eb3b598b39c4fe30026bbecb6c025236d5064cd25d7d7a05290c250b"
#
#snapshot="forklift-operator-2-8-mpc7s"
#
#commits='''{
#  "BUNDLE_IMAGE": "18c0180312e6cdbe103ac307b63d2151aae6e5ea",
#  "API_IMAGE": "b5863eb3768219d320868cb86b5fb056ac1e68ab",
#  "CONTROLLER_IMAGE": "b5863eb3768219d320868cb86b5fb056ac1e68ab",
#  "MUST_GATHER_IMAGE": "e36fd02eea22944cd51e84dacb39caab65a2fb9c",
#  "OPENSTACK_POPULATOR_IMAGE": "16beec323d0a7f3924f071cee6e90eb9e4f8873f",
#  "OPERATOR_IMAGE": "16beec323d0a7f3924f071cee6e90eb9e4f8873f",
#  "OVA_PROVIDER_SERVER_IMAGE": "16beec323d0a7f3924f071cee6e90eb9e4f8873f",
#  "OVIRT_POPULATOR_IMAGE": "16beec323d0a7f3924f071cee6e90eb9e4f8873f",
#  "POPULATOR_CONTROLLER_IMAGE": "16beec323d0a7f3924f071cee6e90eb9e4f8873f",
#  "UI_PLUGIN_IMAGE": "0b60fe6cb0e7df1379eea8516bf96289d10c81f7",
#  "VALIDATION_IMAGE": "23762417d1b081629fc7fdaa6b315420c6b10843",
#  "VIRT_V2V_IMAGE": "b5863eb3768219d320868cb86b5fb056ac1e68ab"
#}'''
#
#changes='''{
#  "forklift": {
#    "073b6206290e507f758c5ff11943290d2fecaf62": {
#      "msg": "chore: bump Z after release (#2656)",
#      "author": "Stefan Olenocin",
#      "date": "9 days ago"
#    },
#    "4cd178b9c993fa272bdeaf9a0b3b056ea3b09382": {
#      "msg": "Update \"virt-v2v-2-8\" to 6d928c9",
#      "author": "red-hat-konflux[bot]",
#      "date": "10 days ago"
#    },
#    "6ba6214770aaea9d8d03b3f37fa1b61691365357": {
#      "msg": "Update forklift-api-2-8 to b114574",
#      "author": "red-hat-konflux[bot]",
#      "date": "10 days ago"
#    },
#    "d9b1637853f6720300eba8e504f82dda83f500be": {
#      "msg": "Update forklift-controller-2-8 to f1b667c",
#      "author": "red-hat-konflux[bot]",
#      "date": "10 days ago"
#    }
#  },
#  "forklift-console-plugin": {
#    "0b60fe6cb0e7df1379eea8516bf96289d10c81f7": {
#      "msg": "Merge pull request #1791 from solenoci/release-2.8",
#      "author": "Stefan Olenocin",
#      "date": "9 days ago"
#    },
#    "c056a1fdb5b0ff17a1d82f58fa4645790c80ab0a": {
#      "msg": "chore: bump Z after release",
#      "author": "Stefan Olenocin",
#      "date": "9 days ago"
#    }
#  },
#  "forklift-must-gather": {
#    "e36fd02eea22944cd51e84dacb39caab65a2fb9c": {
#      "msg": "chore: bump Z after release",
#      "author": "Stefan Olenocin",
#      "date": "9 days ago"
#    }
#  }
#}'''
#
#last_build="2.8.7-GA registry.redhat.io/redhat/redhat-operator-index:v4.16"
#
# slack_auth_token="123456..."

function sanitize {
  echo "$@" | sed 's/"/\\\"/g'
}

# prepare heading message
version_info="IIB $iib_version | $date $time UTC"
iib_heading=$(jq "(.channel |= \"$channel_id\") | (.blocks[0].text.text |= \"$version_info\") | ." "$PROJECT_ROOT/templates/iib_heading.json" 2> errors.log)


# post heading message (e.g. starting message of thread with details)
echo "Sending main 'Header' message..."
resp=$(curl --header "Authorization: Bearer $slack_auth_token" --header "Content-Type: application/json" --request POST --data "$(echo $iib_heading | jq -c '.')" https://slack.com/api/chat.postMessage)

if [[ $(echo $resp | jq '.ok' -r) == "false" ]]; then
  log "Error occured while sending the message to slack..."
  "$SCRIPT_DIR/error_notify.sh" "$(echo errors.log)\n$resp"
  exit 1
fi


# timestamp of the sent message
ts=$(echo $resp | jq '.ts' -r)
# prepare iib details
# you can see the format in templates/iib_details.json
details_query="""(.channel |= \"$channel_id\") | (.thread_ts |= \"$ts\") | """

# set IIB urls for each ocp version
declare -i id=0
for ocp in $(echo $ocp_urls | jq '. | keys.[]' -r); do
  ocp_ver=$ocp
  ocp_url=$(echo $ocp_urls | jq ".\"$ocp\"" -r)
  details_query+="(.blocks[2].elements[0].elements[$id].text |= \"$ocp_ver\") | "
  # needed elements are always 2 indexes away
  id+=2
  details_query+="(.blocks[2].elements[0].elements[$id].text |= \"$ocp_url\") | "
  id+=2
done

# set bundle url
details_query+="(.blocks[10].elements[1].elements[0].text |= \"$bundle_url\") | "

# set snapshot
details_query+="(.blocks[10].elements[3].elements[0].text |= \"$snapshot\") | "

# set commits
# use $(echo $commits) to keep newlines
commits=$(echo $commits | yq -p json -o yaml)
details_query+="(.blocks[10].elements[5].elements[0].text |= \"$(echo "$commits")\") | "

# set commit changes
mrkdwn=""
for origin in $(echo $changes | jq '. | keys.[]' -r); do
  mrkdwn+="*$origin*"
  mrkdwn+=' changes:\n```'
  shas=$(echo $changes | jq ".\"$origin\" | keys.[]" -r)
  if [[ -z $shas ]]; then
    mrkdwn+='None```\n'
    continue
  fi
  for sha in ${shas[@]}; do
    commit=$(echo $changes | jq ".\"$origin\".\"$sha\"")
    mrkdwn+="$(sanitize $(echo $commit | jq '.msg' -r))\n"
    mkrdwn+="\tCommit: $sha\n"
    mrkdwn+="\tAuthor: $(echo $commit | jq '.author' -r)\n"
    mrkdwn+="\tDate: $(echo $commit | jq '.date' -r)\n"
  done
  mrkdwn+='```\n'
done

details_query+="(.blocks[7].text.text |= \"$(echo $mrkdwn)\") | "

# set last build
if [[ $last_build == *"No previous"* ]]; then
  last_build="*Last build*\n$last_build"
  details_query+="(.blocks[5].elements[0].text |= \"$last_build\") | "
else
  last_ver=$(echo $last_build | cut -d ' ' -f 1)
  last_iib=$(echo $last_build | cut -d ' ' -f 2)
  last_build="*Last build*\n$last_ver\n$last_iib"
  details_query+="(.blocks[5].elements[0].text |= \"$last_build\") | "
fi
# end query
details_query+="."

iib_details=$(jq "$details_query" "$PROJECT_ROOT/templates/iib_details.json" 2> errors.log)

# post details in the thread
echo "Sending reply to 'Header' message..."

resp=$(curl --header "Authorization: Bearer $slack_auth_token" --header "Content-Type: application/json" --request POST --data "$(echo $iib_details | jq -c '.')" https://slack.com/api/chat.postMessage)

# if the sending of message failed, also remove the header message so it's not lingering in the slack channel by itself
if [[ $(echo $resp | jq '.ok' -r) == "false" ]]; then
  log "Error occured while sending the message to slack..."
  log "Deleting $ts header message that was already sent..."
  curl --header "Authorization: Bearer $slack_auth_token" --header "Content-Type: application/json" --request POST --data "{\"channel\": \"$channel_id\",\"ts\": \"$ts\"}" https://slack.com/api/chat.delete
  "$SCRIPT_DIR/error_notify.sh" $(sanitize $(cat errors.log)) $resp
fi
