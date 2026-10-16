#!/usr/bin/env python3
# Minimal RV32IM interpreter for golden traces of the course testcases.
import sys

path = sys.argv[1]
maxinsn = int(sys.argv[2]) if len(sys.argv) > 2 else 1000000
trace_loads = "--ld" in sys.argv

mem = bytearray(1 << 28)
addr = 0
with open(path) as f:
    for line in f:
        line = line.split('#')[0].split('//')[0]
        for tok in line.split():
            if tok.startswith('@'):
                addr = int(tok[1:], 16)
            else:
                mem[addr] = int(tok, 16)
                addr += 1

REGS = [0] * 32
pc = 0
out = []

def sx(v, b):
    m = 1 << (b - 1)
    return (v & (m - 1)) - (v & m)

def load(addr, f3):
    if f3 == 0:  # lb
        return sx(mem[addr], 8) & 0xffffffff
    if f3 == 1:  # lh
        v = mem[addr] | (mem[addr + 1] << 8)
        return sx(v, 16) & 0xffffffff
    if f3 == 2:  # lw
        return mem[addr] | (mem[addr+1] << 8) | (mem[addr+2] << 16) | (mem[addr+3] << 24)
    if f3 == 4:
        return mem[addr]
    if f3 == 5:
        return mem[addr] | (mem[addr + 1] << 8)
    raise ValueError(f3)

def store(addr, f3, v):
    if f3 == 0:
        mem[addr] = v & 0xff
    elif f3 == 1:
        mem[addr] = v & 0xff
        mem[addr + 1] = (v >> 8) & 0xff
    elif f3 == 2:
        for i in range(4):
            mem[addr + i] = (v >> (8 * i)) & 0xff
    else:
        raise ValueError(f3)

