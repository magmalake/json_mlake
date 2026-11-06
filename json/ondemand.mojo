# Span in, value ranges out: on-demand scanning over borrowed bytes.
#
# `loads` builds a `Document`: every value in the input gets a tape
# slot, every string a copy. A caller that wants six fields out of a
# GH Archive event, and one of them -- the payload -- exactly as it was
# written, pays for the whole tree and then cannot get the bytes back.
# simdjson answers this with its On-Demand front end: navigate to a
# value, and `raw_json()` hands back the bytes it spans.
#
# This is that front end for a `Span[UInt8]`. A `RawValue` is the byte
# range `[start, end)` of one value in the caller's buffer plus its
# kind, and nothing else: no allocation, no copy, no tape. Looking up a
# key walks the object's members in order, and steps over every value
# it does not want without looking inside it.
#
# Stepping over a nested value
# ----------------------------
# That step is where the time goes, because a value nobody asked for
# can be most of the input. It runs sixty-four bytes at a time, with
# the same bit tricks stage 1 uses (`cpu/stage1.mojo`): four byte
# compares give the quote, backslash, opening and closing bracket masks;
# `find_escape_mask64` and `prefix_xor64` turn the quotes into an
# "inside a string" mask; what is left of the brackets is structural.
# A block whose closing brackets cannot bring the depth to zero only
# adds two popcounts to it, so the bytes of a long payload are not
# visited one by one, and neither are the strings inside it.
#
# What is checked, and when
# -------------------------
# Like simdjson On-Demand, the scan validates what it walks and no more:
#
# - Walking an object or array checks its punctuation: keys are
#   strings, a colon follows each key, members are separated by commas,
#   and the container is closed. A malformed walk yields
#   `RawKind.INVALID` at the offending byte rather than raising.
# - A value that is stepped over is only checked to be closed: its
#   strings terminated and its brackets balanced in number (`{]` is
#   not caught). Nothing inside it is validated.
# - Reading a value checks it as `loads` would: `string()` rejects
#   control characters, bad escapes and ill-formed UTF-8, `int()`
#   and `float()` apply the number grammar, `bool()` the literals.
# - `validate()` checks a value completely, with the typed reader's
#   rules (`reader.mojo`), which are the parser's.
#
# A JSON Lines record's end is its line's end. Bytes after the record's
# closing bracket on the same line are only noticed by `validate()`.

from std.bit import count_trailing_zeros, pop_count
from std.memory.unsafe import pack_bits
from std.sys import simd_byte_width

from .cpu.number_parse import parse_float_span, parse_int_checked
from .cpu.simd_clmul import find_escape_mask64, prefix_xor64
from .cpu.validate import (
    ESC_BAD_CHAR,
    ESC_OK,
    ESC_TRAILING_BACKSLASH,
    STR_CONTROL,
    STR_ESCAPE,
    STR_NON_ASCII,
    find_control_char,
    first_invalid_utf8,
    is_valid_utf8,
    scan_string_body,
    skip_ws,
    validate_escapes,
)
from .errors import parse_error
from .reader import DEFAULT_MAX_DEPTH, JsonReader
from .unicode import unescape_json_string_span

comptime _QUOTE = UInt8(ord('"'))
comptime _BSLASH = UInt8(ord("\\"))
comptime _LBRACE = UInt8(ord("{"))
comptime _RBRACE = UInt8(ord("}"))
comptime _LBRACK = UInt8(ord("["))
comptime _RBRACK = UInt8(ord("]"))
comptime _COLON = UInt8(ord(":"))
comptime _COMMA = UInt8(ord(","))
comptime _NEWLINE = UInt8(ord("\n"))

comptime _BLOCK: Int = simd_byte_width()
"""One native SIMD register, for short runs: strings and newlines."""
comptime _MASK = _mask_dtype()
"""One bit per byte of a `_BLOCK`."""
comptime _WIDE: Int = 64
"""Bytes per step when stepping over a container: one `UInt64` of bits."""


def _mask_dtype() -> DType:
    comptime assert (
        _BLOCK == 16 or _BLOCK == 32 or _BLOCK == 64
    ), "unsupported simd_byte_width()"
    comptime if _BLOCK == 16:
        return DType.uint16
    elif _BLOCK == 32:
        return DType.uint32
    else:
        return DType.uint64


# ---------------------------------------------------------------------------
# Kinds
# ---------------------------------------------------------------------------


