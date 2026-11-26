# Out-of-sample study: which range for the next close lands 80% of the time, across every series.
# Every number for day t uses only closes before t. Train = first half of the dates, test = the rest.
import json, sys, math
import numpy as np

path = sys.argv[1]
TARGET = 0.80
series = []; seen = set()
for line in open(path, encoding='utf-8'):
    d = json.loads(line)
    if d['s'] in seen: continue
    seen.add(d['s'])
    c = np.array([x if x is not None else np.nan for x in d['c']], dtype=float)
    t = np.array(d['t'][:len(c)], dtype=float)
    ok = np.isfinite(c) & (c > 0)
    c, t = c[ok], t[ok]
    if len(c) < 200: continue
    r = np.diff(np.log(c))
    if np.mean(r == 0) > 0.15: continue          # thin trading: a flat day is not a forecast
    if np.max(np.abs(r)) > 1.0: continue         # an unadjusted split or a bad print
    mkt = d['s'].split('.')[1] if '.' in d['s'] else 'US'
    series.append((d['s'], mkt, r, t[1:]))
print(len(series), 'series kept')

def sd_window(r, w):
    out = np.full(len(r), np.nan)
    cs = np.concatenate([[0], np.cumsum(r)]); cs2 = np.concatenate([[0], np.cumsum(r * r)])
    for i in range(w, len(r)):
        s, s2 = cs[i] - cs[i - w], cs2[i] - cs2[i - w]
        out[i] = math.sqrt(max((s2 - s * s / w) / (w - 1), 0))
    return out

def ewma(r, lam, warm=20):
    out = np.full(len(r), np.nan)
    v = np.var(r[:warm], ddof=1)
    for i in range(warm, len(r)):
        out[i] = math.sqrt(v)
        v = lam * v + (1 - lam) * r[i] ** 2
    return out

def blend(r):
    a, b = ewma(r, 0.94), sd_window(r, 60)
    return np.sqrt(0.5 * a * a + 0.5 * b * b)

methods = {
    'sd20': lambda r: sd_window(r, 20),
    'sd60': lambda r: sd_window(r, 60),
    'ewma94': lambda r: ewma(r, 0.94),
    'ewma97': lambda r: ewma(r, 0.97),
    'blend': blend,
}
WARM = 60
res = {}
for name, f in methods.items():
    Z = []                     # (series index, day index, |z|, sigma)
    for si, (s, mkt, r, t) in enumerate(series):
        sig = f(r)
        idx = np.arange(WARM, len(r))
        sg = sig[idx]
        good = np.isfinite(sg) & (sg > 0)
        Z.append((si, idx[good], np.abs(r[idx[good]]) / sg[good], sg[good]))
    res[name] = Z

def evaluate(name, Z, calib):
    hits = tot = 0; width = 0.0; per = []; bymkt = {}
    for si, idx, z, sg in Z:
        n = len(z); half = n // 2
        if n < 120: continue
        if calib == 'gauss':
            k = np.full(n - half, 1.2816)
        elif calib == 'pooled':
            k = np.full(n - half, POOLED[name])
        else:                      # own past |z|: the 80th percentile of the last 250 days
            k = np.empty(n - half)
            for j in range(half, n, 20):
                k[j - half:j - half + 20] = np.quantile(z[max(0, j - 250):j], TARGET)
            k = 0.5 * k + 0.5 * POOLED[name]      # shrink toward the pool
        h = z[half:] <= k
        hits += h.sum(); tot += len(h); width += (k * sg[half:]).sum()
        per.append(h.mean())
        m = series[si][1]; a = bymkt.setdefault(m, [0, 0]); a[0] += h.sum(); a[1] += len(h)
    per = np.array(per)
    return hits / tot, width / tot, np.mean((per >= 0.75) & (per <= 0.85)), tot, {m: round(a[0] / a[1], 3) for m, a in bymkt.items()}

