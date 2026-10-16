#!/usr/bin/env python3
# Hand assembler for a tiny RV32IM directed test (store->load forwarding etc.)
import sys

def lui(rd, imm20):   return ((imm20 & 0xfffff) << 12) | (rd << 7) | 0x37
def addi(rd, rs1, imm): return ((imm & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x13
def st(rs2, rs1, imm, f3):
    imm &= 0xfff
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1f) << 7) | 0x23
def ld(rd, rs1, imm, f3): return ((imm & 0xfff) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x03
def bne(rs1, rs2, off):
    off &= 0x1fff
    return (((off >> 12) & 1) << 31) | (((off >> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) \
         | (1 << 12) | (((off >> 1) & 0xf) << 8) | (((off >> 11) & 1) << 7) | 0x63
def jal(rd, off):
    off &= 0x1fffff
    return (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3ff) << 21) | (((off >> 11) & 1) << 20) \
         | (((off >> 12) & 0xff) << 12) | (rd << 7) | 0x6f

# regs
zero,ra,sp,gp,tp,t0,t1,t2 = 0,1,2,3,4,5,6,7
s0,s1 = 8,9
a0,a1,a2,a3,a4,a5,a6,a7 = 10,11,12,13,14,15,16,17
s2,s3,s4,s5,s6,s7,s8 = 18,19,20,21,22,23,24

prog = []  # (label_or_None, word)
def E(w, label=None): prog.append((label, w & 0xffffffff))

# t0 = 0x40000 scratch
E(lui(t0, 0x40))
# a0 = pass flag
E(addi(a0, zero, 0))
# --- T1: SW -> LW full forward
E(lui(a1, 0x12345)); E(addi(a1, a1, 0x678))          # a1=0x12345678
E(st(a1, t0, 0, 2))                                  # sw a1,0(t0)
E(ld(a2, t0, 0, 2))                                  # lw a2,0(t0)
b1 = len(prog); E(0)                                 # bne a2,a1 -> fail
# --- T2: SB -> LBU byte 3 forward
E(addi(a3, zero, 0xAB))
E(st(a3, t0, 3, 0))                                  # sb a3,3(t0)
E(ld(a4, t0, 3, 4))                                  # lbu a4,3(t0)
b2 = len(prog); E(0)                                 # bne a4,a3
# --- T3: SH -> LHU at offset 2
E(lui(a5, 0x3)); E(addi(a5, a5, 0x456))              # 0x3456
E(st(a5, t0, 2, 1))                                  # sh a5,2(t0)
E(ld(a6, t0, 2, 5))                                  # lhu a6,2(t0)
b3 = len(prog); E(0)
# --- T4: SW word 1 -> LW (different word, same line)
E(lui(a7, 0xd)); E(addi(a7, a7, 0xdef))              # 0xdef
E(st(a7, t0, 4, 2))
E(ld(s0, t0, 4, 2))
b4 = len(prog); E(0)
# --- T5: two stores same addr: load sees newest
E(addi(s1, zero, 0x111)); E(st(s1, t0, 8, 2))
E(addi(s1, zero, 0x222)); E(st(s1, t0, 8, 2))
E(ld(s2, t0, 8, 2))
E(addi(s3, zero, 0x222))
b5 = len(prog); E(0)
# --- T6: SW then SB byte1 -> LBU byte1 (partial overlap)
E(lui(s4, 0x77777)); E(addi(s4, s4, 0x777))          # 0x77777777
E(st(s4, t0, 12, 2))
E(addi(s5, zero, 0x42))
E(st(s5, t0, 13, 0))
E(ld(s6, t0, 13, 4))                                 # expect 0x42
b6 = len(prog); E(0)
# T7: LW word (SW then SB byte 1) expect 0x77774277
E(ld(s7, t0, 12, 2))
E(lui(s8, 0x77774)); E(addi(s8, s8, 0x277))
b7 = len(prog); E(0)
# --- T8: SH byte0 then LW (partial overlap, different lanes)
E(lui(s9 := 25, 0x11111)); E(addi(25, 25, 0x111))    # s9=0x11111111
E(st(25, t0, 16, 2))                                 # sw s9,16(t0)
E(addi(26, zero, 0x55)); E(st(26, t0, 16, 1))        # sh 0x55,16(t0)
E(ld(27, t0, 16, 2))                                 # lw expect 0x11110055
E(lui(28, 0x11110)); E(addi(28, 28, 0x055))
b8 = len(prog); E(0)
# --- success path
E(addi(a0, zero, 1))
E(lui(t1, 0x80000))
E(st(a0, t1, 0, 2))                                  # exit(1)
loop = len(prog); E(jal(zero, 0), 'loop')            # halt loop (jal 0 -> self)
# --- fail path
fail = len(prog)
E(addi(a0, zero, 77))
E(lui(t1, 0x80000))
E(st(a0, t1, 0, 2))                                  # exit(77)
floop = len(prog); E(jal(zero, 0))                   # halt

# patch branches to fail
for bi in (b1, b2, b3, b4, b5, b6, b7, b8):
    off = (fail - bi) * 4
    word = prog[bi][1]
    rs1 = (word >> 15) & 0x1f
    rs2 = (word >> 20) & 0x1f
    prog[bi] = (prog[bi][0], bne(rs1, rs2, off))

# emit text format: @addr then hex bytes
out = []
out.append("# directed store/load forwarding test")
out.append("@00000000")
for _, w in prog:
    b = w.to_bytes(4, 'little')
    out.append(" ".join(f"{x:02x}" for x in b))
with open(sys.argv[1], "w") as f:
    f.write("\n".join(out) + "\n")
print(f"words={len(prog)} fail_pc=0x{fail*4:x} -> result 1 expected")
