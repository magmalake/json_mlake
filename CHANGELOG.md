# Changelog

Changes this distribution makes on top of
[ehsanmok/json](https://github.com/ehsanmok/json).

## Unreleased

- The package installs a precompiled `json.mojoc` instead of the source tree;
  `json.gpu` is not in it (build from source for GPU). (#9)
- A span scan, `json.ondemand` (exported from `json`): `scan(span)` and
  `scan_lines(span)` turn borrowed bytes into `RawValue`s, each a
  value's `[start, end)` in the buffer and its `RawKind`, without
  building a `Document` or copying anything. `field` / `[]`, `path`
  (`"payload.commits.0.message"`), `fields([...])` (several keys in one
  walk), `items()`, `elements()`, `at()`; `raw()` gives the bytes as
  written, `string()` / `int()` / `uint()` / `float()` / `bool()` read
  them with the parser's rules, `string_equals` compares without
  allocating, and `validate()` checks a value in full. Skipped values
  are stepped over 64 bytes at a time. On a GH Archive hour, picking an
  event's six fields runs at 3.3 GB/s (October 2026, 89 MB) and
  5.2 GB/s (January 2025, 1.0 GB), against 0.35–0.52 GB/s for `loads`
  of each line. Malformed walks return `RawKind.INVALID` instead of
  raising. (#5)
- Parse-error messages no longer build an ill-formed `String` when the
  context window cuts a character or the input isn't UTF-8; non-ASCII
  bytes in such a window are shown as `\xHH`.

## 0.4.3 - 2026-11-03

- The simdjson wrapper is found without `CONDA_PREFIX`: after
  `$CONDA_PREFIX/lib`, json looks next to the executable, in its `../lib`,
  and on the binary's rpath (the environment `mojo build` ran in), so a
  binary built with `pixi run mojo build` runs from a plain shell. The
  search is `json/cpu/_dlopen.mojo`, shared with the other magmalake tins
  that load a library. A wrapper that can't be found is an Error naming
  every place searched and saying to set `CONDA_PREFIX`.
- The fallback to `build/libsimdjson_wrapper.so` relative to the working
  directory is gone: loading a library from the working directory isn't
  safe. The activation script installs the wrapper into
  `$CONDA_PREFIX/lib`, so a checkout's own tests still find it.
- CI's consume smoke loads the wrapper and parses a document, and runs the
  binary again with `CONDA_PREFIX` unset.