@fieldwise_init
struct RawKind(Equatable, TrivialRegisterPassable, Writable):
    """What a `RawValue` is, read from its first byte.

    `ABSENT` is a key that is not there, an index past the end, or a
    lookup on something that is not a container. `INVALID` is a
    malformed walk; its value's `start` is the offending byte.
    """

    var _v: UInt8

    comptime ABSENT = RawKind(0)
    comptime OBJECT = RawKind(1)
    comptime ARRAY = RawKind(2)
    comptime STRING = RawKind(3)
    comptime NUMBER = RawKind(4)
    comptime TRUE = RawKind(5)
    comptime FALSE = RawKind(6)
    comptime NULL = RawKind(7)
    comptime INVALID = RawKind(8)

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self._v == other._v

    def write_to(self, mut writer: Some[Writer]):
        var name: StaticString = "?"
        if self._v == 0:
            name = "absent"
        elif self._v == 1:
            name = "object"
        elif self._v == 2:
            name = "array"
        elif self._v == 3:
            name = "string"
        elif self._v == 4:
            name = "number"
        elif self._v == 5:
            name = "true"
        elif self._v == 6:
            name = "false"
        elif self._v == 7:
            name = "null"
        elif self._v == 8:
            name = "invalid"
        writer.write(name)


@always_inline
def _kind_of(c: UInt8) -> RawKind:
    """The kind a value starting with `c` has, or `INVALID`."""
    if c == _LBRACE:
        return RawKind.OBJECT
    if c == _LBRACK:
        return RawKind.ARRAY
    if c == _QUOTE:
        return RawKind.STRING
    if (c >= UInt8(ord("0")) and c <= UInt8(ord("9"))) or c == UInt8(ord("-")):
        return RawKind.NUMBER
    if c == UInt8(ord("t")):
        return RawKind.TRUE
    if c == UInt8(ord("f")):
        return RawKind.FALSE
    if c == UInt8(ord("n")):
        return RawKind.NULL
    return RawKind.INVALID


# ---------------------------------------------------------------------------
# Byte-level stepping. Each returns one past what it stepped over, or -1.
# ---------------------------------------------------------------------------


@always_inline
def _string_close(
    data: Span[UInt8, _], var i: Int, end: Int, mut escaped: Bool
) -> Int:
    """The offset of the quote closing the string whose body starts at `i`,
    or -1. `escaped` is set if the body holds a backslash."""
    var p = data.unsafe_ptr()
    while i + _BLOCK <= end:
        var chunk = p.unsafe_load[width=_BLOCK](i)
        var hit = pack_bits[dtype=_MASK](chunk.eq(_QUOTE) | chunk.eq(_BSLASH))
        if hit == 0:
            i += _BLOCK
            continue
        i += Int(count_trailing_zeros(hit))
        if p[unsafe_offset=i] == _QUOTE:
            return i
        escaped = True
        i += 2
    while i < end:
        var c = p[unsafe_offset=i]
        if c == _QUOTE:
            return i
        if c == _BSLASH:
            escaped = True
            i += 2
            continue
        i += 1
    return -1


@always_inline
def _wide_masks(
    v: SIMD[DType.uint8, _WIDE], valid: UInt64
) -> SIMD[DType.uint64, 4]:
    """Quote, backslash, opening and closing bracket bits of 64 bytes."""
    comptime V = SIMD[DType.uint8, _WIDE]
    # `{` 0x7B and `[` 0x5B, `}` 0x7D and `]` 0x5D differ only in bit 5.
    var folded = v | V(0x20)
    return (
        SIMD[DType.uint64, 4](
            pack_bits[dtype=DType.uint64](v.eq(_QUOTE)),
            pack_bits[dtype=DType.uint64](v.eq(_BSLASH)),
            pack_bits[dtype=DType.uint64](folded.eq(_LBRACE)),
            pack_bits[dtype=DType.uint64](folded.eq(_RBRACE)),
        )
        & valid
    )


