#!/usr/bin/env python3
"""Compare ldmath output against a correctly rounded double reference (mpmath)
and optionally against a second platform's ldmath output.

  python ldmath_compare.py out-a.txt [out-b.txt]

ulp errors vs the reference are exact only for LDBL_MANT_DIG == 53 platforms
(the printed input is the double the function actually saw). On x87 / quad
platforms the input was wider than the printed double, so expect ~1 ulp noise.
"""
import math
import sys

import mpmath

mpmath.mp.prec = 200

REF = {
    "sinl": lambda a, b: mpmath.sin(a), "std::sin": lambda a, b: mpmath.sin(a),
    "cosl": lambda a, b: mpmath.cos(a), "std::cos": lambda a, b: mpmath.cos(a),
    "tanl": lambda a, b: mpmath.tan(a), "atanl": lambda a, b: mpmath.atan(a),
    "sqrtl": lambda a, b: mpmath.sqrt(a),
    "asinl": lambda a, b: mpmath.asin(a), "acosl": lambda a, b: mpmath.acos(a),
    "atan2l": lambda a, b: mpmath.atan2(a, b), "powl": lambda a, b: mpmath.power(a, b),
}


def load(path):
    rows, mant = [], None
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("# LDBL_MANT_DIG"):
            mant = int(line.split()[-1])
            continue
        f = line.split()
        if len(f) >= 4:
            rows.append((f[0], float(f[1]), float(f[2]), float(f[3])))
    return mant, rows


def ulps(x, ref):
    if x == ref:
        return 0.0
    return abs(x - ref) / math.ulp(ref if ref != 0 else 5e-324)


def main():
    mant_a, a = load(sys.argv[1])
    b = load(sys.argv[2])[1] if len(sys.argv) > 2 else None
    print(f"# {sys.argv[1]}: LDBL_MANT_DIG {mant_a}")
    worst = {}
    for i, (fn, x, y, r) in enumerate(a):
        line = f"{fn:10s} {x:<22.17g} {y:<22.17g} {r:<24.17g}"
        if fn in REF:
            ref = float(REF[fn](mpmath.mpf(x), mpmath.mpf(y)))
            e = ulps(r, ref)
            worst[fn] = max(worst.get(fn, 0.0), e)
            line += f" ulp_vs_ref {e:8.3g}"
        if b is not None:
            fb, xb, yb, rb = b[i]
            assert (fb, xb, yb) == (fn, x, y) or fb == fn, (a[i], b[i])
            line += f" | other {rb:<24.17g} ulp_diff {ulps(r, rb):8.3g}"
        print(line)
    print("\n# worst ulp error vs correctly rounded double, per function")
    for fn, e in sorted(worst.items(), key=lambda kv: -kv[1]):
        print(f"#   {fn:10s} {e:10.3g} ulp  ({e * 2.0**-52:.2e} rel)")


if __name__ == "__main__":
    main()
