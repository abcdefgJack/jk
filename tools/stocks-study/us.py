# The same check on US-listed symbols only, split into the big names, the ETFs and the rest by price.
# python -I us.py <data folder>   (the folder collect.py filled: closes.jsonl plus the two Nasdaq lists)
import json, os, sys, math, time
import numpy as np

DATA = sys.argv[1]
BIG = set('''AAPL MSFT NVDA AMZN GOOGL GOOG META TSLA AVGO BRK-B JPM V MA UNH XOM LLY JNJ WMT PG HD
COST ORCL NFLX AMD CRM ADBE KO PEP BAC CVX MRK ABBV TMO CSCO MCD INTC QCOM IBM DIS NKE GS MS WFC
CAT BA GE UBER PLTR PYPL SBUX T VZ PFE AMGN TXN MU LOW UNP HON'''.split())
INDEX = {'SPY', 'QQQ', 'DIA', 'IWM', 'VOO', 'VTI'}

etf = {}
for name, etfcol, test in (('nasdaqlisted.txt', 6, 3), ('otherlisted.txt', 4, 6)):
    for line in open(os.path.join(DATA, name), encoding='utf-8', errors='replace').read().splitlines()[1:]:
        f = line.split('|')
        if len(f) < 7 or f[test] == 'Y': continue
        etf[f[0].strip().replace('.', '-')] = f[etfcol] == 'Y'

def sd20(r):
    out = np.full(len(r), np.nan)
    cs = np.concatenate([[0], np.cumsum(r)]); cs2 = np.concatenate([[0], np.cumsum(r * r)])
    i = np.arange(20, len(r))
    s, s2 = cs[i] - cs[i - 20], cs2[i] - cs2[i - 20]
    out[i] = np.sqrt(np.maximum((s2 - s * s / 20) / 19, 0))
    return out

groups = {}
seen = set()
months = {}
for line in open(os.path.join(DATA, 'closes.jsonl'), encoding='utf-8'):
    d = json.loads(line)
    s = d['s']
    if '.' in s or s in seen or s not in etf: continue
    seen.add(s)
    c = np.array([x if x is not None else np.nan for x in d['c']], dtype=float)
    t = np.array(d['t'][:len(c)], dtype=float)
    ok = np.isfinite(c) & (c > 0); c, t = c[ok], t[ok]
    if len(c) < 200: continue
    r = np.diff(np.log(c))
    if np.mean(r == 0) > 0.15 or np.max(np.abs(r)) > 1.0: continue
    sig = sd20(r)
    j = np.arange(60, len(r)); sg = sig[j]; g = np.isfinite(sg) & (sg > 0); j = j[g]; sg = sg[g]
    z = np.abs(r[j]) / sg
    # a week out, from the 20 days before the week
    cs = np.concatenate([[0], np.cumsum(r)])
    w = np.arange(60, len(r) - 5, 5); sw = sig[w]; gw = np.isfinite(sw) & (sw > 0)
    wz = np.abs(cs[w[gw] + 5] - cs[w[gw]]) / (sw[gw] * math.sqrt(5))
    # direction, every day after the warm-up
    lc = np.cumsum(r); csum = np.concatenate([[0], lc])
    avg = (csum[j] - csum[j - 20]) / 20
    up = r[j] > 0; live = r[j] != 0
    dir1 = ((lc[j - 1] > avg) == up)[live]
    dir2 = ((r[j - 1] > 0) == up)[live & (r[j - 1] != 0)]
    big = live & (np.abs(r[j - 1]) > 2 * sig[j - 1]) & np.isfinite(sig[j - 1])
    dir3 = ((r[j - 1] < 0) == up)[big]
    price = c[-1]
    kind = ('index funds' if s in INDEX else 'big names' if s in BIG else 'other ETFs' if etf[s]
            else 'stocks over $20' if price >= 20 else 'stocks $5-20' if price >= 5 else 'stocks under $5')
    for gname in (kind, 'all US'):
        a = groups.setdefault(gname, {'z': [], 'w': [], 'per': [], 'd1': [0, 0], 'd2': [0, 0], 'd3': [0, 0]})
        a['z'].append(z); a['w'].append(wz); a['per'].append(np.mean(z <= 1.2816))
        for key, v in (('d1', dir1), ('d2', dir2), ('d3', dir3)):
            a[key][0] += int(v.sum()); a[key][1] += len(v)
    # month by month, the stocks and ETFs together (the day's date in New York is close enough here)
    mo = np.array([time.strftime('%Y-%m', time.gmtime(x)) for x in t[1:][j]])
    for m in np.unique(mo):
        h = months.setdefault(m, [0, 0]); sel = mo == m
        h[0] += int((z[sel] <= 1.2816).sum()); h[1] += int(sel.sum())

order = ['all US', 'index funds', 'big names', 'stocks over $20', 'stocks $5-20', 'stocks under $5', 'other ETFs']
print(f"{'group':16} {'series':>6} {'days':>9} {'1.28':>6} {'2.3':>6} {'75-85%':>7} {'week':>6} "
      f"{'p80':>5} {'p95':>5} {'avg':>6} {'yday':>6} {'turn':>6}")
for gname in order:
    a = groups.get(gname)
    if not a: continue
    z = np.concatenate(a['z']); w = np.concatenate(a['w']); per = np.array(a['per'])
    f = lambda k: a[k][0] / a[k][1] if a[k][1] else float('nan')
    print(f"{gname:16} {len(per):6d} {len(z):9d} {np.mean(z <= 1.2816):6.1%} {np.mean(z <= 2.3):6.1%} "
          f"{np.mean((per >= .75) & (per <= .85)):7.1%} {np.mean(w <= 1.2816):6.1%} "
          f"{np.quantile(z, .8):5.2f} {np.quantile(z, .95):5.2f} {f('d1'):6.1%} {f('d2'):6.1%} {f('d3'):6.1%}")
print('\nmonth by month, all US at 1.28:')
for m in sorted(months):
    h, n = months[m]
    if n > 50000: print(f'  {m}  {h / n:6.1%}  of {n}')
