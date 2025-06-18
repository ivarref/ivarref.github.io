#!/usr/bin/env bash

set -euo pipefail
git submodule update --init --recursive || true
#git submodule update --remote --merge

hugo server -D