def _container_end(data: Span[UInt8, _], start: Int, end: Int) -> Int:
    """One past the bracket closing the container opened at `start`, or -1.

    Bytes up to `len(data)` may be loaded, but only those before `end`
    count. Inside strings nothing counts, so a bracket in a string is
    text; brackets are counted, not matched, so `{]` closes.
    """
    var p = data.unsafe_ptr()
    var n = len(data)
    var depth = 0
    var in_string: UInt64 = 0
    var escape: UInt64 = 0
    var i = start
    var pad = Array[UInt8, _WIDE](fill=0)
    while i < end:
        var valid = ~UInt64(0)
        var m: SIMD[DType.uint64, 4]
        if i + _WIDE <= n:
            if end - i < _WIDE:
                valid = (UInt64(1) << UInt64(end - i)) - 1
            m = _wide_masks(p.unsafe_load[width=_WIDE](i), valid)
        else:
            # The last few bytes of the buffer: load them from a copy.
            for k in range(end - i):
                pad[k] = p[unsafe_offset=i + k]
            for k in range(end - i, _WIDE):
                pad[k] = 0
            m = _wide_masks(
                pad.unsafe_ptr().unsafe_load[width=_WIDE](0), ~UInt64(0)
            )
        var quotes = m[0]
        if m[1] != 0 or escape != 0:
            quotes &= ~find_escape_mask64(m[1], escape)
        var inside = prefix_xor64(quotes) ^ in_string
        in_string = UInt64(0) - (inside >> 63)
        var opens = m[2] & ~inside
        var closes = m[3] & ~inside
        var n_closes = Int(pop_count(closes))
        if depth > n_closes:
            # The depth cannot reach zero in this block.
            depth += Int(pop_count(opens)) - n_closes
            i += _WIDE
            continue
        var both = opens | closes
        while both != 0:
            var bit = count_trailing_zeros(both)
            var one = UInt64(1) << bit
            if opens & one != 0:
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    return i + Int(bit) + 1
            both &= both - 1
        i += _WIDE
    return -1


@always_inline
def _is_number_byte(c: UInt8) -> Bool:
    return (
        (c >= UInt8(ord("0")) and c <= UInt8(ord("9")))
        or c == UInt8(ord("."))
        or c == UInt8(ord("-"))
        or c == UInt8(ord("+"))
        or c == UInt8(ord("e"))
        or c == UInt8(ord("E"))
    )


@always_inline
def _literal_end(
    data: Span[UInt8, _], i: Int, end: Int, word: StaticString
) -> Int:
    var p = data.unsafe_ptr()
    var w = word.as_bytes()
    if i + len(w) > end:
        return -1
    for k in range(len(w)):
        if p[unsafe_offset=i + k] != w[k]:
            return -1
    return i + len(w)


@always_inline
def _value_end(data: Span[UInt8, _], i: Int, end: Int, kind: RawKind) -> Int:
    """One past the value of `kind` starting at `i`, or -1."""
    var p = data.unsafe_ptr()
    if kind == RawKind.STRING:
        var escaped = False
        var close = _string_close(data, i + 1, end, escaped)
        return close + 1 if close >= 0 else -1
    if kind == RawKind.OBJECT or kind == RawKind.ARRAY:
        return _container_end(data, i, end)
    if kind == RawKind.NUMBER:
        var j = i + 1
        while j < end and _is_number_byte(p[unsafe_offset=j]):
            j += 1
        return j
    if kind == RawKind.TRUE:
        return _literal_end(data, i, end, "true")
    if kind == RawKind.FALSE:
        return _literal_end(data, i, end, "false")
    if kind == RawKind.NULL:
        return _literal_end(data, i, end, "null")
    return -1


@always_inline
def _key_matches(
    data: Span[UInt8, _], ks: Int, ke: Int, escaped: Bool, key: StringSlice
) -> Bool:
    """Whether the key body `[ks, ke)` spells `key` once unescaped."""
    var kb = key.as_bytes()
    var n = len(kb)
    if not escaped:
        if ke - ks != n:
            return False
        var p = data.unsafe_ptr()
        for k in range(n):
            if p[unsafe_offset=ks + k] != kb[k]:
                return False
        return True
    # An escape only ever shortens a key, so a raw key shorter than the
    # wanted one cannot match. The rest is the rare slow path.
    if ke - ks < n:
        return False
    var expanded = unescape_json_string_span(data, ks, ke)
    if len(expanded) != n:
        return False
    for k in range(n):
        if expanded[k] != kb[k]:
            return False
    return True


# ---------------------------------------------------------------------------
# RawValue
# ---------------------------------------------------------------------------


