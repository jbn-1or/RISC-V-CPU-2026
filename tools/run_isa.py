"""Reproducible, self-checking RV32IM smoke/edge-case audit (not a proof)."""
import argparse
import json
from pathlib import Path
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--exclude', nargs='*', default=[])
parser.add_argument('--tag', default='isa')
parser.add_argument('--sim', type=Path, required=True)
parser.add_argument('--out', type=Path, default=ROOT / 'build' / 'isa')
parser.add_argument('--latencies', nargs='+', type=int, default=[1, 10, 50])
args = parser.parse_args()
if any(latency < 1 or latency > 1000000 for latency in args.latencies):
    parser.error('latencies must be in 1..1000000')
OUT = args.out.resolve()
OUT.mkdir(parents=True, exist_ok=True)
MASK = 0xffffffff
words, checks = [], []


def emit(word):
    words.append(word & MASK)


def i(rd, rs, imm, f3=0, op=0x13):
    return (imm & 0xfff) << 20 | rs << 15 | f3 << 12 | rd << 7 | op


def r(rd, a, b, f3, f7=0):
    return f7 << 25 | b << 20 | a << 15 | f3 << 12 | rd << 7 | 0x33


def b(a, c, f3, off):
    off &= 0x1fff
    return ((off >> 12) << 31 | ((off >> 5) & 63) << 25 | c << 20
            | a << 15 | f3 << 12 | ((off >> 1) & 15) << 8
            | ((off >> 11) & 1) << 7 | 0x63)


def store(rs, base, off, f3):
    off &= 0xfff
    return ((off >> 5) << 25 | rs << 20 | base << 15 | f3 << 12
            | (off & 31) << 7 | 0x23)


def li(rd, value):
    value &= MASK
    emit(((value + 0x800) & 0xfffff000) | rd << 7 | 0x37)
    emit(i(rd, rd, value & 0xfff))


def fail_block(label):
    checks.append(label)
    li(10, len(checks))
    emit(0x80000f37)  # lui x30,0x80000
    emit(store(10, 30, 0, 2))
    emit(0x6f)  # jal x0,0: prevent falling through after exit


def expect(reg, value, label):
    li(8, value)
    emit(b(reg, 8, 0, 24))  # success skips the five-word failure block
    fail_block(label)


def signed(value):
    return value - (1 << 32) if value & (1 << 31) else value


def quotient(a, c):
    q = abs(a) // abs(c)
    return -q if (a < 0) != (c < 0) else q


