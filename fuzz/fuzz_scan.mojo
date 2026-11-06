"""Fuzz harness: the span scan (``json.ondemand``) against ``loads``.

Arbitrary bytes go through three checks, and any disagreement is raised
as an "assertion failed" error, which mozz counts as a crash:

1. **Every walk stays in bounds.** The whole value is walked through
   ``items()`` / ``elements()`` and read with ``string()``, ``int()``,
   ``float()``; each value's range must lie inside the input. Readers
   may raise (that is a rejection); walks never do.
2. **``validate()`` agrees with ``loads``.** Both accept, or both
   reject. Inputs nested deeper than ``validate``'s depth limit are
   skipped, since ``loads`` has none.
3. **On accepted input the scan reads the DOM's tree**, member for
   member, and each container's raw bytes re-parse to the same value.

The same bytes are then split as JSON Lines and each record walked.

Run:
    pixi run -e fuzz fuzz-scan
"""

from mozz import fuzz, FuzzConfig

from json import RawKind, RawValue, Value, dumps, loads, scan, scan_lines


def _bounds(v: RawValue, n: Int) raises:
    if v.kind == RawKind.ABSENT:
        return
    if v.start < 0 or v.end < v.start or v.end > n:
        raise Error(
            "assertion failed: range out of bounds: "
            + String(v.start)
            + ".."
            + String(v.end)
        )


def _walk(v: RawValue, n: Int, depth: Int) raises:
    """Touch every value; raise only on a broken invariant."""
    _bounds(v, n)
    if depth > 200:
        return
    if v.kind == RawKind.OBJECT:
        for m in v.items():
            _bounds(m.key, n)
            _walk(m.value, n, depth + 1)
        _ = v["k"]
        _ = v.fields(["a", "b"])
    elif v.kind == RawKind.ARRAY:
        for e in v.elements():
            _walk(e, n, depth + 1)
        _ = v[1]
    try:
        if v.kind == RawKind.STRING:
            _ = v.string()
            _ = v.string_equals("x")
        elif v.kind == RawKind.NUMBER:
            _ = v.float()
        elif v.is_bool():
            _ = v.bool()
    except:
        pass


def _same(raw: RawValue, dom: Value) raises -> Bool:
    if not raw.found():
        return False
    if dom.is_object():
        var items = dom.object_items()
        var k = 0
        for m in raw.items():
            if not m.value.found() or k >= len(items):
                return False
            if m.key.string() != items[k][0] or not _same(m.value, items[k][1]):
                return False
            k += 1
        return raw.kind == RawKind.OBJECT and k == len(items)
    if dom.is_array():
        var items = dom.array_items()
        var k = 0
        for e in raw.elements():
            if k >= len(items) or not _same(e, items[k]):
                return False
            k += 1
        return raw.kind == RawKind.ARRAY and k == len(items)
    if dom.is_string():
        return raw.kind == RawKind.STRING and raw.string() == dom.string_value()
    if dom.is_int():
        return raw.kind == RawKind.NUMBER and raw.int() == dom.int_value()
    if dom.is_uint():
        return raw.kind == RawKind.NUMBER and raw.uint() == dom.uint_value()
    if dom.is_float():
        return raw.kind == RawKind.NUMBER and raw.float() == dom.float_value()
    if dom.is_bool():
        return raw.is_bool() and raw.bool() == dom.bool_value()
    return raw.kind == RawKind.NULL


def target(data: List[UInt8]) raises:
    var span = Span(data)
    var n = len(data)
    var root = scan(span)
    _walk(root, n, 0)
    for line in scan_lines(span):
        _walk(line, n, 0)

    var dom_ok = True
    var dom = Value(None)
    try:
        dom = loads(span)
    except:
        dom_ok = False
    var scan_ok = True
    var too_deep = False
    try:
        root.validate()
    except e:
        scan_ok = False
        too_deep = String(e).find("depth") >= 0
    if too_deep:
        return
    if dom_ok != scan_ok:
        raise Error(
            "assertion failed: validate "
            + ("rejects" if dom_ok else "accepts")
            + " what loads "
            + ("accepts" if dom_ok else "rejects")
        )
    if dom_ok:
        if not _same(root, dom):
            raise Error("assertion failed: scan and DOM trees differ")
        if root.kind == RawKind.OBJECT or root.kind == RawKind.ARRAY:
            if dumps(loads(root.raw())) != dumps(dom):
                raise Error("assertion failed: raw bytes re-parse differently")
    else:
        # A rejection is what the harness expects for most inputs.
        raise Error("rejected")


def _bytes(s: StringSlice) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        out.append(b[i])
    return out^


def main() raises:
    print("[mozz] fuzzing json.ondemand against loads()...")
    var seeds = List[List[UInt8]]()
    seeds.append(
        _bytes('{"id":"1","type":"PushEvent","payload":{"a":[1,"}"]}}')
    )
    seeds.append(_bytes('{"k":"\\"\\\\","v":[{"x":"]"},[[]],{}],"n":-1.5e3}'))
    seeds.append(_bytes('[true,false,null,"\\u00e9\\ud83d\\udd25",0,-0]'))
    seeds.append(_bytes('{"a":{"b":{"c":{"d":[1,2,3]}}}}\n{"a":1}\n'))
    seeds.append(
        _bytes(String('"') + String("x") * 80 + '\\"' + String("y") * 60 + '"')
    )
    seeds.append(_bytes(String("[") * 70 + String("]") * 70))
    seeds.append(_bytes('{"a":1,}'))
    seeds.append(_bytes('{"a" 1}'))
    seeds.append(_bytes("[01, 1., tru]"))
    seeds.append(_bytes('{"a":"unterminated'))

    fuzz(
        target,
        FuzzConfig(
            max_runs=200_000,
            seed=0,
            verbose=True,
            crash_dir=".mozz_crashes/scan",
            corpus_dir="",
            max_input_len=2048,
        ),
        seeds,
    )
