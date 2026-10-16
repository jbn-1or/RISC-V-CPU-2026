#!/usr/bin/env python3
# Directed unaligned-store + D$ eviction test: byte/half stores must survive a
# full-line refill from memory (catches unmasked AXI write addresses).
import sys
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mk_storeload.py')).read().split('prog = []')[0])  # reuse encoders

prog = []
labels = {}
pending = []

def E(w):
    prog.append(w & 0xffffffff)
    return len(prog) - 1

def L(name):
    labels[name] = len(prog)

def B(rs1, rs2, name):
    i = E(0)
    pending.append((i, rs1, rs2, name))

E(lui(t0, 0x40))              # t0 = 0x40000 scratch
E(lui(t1, 0x80))              # t1 = 0x80000 eviction area
E(lui(29, 0x80000))           # t4 = exit address
E(addi(a0, zero, 0))
# unaligned stores into word 0x40000
E(addi(a1, zero, 0x5A)); E(st(a1, t0, 1, 0))          # sb 0x5A, byte1
E(addi(a2, zero, 0x3C)); E(st(a2, t0, 3, 0))          # sb 0x3C, byte3
E(lui(a3, 0x12345)); E(addi(a3, a3, 0x6BB))
E(st(a3, t0, 2, 1))                                   # sh 0x56BB, bytes2-3
# evict all 256 sets: touch 0x80000 + 16*i
E(addi(t2, zero, 0)); E(addi(28, zero, 256))
L("evict")
E(st(t2, t1, 0, 2)); E(addi(t1, t1, 16)); E(addi(t2, t2, 1))
B(t2, 28, "evict")
# checks
E(ld(s0, t0, 0, 2))                                   # expect 0x56BB5A00
E(lui(s1, 0x56BB6)); E(addi(s1, s1, -0x600))
B(s0, s1, "fail")
E(ld(s2, t0, 1, 4)); E(addi(s3, zero, 0x5A))
B(s2, s3, "fail")
E(ld(s4, t0, 3, 4)); E(addi(s5, zero, 0x56))
B(s4, s5, "fail")
# success: exit(1)
E(addi(a0, zero, 1)); E(st(a0, 29, 0, 2))
E(jal(zero, 0))
# fail: exit(66)
L("fail")
E(addi(a0, zero, 66)); E(st(a0, 29, 0, 2))
E(jal(zero, 0))

for i, rs1, rs2, name in pending:
    prog[i] = bne(rs1, rs2, (labels[name] - i) * 4)

out = ["# unaligned store + eviction test", "@00000000"]
for w in prog:
    out.append(" ".join(f"{b:02x}" for b in w.to_bytes(4, 'little')))
open(sys.argv[1], "w").write("\n".join(out) + "\n")
print(f"words={len(prog)} fail_pc=0x{labels['fail']*4:x}")