struct RawValue[origin: ImmOrigin](TrivialRegisterPassable, Writable):
    """One value's bytes in a borrowed buffer, and what kind it is.

    `data[start:end]` is the value exactly as written (`raw()`), quotes
    included for a string. Copying a `RawValue` copies four words; the
    buffer must outlive it. Lookups on an absent value return absent and
    on an invalid one return it again, so a chain like
    `event["payload"]["pull_request"]["base"]` needs one check at the
    end.
    """

    var data: Span[UInt8, Self.origin]
    """The whole buffer the value lives in."""
    var start: Int
    """Offset of the value's first byte (of the error, if `INVALID`)."""
    var end: Int
    """One past the value's last byte."""
    var kind: RawKind

    @always_inline
    def __init__(
        out self,
        data: Span[UInt8, Self.origin],
        start: Int,
        end: Int,
        kind: RawKind,
    ):
        self.data = data
        self.start = start
        self.end = end
        self.kind = kind

    @always_inline
    def _absent(self) -> Self:
        return Self(self.data, -1, -1, RawKind.ABSENT)

    @always_inline
    def _invalid(self, at: Int) -> Self:
        return Self(self.data, at, at, RawKind.INVALID)

    @always_inline
    def _miss(self) -> Self:
        """What a lookup on a non-container returns."""
        if self.kind == RawKind.INVALID:
            return self
        return self._absent()

    @always_inline
    def _value_at(self, i: Int, end: Int) -> Self:
        """The value starting at `i` (not whitespace), within `end`."""
        if i >= end:
            return self._invalid(i)
        var kind = _kind_of(self.data.unsafe_ptr()[unsafe_offset=i])
        if kind == RawKind.INVALID:
            return self._invalid(i)
        var e = _value_end(self.data, i, end, kind)
        if e < 0:
            return self._invalid(i)
        return Self(self.data, i, e, kind)

    # --- what it is ---------------------------------------------------

    @always_inline
    def found(self) -> Bool:
        """Present and well-formed so far: neither absent nor invalid."""
        return self.kind != RawKind.ABSENT and self.kind != RawKind.INVALID

    @always_inline
    def is_null(self) -> Bool:
        return self.kind == RawKind.NULL

    @always_inline
    def is_object(self) -> Bool:
        return self.kind == RawKind.OBJECT

    @always_inline
    def is_array(self) -> Bool:
        return self.kind == RawKind.ARRAY

    @always_inline
    def is_string(self) -> Bool:
        return self.kind == RawKind.STRING

    @always_inline
    def is_number(self) -> Bool:
        return self.kind == RawKind.NUMBER

    @always_inline
    def is_bool(self) -> Bool:
        return self.kind == RawKind.TRUE or self.kind == RawKind.FALSE

    # --- bytes --------------------------------------------------------

    @always_inline
    def raw(self) -> Span[UInt8, Self.origin]:
        """The value exactly as written; empty if absent or invalid."""
        if not self.found():
            return self.data[0:0]
        return self.data[self.start : self.end]

    @always_inline
    def string_raw(self) -> Span[UInt8, Self.origin]:
        """A string's body between its quotes, escapes as written.

        Empty for anything that is not a string.
        """
        if self.kind != RawKind.STRING:
            return self.data[0:0]
        return self.data[self.start + 1 : self.end - 1]

    def string_has_escapes(self) -> Bool:
        """Whether a string's body contains a backslash."""
        var body = self.string_raw()
        var escaped = False
        _ = _string_close(body, 0, len(body), escaped)
        return escaped

    def write_to(self, mut writer: Some[Writer]):
        """The value as written, or `<absent>` / `<invalid at N>`."""
        if self.kind == RawKind.ABSENT:
            writer.write("<absent>")
        elif self.kind == RawKind.INVALID:
            writer.write("<invalid at ", self.start, ">")
        else:
            writer.write(StringSlice(unsafe_from_utf8=self.raw()))

    # --- objects ------------------------------------------------------

    def field(self, key: StringSlice) -> Self:
        """The value of `key` in this object; the first one if repeated.

        Absent if there is no such key or this is not an object.
        """
        if self.kind != RawKind.OBJECT:
            return self._miss()
        var p = self.data.unsafe_ptr()
        var end = self.end
        var i = skip_ws(self.data, self.start + 1, end)
        if i < end and p[unsafe_offset=i] == _RBRACE:
            return self._absent()
        while True:
            if i >= end or p[unsafe_offset=i] != _QUOTE:
                return self._invalid(i)
            var escaped = False
            var ke = _string_close(self.data, i + 1, end, escaped)
            if ke < 0:
                return self._invalid(i)
            var ks = i + 1
            i = skip_ws(self.data, ke + 1, end)
            if i >= end or p[unsafe_offset=i] != _COLON:
                return self._invalid(i)
            i = skip_ws(self.data, i + 1, end)
            var v = self._value_at(i, end)
            if v.kind == RawKind.INVALID:
                return v
            if _key_matches(self.data, ks, ke, escaped, key):
                return v
            i = skip_ws(self.data, v.end, end)
            if i >= end:
                return self._invalid(i)
            var c = p[unsafe_offset=i]
            if c == _COMMA:
                i = skip_ws(self.data, i + 1, end)
                continue
            if c == _RBRACE:
                return self._absent()
            return self._invalid(i)

    @always_inline
    def __getitem__(self, key: StringSlice) -> Self:
        """`field(key)`."""
        return self.field(key)

    def fields[n: Int](self, keys: Array[StaticString, n]) -> Array[Self, n]:
        """Several keys of this object in one walk of its members.

        `out[k]` is `field(keys[k])`, but the members are walked once,
        and the walk stops as soon as every key has been seen. An
        invalid walk makes every key not found by then `INVALID`.
        """
        var out = Array[Self, n](fill=self._miss())
        if self.kind != RawKind.OBJECT:
            return out^
        var p = self.data.unsafe_ptr()
        var end = self.end
        var missing = n
        var i = skip_ws(self.data, self.start + 1, end)
        if i < end and p[unsafe_offset=i] == _RBRACE:
            return out^
        var bad = -1
        while True:
            if i >= end or p[unsafe_offset=i] != _QUOTE:
                bad = i
                break
            var escaped = False
            var ke = _string_close(self.data, i + 1, end, escaped)
            if ke < 0:
                bad = i
                break
            var ks = i + 1
            i = skip_ws(self.data, ke + 1, end)
            if i >= end or p[unsafe_offset=i] != _COLON:
                bad = i
                break
            i = skip_ws(self.data, i + 1, end)
            var v = self._value_at(i, end)
            if v.kind == RawKind.INVALID:
                bad = v.start
                break
            comptime for k in range(n):
                if out[k].kind == RawKind.ABSENT and _key_matches(
                    self.data, ks, ke, escaped, keys[k]
                ):
                    out[k] = v
                    missing -= 1
            if missing == 0:
                break
            i = skip_ws(self.data, v.end, end)
            if i >= end:
                bad = i
                break
            var c = p[unsafe_offset=i]
            if c == _COMMA:
                i = skip_ws(self.data, i + 1, end)
                continue
            if c == _RBRACE:
                break
            bad = i
            break
        if bad >= 0:
            comptime for k in range(n):
                if out[k].kind == RawKind.ABSENT:
                    out[k] = self._invalid(bad)
        return out^

    def items(self) -> RawMembers[Self.origin]:
        """The members of this object, in order; none if not an object."""
        return RawMembers(self)

    # --- arrays -------------------------------------------------------

    def elements(self) -> RawElements[Self.origin]:
        """The elements of this array, in order; none if not an array."""
        return RawElements(self)

    def at(self, index: Int) -> Self:
        """The element at `index` in this array, or absent."""
        if self.kind != RawKind.ARRAY:
            return self._miss()
        if index < 0:
            return self._absent()
        var it = self.elements()
        var k = 0
        while it.__has_next__():
            var v = it.__next__()
            if v.kind == RawKind.INVALID or k == index:
                return v
            k += 1
        return self._absent()

    @always_inline
    def __getitem__(self, index: Int) -> Self:
        """`at(index)`."""
        return self.at(index)

    # --- paths --------------------------------------------------------

    def path(self, dotted: StringSlice) -> Self:
        """Follow `a.b.c`: each segment is a key, or an index into an array.

        `payload.commits.0.message` is `["payload"]["commits"][0]
        ["message"]`. A key that contains a dot needs `field`.
        """
        var b = dotted.as_bytes()
        var n = len(b)
        var cur = self
        var s = 0
        while s <= n:
            var e = s
            while e < n and b[e] != UInt8(ord(".")):
                e += 1
            var seg = StringSlice(unsafe_from_utf8=b[s:e])
            if cur.kind == RawKind.ARRAY and _all_digits(b, s, e):
                cur = cur.at(_digits_value(b, s, e))
            else:
                cur = cur.field(seg)
            if not cur.found():
                return cur
            s = e + 1
        return cur

    # --- scalars ------------------------------------------------------

    def _error(self, message: String) -> Error:
        return parse_error(message, self.data, max(self.start, 0))

    def string(self) raises -> String:
        """A string value, unescaped and checked as `loads` checks it."""
        if self.kind != RawKind.STRING:
            raise self._error("expected a string, found " + String(self.kind))
        var s = self.start + 1
        var e = self.end - 1
        var flags = scan_string_body(self.data, s, e)
        if flags & STR_CONTROL != 0:
            raise parse_error(
                "control character in string",
                self.data,
                find_control_char(self.data, s, e),
            )
        if flags & STR_NON_ASCII != 0 and not is_valid_utf8(self.data[s:e]):
            raise parse_error(
                "invalid UTF-8 in string",
                self.data,
                first_invalid_utf8(self.data, s, e),
            )
        if flags & STR_ESCAPE == 0:
            return String(unsafe_from_utf8=self.data[s:e])
        var err_pos = s
        var code = validate_escapes(self.data, s, e, False, err_pos)
        if code == ESC_TRAILING_BACKSLASH:
            raise parse_error(
                "trailing backslash in string", self.data, err_pos
            )
        if code == ESC_BAD_CHAR:
            raise parse_error("invalid escape", self.data, err_pos)
        if code != ESC_OK:
            raise parse_error("invalid \\u escape", self.data, err_pos)
        return String(
            unsafe_from_utf8=unescape_json_string_span(self.data, s, e)
        )

    def string_equals(self, text: StringSlice) -> Bool:
        """Whether this is a string spelling `text` once unescaped.

        Allocates nothing unless the string holds an escape.
        """
        if self.kind != RawKind.STRING:
            return False
        var body = self.string_raw()
        var escaped = False
        _ = _string_close(body, 0, len(body), escaped)
        return _key_matches(
            self.data, self.start + 1, self.end - 1, escaped, text
        )

    def int(self) raises -> Int64:
        """An integer value, with the number grammar `loads` applies."""
        if self.kind != RawKind.NUMBER:
            raise self._error("expected a number, found " + String(self.kind))
        var parsed = parse_int_checked[DType.int64](
            self.data, self.start, self.end
        )
        if parsed[1] != self.end:
            raise parse_error("invalid number", self.data, parsed[1])
        return parsed[0]

    def uint(self) raises -> UInt64:
        """A non-negative integer up to `UInt64.MAX`."""
        if self.kind != RawKind.NUMBER:
            raise self._error("expected a number, found " + String(self.kind))
        var parsed = parse_int_checked[DType.uint64](
            self.data, self.start, self.end
        )
        if parsed[1] != self.end:
            raise parse_error("invalid number", self.data, parsed[1])
        return parsed[0]

    def float(self) raises -> Float64:
        """A number as a `Float64`, with the number grammar `loads` applies."""
        if self.kind != RawKind.NUMBER:
            raise self._error("expected a number, found " + String(self.kind))
        var parsed = parse_float_span(self.data, self.start, self.end)
        if parsed[1] != self.end:
            raise parse_error("invalid number", self.data, parsed[1])
        return parsed[0]

    def bool(self) raises -> Bool:
        if self.kind == RawKind.TRUE:
            return True
        if self.kind == RawKind.FALSE:
            return False
        raise self._error("expected a boolean, found " + String(self.kind))

    # --- validation ---------------------------------------------------

    def validate(self, max_depth: Int = DEFAULT_MAX_DEPTH) raises:
        """Check the whole value as `loads` would, without building it.

        Raises a located error for the first problem: what the scan
        skipped (mismatched brackets, bad numbers, bad strings) and
        anything after the value but within its range, such as trailing
        bytes on a JSON Lines record. The rules are the typed reader's,
        which are the parser's, with one difference: nesting deeper
        than `max_depth` is refused, where `loads` takes any depth.
        """
        if self.kind == RawKind.ABSENT:
            raise Error("validate: the value is absent")
        if self.kind == RawKind.INVALID:
            raise self._error("malformed JSON")
        # First, as `loads` does for bytes: outside strings the grammar
        # would reject a stray byte anyway, but it is the UTF-8 check
        # that has the right message for it.
        var bytes = self.data[self.start : self.end]
        if not is_valid_utf8(bytes):
            var at = first_invalid_utf8(self.data, self.start, self.end)
            raise parse_error(
                "invalid UTF-8 in input", self.data, max(at, self.start)
            )
        var reader = JsonReader(bytes, max_depth=max_depth)
        _ = reader.skip_value()
        reader.expect_end()