import collections
hist=collections.Counter()
divlast=None
divlast_f3=0
pcs=[]
trs=[]
for _ in range(maxinsn):
    pcs.append(pc)
    if len(pcs)>30: pcs.pop(0)
    insn = mem[pc] | (mem[pc+1] << 8) | (mem[pc+2] << 16) | (mem[pc+3] << 24)
    op = insn & 0x7f
    hist[op]+=1
    if op==0x33 and ((insn>>25)&0x7f)==1:
        hist[0x3300+((insn>>12)&7)]+=1
        if f3 in (4,5,6,7):
            key=(a,b,(f3 in (4,6)))
            if divlast is not None and divlast==key and (f3 in (4,6)) != (divlast_f3 in (4,6)):
                hist['pair']+=1
            divlast=key; divlast_f3=f3
    rd = (insn >> 7) & 0x1f
    f3 = (insn >> 12) & 7
    rs1 = (insn >> 15) & 0x1f
    rs2 = (insn >> 20) & 0x1f
    f7 = (insn >> 25) & 0x7f
    imm_i = sx(insn >> 20, 12)
    imm_s = sx(((insn >> 25) << 5) | ((insn >> 7) & 0x1f), 12)
    imm_b = sx(((insn >> 31) << 12) | (((insn >> 7) & 1) << 11) | (((insn >> 25) & 0x3f) << 5) | (((insn >> 8) & 0xf) << 1), 13)
    imm_u = insn & 0xfffff000
    imm_j = sx(((insn >> 31) << 20) | (((insn >> 12) & 0xff) << 12) | (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3ff) << 1), 21)
    nxt = pc + 4
    a, b = REGS[rs1], REGS[rs2]
    if pc == 0x23c:
        trs.append(f"TR a5={REGS[15]:x} a1={REGS[11]:x} a2={REGS[12]:x} a0={REGS[10]:x} mem0={int.from_bytes(mem[0x5c8:0x5cc],'little'):x}")
        if len(trs)>2000: trs.pop(0)
    if op == 0x37:
        REGS[rd] = imm_u
    elif op == 0x17:
        REGS[rd] = (pc + imm_u) & 0xffffffff
    elif op == 0x6f:
        REGS[rd] = nxt
        nxt = (pc + imm_j) & 0xffffffff
    elif op == 0x67:
        REGS[rd] = nxt
        nxt = (a + imm_i) & 0xfffffffe
    elif op == 0x63:
        c = {0: a == b, 1: a != b, 4: sx(a,32) < sx(b,32), 5: sx(a,32) >= sx(b,32),
             6: a < b, 7: a >= b}[f3]
        if c:
            nxt = (pc + imm_b) & 0xffffffff
    elif op == 0x03:
        la = (a + imm_i) & 0xffffffff
        if la >= 0x80000000:
            v = 0
        else:
            try:
                v = load(la, f3)
            except IndexError:
                print(f"BADLOAD pc={pc:08x} addr={la:08x} a0={REGS[10]:x} sp={REGS[2]:x}")
                raise SystemExit(1)
        if f3 in (0, 1, 2, 4, 5) and rd != 0:
            out.append(f"LD pc={pc:08x} addr={(a+imm_i)&0xffffffff:08x} f3={f3} val={v:08x}")
        REGS[rd] = v
    elif op == 0x23:
        sa_ = (a + imm_s) & 0xffffffff
        if sa_ == 0x80000000:
            out.append("HIST "+" ".join(f"{k:x}:{v}" for k,v in sorted(hist.items()))+f"\nEXIT val={b & 0xffffffff:08x} pc={pc:08x}")
            break
        store(sa_, f3, b)
        out.append(f"ST pc={pc:08x} addr={sa_:08x} f3={f3} val={b & 0xffffffff:08x}")
    elif op == 0x13:
        sh = (insn >> 20) & 31
        REGS[rd] = {0: (a + imm_i) & 0xffffffff, 2: int(sx(a,32) < imm_i), 3: int(a < (imm_i & 0xffffffff)),
                    4: a ^ (imm_i & 0xffffffff), 6: a | (imm_i & 0xffffffff), 7: a & (imm_i & 0xffffffff),
                    1: (a << sh) & 0xffffffff, 5: (a >> sh) if f7 == 0 else (sx(a,32) >> sh)}[f3]
        REGS[rd] &= 0xffffffff
    elif op == 0x33:
        if f7 == 1:
            p = a * b
            ua, ub = a, b
            sa, sb = sx(a,32), sx(b,32)
            def tdiv(x, y):
                q = abs(x) // abs(y)
                return -q if (x < 0) != (y < 0) else q
            def trem(x, y):
                return x - tdiv(x, y) * y
            if f3 == 0: r = p & 0xffffffff
            elif f3 == 1: r = (sa*sb >> 32) & 0xffffffff
            elif f3 == 2: r = (sa*ub >> 32) & 0xffffffff
            elif f3 == 3: r = (ua*ub >> 32) & 0xffffffff
            elif f3 == 4: r = 0xffffffff if b == 0 else (-2**31 if (sa == -2**31 and sb == -1) else tdiv(sa, sb))
            elif f3 == 5: r = 0xffffffff if b == 0 else ua // ub
            elif f3 == 6: r = a if b == 0 else (0 if (sa == -2**31 and sb == -1) else trem(sa, sb))
            else: r = a if b == 0 else ua % ub
            REGS[rd] = r & 0xffffffff
        else:
            sh = b & 31
            r = {0: (a + b if f7 == 0 else a - b), 1: (a << sh), 2: int(sx(a,32) < sx(b,32)), 3: int(a < b),
                 4: a ^ b, 5: (a >> sh) if f7 == 0 else (sx(a,32) >> sh), 6: a | b, 7: a & b}[f3]
            REGS[rd] = r & 0xffffffff
    else:
        raise ValueError(f"bad op {op:x} at {pc:x}")
    if pc in (0xd4,0xd8,0xdc,0xe0,0xe4,0xe8,0xec,0xf0,0xf4,0xf8,0x100,0x104):
        trs.append(f"T pc={pc:x} a5={REGS[15]:x} s0={REGS[8]:x} a4={REGS[14]:x} s3={REGS[19]:x} a3={REGS[13]:x}")
        if len(trs)>14: trs.pop(0)
    REGS[0] = 0
    if nxt == pc:
        out.append(f"HALT pc={pc:08x}")
        break
    pc = nxt
else:
    out.append("HIST "+" ".join(f"{k:x}:{v}" for k,v in sorted(hist.items()))+f"\nTIMEOUT pc={pc:08x} a0={REGS[10]:08x} sp={REGS[2]:08x} last=" + " ".join(f"{p:x}" for p in pcs[-14:]) + " || " + " | ".join(trs[-6:]))

if trace_loads:
    print("\n".join(out))
else:
    print("\n".join([o for o in out if o.startswith(("EXIT", "HALT", "TIMEOUT", "HIST"))]))
