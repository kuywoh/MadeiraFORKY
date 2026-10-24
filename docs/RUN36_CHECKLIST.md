# Run #36 verification checklist — Madeira 2.1.11

Goal: **name the owner of the wedged section mutex** — the one link the
FEX stamps never cover. Run #35 already pinned the victim side (wine
threads parked in `server_enter_uninterrupted_section` via
`NtAllocateVirtualMemory → allocate_virtual_memory` while holding FEX
shared locks); what it could not name is the thread that *holds*
`virtual_mutex` and never leaves. 2.1.11 closes exactly that.

This is a diagnostic-only build. `v2.1.11` = `2.1.10` + the section-owner
stamp. Nothing behavioural changed this run — a "fail" here still wins,
as long as the rows below are captured.

## What changed since #35

- **2.1.10** (`7b0ba1a`, first run here): census reads holder state under
  `thread_suspend` → read → `thread_resume`, so holders that reported
  `pc=0x0 run_state=0` in #35 get real stacks. Non-alert waits now say
  `WAITING-ON none` instead of being skipped.
- **2.1.11** (this build): `server_enter_uninterrupted_section` stamps the
  TEB (`0x1710/0x1718` outer, `0x1720/0x1728` nested) with the mutex
  address + CLOCK_MONOTONIC ms32 **after** `mutex_lock()` succeeds, and
  clears them before unlock. The census prints:
  `[census-hold] SECTION-OWNER teb=... tid=... mutex=0x... age=Nus rev=ml1240`

  Nonzero = this thread **owns** a section mutex right now. Waiters print
  nothing (they have not locked yet) — they are already visible as the
  parked pool.

## Before starting

- [ ] Sideload 2.1.11 and confirm the log head says `[build] v2.1.11`.
- [ ] JIT on (`[OK] JIT enabled!`), debugger detached.
- [ ] Log export starts **before** launching Studio.
- [ ] Same everything else: prefix, `madeira.cfg`, Studio build, device.
- [ ] One attempt per launch (greyed window does not clear — relaunch
      escapes it). Wait **≥ 5 minutes** at the spinner before exporting,
      so the stuck owner's `age=` grows big enough to be unmistakable.

## While greyed — the three blocks that decide everything

1. **`SECTION-OWNER` rows, swept repeatedly.** The culprit looks like:

       [census-hold] SECTION-OWNER teb=0x457e30000 tid=00XX mutex=0x... age=37us rev=ml1240

   Same `teb=`, same `mutex=`, `age=` climbing across sweeps. Check the
   mutex address against the parked pool: if the parked threads' backtrace
   ends in `allocate_virtual_memory` (virtual_mutex), the owner's
   `mutex=` should match — and `tid=` is our answer.
2. **`HOLDS fexlock` rows with stacks** (2.1.10's suspend read). These
   should no longer read `pc=0x0 run_state=0`; every holder now shows
   where it is parked or spinning. If `WAITING-ON none` prints, the
   holder is genuinely not blocked on anything the census can see.
3. **The RUN35 Phase-C blocks unchanged**: `[xp-api] slices` rate,
   `[srv-queues]` for the UI thread, `[srv-stuck]`, `[evt-life]`.

## Export & after

- [ ] Export the **full** log while the window is still greyed. A post-
      restart export throws away the only state that matters.
- [ ] Note: did the place load / grey out / the timestamp it stopped
      changing.
- [ ] One launch is enough: this run produces a name, not a probability.

If the log shows the owner (`SECTION-OWNER` + a matching parked pool),
the actual behavioural fix (2.1.12) targets exactly that thread's stuck
point instead of guessing.