@always_inline
def _all_digits(b: Span[UInt8, _], s: Int, e: Int) -> Bool:
    if e <= s:
        return False
    for k in range(s, e):
        if b[k] < UInt8(ord("0")) or b[k] > UInt8(ord("9")):
            return False
    return True


@always_inline
def _digits_value(b: Span[UInt8, _], s: Int, e: Int) -> Int:
    """A decimal index; one too long to hold is past any array's end."""
    if e - s > 18:
        return Int.MAX
    var v = 0
    for k in range(s, e):
        v = v * 10 + Int(b[k]) - ord("0")
    return v


# ---------------------------------------------------------------------------
# Iterators. Each finds its next item ahead of time, so `__has_next__`
# can answer; a malformed container ends with one `INVALID` item.
# ---------------------------------------------------------------------------


@fieldwise_init
struct RawMember[origin: ImmOrigin](TrivialRegisterPassable):
    """An object member: its key (a `STRING` value) and its value."""

    var key: RawValue[Self.origin]
    var value: RawValue[Self.origin]


struct RawMembers[origin: ImmOrigin](Copyable, Iterator):
    """The members of an object, from `RawValue.items()`."""

    comptime Element = RawMember[Self.origin]

    var _obj: RawValue[Self.origin]
    var _pos: Int
    var _next: RawMember[Self.origin]

    def __init__(out self, obj: RawValue[Self.origin]):
        self._obj = obj
        self._pos = obj.start + 1
        var none = obj._absent()
        self._next = RawMember(none, none)
        if obj.kind != RawKind.OBJECT:
            if obj.kind == RawKind.INVALID:
                self._next = RawMember(obj, obj)
            self._pos = -1
            return
        var i = skip_ws(obj.data, self._pos, obj.end)
        if i < obj.end and obj.data.unsafe_ptr()[unsafe_offset=i] == _RBRACE:
            self._pos = -1
            return
        self._pos = i
        self._advance()

    def _advance(mut self):
        """Read the member at `_pos` into `_next`, then move past its comma."""
        var obj = self._obj
        var p = obj.data.unsafe_ptr()
        var end = obj.end
        var i = self._pos
        if i >= end or p[unsafe_offset=i] != _QUOTE:
            self._fail(i)
            return
        var escaped = False
        var ke = _string_close(obj.data, i + 1, end, escaped)
        if ke < 0:
            self._fail(i)
            return
        var key = RawValue(obj.data, i, ke + 1, RawKind.STRING)
        i = skip_ws(obj.data, ke + 1, end)
        if i >= end or p[unsafe_offset=i] != _COLON:
            self._fail(i)
            return
        i = skip_ws(obj.data, i + 1, end)
        var v = obj._value_at(i, end)
        if v.kind == RawKind.INVALID:
            self._fail(v.start)
            return
        self._next = RawMember(key, v)
        i = skip_ws(obj.data, v.end, end)
        if i < end and p[unsafe_offset=i] == _COMMA:
            self._pos = skip_ws(obj.data, i + 1, end)
        elif i < end and p[unsafe_offset=i] == _RBRACE:
            self._pos = -1
        else:
            self._pos = -2 - i  # report it after this member

    def _fail(mut self, at: Int):
        var bad = self._obj._invalid(at)
        self._next = RawMember(bad, bad)
        self._pos = -1

    def __iter__(self) -> Self:
        return self.copy()

    @always_inline
    def __has_next__(self) -> Bool:
        return self._next.value.kind != RawKind.ABSENT

    def __next__(mut self) -> RawMember[Self.origin]:
        var item = self._next
        if item.value.kind == RawKind.INVALID or self._pos == -1:
            var none = self._obj._absent()
            self._next = RawMember(none, none)
        elif self._pos < -1:
            var bad = self._obj._invalid(-2 - self._pos)
            self._next = RawMember(bad, bad)
            self._pos = -1
        else:
            self._advance()
        return item


