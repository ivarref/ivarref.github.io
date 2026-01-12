#!/usr/bin/env bash

set -euo pipefail

if ! [ -e "./.git" ]; then
  echo "Error: $0 expected to be executed in git repository root."
  echo "Aborting!"
  exit 1
fi

REMOTE_HOST='lima-ubuntu'
REMOTE_PATH="${REMOTE_PATH:-$(pwd | sed "s|$HOME/||")}"

REMOTE_SCRIPT='mkdir -p '"${REMOTE_PATH@Q}"
echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s
# Creates the remote path if it does not exist.
# OS X' rsync (version 2.6.9) do not support this out of the box.

# What is ${REMOTE_PATH@Q}?
# The @Q part expands the variable in a quote safe way.
# Thus, if you really want, you can put a space inside your remote path.
# Why would you want to do that though?
# Don't add a tilde (~) in the path. It won't be expanded.

if ! [ -e "./.gitignore" ]; then
  scp -q ./.gitignore "${REMOTE_HOST}:${REMOTE_PATH}"
fi

REMOTE_SCRIPT='cd '"${REMOTE_PATH@Q}/.git"
REMOTE_HAS_GIT_DIR="true"
echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s 2>/dev/null || REMOTE_HAS_GIT_DIR="false"

PROTECT_FILES="protect_files_arr=()"
if [[ "${REMOTE_HAS_GIT_DIR}" == "true" ]]; then
  REMOTE_SCRIPT='cd '"${REMOTE_PATH@Q}"' && git status --ignored=matching --porcelain'
  PROTECT_FILES="$(echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s | \
/usr/bin/env python3 -c "import fileinput
import sys
print('protect_files_arr=(', end='')
for line in fileinput.input():
  line1 = line.strip()
  if line1.startswith('!! '):
    assert \"'\" not in line1
    v = f'\'--filter=protect {line1[3:]}\''
    print(v, end=' ')
    #print(v, file=sys.stderr)
print(')', end='')
")" || { echo "Failure to list remote ignored files!"; exit 1; }
fi

eval "${PROTECT_FILES}"

# shellcheck disable=SC2154
rsync -aq \
--include='**.gitignore' \
--filter=':- .gitignore' \
"${protect_files_arr[@]}" \
--delete \
. "${REMOTE_HOST}:${REMOTE_PATH@Q}"
# Sync files based on .gitignore:
# -a: Archive mode, preserves timestamps, etc.
# -q: Quiet.
# --include='**.gitignore': Include files not in .gitignore.
# --filter=':- .gitignore': Exclude files in .gitignore.
# --delete: Delete files on the remote which are not in the source.

if [[ "0" == "$#" ]]; then
  echo "No arguments given, synced files only"
else
  # shellcheck disable=SC2124
  # shellcheck disable=SC2016
  REMOTE_SCRIPT='set -euo pipefail
shopt -s huponexit
cd '"${REMOTE_PATH@Q}"' || \
{ echo "Could not cd to directory! Exiting."; exit 1; }
'"${@@Q}"' && EXIT_CODE="$?" || EXIT_CODE="$?"
#echo "Command exited with code $EXIT_CODE"
exit "$EXIT_CODE"
'
  # This script will be executed on the remote.
  # Changes directory to the remote path and executes the command.
  # shopt -s huponexit: Send SIGHUP to all jobs when the ssh session ends.
  echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s
fi
