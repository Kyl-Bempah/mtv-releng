#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/util.sh"

# Gets commit history for specified component (backend, frontend or gather), for specified branch (main, release-2.9...) and from the most recent commit to oldest commit (excluding the oldest commit in output)

# Print Usage if argument is missing
if [[ -z $1 || -z $2 || -z $3 || -z $4 ]]; then
    echo -e "Gets commit history for specified component (forklift, forklift-console-pluign or forklift-must-gather), for specified branch (main, release-2.9...) and from the most recent commit to oldest commit (excluding the oldest commit in output)\n"
    echo "Usage: ./commit_history.sh <component> <branch> <oldest_commit> <newest_commit>, examples:"
    echo "./commit_history.sh forklift main 881e5d25da866700d9d68b5a6dc109cd8ddbaa39 600e32ad5327240e94433a219d5269d3e12e8a4d"
    echo "./commit_history.sh forklift-console-pluign main d6cbce8e6e1cb7e21be8d25d36a2c1310d2f4bcc 9dc23ebcfd1941bd5dc2e431a0d349653ddc1f85"
    echo "./commit_history.sh forklift-must-gather release-2.9 c4ee6c5acb9e837ce97a391e85b90d2752546a1f 8c0e1ff419eac68726f5a7d3dcd279036fe92b3c"
    exit 0
     
fi

c=$1
branch=$2
from=$3
to=$4

json="{}"

if [[ $from == $to ]]; then
  cl_output
  w_output $json
  exit 0
fi

function sanitize {
  echo $1 | sed 's/"/\\\"/g'
}

if [[ -n $(ls | grep temp) ]]; then
  rm -rf temp
fi
mkdir temp
cd temp
git init
git remote add origin https://github.com/kubev2v/$c.git
git fetch origin $branch
commits=$(git --no-pager log --remotes --format=format:'%H%n' --grep="chore(.*)" --invert-grep $from..$to)
for commit in ${commits[@]}; do
  msg=$(sanitize "$(git show -s --format=format:'%s' $commit)")
  author=$(sanitize "$(git show -s --format=format:'%an' $commit)")
  date=$(sanitize "$(git show -s --format=format:'%cr' $commit)")
  json=$(echo $json | jq ". += {\"$commit\": {\"msg\": \"$msg\", \"author\":\"$author\", \"date\": \"$date\"}}")
done
cl_output
w_output $json
cd ..
rm -rf temp