struct RawElements[origin: ImmOrigin](Copyable, Iterator):
    """The elements of an array, from `RawValue.elements()`."""

    comptime Element = RawValue[Self.origin]

    var _arr: RawValue[Self.origin]
    var _pos: Int
    var _next: RawValue[Self.origin]

    def __init__(out self, arr: RawValue[Self.origin]):
        self._arr = arr
        self._pos = -1
        self._next = arr._absent()
        if arr.kind != RawKind.ARRAY:
            if arr.kind == RawKind.INVALID:
                self._next = arr
            return
        var i = skip_ws(arr.data, arr.start + 1, arr.end)
        if i < arr.end and arr.data.unsafe_ptr()[unsafe_offset=i] == _RBRACK:
            return
        self._pos = i
        self._advance()

    def _advance(mut self):
        var arr = self._arr
        var p = arr.data.unsafe_ptr()
        var end = arr.end
        var v = arr._value_at(self._pos, end)
        self._next = v
        if v.kind == RawKind.INVALID:
            self._pos = -1
            return
        var i = skip_ws(arr.data, v.end, end)
        if i < end and p[unsafe_offset=i] == _COMMA:
            self._pos = skip_ws(arr.data, i + 1, end)
        elif i < end and p[unsafe_offset=i] == _RBRACK:
            self._pos = -1
        else:
            self._pos = -2 - i

    def __iter__(self) -> Self:
        return self.copy()

    @always_inline
    def __has_next__(self) -> Bool:
        return self._next.kind != RawKind.ABSENT

    def __next__(mut self) -> RawValue[Self.origin]:
        var item = self._next
        if item.kind == RawKind.INVALID or self._pos == -1:
            self._next = self._arr._absent()
        elif self._pos < -1:
            self._next = self._arr._invalid(-2 - self._pos)
            self._pos = -1
        else:
            self._advance()
        return item


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------


