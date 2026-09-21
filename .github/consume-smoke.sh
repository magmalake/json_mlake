#!/usr/bin/env bash
# Install the freshly built package into a throwaway project and compile
# against it with no `-I` flag, the way a real consumer would.
#
# The `-I`-free part is the point: it proves the recipe staged the module
# where Mojo looks for it ($CONDA_PREFIX/lib/mojo), rather than the build
# merely having produced a file.
set -euo pipefail

# Only the platform this runner just built is present in the local channel, so
# the throwaway project must declare exactly that one. Declaring both makes
# pixi solve for both and fail on whichever it has no packages for.
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64)  PLATFORM=linux-64  ;;
  Darwin/arm64)  PLATFORM=osx-arm64 ;;
  Darwin/x86_64) PLATFORM=osx-64    ;;
  *) echo "unsupported runner: $(uname -s)/$(uname -m)" >&2; exit 1 ;;
esac
echo "consuming on $PLATFORM"

CHANNEL="$(cd ./channel && pwd)"
WORK="$(mktemp -d)"
cd "$WORK"

cat > pixi.toml <<TOML
[workspace]
name = "consume-smoke"
channels = ["file://$CHANNEL", "https://conda.modular.com/max-nightly", "conda-forge"]
platforms = ["$PLATFORM"]

[dependencies]
mojo = "==1.1.0"
json_mlake = "*"
TOML

cat > smoke.mojo <<'MOJO'
from json import *

def main():
    print("json_mlake: module 'json' resolved from the package with no -I")
MOJO

pixi install
pixi run mojo build smoke.mojo -o ./smoke
./smoke
