#!/usr/bin/env python3
import hashlib, struct, sys
data = open(sys.argv[1], "rb").read()
ncmds = struct.unpack_from("<I", data, 16)[0]
lc_off = 32
sig_off = sig_size = None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, lc_off)
    if cmd == 0x1d:
        sig_off, sig_size = struct.unpack_from("<II", data, lc_off + 8)
        break
    lc_off += cmdsize
if sig_off is None:
    print("no LC_CODE_SIGNATURE"); sys.exit(2)
blob = data[sig_off:sig_off+sig_size]
def u32be(off): return struct.unpack_from(">I", blob, off)[0]
sb_count = u32be(8)
cd_rel = next(u32be(16+i*8) for i in range(sb_count) if u32be(12+i*8)==0)
cd = blob[cd_rel:]
hashOffset = struct.unpack_from(">I", cd, 16)[0]
n = struct.unpack_from(">I", cd, 28)[0]
ps = 1 << cd[39]
limit = struct.unpack_from(">I", cd, 32)[0]
print(f"nCodeSlots={n} pageSize={ps} codeLimit=0x{limit:x}")
mismatches = [(i, i*ps) for i in range(n)
              if cd[hashOffset+i*32:hashOffset+(i+1)*32] !=
                 hashlib.sha256(data[i*ps:min((i+1)*ps,limit)]).digest()]
print(f"{len(mismatches)}/{n} mismatches")
for i, off in mismatches[:5]:
    print(f"  page {i} @ 0x{off:08x}")
