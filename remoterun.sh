#!/usr/bin/env bash

set -euo pipefail

REMOTE_HOST='lima-ubuntu'
REMOTE_PATH='code/my-app'

REMOTE_SCRIPT='mkdir -p '"${REMOTE_PATH@Q}"
echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s
# Creates the remote path if it does not exist.
# OS X' rsync (version 2.6.9) do not support this out of the box.

# What is ${REMOTE_PATH@Q}?
# The @Q part expands the variable in a quote safe way.
# Thus, if you really want, you can put a space inside your remote path.
# Why would you want to do that though?
# Don't add a tilde (~) in the path. It won't be expanded.

rsync -aq \
--include='**.gitignore' \
--filter=':- .gitignore' \
--filter='protect node_modules/' \
--delete \
. "${REMOTE_HOST}:${REMOTE_PATH@Q}"
# Sync files based on .gitignore:
# -a: Archive mode, preserves timestamps, etc.
# -q: Quiet.
# --include='**.gitignore': Include files not in .gitignore.
# --filter=':- .gitignore': Exclude files in .gitignore.
# --delete: Delete files on the remote which are not in the source.
# --filter='protect node_modules/': Don't delete the remote path node_modules/

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
  # shopt -s huponexit: Send SIGHUP to all jobs when the job exits.
  echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s
fi
