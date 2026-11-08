#!/usr/bin/env python3
"""Run every program on a set of D81 images in the system simulator.

usage: intro_batch.py <outdir> <frames> <jobs> <disk.d81>[:NAME,NAME...] ...

For each program: boot the ROM with the disk mounted, type RUN "NAME" at
frame 300, press space at frame 1000 (past most title screens) and save a
frame every 250 frames.  Writes <outdir>/<disk>/<name>/f*.png, log.txt and
a contact sheet <outdir>/index.html.

Programs whose final.png already exists are skipped, so an interrupted run
can be restarted.  Set TB_LIMIT_DAY / TB_LIMIT_NIGHT to cap how many tb.exe
processes may run on the machine at once (all of them, not just this
batch's); night is 00:01-07:00.  A file <outdir>/limit holding a number
overrides both.
"""
import os, sys, subprocess, concurrent.futures, html, re, threading, time, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TB = os.environ.get('TB') or os.path.join(ROOT, 'sim', 'system', 'build', 'tb.exe')
ROM = os.path.join(ROOT, 'roms', 'mega65_920423.bin')
sys.path.insert(0, os.path.join(ROOT, 'scripts'))


def d81_programs(path):
    d = open(path, 'rb').read()
    out = []
    t, s = 40, 3
    seen = set()
    while t and (t, s) not in seen:
        seen.add((t, s))
        off = ((t - 1) * 40 + s) * 256
        blk = d[off:off + 256]
        for i in range(8):
            e = blk[i * 32:(i + 1) * 32]
            if (e[2] & 7) != 2:
                continue
            name = e[5:21].split(b'\xa0')[0]
            ft, fs = e[3], e[4]
            if ft == 0:
                continue
            o = ((ft - 1) * 40 + fs) * 256
            la = d[o + 2] | d[o + 3] << 8
            out.append((name, la))
        t, s = blk[0], blk[1]
    return out


def petscii_to_typed(name):
    s = ''
    for c in name:
        if 0x41 <= c <= 0x5A:
            s += chr(c + 32)        # unshifted letters
        elif 0x20 <= c < 0x40:
            s += chr(c)
        else:
            return None
    return s


_gate = threading.Lock()
_outroot = '.'


def _limit():
    try:
        return int(open(os.path.join(_outroot, 'limit')).read().strip())
    except Exception:
        pass
    now = datetime.datetime.now().time()
    night = datetime.time(0, 1) <= now < datetime.time(7, 0)
    return int(os.environ.get('TB_LIMIT_NIGHT' if night else 'TB_LIMIT_DAY', '1000'))


def _tb_count():
    try:
        out = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq tb.exe', '/NH'],
                             capture_output=True, text=True).stdout
        return sum(1 for l in out.splitlines() if l.lower().startswith('tb.exe'))
    except Exception:
        return 0


def _start(cmd, **kw):
    # wait for a free slot under the machine-wide limit, then start
    while True:
        with _gate:
            if _tb_count() < _limit():
                p = subprocess.Popen(cmd, **kw)
                time.sleep(2)   # let tasklist see it before the next check
                return p
        time.sleep(15)


def run_one(job):
    disk, name, typed, outdir, frames = job
    if os.path.exists(os.path.join(outdir, 'final.png')):
        return outdir
    os.makedirs(outdir, exist_ok=True)
    keys = os.path.join(outdir, 'k.txt')
    bs = chr(92)
    with open(keys, 'w', newline='\n') as f:
        f.write('300 run "%s"%sr\n' % (typed, bs))
        f.write('1000  \n')
    log = os.path.join(outdir, 'log.txt')
    with open(log, 'w') as lf:
        _start([TB, ROM, outdir, str(frames), '-d81', disk, '-keys', keys, '-shot', '250'],
               stdout=lf, stderr=subprocess.STDOUT).wait(timeout=4 * 3600)
    for fn in sorted(os.listdir(outdir)):
        if fn.endswith('.ppm'):
            subprocess.run([sys.executable, '-I', os.path.join(ROOT, 'scripts', 'ppm2png.py'),
                            os.path.join(outdir, fn), os.path.join(outdir, fn[:-4] + '.png')])
            os.remove(os.path.join(outdir, fn))
    for fn in ('ram.bin',):
        p = os.path.join(outdir, fn)
        if os.path.exists(p):
            os.remove(p)
    return outdir


def main():
    global _outroot
    outroot, frames, jobs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    _outroot = outroot
    work = []
    for arg in sys.argv[4:]:
        disk, _, only = arg.partition(':')
        want = set(only.split(',')) if only else None
        dname = os.path.splitext(os.path.basename(disk))[0]
        for name, la in d81_programs(disk):
            typed = petscii_to_typed(name)
            if typed is None or la not in (0x2001, 0x0801) or b'UTOBOOT.C65' in name:
                continue
            if want and typed.upper() not in want:
                continue
            safe = re.sub(r'[^A-Za-z0-9]+', '_', typed).strip('_')
            work.append((disk, name, typed, os.path.join(outroot, dname, safe), frames))
    print('%d programs' % len(work), flush=True)
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        for d in ex.map(run_one, work):
            print('done', d, flush=True)
    # contact sheet
    rows = []
    for disk, name, typed, od, _ in work:
        imgs = sorted(f for f in os.listdir(od) if f.endswith('.png'))
        cells = ''.join('<img src="%s" width="240">' % html.escape(os.path.relpath(os.path.join(od, f), outroot).replace(os.sep, '/')) for f in imgs)
        rows.append('<tr><td>%s<br>%s</td><td>%s</td></tr>' % (html.escape(os.path.basename(os.path.dirname(od))), html.escape(typed.upper()), cells))
    with open(os.path.join(outroot, 'index.html'), 'w') as f:
        f.write('<html><body><table>%s</table></body></html>' % ''.join(rows))


if __name__ == '__main__':
    main()
