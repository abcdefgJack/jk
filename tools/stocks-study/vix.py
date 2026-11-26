# Does the VIX (the market's own guess at the next month's swings) fix the months the 20-day range misses?
# Scale each stock's 20-day spread by (VIX / SPY's own 20-day spread) ** a, and see how month-to-month coverage moves.
import json, os, sys, math, time
import numpy as np

DATA, VIXF = sys.argv[1], sys.argv[2]
day = lambda x: time.strftime('%Y-%m-%d', time.gmtime(x))
v = json.load(open(VIXF))

def sd20(r):
    out = np.full(len(r), np.nan)
    cs = np.concatenate([[0], np.cumsum(r)]); cs2 = np.concatenate([[0], np.cumsum(r * r)])
    i = np.arange(20, len(r))
    s, s2 = cs[i] - cs[i - 20], cs2[i] - cs2[i - 20]
    out[i] = np.sqrt(np.maximum((s2 - s * s / 20) / 19, 0))
    return out

def closes(k):
    c = np.array([x if x is not None else np.nan for x in v[k]['close']], float); t = np.array(v[k]['timestamp'][:len(c)], float)
    ok = np.isfinite(c); return c[ok], t[ok]

ratio = {}
sc, st = closes('SPY'); sr = np.diff(np.log(sc)); ss = sd20(sr)
for name in ('^VIX', '^VIX9D'):
    vc, vt = closes(name); vix = {day(a): b for a, b in zip(vt, vc)}
    # spread after the close of day i is sd of r[i-19..i] = ss[i+1]
    ratio[name] = {}
    for i in range(20, len(sr) - 1):
        d = day(st[i + 1])
        if d in vix and ss[i + 1] > 0: ratio[name][d] = (vix[d] / 100 / math.sqrt(252)) / ss[i + 1]
for name, rr in ratio.items():
    a = np.array(list(rr.values())); print(name, 'VIX / SPY spread: median', round(float(np.median(a)), 2), 'p10', round(float(np.quantile(a, .1)), 2), 'p90', round(float(np.quantile(a, .9)), 2))

us = set()
for nm in ('nasdaqlisted.txt', 'otherlisted.txt'):
    for line in open(os.path.join(DATA, nm), encoding='utf-8', errors='replace').read().splitlines()[1:]:
        us.add(line.split('|')[0].strip().replace('.', '-'))
Z, S, R, M, ID = [], [], {k: [] for k in ratio}, [], []
seen = set()
for line in open(os.path.join(DATA, 'closes.jsonl'), encoding='utf-8'):
    d = json.loads(line); s = d['s']
    if '.' in s or s in seen or s not in us: continue
    seen.add(s)
    c = np.array([x if x is not None else np.nan for x in d['c']], float); t = np.array(d['t'][:len(c)], float)
    ok = np.isfinite(c) & (c > 0); c, t = c[ok], t[ok]
    if len(c) < 200: continue
    r = np.diff(np.log(c))
    if np.mean(r == 0) > 0.15 or np.max(np.abs(r)) > 1.0: continue
    sig = sd20(r); j = np.arange(60, len(r)); sg = sig[j]; g = np.isfinite(sg) & (sg > 0); j = j[g]
    prev = [day(x) for x in t[1:][j - 1]]          # the close the range is made at
    for k in ratio: R[k].append(np.array([ratio[k].get(p, np.nan) for p in prev]))
    Z.append(np.abs(r[j]) / sig[j]); M.append(np.array([p[:7] for p in prev])); ID.append(np.full(len(j), len(seen)))
z = np.concatenate(Z); m = np.concatenate(M); sid = np.concatenate(ID)
Rk = {k: np.concatenate(x) for k, x in R.items()}
keep = np.isfinite(Rk['^VIX']) & np.isfinite(Rk['^VIX9D'])
z, m, sid = z[keep], m[keep], sid[keep]; Rk = {k: x[keep] for k, x in Rk.items()}
half = np.sort(np.unique(m))[len(np.unique(m)) // 2]
print(len(z), 'stock-days; first-half months fit k, second half judged; split at', half)
def report(label, zz):
    tr, te = m < half, m >= half
    k = float(np.quantile(zz[tr], .8))
    h = zz[te] <= k
    mos = sorted(set(m[te])); cov = [np.mean(h[m[te] == x]) for x in mos]
    print(f'{label:22} k={k:5.3f}  held {h.mean():6.1%}  months: worst {min(cov):6.1%} best {max(cov):6.1%} spread(sd) {np.std(cov):5.1%}')
report('20 days alone', z)       # every k here is fitted on the first half
for k in ratio:
    for a in (0.25, 0.5, 0.75, 1.0):
        report(f'{k} a={a}', z / Rk[k] ** a)
