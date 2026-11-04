# Changelog

Changes this distribution makes on top of
[ehsanmok/json](https://github.com/ehsanmok/json).

## Unreleased

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
