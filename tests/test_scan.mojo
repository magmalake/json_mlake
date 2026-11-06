"""Tests for the span scan (`json.ondemand`).

Three kinds of check:

- Unit cases for each lookup, iterator and reader, including the
  malformed walks that must come back `INVALID` rather than raise.
- Agreement with `loads`: on every case of the RFC 8259 catalog,
  `validate()` accepts exactly what `loads` accepts, and on every
  accepted case the scan reads the same tree the DOM holds.
- The 64-byte container step, which is where a bug would hide: values
  are placed at every offset across two blocks, with brackets, quotes
  and backslash runs straddling the block edges, and the end the scan
  finds must be the end the validating reader finds.

Set `JSON_SCAN_CORPUS` to a JSON Lines file (a GH Archive hour, say) to
also compare every record of it against `loads`.
"""

from std.os import getenv
from std.pathlib import Path
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from json import RawKind, RawValue, Value, dumps, loads, scan, scan_lines
from json.reader import JsonReader


def _b(s: StringSlice) -> List[UInt8]:
    var out = List[UInt8]()
    for c in s.as_bytes():
        out.append(c)
    return out^


def _text(v: RawValue) -> String:
    return String(v)


# ===================================================================
# Lookups
# ===================================================================


def test_kinds() raises:
    var s = String(
        '{"o":{},"a":[],"s":"x","n":-1.5e3,"t":true,"f":false,"z":null}'
    )
    var root = scan(s.as_bytes())
    assert_true(root.kind == RawKind.OBJECT)
    assert_true(root["o"].kind == RawKind.OBJECT)
    assert_true(root["a"].kind == RawKind.ARRAY)
    assert_true(root["s"].kind == RawKind.STRING)
    assert_true(root["n"].kind == RawKind.NUMBER)
    assert_true(root["t"].kind == RawKind.TRUE)
    assert_true(root["f"].kind == RawKind.FALSE)
    assert_true(root["z"].kind == RawKind.NULL)
    assert_true(root["missing"].kind == RawKind.ABSENT)
    assert_equal(_text(root["n"]), "-1.5e3")
    assert_equal(root["n"].float(), -1500.0)
    assert_true(root["t"].bool())
    assert_false(root["f"].bool())
    assert_true(root["z"].is_null())


def test_raw_is_exact_bytes() raises:
    var s = String('{ "p" : { "a" : [ 1 , "}" ] , "b":"\\"]" } , "q":1 }')
    var root = scan(s.as_bytes())
    assert_equal(_text(root["p"]), '{ "a" : [ 1 , "}" ] , "b":"\\"]" }')
    assert_equal(_text(root["q"]), "1")
    # The range is into the caller's buffer.
    var p = root["p"]
    assert_equal(p.start, 8)
    assert_equal(p.end - p.start, len(p.raw()))


def test_nested_paths() raises:
    var s = String(
        '{"payload":{"pull_request":{"base":{"repo":{"language":"Mojo"}}},'
        + '"commits":[{"message":"a"},{"message":"b"}]}}'
    )
    var root = scan(s.as_bytes())
    var lang = root.path("payload.pull_request.base.repo.language")
    assert_equal(lang.string(), "Mojo")
    assert_equal(
        root["payload"]["pull_request"]["base"]["repo"]["language"].string(),
        "Mojo",
    )
    assert_equal(root.path("payload.commits.1.message").string(), "b")
    assert_true(root.path("payload.commits.2.message").kind == RawKind.ABSENT)
    assert_true(root.path("payload.nope.base").kind == RawKind.ABSENT)
    # A lookup on a scalar is absent, not an error.
    assert_true(lang["x"].kind == RawKind.ABSENT)
    assert_true(lang[0].kind == RawKind.ABSENT)


def test_first_key_wins_and_escaped_keys_match() raises:
    var s = String('{"a":1,"a":2,"\\u0062":3,"c\\"d":4}')
    var root = scan(s.as_bytes())
    assert_equal(root["a"].int(), 1)
    assert_equal(root["b"].int(), 3)
    assert_equal(root['c"d'].int(), 4)
    var f = root.fields(['c"d', "b", "a", "zz"])
    assert_equal(f[0].int(), 4)
    assert_equal(f[1].int(), 3)
    assert_equal(f[2].int(), 1)
    assert_true(f[3].kind == RawKind.ABSENT)


