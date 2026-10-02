#!/usr/bin/env python3
"""compare_outputs.py <workdir> [<refdir>]

Numeric comparison of example outputs in <workdir>/<ex>/outputfiles against
<refdir>/<ex> (default: <workdir>/sampleOutput, i.e. upstream's sampleOutput).

Text files are compared line by line; numbers are compared by value, so last-digit
rounding and -0 vs 0 show up as a small max delta, while differing integers (cell
ids, counts) or non-numeric text are counted separately. Binary files (shp/shx/dbf)
are only checked for equality. Informational: always exits 0. See build_notes.md.
"""
import filecmp
import os
import re
import sys

NUM = re.compile(r"[-+]?\d+\.\d+(?:[eE][-+]?\d+)?|[-+]?\d+")
BINARY = (".shp", ".shx", ".dbf")


def compare_text(a, b):
    la = open(a, errors="replace").read().splitlines()
    lb = open(b, errors="replace").read().splitlines()
    if len(la) != len(lb):
        return f"line count {len(la)} vs {len(lb)}"
    lines = other = 0
    max_delta = 0.0
    for x, y in zip(la, lb):
        if x == y:
            continue
        lines += 1
        if NUM.sub("#", x) != NUM.sub("#", y):
            other += 1
            continue
        for p, q in zip(NUM.findall(x), NUM.findall(y)):
            if p == q:
                continue
            if "." not in p and "." not in q:
                other += 1
            else:
                max_delta = max(max_delta, abs(float(p) - float(q)))
    return f"{lines} lines differ, max delta {max_delta:g}, int/text diffs {other}"


def main():
    work = sys.argv[1]
    ref = sys.argv[2] if len(sys.argv) > 2 else os.path.join(work, "sampleOutput")
    examples = open(os.path.join(work, "examplesNoGDAL.lst")).read().split()
    rows = []
    for ex in examples:
        out_dir, ref_dir = os.path.join(work, ex, "outputfiles"), os.path.join(ref, ex)
        if not os.path.isdir(ref_dir):
            continue
        for name in sorted(os.listdir(ref_dir)):
            if name == ex + ".txt":
                continue  # run log, contains timings
            a, b = os.path.join(out_dir, name), os.path.join(ref_dir, name)
            if not os.path.exists(a):
                rows.append((ex, name, "missing"))
            elif filecmp.cmp(a, b, shallow=False):
                continue
            elif name.endswith(BINARY):
                rows.append((ex, name, "binary differs"))
            else:
                rows.append((ex, name, compare_text(a, b)))

    report = [f"#### output comparison vs `{ref}` (informational)", ""]
    if rows:
        report += ["| example | file | result |", "|---|---|---|"]
        report += [f"| {ex} | {name} | {res} |" for ex, name, res in rows]
    else:
        report.append("all outputs identical")
    text = "\n".join(report) + "\n"
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(text)


if __name__ == "__main__":
    main()
