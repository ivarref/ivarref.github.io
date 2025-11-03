#!/usr/bin/env bash

set -euo pipefail
git submodule update --init --recursive || true
#git submodule update --remote --merge

hugo server -D --disableFastRender | ./watch.py
#hugo server -D --disableFastRender

#