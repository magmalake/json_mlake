#!/usr/bin/env bash
# Install the freshly built package into a throwaway project and compile
# against it with no `-I` flag, the way a real consumer would.
#
# The `-I`-free part is the point: it proves the recipe staged the module
# where Mojo looks for it ($CONDA_PREFIX/lib/mojo), rather than the build
# merely having produced a file.
set -euo pipefail

CHANNEL="$(cd ./channel && pwd)"
WORK="$(mktemp -d)"
cd "$WORK"

cat > pixi.toml <<TOML
[workspace]
name = "consume-smoke"
channels = ["file://$CHANNEL", "https://conda.modular.com/max-nightly", "conda-forge"]
platforms = ["linux-64", "osx-arm64"]

[dependencies]
mojo = "==1.0.0"
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
