#!/usr/bin/env python3
# Copyright 2026 125hz.  GPL-3.0-or-later, like the rest of this repository.
"""The FEX CALL/RET prediction stack's size and guard window agree, everywhere (FEX submodule).

ml1250 halved CALLRET_STACK_SIZE from 16MB to 8MB. That only works because the guard
window is ABSOLUTE -- BranchOps.cpp pins sp to [base+2MB, base+6MB) with immediates and
resets it to base+4MB, so nothing above base+6MB was ever touched and the top half of the
16MB reservation was pure address space. The 8MB was not spare: Studio exhausts the 2GB
FEX host arena (the largest free hole on a 17GB no-EVM device) at ~45s, and each guest
thread claims 16MB of it for this stack -- 27 of them were 432MB.

The danger this check exists for: CALLRET_STACK_SIZE is a plain constant, but the code
that *enforces* the window is emitted as machine-code immediates. Change the constant
alone and the JIT keeps bounding sp to a window that no longer relates to the allocation;
change the immediates alone and the same happens the other way. Neither is a compile
error, and the failure shows up much later as a SIGSEGV writing a return address into the
arena (or as [CALLRET_OOB] resets on every block).

Checks, all from source text -- no compiler, no FEX build:
  * CALLRET_STACK_SIZE is at most 8MB (the per-thread budget on a 2GB arena), and the
    three named offsets are still consistent with it: default == centre of the window,
    window inside the reservation, window a power of two;
  * every CALL/RET guard in BranchOps.cpp is the SAME pair (low bound, default, shift),
    and that pair equals the header's LIVE_OFFSET / DEFAULT_OFFSET / log2(LIVE_SIZE);
  * Dispatcher.cpp's whole-allocation guard shifts by log2(CALLRET_STACK_SIZE), because it
    is the check that keeps the callback sentinel push inside the allocation;
  * no site still derives the default sp as "SIZE / 4" -- that expression silently means
    2MB at 8MB, which is the bottom of the guard window instead of its centre;
  * the frontend's decoded-buffer claim stays at or below 0x4000 instructions AND the
    decode loop has the per-instruction bound that makes a buffer that small safe
    (the FinalInstruction check only runs at a block terminator).
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
fex = root / 'FEX'
state = fex / 'FEXCore/include/FEXCore/Debug/InternalThreadState.h'
branchops = fex / 'FEXCore/Source/Interface/Core/JIT/BranchOps.cpp'
dispatcher = fex / 'FEXCore/Source/Interface/Core/Dispatcher/Dispatcher.cpp'
frontend_h = fex / 'FEXCore/Source/Interface/Core/Frontend.h'
frontend_cpp = fex / 'FEXCore/Source/Interface/Core/Frontend.cpp'
callret = fex / 'Source/Windows/Common/CallRetStack.h'
core = fex / 'FEXCore/Source/Interface/Core/Core.cpp'
lin = fex / 'Source/Tools/LinuxEmulation/LinuxSyscalls/ThreadManager.h'

failures = []


def check(cond, what):
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures.append(what)


missing = [str(p.relative_to(root)) for p in (state, branchops, dispatcher, frontend_h, frontend_cpp, callret, core, lin)
           if not p.exists()]
if missing:
    print('FAIL: FEX submodule not checked out: ' + ', '.join(missing))
    sys.exit(1)

state_text = state.read_text(encoding='utf-8', errors='replace')
branch_text = branchops.read_text(encoding='utf-8', errors='replace')
disp_text = dispatcher.read_text(encoding='utf-8', errors='replace')
fh_text = frontend_h.read_text(encoding='utf-8', errors='replace')
fc_text = frontend_cpp.read_text(encoding='utf-8', errors='replace')
cr_text = callret.read_text(encoding='utf-8', errors='replace')
core_text = core.read_text(encoding='utf-8', errors='replace')
lin_text = lin.read_text(encoding='utf-8', errors='replace')


MB = 1024 * 1024

# The pin decides which geometry is the correct one. 2.1.14 pinned FEX back to the 2.1.12
# emulator, which predates ml1250 -- there CALLRET_STACK_SIZE is 16MB by design and the
# offsets are SIZE/4-derived, so the assertions below describe a stack this tree does not
# have. Skip loudly, before any assertion can print, rather than pass or fail: a pin that
# DOES carry ml1250 is still checked in full, and the printed reason names the shape so a
# silent pass is impossible.
_pinned = re.search(r'CALLRET_STACK_SIZE\s*\{\s*(0x[0-9a-fA-F]+|\d+)\s*\}', state_text)
if _pinned and int(_pinned.group(1), 0) > 8 * MB:
    print(f'SKIP: FEX is pinned before ml1250 (CALLRET_STACK_SIZE is {int(_pinned.group(1), 0) >> 20}MB); '
          'the 8MB geometry and its per-instruction decode bound apply only to a FEX that carries it')
    sys.exit(0)


def const(text, name, where):
    m = re.search(re.escape(name) + r'\s*\{\s*(0x[0-9a-fA-F]+|\d+)\s*\}', text)
    if not m:
        check(False, f'{where}: {name} is declared as a braced integer constant')
        return None
    return int(m.group(1), 0)


size = const(state_text, 'CALLRET_STACK_SIZE', 'InternalThreadState.h')
default = const(state_text, 'CALLRET_DEFAULT_OFFSET', 'InternalThreadState.h')
low = const(state_text, 'CALLRET_LIVE_OFFSET', 'InternalThreadState.h')
win = const(state_text, 'CALLRET_LIVE_SIZE', 'InternalThreadState.h')

if size is not None:
    # 16MB per guest thread is what exhausted the arena (27 stacks = 432MB of 2048MB).
    check(size <= 8 * MB, f'CALLRET_STACK_SIZE is {size >> 20}MB (budget: at most 8MB per guest thread)')
    check(size >= 1 * MB, f'CALLRET_STACK_SIZE is {size >> 20}MB (a floor, so a typo cannot collapse the stack)')
    check((size & (size - 1)) == 0, 'CALLRET_STACK_SIZE is a power of two (Dispatcher.cpp shifts by its log2)')

if None not in (size, default, low, win):
    check(win > 0 and (win & (win - 1)) == 0, f'the guard window is {win >> 20}MB, a power of two (BranchOps shifts by its log2)')
    check(low + win <= size,
          f'the guard window [{(low) >> 20}MB,{(low + win) >> 20}MB) fits inside the {size >> 20}MB reservation')
    check(default == low + win // 2,
          f'the default sp is the centre of the window ({default >> 20}MB == {(low + win // 2) >> 20}MB)')
    check(low < default < low + win, 'the default sp lies strictly inside the guard window')
    # The predictor grows down from the default: it needs the window half below it.
    check(default - low >= win // 2, 'at least half the window is reachable by pushes below the default sp')

# ---------------------------------------------------------------- BranchOps guards
# Every CALL push / RET pop guard is: load callret_sp_base; add <low>; sub; lsr <shift>;
# on failure load base and add <default>. Collect them and require one shape.
guards = []
for m in re.finditer(r'State\.callret_sp_base\)\)?;\s*add\(ARMEmitter::Size::i64Bit, TMP1, TMP1, (0x[0-9a-fA-F]+)\);'
                     r'[\s\S]*?lsr\(ARMEmitter::Size::i64Bit, TMP1, TMP1, (\d+)\);'
                     r'[\s\S]*?add\(ARMEmitter::Size::i64Bit, REG_CALLRET_SP, REG_CALLRET_SP, (0x[0-9a-fA-F]+)\);',
                     branch_text):
    guards.append((int(m.group(1), 0), int(m.group(2), 10), int(m.group(3), 0)))

check(len(guards) >= 2, f'BranchOps.cpp emits the CALL/RET guard at every push and pop site ({len(guards)} found)')
check(len(set(guards)) == 1, 'every CALL/RET guard in BranchOps.cpp uses the same (low, shift, default) triple'
      + ('' if len(set(guards)) <= 1 else f': {sorted(set(guards))}'))
if guards and None not in (low, win, default):
    g_low, g_shift, g_def = guards[0]
    check(g_low == low, f'BranchOps bounds sp at base+{g_low >> 20}MB, the header\'s LIVE_OFFSET')
    check(g_def == default, f'BranchOps resets sp to base+{g_def >> 20}MB, the header\'s DEFAULT_OFFSET')
    check(g_shift == win.bit_length() - 1,
          f'BranchOps shifts by {g_shift} == log2(LIVE_SIZE) ({(win).bit_length() - 1}), so the window is exactly LIVE_SIZE wide')

# --------------------------------------------------------------- Dispatcher guard
# The callback sentinel push tests the WHOLE allocation, so this shift tracks the size,
# not the window. At 8MB a >>24 test would let a drifted sp run 8..16MB, which is past the
# reservation, before it ever reset.
disp = re.search(r'State\.callret_sp_base\)\)?;\s*sub\(ARMEmitter::Size::i64Bit, TMP1, REG_CALLRET_SP, TMP1\);'
                 r'[\s\S]*?lsr\(ARMEmitter::Size::i64Bit, TMP1, TMP1, (\d+)\);', disp_text)
if not disp:
    check(False, 'Dispatcher.cpp still has the callback call-ret guard before its sentinel push')
elif size is not None:
    check(int(disp.group(1), 10) == size.bit_length() - 1,
          f'Dispatcher.cpp guards the whole allocation with >>{disp.group(1)} == log2(CALLRET_STACK_SIZE) '
          f'(expect {(size).bit_length() - 1})')

# ------------------------------------------------------ no "SIZE / 4" default sp left
for text, name in ((core_text, 'Core.cpp'), (cr_text, 'CallRetStack.h'), (state_text, 'InternalThreadState.h'),
                   (lin_text, 'ThreadManager.h (Linux tooling, same header)')):
    bad = re.findall(r'CALLRET_STACK_SIZE\s*/\s*4', text)
    check(not bad, f'{name}: the default sp is not derived as CALLRET_STACK_SIZE / 4 '
                   f'({len(bad)} occurrence(s) left; at 8MB that is the window floor, not its centre)')
check('CALLRET_DEFAULT_OFFSET' in cr_text, 'CallRetStack.h places the initial sp at CALLRET_DEFAULT_OFFSET')

# ------------------------------------------------------------------ frontend claim
fbuf = re.search(r'DefaultDecodedBufferSize\s*=\s*(0x[0-9a-fA-F]+|\d+);', fh_text)
if not fbuf:
    check(False, 'Frontend.h still declares DefaultDecodedBufferSize')
else:
    n = int(fbuf.group(1), 0)
    # sizeof(DecodedInst) * n is the per-thread FEXMem_Frontend claim (8MB at 0x10000).
    check(n <= 0x4000, f'the decoded-instruction buffer is {n} (at most 0x4000 = a 2MB claim per guest thread)')
    check(n >= 0x1000, f'the decoded-instruction buffer is {n} (a floor, so a block is still worth compiling)')
    guard = re.search(r'while \(1\) \{\s*/\*.*?\*/\s*if \(DecodedSize >= DefaultDecodedBufferSize\) \{\s*break;\s*\}\s*'
                      r'InstructionSize = 0;', fc_text, re.S)
    check(guard is not None,
          'Frontend.cpp bounds DecodedSize per INSTRUCTION, before DecodeInstruction writes DecodedBuffer[DecodedSize] '
          '(the FinalInstruction check only runs at a block terminator)')
    final_check = fc_text.index('FinalInstruction = DecodedSize >= MaxInst')
    loop = fc_text.index('BlockIt->DecodedInstructions = &DecodedBuffer[BlockStartOffset]')
    check(guard is not None and loop < fc_text.index('if (DecodedSize >= DefaultDecodedBufferSize) {', loop) < final_check,
          'the per-instruction bound sits after DecodedBuffer is claimed and before the terminator-only check')

print('check-callret-geometry:', 'FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
