#!/usr/bin/env python3
"""Fail when recipe.yaml disagrees with pixi.toml or shelf.toml.

The package rattler-build makes takes its version from recipe.yaml, while
`shelf release` bumps only shelf.toml and pixi.toml. A release that forgets
the recipe ships a package recording the old version, so installs and pixi
locks name the wrong release. The recipe's extra git sources (the siblings it
precompiles against) have to be the revisions pixi.toml pins, for the same
reason: otherwise the package is built against a different tree than the one
installed beside it.

Stdlib only: tomllib for the TOML files, a small reader for the few recipe
keys checked, so the job needs no environment.
"""

import re
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
errors = []

shelf = tomllib.loads((root / "shelf.toml").read_text())
pixi = tomllib.loads((root / "pixi.toml").read_text())
recipe = (root / "recipe.yaml").read_text().splitlines()


def block(name):
    """The lines of a top-level YAML mapping, e.g. `context:`."""
    out, inside = [], False
    for line in recipe:
        if re.match(rf"^{name}:\s*(#.*)?$", line):
            inside = True
            continue
        if inside:
            if line and not line[0].isspace() and not line.startswith("#"):
                break
            out.append(line)
    return out


def scalar(lines, key):
    for line in lines:
        m = re.match(rf"^\s+{key}:\s*(.+?)\s*(#.*)?$", line)
        if m:
            return m.group(1).strip("\"'")
    return None


context = block("context")
version = scalar(block("package"), "version")
if version is not None and "${{" in version:
    version = scalar(context, "version")

versions = {
    "recipe.yaml": version,
    "shelf.toml": shelf.get("version"),
    "pixi.toml [package]": pixi.get("package", {}).get("version"),
    "pixi.toml [workspace]": pixi.get("workspace", {}).get("version"),
}
if len({v for v in versions.values() if v is not None}) != 1 or None in (
    versions["recipe.yaml"],
    versions["shelf.toml"],
):
    errors.append(
        "versions disagree: " + ", ".join(f"{k} {v}" for k, v in versions.items())
    )

# git sources in the recipe: `- git: URL` followed by `rev: SHA`.
recipe_revs = {}
url = None
for line in block("source"):
    m = re.match(r"^\s*-?\s*git:\s*(\S+)", line)
    if m:
        url = m.group(1)
        continue
    m = re.match(r"^\s*rev:\s*(\S+)", line)
    if m and url:
        recipe_revs[url] = m.group(1).strip("\"'")
        url = None


def norm(u):
    return u.rstrip("/").removesuffix(".git").lower()


def pixi_pins(node, path=""):
    if isinstance(node, dict):
        if "git" in node and isinstance(node["git"], str):
            yield path, node["git"], node.get("rev")
            return
        for k, v in node.items():
            yield from pixi_pins(v, f"{path}.{k}" if path else k)


pins = list(pixi_pins(pixi))
for url, rev in recipe_revs.items():
    matching = [(p, r) for p, u, r in pins if norm(u) == norm(url)]
    if not matching:
        errors.append(f"recipe.yaml builds against {url}, which pixi.toml doesn't pin")
    for path, r in matching:
        if r != rev:
            errors.append(f"recipe.yaml pins {url} at {rev}, pixi.toml {path} at {r}")

for e in errors:
    print(f"::error::{e}")
if errors:
    sys.exit(1)
print(f"recipe.yaml, shelf.toml and pixi.toml agree on {version}", end="")
print(f"; {len(recipe_revs)} recipe git source(s) match pixi.toml" if recipe_revs else "")
