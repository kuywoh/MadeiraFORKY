#!/usr/bin/env python3
# Copyright 2026 125hz.  GPL-3.0-or-later, like the rest of this repository.
"""FEX's IR list overruns into a reserved slot and flushes the block, instead of past the claim.

The OpDispatcher IR arena (FEXMem_OpDispatcher) is a fixed claim per guest process, and on
iOS it cannot grow: run #36 exhausted the 2GB FEX host arena at ~45s with extended-va off
on a 17GB device. Two per-list claims of 8MB were part of that. Shrinking the claim is only
safe if three things stay true together, and none of them is a compile error when broken:

  1. an allocation that does not fit does NOT write past the claim. ml1251 answered with a
     trap (LOGMAN_THROW before it compiles to nothing in release) -- that stops corruption
     but kills the guest thread. ml1252 answers with a reserved slot at the tail of each
     list: claimed, never handed out linearly, valid in-arena offset so a NodeWrapper still
     round-trips, and the compile is discarded instead of compiled.
  2. GenerateIR stops a block before the claim runs out, at an instruction boundary, and
     FLUSHES the block there (ExitFunction at that guest address) instead of throwing the
     whole attempt away -- a shorter block, compiled, is the whole point of a smaller claim.
  3. the flush only happens in the LAST block of a multiblock. Earlier blocks may already
     jump to labels for blocks that would come later, so a partial multiblock has dangling
     targets and must be re-decoded smaller instead.

Checks, all from source text -- no compiler, no FEX build:
  * the compiled-out LOGMAN_THROW is gone from DataAllocate/ListAllocate, and the overrun
    path latches a flag and returns an address INSIDE the claim (Base + UsableSize), never
    past it and never a separate scratch object (32-bit offsets would not round-trip);
  * DataCheckSize/ListCheckSize are bounded by UsableSize, so the slot is not part of the
    linear allocation space, and UsableSize is the claim minus exactly one slot;
  * the latch is cleared when a buffer is reset, or the retry would trip over it again;
  * the claim is at most 2MB per list and the margin is small against it but large enough
    to hold a flush (ExitFunction plus block links);
  * GenerateIR checks the margin BEFORE dispatching the instruction, flushes only in the
    last block, and checks the latch after dispatch, after Finalize and after the pass
    manager -- any of those, unchecked, is garbage IR reaching the backend.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
fex = root / 'FEX'
list_h = fex / 'FEXCore/Source/Interface/IR/IntrusiveIRList.h'
emitter_h = fex / 'FEXCore/Source/Interface/IR/IREmitter.h'
emitter_cpp = fex / 'FEXCore/Source/Interface/IR/IREmitter.cpp'
core = fex / 'FEXCore/Source/Interface/Core/Core.cpp'

failures = []


def check(cond, what):
    print(('PASS: ' if cond else 'FAIL: ') + what)
    if not cond:
        failures.append(what)


missing = [str(p.relative_to(root)) for p in (list_h, emitter_h, emitter_cpp, core) if not p.exists()]
if missing:
    print('FAIL: FEX submodule not checked out: ' + ', '.join(missing))
    sys.exit(1)

list_text = list_h.read_text(encoding='utf-8', errors='replace')
em_h_text = emitter_h.read_text(encoding='utf-8', errors='replace')
em_cpp_text = emitter_cpp.read_text(encoding='utf-8', errors='replace')
core_text = core.read_text(encoding='utf-8', errors='replace')

MB = 1024 * 1024


def const(text, name, where):
    m = re.search(re.escape(name) + r'\s*\{\s*(0x[0-9a-fA-F]+|\d+)\s*\}', text)
    if not m:
        check(False, f'{where}: {name} is declared as a braced integer constant')
        return None
    return int(m.group(1), 0)


# ------------------------------------------------------------- the allocator itself
check('#include <atomic>' in list_text, 'IntrusiveIRList.h includes <atomic> (the overrun log is bounded per process)')
slot = const(list_text, 'OVERRUN_SLOT_SIZE', 'IntrusiveIRList.h')

check('LOGMAN_THROW_A_FMT(DataCheckSize' not in list_text and 'LOGMAN_THROW_A_FMT(ListCheckSize' not in list_text,
      'DataAllocate/ListAllocate no longer guard with LOGMAN_THROW (it compiles to (void)(pred) in release)')
check('OverrunReport' not in list_text,
      'the ml1251 noreturn OverrunReport trap is gone from the allocation path')
check('HasOverrun' in list_text and 'Overran = true;' in list_text,
      'an allocation that does not fit LATCHES a flag instead of aborting or writing past the claim')
check('ClearOverrun' in list_text and re.search(r'void ClearOverrun\(\)\s*\{\s*Overran = false;', list_text) is not None,
      'the latch can be cleared, so a retried compile starts clean')
check(re.search(r'void Reset\(\)\s*\{[^}]*Overran = false;', list_text) is not None,
      'Reset() clears the latch too (a fresh buffer must not inherit the previous attempt\'s overrun)')

bounds = re.findall(r'bool (Data|List)CheckSize\(size_t Size\) const \{\s*size_t NewOffset = \w+CurrentOffset \+ Size;\s*\n\s*return NewOffset <= (\w+);',
                    list_text)
check(sorted(b[0] for b in bounds) == ['Data', 'List'] and all(b[1] == 'UsableSize' for b in bounds),
      'both linear-allocation bounds are UsableSize, not the whole claim '
      f'(found {[(b[0], b[1]) for b in bounds]})')
check(re.search(r'UsableSize\s*\{\s*Size - OVERRUN_SLOT_SIZE\s*\}', list_text) is not None,
      'UsableSize is the claim minus exactly one OVERRUN_SLOT_SIZE slot')
check(re.search(r'return reinterpret_cast<void\*>\(Base \+ UsableSize\);', list_text) is not None,
      'an overrun lands at Base + UsableSize -- inside the claim and a valid in-arena offset '
      '(a separate scratch object would not survive the 32-bit NodeWrapper round-trip)')
check(re.search(r'if \(Overran \|\| !DataCheckSize\(Size\)\)', list_text) is not None and
      re.search(r'if \(Overran \|\| !ListCheckSize\(Size\)\)', list_text) is not None,
      'once the latch is set, every further allocation also goes to the slot (the attempt is garbage either way)')

# A request bigger than the slot cannot be placed inside the claim at all; that one case may
# stay fatal, but it must say so rather than writing past the claim.
check(re.search(r'if \(Want > OVERRUN_SLOT_SIZE\)', list_text) is not None,
      'a request larger than the slot is named and refused, not written past the claim')

# ------------------------------------------------------------------ emitter geometry
m = re.search(r'DualListData\s*\{\s*ThreadAllocator,\s*(\d+)\s*\*\s*1024\s*\*\s*1024\s*\}', em_h_text)
claim = None
if not m:
    check(False, 'IREmitter still claims its IR list with an explicit size (ThreadAllocator, N MB)')
else:
    claim = int(m.group(1)) * MB
    check(claim <= 2 * MB, f'the IR list claim is {claim // MB}MB per list (budget: at most 2MB, was 8MB)')
    check(claim >= 512 * 1024, f'the IR list claim is {claim // MB}MB per list (a floor, so a block still fits)')
    check((claim & (claim - 1)) == 0, 'the IR list claim is a power of two')

margin = const(em_h_text, 'IR_ONE_INSTRUCTION_MARGIN', 'IREmitter.h')
if margin is not None:
    check(0x2000 <= margin <= 0x20000,
          f'the per-instruction margin is 0x{margin:x} (small against the claim, and large enough to hold a flush)')
    if claim:
        check(claim - margin >= 4 * margin,
              f'a block still has real room before the margin: 0x{claim - margin:x} usable, margin 0x{margin:x}')

check('IROverran()' in em_h_text and 'HasOverrun()' in em_h_text,
      'IREmitter exposes the latch (IROverran) so GenerateIR can act on it')
check('IRClearOverran()' in em_h_text and 'ClearOverrun()' in em_h_text,
      'IREmitter exposes clearing the latch, for the discard-and-retry path')
check(re.search(r'void IREmitter::ResetWorkingList\(\)\s*\{\s*DualListData\.Reset\(\);', em_cpp_text) is not None,
      'IREmitter::ResetWorkingList resets the dual list, which is what clears the latch on a new claim')

# ------------------------------------------------------------------ GenerateIR wiring
check('IrBudgetHit' not in core_text,
      'no IrBudgetHit bookkeeping is left behind (the stop reason replaced it)')
if 'enum class IrStopReason' not in core_text:
    check(False, 'GenerateIR names why an attempt stopped (IrStopReason: Margin vs Overrun)')
else:
    check(re.search(r'enum class IrStopReason \{[^}]*Margin[^}]*Overrun[^}]*\}', core_text) is not None,
          'IrStopReason distinguishes the two discard causes: Margin and Overrun')

invoke = core_text.find('std::invoke(Fn, Thread->OpDispatcher, DecodedInfo);')
margin_check = core_text.find('IRRemaining() < IR::IREmitter::IR_ONE_INSTRUCTION_MARGIN')
if invoke < 0 or margin_check < 0:
    check(False, 'GenerateIR checks IRRemaining() against IR_ONE_INSTRUCTION_MARGIN before dispatching an instruction')
else:
    check(margin_check < invoke,
          'the margin is checked BEFORE std::invoke, so a block is only ever cut at an instruction boundary')

if margin_check < 0:
    check(False, 'the margin check can flush the block instead of discarding the attempt')
else:
    flush_set = core_text.find('IrFlushed = true;', margin_check)
    check(flush_set > 0 and flush_set - margin_check < 400,
          'reaching the margin in the last block sets IrFlushed (keep the prefix) instead of discarding it')
    guard = core_text.rfind('j + 1 == CodeBlocks->size()', margin_check, flush_set if flush_set > 0 else len(core_text))
    check(guard > 0,
          'the flush is limited to the LAST decoded block -- earlier blocks may jump to labels for '
          'later blocks, which a partial multiblock would leave dangling')

    flush_block = core_text.find('if (IrFlushed) {', flush_set if flush_set > 0 else margin_check)
    exit_at = core_text.find('Thread->OpDispatcher->ExitFunction', flush_block) if flush_block > 0 else -1
    check(flush_block > 0 and exit_at > flush_block and
          'Block.Entry + BlockInstructionsLength - GuestRIP' in core_text[exit_at:exit_at + 400],
          'the flush exits at the guest address of the instruction that did not fit (same shape as the NeedsBlockEnd path)')
    check('[ir-flush]' in core_text,
          'the flush is logged as [ir-flush] with its numbers')

check(re.search(r'if \(Thread->OpDispatcher->IROverran\(\)\) \[\[unlikely\]\]', core_text) is not None,
      'GenerateIR checks the latch right after dispatch, before the instruction can be counted or the block ended')
check('IrStop = IrStopReason::Overrun;' in core_text,
      'an overrun during dispatch discards the attempt (the nodes produced are garbage)')
check('ran out of IR while finalising' in core_text and
      'return DiscardAndRetry("finalize");' in core_text,
      'the finalizer\'s own allocations are checked, and the block is re-emitted smaller '
      '(it has no instruction boundary to stop at)')
check('ran out of IR in the pass manager' in core_text and
      'return DiscardAndRetry("pass-manager");' in core_text,
      'the pass manager\'s allocations are checked, and the block is re-emitted smaller '
      'rather than dropped, which would leave this RIP uncompilable')
check('-- dropping the block' not in core_text,
      'no path drops a block because the IR list ran out -- every one of them retries smaller')

check(core_text.count('IROverran()') >= 3,
      f'the latch is checked at every place IR is emitted (found {core_text.count("IROverran()")}, expect >= 3)')
check('[ir-overrun]' in core_text and 'rev=ml1252' in core_text,
      'the overrun is reported once with rev=ml1252, so a run can be attributed')

# The discard path is the same one the margin check used: halve, retry, and never recurse forever.
check('const uint64_t NextMax = StartMax / 2;' in core_text and
      'return GenerateIR(Thread, GuestRIP, ExtendedDebugInfo, NextMax);' in core_text,
      'the discard path re-decodes with half the instruction budget')
check(re.search(r'if \(StartMax > 1 && NextMax > 0\)', core_text) is not None,
      'the retry is bounded -- a 1-instruction compile is not split again')

if claim and margin:
    print(f'INFO: {claim >> 20}MB per list, {margin >> 10}KB margin, {slot >> 10}KB reserved slot per list'
          if slot else f'INFO: {claim >> 20}MB per list, {margin >> 10}KB margin')
    if slot:
        check(slot <= claim // 64,
              f'the reserved slot is 0x{slot:x} of a 0x{claim:x} claim (under 1/64, so it is not wasted room)')

print('check-ir-overflow:', 'FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