@always_inline
def _is_ws(c: UInt8) -> Bool:
    return c == 0x20 or c == 0x0A or c == 0x0D or c == 0x09


def _trimmed(data: Span[UInt8, _], var s: Int, var e: Int) -> Tuple[Int, Int]:
    s = skip_ws(data, s, e)
    var p = data.unsafe_ptr()
    while e > s and _is_ws(p[unsafe_offset=e - 1]):
        e -= 1
    return (s, e)


def _top_level[
    origin: ImmOrigin
](data: Span[UInt8, origin], s: Int, e: Int) -> RawValue[origin]:
    """The value filling `[s, e)`, which is trimmed and not empty.

    A container takes the whole range without reading it; that is what
    keeps a JSON Lines split from reading each record twice. A scalar
    is short, so its end is found and must be `e`.
    """
    var kind = _kind_of(data[s])
    if kind == RawKind.INVALID:
        return RawValue(data, s, s, kind)
    if kind == RawKind.OBJECT or kind == RawKind.ARRAY:
        return RawValue(data, s, e, kind)
    var end = _value_end(data, s, e, kind)
    if end != e:
        var at = end if end >= 0 else s
        return RawValue(data, at, at, RawKind.INVALID)
    return RawValue(data, s, e, kind)


def scan[origin: ImmOrigin](data: Span[UInt8, origin]) -> RawValue[origin]:
    """The document in `data`, without reading an object or array.

    The value spans `data` minus surrounding whitespace (and a UTF-8
    byte order mark); its kind comes from its first byte. A container
    is not checked until it is walked, read or `validate()`d; a scalar
    must fill the span. An empty or all-whitespace input is `INVALID`
    at 0.
    """
    var s = 0
    if (
        len(data) >= 3
        and data[0] == UInt8(0xEF)
        and data[1] == UInt8(0xBB)
        and data[2] == UInt8(0xBF)
    ):
        s = 3
    var t = _trimmed(data, s, len(data))
    if t[0] >= t[1]:
        return RawValue(data, 0, 0, RawKind.INVALID)
    return _top_level(data, t[0], t[1])


