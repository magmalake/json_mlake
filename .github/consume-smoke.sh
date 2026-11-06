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
mojo = "==1.2.0"
json_mlake = "*"
TOML

cat > smoke.mojo <<'MOJO'
from json import *
from json.cpu.simdjson_ffi import SimdjsonFFI

def main() raises:
    print("json_mlake: module 'json' resolved from the package with no -I")
    _ = SimdjsonFFI()
    var v = loads('{"a": [1, 2, 3]}')
    print("json_mlake: libsimdjson_wrapper.so loaded, parsed", dumps(v))
    var text = String('{"id":"1","payload":{"a":[1,"}"]}}\n{"id":"2"}\n')
    var n = 0
    var payload = String()
    for line in scan_lines(text.as_bytes()):
        line.validate()
        if n == 0:
            payload = String(line["payload"])
        n += 1
    if n != 2 or payload != '{"a":[1,"}"]}':
        raise Error("json_mlake: span scan returned the wrong ranges")
    print("json_mlake: span scan read", n, "records; payload", payload)
MOJO

pixi install
pixi run mojo build smoke.mojo -o ./smoke
./smoke
# From a plain shell, as a deployed binary runs: with no CONDA_PREFIX the
# wrapper is found through the binary's rpath (the environment it built in).
env -u CONDA_PREFIX ./smoke