def test_fields_one_walk() raises:
    var s = String(
        '{"id":"7","type":"PushEvent","actor":{"login":"x"},'
        + '"repo":{"name":"r/r"},"payload":{"k":[1,2,{"z":"}"}]},'
        + '"created_at":"2026-01-01T00:00:00Z"}'
    )
    var root = scan(s.as_bytes())
    var f = root.fields(
        ["id", "type", "created_at", "repo", "actor", "payload"]
    )
    assert_equal(f[0].string(), "7")
    assert_equal(f[1].string(), "PushEvent")
    assert_equal(f[2].string(), "2026-01-01T00:00:00Z")
    assert_equal(f[3]["name"].string(), "r/r")
    assert_equal(f[4]["login"].string(), "x")
    assert_equal(_text(f[5]), '{"k":[1,2,{"z":"}"}]}')


def test_arrays() raises:
    var s = String('[ 1, "two", [3], {"four":4}, null ]')
    var root = scan(s.as_bytes())
    var got = List[String]()
    for v in root.elements():
        got.append(_text(v))
    assert_equal(len(got), 5)
    assert_equal(got[1], '"two"')
    assert_equal(got[3], '{"four":4}')
    assert_equal(root[3]["four"].int(), 4)
    assert_true(root[5].kind == RawKind.ABSENT)
    assert_true(root[-1].kind == RawKind.ABSENT)
    var empty = String("[ ]")
    var n = 0
    for _ in scan(empty.as_bytes()).elements():
        n += 1
    assert_equal(n, 0)


def test_members() raises:
    var s = String('{"a":1, "b" : [2] ,"c":{"d":"e"}}')
    var keys = List[String]()
    var vals = List[String]()
    for m in scan(s.as_bytes()).items():
        keys.append(m.key.string())
        vals.append(_text(m.value))
    assert_equal(len(keys), 3)
    assert_equal(keys[1], "b")
    assert_equal(vals[1], "[2]")
    assert_equal(vals[2], '{"d":"e"}')


# ===================================================================
# Strings and numbers
# ===================================================================


def test_string_decoding() raises:
    var s = String(
        '{"e":"a\\nb\\t\\"q\\"\\\\\\/","u":"\\u00e9\\ud83d\\udd25",'
        + '"lit":"é🔥","plain":"abc"}'
    )
    var root = scan(s.as_bytes())
    assert_equal(root["e"].string(), 'a\nb\t"q"\\/')
    assert_equal(root["u"].string(), "é🔥")
    assert_equal(root["lit"].string(), "é🔥")
    assert_true(root["e"].string_has_escapes())
    assert_false(root["plain"].string_has_escapes())
    assert_true(root["u"].string_equals("é🔥"))
    assert_true(root["plain"].string_equals("abc"))
    assert_false(root["plain"].string_equals("abd"))
    assert_equal(
        String(StringSlice(unsafe_from_utf8=root["e"].string_raw())),
        'a\\nb\\t\\"q\\"\\\\\\/',
    )


def test_string_rejections() raises:
    var bad_escape = String('{"s":"\\x"}')
    with assert_raises(contains="invalid escape"):
        _ = scan(bad_escape.as_bytes())["s"].string()
    var bad_hex = String('{"s":"\\u12g4"}')
    with assert_raises(contains="\\u"):
        _ = scan(bad_hex.as_bytes())["s"].string()
    var ctl = _b('{"s":"a')
    ctl.append(0x01)
    ctl.append(UInt8(ord('"')))
    ctl.append(UInt8(ord("}")))
    with assert_raises(contains="control character"):
        _ = scan(Span(ctl))["s"].string()
    var utf = _b('{"s":"')
    utf.append(0xC3)
    utf.append(0x28)
    utf.append(UInt8(ord('"')))
    utf.append(UInt8(ord("}")))
    with assert_raises(contains="UTF-8"):
        _ = scan(Span(utf))["s"].string()
    var num = String('{"s":"x"}')
    with assert_raises(contains="expected a number"):
        _ = scan(num.as_bytes())["s"].int()


def test_error_context_is_utf8() raises:
    """An error quoting ill-formed bytes shows them escaped."""
    var b = _b('{"s":"')
    b.append(0xC3)
    b.append(0x28)
    for c in String('"}').as_bytes():
        b.append(c)
    with assert_raises(contains="\\xC3("):
        scan(Span(b)).validate()


