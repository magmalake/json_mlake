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

Tracks upstream **v0.3.0**. Three packaging changes, no source changes:

- **The build backend pin.** Upstream pins
  `pixi-build-rattler-build ==0.3.13`, which requires a
  `pixi-build-api-version` that is no longer published, so no current pixi can
  solve it — upstream copes by pinning CI to pixi 0.70.2. The magmalake repos
  are all on pixi 0.78.0, so this tracks `0.4.*`.
- **`-include iterator` on the simdjson wrapper.** `simdjson.h` uses
  `std::inserter` without including `<iterator>`; current libc++ no longer
  supplies it transitively, so the build fails on macOS with
  `no member named 'inserter' in namespace 'std'`.
- **`mojodoc` dropped** from the dev feature — same dead backend pin, and it is
  a docs generator nothing in the test suite needs. The `docs` task is
  therefore unavailable here.

**One metadata correction:** upstream's `recipe.yaml` declares
`license: Apache-2.0`, but `LICENSE`, the README badge and the README's License
section all say MIT. This distribution declares MIT, matching the licence
actually shipped.

The package is named `json_mlake`; the module is still imported as `json`, so
no consumer source changes and switching to an official package later is a
one-line dependency change.

Upstream's README is preserved verbatim as
[README.upstream.md](README.upstream.md).

## This repository should not outlive its usefulness

The moment json is published to a channel `pixi` can resolve, magmalake should
depend on that and this repository should be archived.

## License

MIT, © 2025 Ehsan M. Kermani. See [LICENSE](LICENSE), unchanged from upstream.
