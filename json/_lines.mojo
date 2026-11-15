# json - splitting text into lines, for NDJSON
#
# Below `parser`, `ndjson` and `gpu.backend`, which all use them.

from std.collections import List


def _split_lines(s: String) -> List[String]:
    """Split string into lines."""
    var result = List[String]()
    var s_bytes = s.as_bytes()
    var n = len(s_bytes)
    var line_start = 0

    for i in range(n):
        if s_bytes[i] == UInt8(ord("\n")):
            # Handle \r\n
            var end = i
            if end > line_start and s_bytes[end - 1] == UInt8(ord("\r")):
                end -= 1
            result.append(String(unsafe_from_utf8=s.as_bytes()[line_start:end]))
            line_start = i + 1

    # Add last line if not empty
    if line_start < n:
        var end = n
        if end > line_start and s_bytes[end - 1] == UInt8(ord("\r")):
            end -= 1
        result.append(String(unsafe_from_utf8=s.as_bytes()[line_start:end]))

    return result^


def _is_whitespace_only(s: String) -> Bool:
    """Check if string contains only whitespace."""
    var s_bytes = s.as_bytes()
    for i in range(len(s_bytes)):
        var c = s_bytes[i]
        if (
            c != UInt8(ord(" "))
            and c != UInt8(ord("\t"))
            and c != UInt8(ord("\r"))
            and c != UInt8(ord("\n"))
        ):
            return False
    return True