def test_numbers() raises:
    var s = String(
        "[0,-0,12345678901234,18446744073709551615,1.5,-2e-3,01,1.,9223372036854775808]"
    )
    var root = scan(s.as_bytes())
    assert_equal(root[0].int(), 0)
    assert_equal(root[2].int(), 12345678901234)
    assert_equal(root[3].uint(), UInt64.MAX)
    with assert_raises():
        _ = root[3].int()
    assert_equal(root[4].float(), 1.5)
    assert_equal(root[5].float(), -0.002)
    with assert_raises():
        _ = root[6].int()  # leading zero
    with assert_raises():
        _ = root[7].float()  # no digit after the point
    with assert_raises():
        _ = root[4].int()  # a fraction is not an integer
    assert_equal(root[8].uint(), UInt64(9223372036854775808))


# ===================================================================
# Malformed walks come back INVALID
# ===================================================================


def _walk_kind(text: String, key: String) -> RawKind:
    return scan(text.as_bytes())[key].kind


def test_invalid_walks() raises:
    assert_true(_walk_kind('{"a":1', "b") == RawKind.INVALID)
    assert_true(_walk_kind('{"a" 1}', "a") == RawKind.INVALID)
    assert_true(_walk_kind("{a:1}", "a") == RawKind.INVALID)
    assert_true(_walk_kind('{"a":1,}', "b") == RawKind.INVALID)
    assert_true(_walk_kind('{"a":1 "b":2}', "b") == RawKind.INVALID)
    assert_true(_walk_kind('{"a":[1,2}', "b") == RawKind.INVALID)
    assert_true(_walk_kind('{"a":"unterminated}', "b") == RawKind.INVALID)
    assert_true(_walk_kind('{"a":nul}', "a") == RawKind.INVALID)
    assert_true(_walk_kind('{"a":@}', "a") == RawKind.INVALID)
    # The error position is the offending byte.
    var s = String('{"a":1 "b":2}')
    assert_equal(scan(s.as_bytes())["b"].start, 7)
    # Chained lookups carry the INVALID through.
    var t = String('{"a":{"b":}}')
    assert_true(scan(t.as_bytes())["a"]["b"]["c"].kind == RawKind.INVALID)
    # Iterators end with one INVALID item.
    var u = String("[1, 2 3]")
    var kinds = List[RawKind]()
    for v in scan(u.as_bytes()).elements():
        kinds.append(v.kind)
    assert_equal(len(kinds), 3)
    assert_true(kinds[2] == RawKind.INVALID)
    var w = String('{"a":1,"b"}')
    var n = 0
    var last = RawKind.ABSENT
    for m in scan(w.as_bytes()).items():
        n += 1
        last = m.value.kind
    assert_equal(n, 2)
    assert_true(last == RawKind.INVALID)
    var e = String("   ")
    assert_true(scan(e.as_bytes()).kind == RawKind.INVALID)


def test_skipped_values_are_only_balanced() raises:
    """What the lazy walk does not check, and `validate` does."""
    var s = String('{"a":{"x":[1,2}],"b":2}')  # `{]` inside a skipped value
    var root = scan(s.as_bytes())
    assert_equal(root["b"].int(), 2)
    with assert_raises():
        root.validate()
    var t = String('{"a":[01, tru],"b":2}')
    assert_equal(scan(t.as_bytes())["b"].int(), 2)
    with assert_raises():
        scan(t.as_bytes()).validate()


# ===================================================================
# JSON Lines
# ===================================================================


def test_lines() raises:
    var s = String('{"a":1}\r\n\n  \n[2]\n  "three"  \n{"a":4}')
    var got = List[String]()
    var it = scan_lines(s.as_bytes())
    while it.__has_next__():
        var v = it.__next__()
        got.append(_text(v))
        if len(got) == 1:
            assert_equal(it.line_start, 0)
            assert_equal(it.line_end, 8)
    assert_equal(len(got), 4)
    assert_equal(got[0], '{"a":1}')
    assert_equal(got[1], "[2]")
    assert_equal(got[2], '"three"')
    assert_equal(got[3], '{"a":4}')
    var n = 0
    for line in scan_lines(s.as_bytes()):
        n += 1
        line.validate()
    assert_equal(n, 4)


