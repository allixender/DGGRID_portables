import sys, re, os, filecmp
NUM = re.compile(r'[-+]?\d+\.\d+(?:[eE][-+]?\d+)?|[-+]?\d+')
def cmp(a, b):
    """return (n_lines, n_textual, n_nonnumeric, maxabs)"""
    la = open(a, errors='replace').read().splitlines(); lb = open(b, errors='replace').read().splitlines()
    if len(la) != len(lb): return ('LINECOUNT', len(la), len(lb))
    tex = nonnum = 0; mx = 0.0
    for x, y in zip(la, lb):
        if x == y: continue
        tex += 1
        if NUM.sub('#', x) != NUM.sub('#', y): nonnum += 1; continue
        for p, q in zip(NUM.findall(x), NUM.findall(y)):
            if p != q:
                if '.' not in p and '.' not in q: nonnum += 1  # integer differs -> index/ID mismatch
                else: mx = max(mx, abs(float(p) - float(q)))
    return (len(la), tex, nonnum, mx)
root, ref = sys.argv[1], sys.argv[2]
for ex in sorted(os.listdir(root)):
    od = os.path.join(root, ex, 'outputfiles'); rd = os.path.join(ref, ex)
    if not os.path.isdir(od) or not os.path.isdir(rd): continue
    for fn in sorted(os.listdir(rd)):
        if fn == ex + '.txt': continue
        a, b = os.path.join(od, fn), os.path.join(rd, fn)
        if not os.path.exists(a): print(f'{ex}/{fn}: MISSING'); continue
        if filecmp.cmp(a, b, shallow=False): continue
        if fn.endswith(('.shp', '.shx', '.dbf')): print(f'{ex}/{fn}: binary differs'); continue
        print(f'{ex}/{fn}:', cmp(a, b))
