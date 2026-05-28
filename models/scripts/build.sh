#!/usr/bin/env bash
# Compile both .pproj files. No checking.

set -euo pipefail

cd "$(dirname "$0")/.."

p compile splicing.pproj
p compile infra.pproj
