# json_mlake

**This is not a new JSON library. It is a packaged build of
[json](https://github.com/ehsanmok/json) by
[Ehsan M. Kermani](https://github.com/ehsanmok), redistributed so that
[magmalake](https://github.com/magmalake) repositories can depend on it.**

All of the code here — the simdjson FFI, the two-stage parser, the value types,
reflection, JSONPath, schema validation, the GPU backend — is upstream's work.

**If you are looking for the project, go upstream:
<https://github.com/ehsanmok/json>.** Star it there, file issues there, send
pull requests there.

## Why this exists

json is not published to any conda channel, so `pixi` cannot resolve it. It is
a dependency of [flare](https://github.com/ehsanmok/flare), which magmalake
needs for HTTP and gRPC.

## What differs from upstream

Tracks upstream **v0.4.2**. Packaging, and these source deltas:

- **The package ships a precompiled `json.mojoc`**, not the source tree,
  so consumers stop re-parsing json on every build. `json.gpu` is not in
  it: it imports `max`, and a `.mojoc` resolves every import when it
  loads. Build json from source for the GPU path.

- **A span scan, `json/ondemand.mojo`** (magmalake/json_mlake#5):
  `scan(span)` / `scan_lines(span)` return `RawValue`s, a value's byte
  range in the caller's buffer plus its kind, like simdjson On-Demand's
  `raw_json()`. Key and path lookups (`v["payload"]`,
  `v.path("payload.pull_request.base.repo.language")`, `v.fields([...])`
  for several keys in one walk) step over unwanted values 64 bytes at a
  time with stage 1's escape and in-string masks, and allocate nothing.
  It validates lazily, as On-Demand does: walked punctuation, read
  strings and numbers; `validate()` checks a value with the parser's
  rules. Written to go upstream: one new module, its exports, a test
  file (`tests/test_scan.mojo`, in `tests-cpu`), a fuzz target
  (`fuzz/fuzz_scan.mojo`) and a benchmark (`bench-scan`).
- **Parse-error context is always valid UTF-8** (`json/errors.mojo`):
  the "Near:" window could cut a character in two, or quote a document
  that isn't UTF-8, and build an ill-formed `String` (an assertion under
  `-D ASSERT=all`). Such a window now shows its non-ASCII bytes as
  `\xHH`. Found by fuzzing the span scan; worth sending upstream.

- **The simdjson wrapper is found without `CONDA_PREFIX`**
  (`json/cpu/_dlopen.mojo`, the library search every magmalake tin that
  loads a library shares): `$CONDA_PREFIX/lib`, the executable's directory
  and its `../lib`, then the binary's rpath, so a binary built under pixi
  runs from a plain shell. A missing wrapper is an Error saying to set
  `CONDA_PREFIX`. Upstream falls back to `build/libsimdjson_wrapper.so`
  relative to the working directory, which this drops. Worth sending
  upstream.

- **The package is named `json_mlake`**; the module is still imported as
  `json`, so consumers change no source, and switching to an official package
  later is a one-line dependency change. The recipe's description says it is a
  redistribution.
- **`mojodoc` dropped** from the dev feature. It is a docs generator nothing in
  the test suite needs, so the `docs` task is unavailable here.
- **CI builds the package and consumes it** on linux-64 and osx-arm64, instead
  of upstream's test matrix; upstream's docs and fuzz workflows are dropped.

Deltas this fork used to carry and upstream has since absorbed: the build
backend pin (upstream now takes `pixi-build-rattler-build >=0.3.13`), the
`-include iterator` fix on the simdjson wrapper, and the MIT licence in
`recipe.yaml`.

Upstream's README is preserved verbatim as
[README.upstream.md](README.upstream.md).

## This repository should not outlive its usefulness

The moment json is published to a channel `pixi` can resolve, magmalake should
depend on that and this repository should be archived.

## License

MIT, © 2025 Ehsan M. Kermani. See [LICENSE](LICENSE), unchanged from upstream.
