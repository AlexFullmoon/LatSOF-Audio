#!/usr/bin/env python3
"""Minimal SOF trace decoder for the LatSOF 'FW-Trace' dump (no Linux needed).

  python3 -I tools/ldc_decode.py sof-cnl.ldc fwtrace.bin

fwtrace.bin = SRAM window 2 dump; log records start where the first non-zero
data begins (0x2000 on cAVS 1.8). Record = 20-byte header (uid, ids, timestamp(8), entry address)
followed by params_num 32-bit parameters; the text comes from the .ldc dictionary.
"""
import struct, sys
ldc = open(sys.argv[1], 'rb').read()
trace = open(sys.argv[2], 'rb').read()
base = struct.unpack_from('<I', ldc, 4)[0]
# dictionary data starts after the header; locate it from a known anchor: first entry with a plausible file name
hdr_size = None
for off in range(0x20, 0x400, 4):
    lvl, cls, pn, line, fl, tl = struct.unpack_from('<6I', ldc, off)
    if lvl < 8 and 0 < fl < 80 and 0 < tl < 400 and pn < 12 and ldc[off+24:off+24+fl].endswith(b'.c\0'):
        hdr_size = off; break
assert hdr_size is not None, "cannot find first dictionary entry"

def entry(addr):
    off = hdr_size + (addr - base)
    lvl, cls, pn, line, fl, tl = struct.unpack_from('<6I', ldc, off)
    f = ldc[off+24:off+24+fl].rstrip(b'\0').decode(errors='replace')
    t = ldc[off+24+fl:off+24+fl+tl].rstrip(b'\0').decode(errors='replace')
    return lvl, pn, f, line, t

pos = next((i for i in range(0, len(trace), 4) if any(trace[i:i+4])), None)
levels = {0: 'CRIT', 1: 'ERROR', 2: 'WARN', 3: 'INFO', 4: 'DEBUG', 5: 'VERBOSE'}
while pos is not None and pos + 20 <= len(trace):
    uid, ids, tlo, thi, addr = struct.unpack_from('<IIIII', trace, pos)
    if uid == 0 and addr == 0:
        break
    try:
        lvl, pn, f, line, t = entry(addr)
    except Exception:
        print(f'[bad record @0x{pos:x}: addr=0x{addr:08x}]'); break
    params = struct.unpack_from(f'<{pn}I', trace, pos + 20) if pn else ()
    try:
        txt = t % tuple(params) if pn else t
    except Exception:
        txt = t + ' ' + str(params)
    print(f'[{(tlo | thi << 32):>12}] {levels.get(lvl, lvl):5s} {f.split("/")[-1]}:{line}  {txt}')
    pos += 20 + 4 * pn