def test_line_trailing_bytes_need_validate() raises:
    var s = String('{"a":1} junk\n')
    for line in scan_lines(s.as_bytes()):
        assert_equal(line["a"].int(), 1)
        with assert_raises(contains="trailing"):
            line.validate()


def test_scan_skips_bom() raises:
    var b = List[UInt8]()
    b.append(0xEF)
    b.append(0xBB)
    b.append(0xBF)
    for c in String('{"a":1}').as_bytes():
        b.append(c)
    var root = scan(Span(b))
    assert_equal(root["a"].int(), 1)
    root.validate()


# ===================================================================
# Deep, huge, and block edges
# ===================================================================


def test_deep_nesting() raises:
    var s = String('{"deep":')
    for _ in range(5000):
        s += "["
    s += '"x]}"'
    for _ in range(5000):
        s += "]"
    s += ',"after":true}'
    var root = scan(s.as_bytes())
    assert_true(root["after"].bool())
    assert_equal(root["deep"].end - root["deep"].start, 10005)
    with assert_raises(contains="depth"):
        root.validate()
    root.validate(max_depth=6000)


def test_huge_string() raises:
    var b = _b('{"big":"')
    for i in range(1 << 20):
        if i % 997 == 0:
            b.append(UInt8(ord("\\")))
            b.append(UInt8(ord('"')))
        elif i % 991 == 0:
            b.append(UInt8(ord("\\")))
            b.append(UInt8(ord("\\")))
        else:
            b.append(UInt8(ord("a")))
    for c in String('","after":[1]}').as_bytes():
        b.append(c)
    var root = scan(Span(b))
    assert_equal(_text(root["after"]), "[1]")
    var big = root["big"].string()
    assert_true(big.byte_length() > 1_000_000)
    root.validate()


def _reader_end(data: Span[UInt8, _], start: Int) raises -> Int:
    var r = JsonReader(data[start:])
    var range = r.skip_value()
    return start + range[1]


def test_block_edges() raises:
    """Every value at every offset across two 64-byte blocks."""
    var docs: List[String] = [
        '{"a":"}"}',
        '[["]"],{"k":"\\\\"},"\\\\\\""]',
        '{"q":"\\"{\\"","r":[{},[],{"s":"\\\\\\\\"}]}',
        '["' + String("x") * 70 + '\\"}' + String("y") * 60 + '"]',
        '{"b":"\\\\' + String("\\\\") * 40 + '","c":{"d":[1,{}]}}',
        "[" + String("[") * 70 + String("]") * 70 + "]",
    ]
    var checked = 0
    for d in range(len(docs)):
        for pad in range(0, 140):
            var s = String('{"pad":"') + String(" ") * pad + '","v":'
            var at = s.byte_length()
            s += docs[d]
            s += ',"after":1}'
            var bytes = s.as_bytes()
            var v = scan(bytes)["v"]
            assert_equal(v.start, at)
            assert_equal(v.end, _reader_end(bytes, at))
            assert_equal(scan(bytes)["after"].int(), 1)
            # The same value as the last bytes of a buffer, so the final
            # block is read from the padded copy.
            var tail = String('{"v":') + String(" ") * pad + docs[d]
            var tb = tail.as_bytes()
            var tv = scan(tb)["v"]
            assert_equal(tv.end, _reader_end(tb, tv.start))
            checked += 1
    assert_equal(checked, len(docs) * 140)


# ===================================================================
# Agreement with loads
# ===================================================================


def _same(raw: RawValue, dom: Value, depth: Int = 0) raises -> Bool:
    """Whether the scan reads the tree `dom` holds."""
    if not raw.found():
        return False
    if dom.is_object():
        if raw.kind != RawKind.OBJECT:
            return False
        var items = dom.object_items()
        var k = 0
        for m in raw.items():
            if not m.value.found() or k >= len(items):
                return False
            if m.key.string() != items[k][0]:
                return False
            if not _same(m.value, items[k][1], depth + 1):
                return False
            k += 1
        return k == len(items)
    if dom.is_array():
        if raw.kind != RawKind.ARRAY:
            return False
        var items = dom.array_items()
        var k = 0
        for v in raw.elements():
            if k >= len(items) or not _same(v, items[k], depth + 1):
                return False
            k += 1
        return k == len(items)
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


