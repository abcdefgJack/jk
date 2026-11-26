# Collect two years of daily closes for every US-listed symbol plus the Shanghai, Shenzhen,
# Hong Kong and Tokyo code ranges, 20 symbols a request, politely paced; resumable.
import json, os, re, sys, time, urllib.request, urllib.error

DATA = sys.argv[1]
OUT = os.path.join(DATA, 'closes.jsonl')
DONE = os.path.join(DATA, 'done.txt')
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) jk'

def us():
    syms = []
    for name, col, test in (('nasdaqlisted.txt', 0, 3), ('otherlisted.txt', 0, 6)):
        for line in open(os.path.join(DATA, name), encoding='utf-8', errors='replace').read().splitlines()[1:]:
            f = line.split('|')
            if len(f) < 7 or line.startswith('File Creation'): continue
            if f[test] == 'Y': continue
            s = f[col].strip()
            if not re.fullmatch(r'[A-Z]{1,5}(\.[A-Z])?', s): continue
            syms.append(s.replace('.', '-'))
    return sorted(set(syms))

def ranged():
    r = []
    r += ['%06d.SS' % i for i in list(range(600000, 606000)) + list(range(688000, 690000))]
    r += ['%06d.SZ' % i for i in list(range(1, 4000)) + list(range(300001, 302000))]
    r += ['%04d.HK' % i for i in range(1, 10000)]
    r += ['%04d.T' % i for i in range(1300, 10000)]
    return r

def fetch(batch):
    url = 'https://query1.finance.yahoo.com/v8/finance/spark?symbols=' + ','.join(batch) + '&range=2y&interval=1d'
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            if e.code == 404: return {}
            wait = 30 * (attempt + 1) if e.code == 429 else 5 * (attempt + 1)
        except Exception:
            wait = 5 * (attempt + 1)
        time.sleep(wait)
    raise RuntimeError('gave up on ' + batch[0])

def main():
    allsyms = us() + ranged()
    done = set(open(DONE).read().split()) if os.path.exists(DONE) else set()
    batches = [allsyms[i:i + 20] for i in range(0, len(allsyms), 20)]
    todo = [b for b in batches if b[0] not in done]
    print(f'{len(allsyms)} symbols, {len(batches)} batches, {len(todo)} to go', flush=True)
    got = 0
    from concurrent.futures import ThreadPoolExecutor
    def job(b):
        d = fetch(b); time.sleep(1.0); return b, d
    with open(OUT, 'a', encoding='utf-8') as out, open(DONE, 'a') as dn, ThreadPoolExecutor(4) as ex:
        for i, (b, d) in enumerate(ex.map(job, todo)):
            for s, v in (d or {}).items():
                c = v.get('close') or []
                t = v.get('timestamp') or []
                if len(c) >= 60:
                    out.write(json.dumps({'s': s, 't': t, 'c': c}) + chr(10)); got += 1
            out.flush(); dn.write(b[0] + chr(10)); dn.flush()
            if i % 50 == 0: print(f'{i}/{len(todo)} batches, {got} series', flush=True)
    print(f'done: {got} new series', flush=True)

main()