rng = random.Random(20261024)
edges = [0, 1, 2, 31, 32, 0x7fffffff, 0x80000000, 0xfffffffe, MASK]
pairs = [(a, c) for a in edges for c in edges]
pairs += [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(100)]
for a, c in pairs:
    sa, sc, shift = signed(a), signed(c), c & 31
    q = MASK if c == 0 else quotient(sa, sc)
    rem = a if c == 0 else sa - q * sc
    ops = [
        ('ADD', 0, 0, a + c), ('SUB', 0, 32, a - c),
        ('SLL', 1, 0, a << shift), ('SLT', 2, 0, int(sa < sc)),
        ('SLTU', 3, 0, int(a < c)), ('XOR', 4, 0, a ^ c),
        ('SRL', 5, 0, a >> shift), ('SRA', 5, 32, sa >> shift),
        ('OR', 6, 0, a | c), ('AND', 7, 0, a & c),
        ('MUL', 0, 1, a * c), ('MULH', 1, 1, sa * sc >> 32),
        ('MULHSU', 2, 1, sa * c >> 32), ('MULHU', 3, 1, a * c >> 32),
        ('DIV', 4, 1, q), ('DIVU', 5, 1, MASK if c == 0 else a // c),
        ('REM', 6, 1, rem), ('REMU', 7, 1, a if c == 0 else a % c),
    ]
    li(5, a)
    li(6, c)
    for name, f3, f7, value in ops:
        if name in args.exclude:
            continue
        emit(r(7, 5, 6, f3, f7))
        expect(7, value, f'{name} a={a:08x} b={c:08x}')

for a in edges:
    li(5, a)
    for imm in [-2048, -1025, -33, -1, 0, 1, 31, 1024, 2047]:
        for name, f3, value in [
            ('ADDI', 0, a + imm), ('SLTI', 2, int(signed(a) < imm)),
            ('SLTIU', 3, int(a < (imm & MASK))), ('XORI', 4, a ^ (imm & MASK)),
            ('ORI', 6, a | (imm & MASK)), ('ANDI', 7, a & (imm & MASK)),
        ]:
            emit(i(7, 5, imm, f3))
            expect(7, value, f'{name} a={a:08x} imm={imm}')
    for sh in [0, 1, 15, 31]:
        for name, f3, imm, value in [
            ('SLLI', 1, sh, a << sh), ('SRLI', 5, sh, a >> sh),
            ('SRAI', 5, 0x400 | sh, signed(a) >> sh),
        ]:
            if name in args.exclude:
                continue
            emit(i(7, 5, imm, f3))
            expect(7, value, f'{name} a={a:08x} sh={sh}')

for a in edges:
    emit((a & 0xfffff000) | 7 << 7 | 0x37)
    expect(7, a & 0xfffff000, 'LUI')
    pc = len(words) * 4
    emit((a & 0xfffff000) | 7 << 7 | 0x17)
    expect(7, pc + (a & 0xfffff000), 'AUIPC')

for a, c in pairs[:81]:
    li(5, a)
    li(6, c)
    for name, f3, taken in [
        ('BEQ', 0, a == c), ('BNE', 1, a != c),
        ('BLT', 4, signed(a) < signed(c)), ('BGE', 5, signed(a) >= signed(c)),
        ('BLTU', 6, a < c), ('BGEU', 7, a >= c),
    ]:
        emit(i(7, 0, 0))
        emit(b(5, 6, f3, 8))
        emit(i(7, 0, 1))
        expect(7, int(not taken), f'{name} a={a:08x} b={c:08x}')

pc = len(words) * 4
emit(0x008003ef)  # jal x7,+8
emit(i(7, 0, 0))
expect(7, pc + 4, 'JAL link/redirect')
target = (len(words) + 4) * 4
li(7, target | 1)
pc = len(words) * 4
emit(i(7, 7, 0, 0, 0x67))  # JALR rd==rs1 and target bit 0 clearing
emit(i(7, 0, 0))
expect(7, pc + 4, 'JALR rd==rs1 / bit0 / link')
li(5, MASK)
emit(i(0, 5, 1))
expect(0, 0, 'x0 ignores writes')

for base in [0x40000, 0x0fffffc0]:
    li(20, base)
    emit(i(7, 20, 60, 2, 0x03))
    expect(7, 0, f'zero-initialized RAM at {base + 60:08x}')
    for value in edges + [rng.getrandbits(32) for _ in range(20)]:
        li(5, value)
        emit(store(5, 20, 0, 2))
        emit(i(7, 20, 0, 2, 0x03))
        expect(7, value, 'SW/LW')
        for offset in range(4):
            emit(store(5, 20, 4 + offset, 0))
            for name, f3, expected in [
                ('LB', 0, (value & 0x7f) - (value & 0x80)),
                ('LBU', 4, value & 0xff),
            ]:
                emit(i(7, 20, 4 + offset, f3, 0x03))
                expect(7, expected, f'SB/{name} lane={offset}')
        for offset in [0, 2]:
            emit(store(5, 20, 8 + offset, 1))
            for name, f3, expected in [
                ('LH', 1, (value & 0x7fff) - (value & 0x8000)),
                ('LHU', 5, value & 0xffff),
            ]:
                emit(i(7, 20, 8 + offset, f3, 0x03))
                expect(7, expected, f'SH/{name} lane={offset}')

# Force a cold-load-dependent taken branch while younger independent MUL/DIV
# results and stores are in flight. Recovery must preserve the previous x7
# mapping, suppress the wrong-path write, and quarantine killed producer tags.
for trial in range(96):
    li(20, 0x100000 + trial * 64)
    li(7, 0x13572468 ^ trial)
    li(10, 0x7fffffff)
    li(11, 3)
    emit(i(5, 20, 0, 2, 0x03))
    branch = len(words)
    emit(0)
    emit(r(7, 10, 11, trial % 8, 1))
    for delay in range(trial % 12):
        emit(i(12, 0, delay + 1))
    emit(store(7, 20, 0, 2))
    target = len(words)
    words[branch] = b(5, 0, 0, (target-branch)*4)
    expect(7, 0x13572468 ^ trial, f'flush preserves old mapping after M op {trial}')
    emit(i(6, 20, 0, 2, 0x03))
    expect(6, 0, f'flush kills speculative store {trial}')

li(10, 0)
emit(0x80000f37)
emit(store(10, 30, 0, 2))
emit(0x6f)
image = OUT / f'{args.tag}_audit.bin'
image.write_bytes(b''.join(w.to_bytes(4, 'little') for w in words))
(OUT / f'{args.tag}_checks.json').write_text(json.dumps(checks, indent=2) + '\n')
results = []
for latency in args.latencies:
    result = subprocess.run([str(args.sim.resolve()), str(image), '0',
                             '20000000', str(latency)], capture_output=True, text=True)
    entry = dict(latency=latency, returncode=result.returncode,
                 checks=len(checks), words=len(words), stdout=result.stdout, stderr=result.stderr)
    results.append(entry)
    print(json.dumps(entry), flush=True)
(OUT / f'{args.tag}_results.json').write_text(json.dumps(results, indent=2) + '\n')
raise SystemExit(any(r['returncode'] for r in results))
