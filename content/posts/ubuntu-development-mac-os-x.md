---
title: "Ubuntu development on Mac OS X"
date: 2025-10-31T08:46:36+02:00
---

My main development machine is Mac OS X.
Sometimes I need to use some Linux specific tool though.
Here is my setup for doing that.

## VM, shell and ssh setup

[Lima-VM](https://lima-vm.io/) launches
Linux virtual machines with automatic file sharing
and port forwarding.

Install lima-vm
using [homebrew](https://brew.sh):

```
brew install lima
```

Next I'm creating and starting an ubuntu VM:

```
limactl create --name=ubuntu template://ubuntu-lts
...
INFO[0005] Run `limactl start ubuntu` to start the instance.

limactl start ubuntu
...
INFO[0012] READY. Run `limactl shell ubuntu` to open the shell.
```

At this point the ubuntu VM is running, and lima tells us how we can
open the shell: `limactl shell ubuntu`.

I'm a [fish shell](https://fishshell.com/) user, so
the next step for me is to execute:

```
sudo apt-get install fish
```

inside `limactl shell ubuntu`.

It was somewhat tricky to set up a proper default shell.
I did it by executing:

```
sudo chsh --shell /usr/bin/fish "$USER"
```

inside `limactl shell ubuntu`.

Then, for reasons I do not know, the VM needs to be _restarted_
for the shell change to take effect:

```
limactl restart ubuntu
```

After that completes, `limactl shell ubuntu` should give you a fish shell.

Next up is setting up ssh such that `ssh lima-ubuntu` will work.
I edited `~/.ssh/config` and put the following line
at the _top_:

```
Include ~/.lima/*/ssh.config
```

and at the _bottom_ of `~/.ssh/config` I put the following ilnes:

```
Host *
  SetEnv TERM=xterm-256color
```

Now `ssh lima-ubuntu` should drop you into a fish shell on the VM.

## Syncing files and executing remote commands

Lima-VM can do file sharing, but I like to keep things separate.

In a given project I add a file `remoterun.sh`:

```bash
#!/usr/bin/env bash

set -euo pipefail

REMOTE_HOST='lima-ubuntu'
REMOTE_PATH="$(pwd | sed "s|$HOME/||")"

REMOTE_SCRIPT='mkdir -p '"${REMOTE_PATH@Q}"
echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s
# Creates the remote path if it does not exist.
# OS X' rsync (version 2.6.9) do not support this out of the box.

# What is ${REMOTE_PATH@Q}?
# The @Q part expands the variable in a quote safe way.
# Thus, if you really want, you can put a space inside your remote path.
# Why would you want to do that though?
# Don't add a tilde (~) in the path. It won't be expanded.

scp -q ./.gitignore "${REMOTE_HOST}:${REMOTE_PATH}"

REMOTE_SCRIPT='cd '"${REMOTE_PATH@Q}/.git"
REMOTE_HAS_GIT="true"
echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s 2>/dev/null || REMOTE_HAS_GIT="false"

PROTECT_FILES="protect_files_arr=()"
if [[ "${REMOTE_HAS_GIT}" == "true" ]]; then
  REMOTE_SCRIPT='cd '"${REMOTE_PATH@Q}"' && git status --ignored=matching --porcelain | grep "^!!"'
  PROTECT_FILES="$(echo "${REMOTE_SCRIPT}" | ssh "${REMOTE_HOST}" /bin/bash -s | \
/usr/bin/env python3 -c "import fileinput
import sys
print('protect_files_arr=(', end='')
for line in fileinput.input():
  line1 = line.strip()
  if line1 == '':
    continue
  assert \"'\" not in line1
  assert line1.startswith('!! ')
  v = f'\'--filter=protect {line1[3:]}\''
  print(v, end=' ')
  #print(v, file=sys.stderr)
print(')', end='')
")"
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
```

With this in place I can do `./remoterun.sh ./my-app`.

## Executing commands on a file change

On my Mac, I typically use
[entr](https://formulae.brew.sh/formula/entr) to execute a remote command on the VM
when a file changes:

```bash
git ls-files | entr -ccr ./remoterun.sh ./my-app arg1 arg2
```

It is also possible to chain commands:

```bash
git ls-files | entr -ccr ./remoterun.sh bash -c 'npm run build && npm start'
```

I recommend checking out Julia Evans' [introduction to entr](https://jvns.ca/blog/2020/06/28/entr/)
if you are interested in learning more about `entr`.

## Final words

On my machine `remoterun.sh` adds about 150 milliseconds of extra time for each command.
That is fine by me.

That is pretty much it. [Let me know](mailto:refsdal.ivar@gmail.com) if you
have suggestions or improvements!