POOLED = {}
for name, Z in res.items():
    train = np.concatenate([z[:len(z) // 2] for _, _, z, _ in Z if len(z) >= 120])
    POOLED[name] = float(np.quantile(train, TARGET))
print('pooled k (80th percentile of |move| / sigma on the first half):', {k: round(v, 3) for k, v in POOLED.items()})
print(f"{'method':8} {'calib':7} {'held':>6} {'width':>7} {'75-85%':>7} {'days':>9}  by market")
for name, Z in res.items():
    for calib in ('gauss', 'pooled', 'own'):
        cov, w, inband, tot, bm = evaluate(name, Z, calib)
        print(f'{name:8} {calib:7} {cov:6.1%} {w:7.2%} {inband:7.1%} {tot:9d}  {bm}', flush=True)

# direction: does anything simple call tomorrow's sign?
print('\ndirection, test half, all series:')
acc = {'above 20-day average': [0, 0], 'yesterday up': [0, 0], 'big move then reversal': [0, 0]}
for s_, mkt, r, t in series:
    n = len(r); half = max(n // 2, 22)
    lc = np.cumsum(r); cs = np.concatenate([[0], lc])
    j = np.arange(half, n)
    avg = (cs[j] - cs[j - 20]) / 20                     # mean of lc[j-20 .. j-1]
    up = r[j] > 0; live = r[j] != 0
    c1 = ((lc[j - 1] > avg) == up)[live]; acc['above 20-day average'][0] += c1.sum(); acc['above 20-day average'][1] += len(c1)
    c2 = ((r[j - 1] > 0) == up)[live & (r[j - 1] != 0)]; acc['yesterday up'][0] += c2.sum(); acc['yesterday up'][1] += len(c2)
    sd = np.array([np.std(r[k - 20:k]) for k in j])
    big = live & (sd > 0) & (np.abs(r[j - 1]) > 2 * sd)
    c3 = ((r[j - 1] < 0) == up)[big]; acc['big move then reversal'][0] += c3.sum(); acc['big move then reversal'][1] += len(c3)
for k, (a, b) in acc.items():
    print(f'  {k:24} right {a / b:.1%} of {b} days')

# the sd20 range at fixed multiples, over every day after the warm-up (the whole two years)
print('\nsd20 at fixed k, all days after the first 60:')
Z = res['sd20']
allz = np.concatenate([z for _, _, z, _ in Z]); mk = np.concatenate([[series[si][1]] * len(z) for si, _, z, _ in Z])
per = {k: [] for k in (1.0, 1.2816, 1.30, 1.96, 2.0, 2.3)}
for si, idx, z, sg in Z:
    for k in per: per[k].append(np.mean(z <= k))
for k in per:
    p = np.array(per[k]); tgt = 0.8 if k < 1.5 else 0.95
    line = f'  k={k:<6} held {np.mean(allz <= k):6.2%}  stocks within 5 points of {tgt:.0%}: {np.mean(np.abs(p - tgt) <= 0.05):6.1%}  by market '
    line += str({m: round(float(np.mean(allz[mk == m] <= k)), 3) for m in sorted(set(mk))})
    print(line)
# by year: the first and the second
for half in (0, 1):
    zz = np.concatenate([z[:len(z) // 2] if half == 0 else z[len(z) // 2:] for _, _, z, _ in Z])
    print(f'  {"first" if half == 0 else "second"} year at 1.2816: {np.mean(zz <= 1.2816):.2%}')
print('  80th percentile of |z| over everything:', round(float(np.quantile(allz, 0.8)), 4), ' 95th:', round(float(np.quantile(allz, 0.95)), 4))

# a week out: the 5-day move against sigma20 * sqrt(5), sigma from the 20 days before the week
w5 = []
for s, mkt, r, t in series:
    sig = sd_window(r, 20); cs = np.concatenate([[0], np.cumsum(r)])
    j = np.arange(60, len(r) - 5, 5)
    sg = sig[j]; ok = np.isfinite(sg) & (sg > 0)
    w5.append(np.abs(cs[j[ok] + 5] - cs[j[ok]]) / (sg[ok] * math.sqrt(5)))
w5 = np.concatenate(w5)
print(f'\na week out: {len(w5)} weeks; held at 1.2816: {np.mean(w5 <= 1.2816):.2%}; 80th percentile {np.quantile(w5, 0.8):.4f}; 95th {np.quantile(w5, 0.95):.4f}')