@always_inline
def find_newline(data: Span[UInt8, _], var i: Int, end: Int) -> Int:
    """The offset of the first `\\n` at or after `i`, or `end`."""
    var p = data.unsafe_ptr()
    while i + _BLOCK <= end:
        var m = pack_bits[dtype=_MASK](
            p.unsafe_load[width=_BLOCK](i).eq(_NEWLINE)
        )
        if m != 0:
            return i + Int(count_trailing_zeros(m))
        i += _BLOCK
    while i < end and p[unsafe_offset=i] != _NEWLINE:
        i += 1
    return i


struct RawLines[origin: ImmOrigin](Copyable, Iterator):
    """The records of a JSON Lines buffer, from `scan_lines`.

    Each item is one line with its surrounding whitespace (and a `\\r`)
    trimmed; blank lines are skipped. `line_start` and `line_end` give
    the untrimmed line, for a caller that slices the buffer by line.
    """

    comptime Element = RawValue[Self.origin]

    var data: Span[UInt8, Self.origin]
    var _pos: Int
    var _next: RawValue[Self.origin]
    var line_start: Int
    """Where the line of the item `__next__` returned last starts."""
    var line_end: Int
    """Where that line ends (its `\\n`, or the end of the buffer)."""
    var _next_line_start: Int
    var _next_line_end: Int

    def __init__(out self, data: Span[UInt8, Self.origin]):
        self.data = data
        self._pos = 0
        self._next = RawValue(data, -1, -1, RawKind.ABSENT)
        self.line_start = 0
        self.line_end = 0
        self._next_line_start = 0
        self._next_line_end = 0
        self._advance()

    def _advance(mut self):
        var n = len(self.data)
        while self._pos < n:
            var s = self._pos
            var e = find_newline(self.data, s, n)
            self._pos = e + 1
            var t = _trimmed(self.data, s, e)
            if t[0] >= t[1]:
                continue
            self._next_line_start = s
            self._next_line_end = e
            self._next = _top_level(self.data, t[0], t[1])
            return
        self._next = RawValue(self.data, -1, -1, RawKind.ABSENT)

    def __iter__(self) -> Self:
        return self.copy()

    @always_inline
    def __has_next__(self) -> Bool:
        return self._next.kind != RawKind.ABSENT

    def __next__(mut self) -> RawValue[Self.origin]:
        var item = self._next
        self.line_start = self._next_line_start
        self.line_end = self._next_line_end
        self._advance()
        return item


def scan_lines[
    origin: ImmOrigin
](data: Span[UInt8, origin]) -> RawLines[origin]:
    """The records of a JSON Lines (NDJSON) buffer, one `RawValue` each.

    Splitting by line reads nothing but newlines; each record is then
    walked as `scan` would walk it. A record must fit on its line, which
    JSON Lines requires anyway: a raw newline cannot appear in a string.
    """
    return RawLines(data)
