# Span scan benchmark: JSON Lines in, a few fields out.
#
# The workload is a GH Archive hour: one event per line, from which a
# consumer wants `id`, `type`, `created_at`, `repo.name`, `actor.login`
# and the `payload` exactly as written. Each lane does that job a
# different way over the same bytes:
#
#   lines            split the buffer into lines, nothing else
#   scan             scan_lines + fields() + two nested lookups;
#                    the payload is a byte range, never copied
#   scan+decode      the same, decoding the four strings to `String`
#   scan+validate    scan, then validate() each record in full
#   dom              loads() each line, read the fields, dumps() the
#                    payload (a DOM has no way back to its bytes)
#   dom-simdjson     the same with target="cpu-simdjson"
#
# Each lane runs once to warm up and then `runs` times; the report is
# the median and p90 wall time, and MB/s from the median.
#
# Usage:
#   pixi run build-bench-scan
#   benchmark/build/bench_scan <file.jsonl> [runs] [--no-dom]

from std.pathlib import Path
from std.sys import argv
from std.time import perf_counter_ns

from json import RawValue, Value, dumps, loads, scan_lines

comptime _KEYS: Array[StaticString, 6] = [
    "id",
    "type",
    "created_at",
    "repo",
    "actor",
    "payload",
]


def _lane_lines(data: Span[UInt8, _]) -> Int:
    var n = 0
    for line in scan_lines(data):
        n += line.end - line.start
    return n


def _lane_scan(data: Span[UInt8, _]) -> Int:
    var sum = 0
    for line in scan_lines(data):
        var f = line.fields(materialize[_KEYS]())
        var repo = f[3]["name"]
        var actor = f[4]["login"]
        sum += (f[0].end - f[0].start) + (f[1].end - f[1].start)
        sum += (f[2].end - f[2].start) + (repo.end - repo.start)
        sum += (actor.end - actor.start) + (f[5].end - f[5].start)
    return sum


def _text(v: RawValue) raises -> Int:
    """A string's decoded length; 0 when absent (`"repo": {}` happens)."""
    if not v.found():
        return 0
    return v.string().byte_length()


def _lane_decode(data: Span[UInt8, _]) raises -> Int:
    var sum = 0
    for line in scan_lines(data):
        var f = line.fields(materialize[_KEYS]())
        sum += _text(f[0]) + _text(f[1])
        sum += _text(f[3]["name"]) + _text(f[4]["login"])
        sum += f[2].end - f[2].start + len(f[5].raw())
    return sum


def _lane_validate(data: Span[UInt8, _]) raises -> Int:
    var sum = 0
    for line in scan_lines(data):
        line.validate()
        var f = line.fields(materialize[_KEYS]())
        sum += len(f[5].raw()) + len(f[0].raw())
    return sum


def _dom_text(obj: Value, key: String) raises -> Int:
    var got = obj.get(key)
    if not got:
        return 0
    return got.value().string_value().byte_length()


def _lane_dom[target: StaticString](data: Span[UInt8, _]) raises -> Int:
    var sum = 0
    var it = scan_lines(data)
    for line in it:
        var v = loads[target](line.raw())
        sum += v["id"].string_value().byte_length()
        sum += v["type"].string_value().byte_length()
        sum += v["created_at"].string_value().byte_length()
        sum += _dom_text(v["repo"], "name") + _dom_text(v["actor"], "login")
        sum += dumps(v["payload"]).byte_length()
    return sum


def _median_p90(var times: List[Int]) -> Tuple[Float64, Float64]:
    sort(times)
    var n = len(times)
    var p90 = min(n - 1, (n * 9) // 10)
    return (Float64(times[n // 2]) / 1e6, Float64(times[p90]) / 1e6)


def _report(label: String, var times: List[Int], size: Int, check: Int):
    var t = _median_p90(times^)
    var mbs = Float64(size) / 1e6 / (t[0] / 1000.0)
    print(
        "  ",
        label.ascii_ljust(16),
        " p50 ",
        t[0],
        " ms  p90 ",
        t[1],
        " ms  ",
        Int(mbs),
        " MB/s  (check ",
        check,
        ")",
        sep="",
    )


def _run(lane: Int, data: Span[UInt8, _]) raises -> Int:
    if lane == 0:
        return _lane_lines(data)
    if lane == 1:
        return _lane_scan(data)
    if lane == 2:
        return _lane_decode(data)
    if lane == 3:
        return _lane_validate(data)
    if lane == 4:
        return _lane_dom["cpu"](data)
    return _lane_dom["cpu-simdjson"](data)


def _time(lane: Int, label: String, data: Span[UInt8, _], runs: Int) raises:
    var check = _run(lane, data)
    var times = List[Int](capacity=runs)
    for _ in range(runs):
        var t0 = perf_counter_ns()
        var c = _run(lane, data)
        times.append(Int(perf_counter_ns() - t0))
        if c != check:
            raise Error(label + ": checksum changed between runs")
    _report(label, times^, len(data), check)


def main() raises:
    var args = argv()
    if len(args) < 2:
        raise Error("usage: bench_scan <file.jsonl> [runs] [--no-dom]")
    var path = String(args[1])
    var runs = 7
    var dom = True
    for k in range(2, len(args)):
        if args[k] == "--no-dom":
            dom = False
        else:
            runs = Int(String(args[k]))
    var bytes = Path(path).read_bytes()
    var data = Span(bytes)
    var records = 0
    for _ in scan_lines(data):
        records += 1
    print(
        "bench_scan:",
        path,
        "--",
        len(bytes),
        "bytes,",
        records,
        "records,",
        runs,
        "runs",
    )
    _time(0, "lines", data, runs)
    _time(1, "scan", data, runs)
    _time(2, "scan+decode", data, runs)
    _time(3, "scan+validate", data, runs)
    if dom:
        _time(4, "dom", data, max(1, runs // 3))
        _time(5, "dom-simdjson", data, max(1, runs // 3))
    _ = bytes^