def _hex(c: UInt8) -> Int:
    var v = Int(c)
    if v >= ord("0") and v <= ord("9"):
        return v - ord("0")
    if v >= ord("a") and v <= ord("f"):
        return v - ord("a") + 10
    return v - ord("A") + 10


def _case_bytes(item: Value) raises -> List[UInt8]:
    var text = item["input"].string_value()
    var enc = "utf-8"
    var got = item.get("input_encoding")
    if got:
        enc = got.value().string_value()
    var src = text.as_bytes()
    var out = List[UInt8]()
    if enc != "hex":
        for c in src:
            out.append(c)
        return out^
    var i = 0
    while i + 1 < len(src):
        out.append(UInt8(_hex(src[i]) * 16 + _hex(src[i + 1])))
        i += 2
    return out^


def test_conformance_catalog_agrees_with_loads() raises:
    var catalog = loads(Path("tests/conformance/rfc8259.json").read_text())
    var cases = catalog["cases"].array_items()
    var compared = 0
    var accepted = 0
    var disagree = List[String]()
    for i in range(len(cases)):
        var bytes = _case_bytes(cases[i])
        var data = Span(bytes)
        var dom_ok = True
        var dom = Value(None)
        try:
            dom = loads(data)
        except:
            dom_ok = False
        var scan_ok = True
        try:
            scan(data).validate()
        except:
            scan_ok = False
        compared += 1
        if dom_ok != scan_ok:
            disagree.append(
                cases[i]["id"].string_value()
                + (" (loads accepts)" if dom_ok else " (validate accepts)")
            )
            continue
        if dom_ok:
            accepted += 1
            if not _same(scan(data), dom):
                disagree.append(cases[i]["id"].string_value() + " (tree)")
    for d in disagree:
        print("    disagrees:", d)
    print("   ", compared, "catalog cases,", accepted, "accepted by both")
    assert_equal(len(disagree), 0)


def _gh_like() -> List[String]:
    return [
        '{"id":"1","type":"PushEvent","actor":{"id":5,"login":"a-b"},'
        + '"repo":{"id":9,"name":"o/r"},"payload":{"commits":[{"sha":"ab",'
        + '"message":"fix \\"x\\" in a.mojo\\n\\nmore","distinct":true}],'
        + '"size":1},"public":true,"created_at":"2026-01-01T00:00:00Z"}',
        '{"id":"2","type":"ForkEvent","actor":{"login":"x"},"repo":{},'
        + '"payload":{"forkee":{"language":null,"topics":[],"full_name":"🔥/é"}},'
        + '"created_at":"2026-01-01T00:00:01Z","org":{"login":"o"}}',
        '{"type":"PullRequestEvent","payload":{"pull_request":{"base":{"repo":'
        + '{"language":"Mojo","description":"a \\u00e9 \\ud83d\\udd25 [x]'
        ' {y}"}}'
        + ',"body":"'
        + String("line\\r\\n") * 50
        + '"}},"id":"3"}',
    ]


def _check_record(line: RawValue) raises -> Bool:
    var dom = loads(line.raw())
    line.validate()
    if not _same(line, dom):
        return False
    # The payload's bytes parse to the DOM's payload.
    var payload = line["payload"]
    var dp = dom.get("payload")
    if payload.found() != Bool(dp):
        return False
    if payload.found():
        if dumps(loads(payload.raw())) != dumps(dp.value()):
            return False
    return True


def test_gh_like_records() raises:
    var text = String()
    for l in _gh_like():
        text += l + "\n"
    var n = 0
    for line in scan_lines(text.as_bytes()):
        assert_true(_check_record(line), "record " + String(n))
        n += 1
    assert_equal(n, 3)


def test_corpus_file() raises:
    """Every record of `$JSON_SCAN_CORPUS`, if set."""
    var path = getenv("JSON_SCAN_CORPUS")
    if path == "":
        print("    (JSON_SCAN_CORPUS not set, skipped)")
        return
    var bytes = Path(path).read_bytes()
    var n = 0
    var bad = 0
    for line in scan_lines(Span(bytes)):
        if not _check_record(line):
            bad += 1
            if bad <= 3:
                print("    mismatch in record", n, "at byte", line.start)
        n += 1
    print("   ", n, "records of", path, "--", bad, "mismatches")
    assert_equal(bad, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
