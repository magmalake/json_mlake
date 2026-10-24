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

Tracks upstream **v0.4.2**. Packaging only; no source changes:

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
