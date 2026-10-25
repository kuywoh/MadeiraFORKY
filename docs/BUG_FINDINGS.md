# Madeira Studio bugs — findings log

Running notes on the Roblox Studio failures in Madeira (iOS). Append new runs;
do not rewrite history when a hypothesis dies — mark it dead and say why.

**Provenance tags** — keep them on every claim:

- **Verified** — read out of the code in this tree, with a `file:line`.
- **Observed** — a number or a row from a real device log (say which run).
- **Inferred** — a mechanism that fits the observations but is not proven.
- **Open** — not known. Leave it open rather than filling it in.

The failure that matters to the user is: **Studio boots, then `File > New` /
opening a `.rbxl` hangs at the spinner.** Everything below is either that bug,
or a bug introduced while chasing it.

---

## Run log

| Run | Build | What happened | Verdict |
|---|---|---|---|
| #30–#32 | 2.1.5, 2.1.6 | Place-load wedge at the spinner ([srv-stuck] pool, `[evt-life]` SET with `releases=0`) | Reported, not measured here |
| #33 | 2.1.7 (4) | `slices 0/s` on all 349 `[xp-api]` rows; CI green; `[srv-stuck]` still catching INF waits | **Healer never ran** — see Bug 1 |
| #34 | 2.1.8 (4) | Ran 67 s, ~1000% CPU, `slices` ~400k/s, `cum` 16.7M, Studio never reached first frame | **New regression** — see Bug 2 |
| #35 | 2.1.9 (4) | Slices normal (21/s, `cum` 3172 in 126 s) but Studio still stops at the splash; ~600–950% CPU from two spinning threads; 12 threads parked >60 s | **Bug 2 fixed, different blocker** — see Bug 4 |
| #36 | 2.1.12 (4) | Boots, no boot crash, Qt loop up, Studio logs its last line at ~21 s, then a FEX allocation fails at ~45 s, one thread dies holding the FEX shared lock, two threads spin, splash forever | **Bug 4 root cause found** — see Bug 5 |
| #37 | 2.1.13 (4) | Boot crash: Studio's main thread executes x64 bytes as ARM64 at +4 s, `c000001d` at `ucrtbase+0x63c10`; no arena-exhaustion rows at all | **New failure, not Bug 5** — see the #37 section |

#33 is second-hand (as reported); #34 and #35 were measured directly from the device logs.

---

## Bug 1 — the 2.1.7 slice healer was never compiled

**Verified.** `build/ntdll-unix/build.sh` resolves the `server` object of the
ntdll-unix library to `build/ntdll-unix/server_ios.c`, **not** the submodule's
`wine/dlls/ntdll/unix/server.c`. The 2.1.7 patch went into the submodule copy,
which this build does not compile.

**Consequence (mechanical, observed in #33):** the counters
`ios_xp_wait_slices` / `ios_xp_slice_wakes` (defined in
`wine/dlls/ntdll/unix/sync.c:2180`, since that file *is* compiled) had a
reporter in `server_ios.c:1282,1338` and **zero writers**. Reporter alive, no
writes ⇒ `slices 0/s` forever, regardless of what the waits were doing. CI
cannot catch this: the build is green and the counters "exist".

**Lesson.** Telemetry with a reader and no writer looks exactly like telemetry
that says "nothing happened". Before trusting a zero, prove the writer is in a
compiled translation unit.

`wine/dlls/ntdll/unix/server.c:820` still carries the broken 2.1.7 line
(`timeout_t slice = -2500000;`) as dead code. If the build ever stops
substituting `server_ios.c`, Bug 2 comes back.

---

## Bug 2 — 2.1.8's slice timeout was mis-encoded and spun the CPU

**Verified + arithmetic + observed in #34.** This is a *new* bug, not the old
wedge: it is why the app stopped booting at all.

### The encoding

`server_wait()` (`build/ntdll-unix/server_ios.c:2573`) passes its timeout to
`server_select()`, which forwards it verbatim as `req->timeout`; the server hands
it to `select_on()` (`wine/server/thread.c:2490`) and then
`add_timeout_user(abstime_to_timeout(when))` (`wine/server/thread.c:1681`).
That conversion is (`wine/server/file.h:152`):

```c
if (abstime > 0) return abstime;                       /* absolute */
return -abstime < monotonic_time ? 0 : abstime + monotonic_time;
```

So a negative value is not "a relative duration" — it is a duration **folded
against the monotonic clock**, which is exactly what the caller-relative path two
lines above the slice loop does (`abs_timeout -= now.QuadPart`).

| Value handed to `server_select()` | Server resolves it to | Result |
|---|---|---|
| `TIMEOUT_INFINITE` | no timer (guarded out by `!= TIMEOUT_INFINITE`) | parks forever |
| `-2500000` (2.1.8, bare) | `2 500 000 < monotonic_time` ⇒ `0` | **already expired** ⇒ instant `STATUS_TIMEOUT` |
| `-2500000 - now.QuadPart` (2.1.9) | valid future deadline | **exactly 250 ms** |

Arithmetic checked against the server's own conversion; `expires_in = 0.250 s`
for the folded form at any uptime, `deadline == now` for the bare form.

### What it did to the device (#34)

- `[xp-api] ... | slices 400267/s (empty 400267/s) cum 16672884 (wake 16672837)`
- `[srv-req] ... last 200000 requests in 0.5 s: req29=199976` (req29 = select)
- `[xp] ... cpu=955 (thr 955)` — every core saturated on an 8-core device
- `[wineserver-fd] iter=6400000`, `[srv-poll] iter=6400000`
- Log ends at 17:46:04 mid-stream, 67 s after launch: killed/force-quit, no clean
  exit, no first frame.

Every `INFINITE` wait became a µs-cadence re-select. That is a total-CPU
regression, and it explains "it won't even boot" completely.

**Fix (in tree, uncommitted):** `build/ntdll-unix/server_ios.c:2633` —
`slice = -2500000 - now.QuadPart`, recomputed each iteration.

**Lesson.** `slices` climbing is not a pass. The cadence is the measurement:
~4/s per parked thread is healthy; ~400k/s is a masked busy loop. `empty ≈
slices` is normal even when healthy, so the empty fraction proves nothing.

---

## Bug 3 — the actual place-load wedge (OPEN)

The original symptom, still unexplained: a pool of threads parked on `INFINITE`
waits whose events were signalled, yet whose waiters never released.

### How it presents (observed, user, #30–#34)

`File > New` or opening a `.rbxl` **greys the window out** and it stays that way
indefinitely; it never recovers, so a failed attempt can only be escaped by
relaunching the app. That is the signature of a *disabled owner window*: Windows
greys a window's controls while a modal or synchronous operation it owns is in
progress. Two shapes fit, and they lead to different code:

- **A — the UI thread is inside the blocking call** (place load / `CreateProcess`
  / COM) and that call never returns.
- **B — a modal was entered but its window never became visible**, so the app
  looks greyed with nothing on top; the load path may not be involved at all.

Not a crash and not a dead renderer: the process is alive and holding the CPU
(#34) while the window is disabled. Distinguish A from B with the `[srv-queues]`
readings in `docs/RUN35_CHECKLIST.md` (Phase C).

Do not design this as a rapid try-loop: each attempt costs an app restart, so
repeatability is measured in launches, not clicks.

### The signature, in the instrument's own vocabulary

`[srv-stuck]` prints, per handle (`build/wineserver/queue_ios.c:4456`):

```
raw_obj / raw_waiters      the WRAPPER's queue
sync_obj / sync_waiters    the real queue for Events and Semaphores
thread_wait                the thread's active server-side wait
LINKED / NOT-LINKED / NO-WAIT   does that wait actually reference this object?
```

`LINKED` + `sync_waiters=1` + `signaled=1` = a live waiter the server forgot to
release. `NO-WAIT` (`!thread->wait`, `wine/server/thread.c:1243`) = **the server
holds no wait at all** for a thread the client believes is blocked — a
client/server desync.

### What #34 actually showed

Every dumped stuck handle (tids `003c`, `0030`, `0038`, `0064`, `0060`, `0054`)
read `state=NO-WAIT`, `thread_wait=0x0`, `sync_waiters=0`, `signaled=0`, with
ages climbing 5.7 s → 55.7 s; and `[evt-life]` said the same objects were
`SET=0 ... NEVER SET BY ANYONE`.

So #34's stuck rows are **not** the lost-wake signature. They are either
legitimately-never-signalled startup events, or desync — the data cannot
separate them.

Two readings, and #34 cannot decide between them:

1. **Sampling artifact.** At a µs slice cadence, a thread is between selects a
   large fraction of the time, so `NO-WAIT` is what a random sample looks like.
2. **Real desync.** The client is blocked in the reply wait for a select the
   server already finished — the swallowed *reply*, not the swallowed wake.

**Discriminator for #35:** under a correct 250 ms cadence the in-wait window
dominates, so a genuinely waiting thread must dump `LINKED` with
`sync_waiters=1`. If stuck threads still read `NO-WAIT` at 250 ms cadence, the
desync is real and the next target is `wait_select_reply`, not the wait path.

### What the healer can and cannot do

**Inferred.** Re-issuing select makes the server re-evaluate object state, so a
swallowed wake is repaired within one slice. It cannot repair a swallowed
*reply*: that parks the client inside slice #0 with no way to re-issue. Expected
#35 outcomes are enumerated in `docs/RUN35_CHECKLIST.md`.

---

## Instrumentation map

| Tag | Answers | Tell / caveat |
|---|---|---|
| `[xp-api] ... slices/cum` | is the healer running, and at what cadence | rate, not the empty fraction; 4/s/thread = healthy |
| `[srv-req]` | which server requests dominate | `req29` (select) exploding = spin |
| `[xp] ... cpu=` | total CPU | the fastest boot-regression check; ~1000% = spin |
| `[wineserver-fd] iter=`, `[srv-poll] iter=` | main-loop churn | millions per minute = spin, not load |
| `[srv-stuck]` | a wait that outlived its threshold | needs LINKED / NO-WAIT, not just ages |
| `[evt-life]` | per-object op counts + verdict note | `SET>0` with `releases=0` is the bug; `SET=0` is not |
| `[evt-hist]` / `[evt-entry]` / `[evt-before]` / `[evt-after]` | op sequence around a signalled object | `[evt-after] matched=N` brackets the probe |
| `[srv-queues]`, `[srv-own]` | server queue/fd ownership | fd-cache and fifo ownership during teardown |
| `[thread-sample]`, `[thread-stacks]` | where threads actually are | `wait pc=` names the syscall; `cpu=%` spots a pinned thread |
| `[pool-freechk]` | JIT pool slice accounting | module lifetime, unrelated to waits |

`ios_srv_game_teb` gates the per-game accounting, so `[xp-t]` rows cover the game
process, not the whole session.

---

## Traps already paid for (do not re-derive these)

- **Wrapper vs sync queue.** Events/Semaphores are wrappers; waiters queue on
  `get_obj_sync(obj)`, never on the wrapper. Reading `raw_waiters` alone once
  produced a false "522 objects with no waiters" root cause — see the comment at
  `build/wineserver/queue_ios.c:4435`. Always read `sync_waiters` **and** the
  LINKED token.
- **Stale pointers/handles.** Object and handle values change every launch.
  Only pointers resolved from the stuck thread's own handle table in the same
  dump mean anything.
- **Zero counters.** See Bug 1: a reader with no writer is indistinguishable
  from "nothing happened".
- **CI green proves compilation, not behaviour.** #33 and #34 were both green.

## Known non-signals

- `[ERR] [no-footprint] pool applied=false` / pool stays jetsam-counted — present
  and harmless-looking in #34; separate issue.
- `[evt-life] ... <-- NEVER SET BY ANYONE` — legitimate for startup/shutdown
  events; not evidence of the wedge.
- `err:` lines from Wine (`mprotect_exec`, `init_syscall_frame`,
  `NtTerminateProcess`, `POOL_FREE`/`[pool-freechk] POISONED AT FREE`) — expected
  noise for this build.
- `[va-scan] ... iOS REFUSED A FREE ADDRESS` — address-space probing.

## Open questions

1. Who loses the wake (or the reply) at the in-process wineserver ↔ FEX
   boundary? No mechanism has been demonstrated yet; every candidate so far died
   on a measurement.
2. Does the same defect also swallow timeout replies? #35 answers this: if the
   place wedges while `cum` keeps climbing, yes.
3. Is `NO-WAIT` on stuck handles a sampling artifact or a real desync? #35
   discriminates it (see Bug 3).
4. Does `[no-footprint] pool applied=false` matter for Studio at all? Untested;
   do not fold it into the wedge investigation.

## Bug 4 — the splash stall is a lock deadlock, not an API gap (#35, 2.1.9)

**Observed.** Studio `0.743.0.7431133` under Wine 11.4 logs a clean startup
(version, GUAC, fast flags, Qt event loop at 15.6 s, reflection DB 8609 entries at
16.1 s) and then **stops with no error** — the Qt splash never gives way to the
main window. `[build] v2.1.9 (4)` is in the Madeira log, so the healer was
actually running.

**Observed — the healer itself is fine.** `slices 21/s (empty 21/s) cum 3172`
after 126 s, against `~400k/s` and `cum 16.7M` in #34. Bug 2 measures fixed: the
slice is parked, not re-selected in a µs loop.

**Observed — the CPU is going somewhere else.** Two threads sit at 100% duty on
the *same* host PC for the whole run:

```
[cpu-prof] 49.1% of running (duty 400/400) " RBX Worker G" hostPC=0x315411d2c
[cpu-prof] 49.1% of running (duty 400/400) ""               hostPC=0x315411d2c
```

Disassembled, that PC is an 8-byte exclusive-monitor loop — `ldaxr; cbnz back`
with `dmb ish` + `yield` — i.e. an unbounded acquire spin. The register dump
shows the word it is spinning on is another thread's **tagged TEB**
(`x9=0x457e00001` = own TEB|1 to install, `x11=0x457e30001` = current owner).
An owner word that never clears pins every acquirer at 100% and never lets them
block.

**Observed — the holder is not waiting on anything.** The existing census names
two threads holding the FEX shared lock, and neither has a state it could read:

```
[census-hold] idx=30 port=0xd50b teb=0x457e20000 tid=00b8 HOLDS fexlock @0x3710f0108 run_state=0 susp=0 pc=0x0 lr=0x0 sp=0x0 bt: 0 0 0 0 0 0 0 0
[census-hold] idx=18 port=0x5b03 teb=0x457ec0000 tid=0088 HOLDS fexlock @0x39a0f108 run_state=0 susp=0 pc=0x0 lr=0x0 sp=0x0 bt: 0 0 0 0 0 0 0 0
```

No `WAITING-ON` sub-line was printed for either, and `[waiters]` shows 12 threads
parked **INF for >60 s**. Studio's UI thread (`tid=0024`) never appears in either
list and `[srv-queues] tid=0024 … send_pend=0 post=0 recv_in_prog=0` says it is
not inside a server call — so it is blocked in userspace, behind this lock.

**Inferred (the branch this selects).** A lock whose owner word is a TEB that is
neither running-to-release nor parked-on-a-wake = a **leaked or never-released
lock**, the same class the `[lock-reap]` path already repairs for *dead* holders.
This is not a lost wake, and slicing INFINITE waits cannot help: the wait that
would fix it is an ordinary user-mode lock acquisition.

**Gap in the instrument (ml1132).** `thread_get_state()` fails on a thread that
is running on another CPU, so the census printed `pc=0x0` + an all-zero backtrace
for exactly the threads whose stack would name the stuck code, and the missing
`WAITING-ON` line could not distinguish "not parked" from "lookup failed".
2.1.10 suspends the holder for the duration of the read and says
`WAITING-ON none` explicitly.

**Open.** Whether the leaked owner word is a dead thread's TEB (reapable) or a
live thread stuck inside the lock — run #36's holder stack answers it.

## Bug 5 — the 2GB FEX host arena is what wedges Studio (#36, 2.1.12)

**Observed — the device has 17 GB of address space, and that is permanent.**

```
[device] address-map=[0x1026bc000,0x458000000) 17GB increased-memory=0 extended-va=0
[va-profile] ml749 post-limit TASK_VM_INFO.max_address=0x458000000 (17.4 GB)
```

`increased-memory-limit` is the *resident* (jetsam) cap and was never hit — the run peaked
at 2,664 MB with 5,098 MB available and was not killed. The binding limit is
`extended-virtual-addressing`, which the sideload profile does not carry (and cannot: it
is not granted to free/paid personal teams). So the whole emulator + guest must fit in
17.4 GB, and `host_addr_space_limit=0x800000000` (32 GB) is a *fiction* the layout is
still written against.

**Observed — every fixed arena candidate is above the real ceiling.**

```
[fex-arena] ml799 hardware high band 16GB: native reserve FAILED kr=3
[fex-arena] ml799 constrained 8GB: native reserve FAILED kr=3
[fex-arena] ml799 8GB @16-32G / @8-16G, 4GB @32-48G / @48-63G / @16-32G / @8-16G: FAILED kr=3
[fex-arena] ml901 2GB anywhere low: no FIXED home outside CoreAnimation's range … keeping the ANYWHERE placement at 0x370000000
[fex-arena] ml774 WARNING: only 0x80000000 bytes. Sufficient for small guests; heavy titles are expected to exhaust it.
```

kr=3 is `KERN_NO_SPACE`. Eight of the nine `plan[]` windows live at or above 16 GB, i.e.
entirely outside a 17.4 GB task, so they can never succeed here — and the 2 GB fallback is
not a choice, it is the largest *fitting* hole the kernel could find (the tail above it is
libmalloc's brk; the JIT pool later took the hole below it).

**Observed — what the 2 GB is spent on.** Counted from the same log's `[vname]` lines
(a name appears once per claim, and these are all per guest thread unless noted):

| region | count | total |
|---|---|---|
| `FEXMem_CallRetStacks` (16 MB + 2 pages) | 27 | 432 MB |
| `FEXMem_OpDispatcher` (16 MB, dual IR list) | 18 | 288 MB |
| `FEXMem_Frontend` (8 MB) | 18 | 144 MB |
| `FEXMem_Lookup_L1` (2 MB) | 38 | 76 MB |
| `FEXMem_BlockLinks` / `CPUBackend` / `ThreadState` | 110 | 24 MB |
| unnamed (FEX's own heap inside the band) | — | ~1 GB |

So ≈42 MB of arena per guest thread, most of it *reservation* the thread never touches.

**Observed — how that ends the run, in order (t = seconds after launch).**

```
t+45  [va-scan] FAILED window=0x370000000..0x3f0000000 size=0x1002000 … maxgap=0x1000000   (×11)
t+45  [callret] RESERVE FAILED … thread cannot start                                        (×11)
t+45  [alloc-fail] ml798 FEXAlloc could not allocate bytes=0x2990 …                        (traps)
t+45  [deliver-hold] teb=0x457f20000 tid=006c HOLDS FEX shared lock @0x3710f108 at guest redirect — this delivery leaks the read hold
t+45  err:seh:NtRaiseException Unhandled exception code c000001d → NtTerminateProcess
t+46  [lock-reap] dead port=0x9143 tid=006c … released 1 shared (word 00020001 -> 00020000)
t+46  SEGV pc=0x32f05a338 (pool, x1=0) and BUS pc=0x4519515d0 (exec in a prot=1/3 page) → [fault-stuck] abort_thread
```

**Inferred (fits every number above).** The splash waits on work that a worker thread
owns. Studio tolerates the eleven threads that never started — it kept initialising for
another second — but a FEX *internal* allocation cannot return NULL (FEXCore is
`-fno-exceptions`), so ml798 traps. That thread was inside a JIT region holding the FEX
`WritePriorityMutex` **shared**, so its death leaks the read hold; every later compile
blocks on it. #35 saw exactly this from the outside (owner word never clearing, two
threads at 100 %, the UI thread in neither the server queue nor the alarm pool); #36 names
the owner and the reason it died. The `[lock-reap]` 1.5 s later releases the hold, and the
blocked writers then invalidate/execute blocks that were already torn down — the SEGV/BUS
pair and the 50-fault `[fault-stuck]` loop are the aftermath, not the cause.

**Fix shipped for #37 (ml1250): cut per-thread arena demand, do not move the arena.**

The arena cannot grow (2 GB is the largest fitting hole) and placement is load-bearing for
the JIT pool, so the arena *reservation* per guest thread is what changes:

- `CALLRET_STACK_SIZE` 16 MB → **8 MB**. The guard window is absolute — BranchOps pins sp
to `[base+2MB, base+6MB)` and resets to `base+4MB` — so nothing above `base+6MB` was ever
written: the top 10 MB of every stack was pure address space. The geometry is unchanged
byte for byte; `CALLRET_DEFAULT_OFFSET`/`_LIVE_OFFSET`/`_LIVE_SIZE` are now explicit
constants instead of `SIZE/4`-derived (at 8 MB, `SIZE/4` would have been 2 MB — the window
floor, not its centre), and Dispatcher's whole-allocation guard moved `>>24` → `>>23` so a
drift past the *new* allocation still resets instead of writing the callback sentinel into
the arena. **Verified** by `tests/host/check-callret-geometry.py`.
- `DefaultDecodedBufferSize` 0x10000 → **0x4000** instructions: the `FEXMem_Frontend` claim
is `sizeof(DecodedInst) * N`, so 8 MB → 2 MB. Exceeding it is not a failure path — the
decode loop stops at the bound (`MaxInst` already does the same) — but the loop only
checked it at a block *terminator*, so a long straight-line run could write past
`DecodedBuffer[]`. ml1250 adds the per-instruction bound that makes the smaller buffer
safe (and closes the same hole at the old size).
- Measured effect: ≈14 MB less reservation per guest thread (42 → 28 MB), i.e. 378 MB of a
  2 GB arena for the 27 threads #36 had, plus every later thread.

**Also shipped for #37 (ml1252): the IR list now has a real overflow path, and is 8 MB →
4 MB per buffer.** `FEXMem_OpDispatcher` is the dual IR list every block compile is emitted
into; it was left out of ml1250 because `DataAllocate`/`ListAllocate`'s only bound was
`LOGMAN_THROW_A_FMT`, which compiles to `(void)(pred)` without `ASSERTIONS_ENABLED` — a
block whose IR outgrew a smaller list would have written into the next FEX allocation, with
no diagnostic. That is fixed at the allocation itself:

- the last 4 KB of each list are never handed out linearly; they are the landing pad for an
  allocation that does not fit, so an overrun stays *inside* the claim. Its offset is a
  valid in-arena offset, so a `NodeWrapper` pointing at it still round-trips (a separate
  scratch object would not: offsets are 32-bit `ptr - base` truncations);
- an overrun latches `Overran`. `GenerateIR` checks it after each instruction dispatch,
  after `Finalize()` and after the pass manager — the IR built after an overrun is never
  compiled. The attempt is discarded and re-decoded with half the instruction budget;
- `GenerateIR` stops a block 128 KB before the claim is used up and **flushes it there** —
  `ExitFunction` at the guest address of the instruction that did not fit, same shape as the
  `NeedsBlockEnd` path — so a block that no longer fits becomes two blocks instead of a
  failed compile. This only applies to the *last* block of a multiblock; earlier blocks may
  already jump to labels for later ones, so those still re-decode smaller;
- claim 4 MB → **2 MB per list** (8 MB → 4 MB per `FEXMem_OpDispatcher` buffer).
  **Verified** structurally by `tests/host/check-ir-overflow.py`; the first real compile is
  CI's `fex-ios-build`, and the run's `[ir-size]` / `[ir-flush]` / `[ir-overrun]` lines are
  what say whether 2 MB is the right number or whether the next cut is available.

**Open.** Whether ≈380 MB plus 4 MB per IR buffer is enough headroom for Studio's remaining
threads is what #37 measures. If it is not, the next levers are that IR claim (now
shrinkable on the `[ir-size]` measurement) and 2.1.11's section-owner stamp, which writes
TEB `0x1710`/`0x1720` — real fields (`ActivityId`, `SubProcessTag`, `PerflibData`), not the
free slots the patch assumed; it must move to a side table.

## Files changed for 2.1.9 (pushed as `784f91d`)

- `build/ntdll-unix/server_ios.c` — slice folded against `NtQueryPerformanceCounter()`,
  comment records the encoding trap and the #34 numbers.
- `app/Madeira.xcodeproj/project.pbxproj` — `MARKETING_VERSION = 2.1.9`.
- `docs/RUN35_CHECKLIST.md` — the device procedure.
- `docs/BUG_FINDINGS.md` — this file.

## Files changed for 2.1.10

- `build/ntdll-unix/signal_arm64_ios.c` — `ios_peek_thread_state()` (ml1132):
  suspend → read → resume in the fexlock census, so a holder that is running on
  another CPU yields a real pc/lr/backtrace instead of `pc=0x0`; the census line
  now also prints the slot-6 SRW stamp, and a holder with no alert wait prints
  `WAITING-ON none` instead of nothing.
- `app/Madeira.xcodeproj/project.pbxproj` — `MARKETING_VERSION = 2.1.10`.

## Run #37 — 2.1.13 does not boot: native execution of x64 bytes (+4 s)

**Observed** (device log exported 2026-10-25, session
`logs/RobloxStudioBeta.exe-2026-10-25_10-14-05.txt`). Follows Bug 5's planned run,
and the first build with ml1250/ml1252 in it.

```
[build] v2.1.13 (4)
[device] address-map=[0x102d34000,0xfc0000000) 63GB        <- debugger attached; #36 had 17GB
[fex-arena] ml799 RESERVED constrained 8GB base=0xb30000000   <- not #36's 2GB @0x370000000
[phase] spawn:RobloxStudioBeta.exe t+3.057s
arm64ec_process_init_dispatchers: re-patching xtajit64.dll / kernelbase.dll / kernel32.dll metadata
t+4.2s  pc=0x3161c0c10 (pool copy of ucrtbase+0x63c10)  host ran the x86 bytes
        err:seh:NtRaiseException Unhandled exception code c000001d
        NtTerminateProcess(exit_code=0xc000001d)  -> abort_process (ml937, this pseudo-process only)
```

The faulting word is the giveaway: the ARM instruction word at the host PC is
`0x245c8948`, which is no A64 encoding — it is `48 89 5c 24`, i.e. `mov [rsp+8],rbx`,
the first four bytes of the x86 function at `ucrtbase+0x63c10`. The host branch
landed on a **function entry**, so the target was right and only the *kind* of code
was wrong: the address was treated as ARM64EC-native and executed on the CPU
instead of being translated.

**Supporting rows from the same crash**

| Row | Reads |
|---|---|
| `[mach_exc] pc pool-copy pe=0xfb8810000` / `pc PE: ucrtbase.dll+0x63c10` | the copy belongs to Studio's **own** `C:\WebView2Loader\ucrtbase.dll` (loaded `native` at `0xFB8810000`), not Wine's builtin |
| `[ec-fault-regs] x0=0xfb8810000 x11=0xfb8873c10` | x0 = the module base, x11 = the x64 target — the register shape of the ARM64EC x64-call dispatch |
| `[x86_live] State.RIP=0x0 RSP=0x0` `callret_sp=0x0` | no FEX x86 state: the branch never went through the emulator, so `[fault_rip] rip=0x0` |
| `[unalign-byte] ml624 #1` / `[store-noalias] #1` / `[fault_rip] cnt=1` | first occurrence in the run — this is the very first thing Studio does of this kind |
| `[data-align] ucrtbase.dll shifted +0x1000 so .data lands on a 16KB page` | the image Studio crashed in is one whose section layout is **not** the file's |

**Verified — this is not Bug 5 repeating.** The log has zero `[callret] RESERVE FAILED`,
zero `[alloc-fail] ml798`, zero `[deliver-hold]`, and the arena is 8 GB at
`0xb30000000` rather than 2 GB. The `[va-scan] SLOW … iOS REFUSED A FREE ADDRESS`
rows are the known non-signal. So neither ml1250's arena cut nor ml1252's IR claim is
what failed here; the process died 0.6 s after `arm64ec_process_init_dispatchers`
finished, before any Studio code of its own ran.

**Verified — the config in this run cannot explain it either.**

- `[jumbo-hold] ml996 want=40961 MB; largest free hole 31744 MB … NOT holding` —
  `jumbo-mb = 40961` is unsatisfiable on this layout; it reserved nothing.
- `env.WINEDEBUG` there only *adds* channels (`trace+dll` gave the `Loaded` rows quoted
  above); it cannot change a branch decision.
- `env.MIMALLOC_FORCE_REDIRECT` is read by **nothing** in this tree (no `mimalloc` match
  anywhere in `app/`, `build/`, `wine/`, `FEX/`); it is Studio's own allocator switch.
- `[fex-exports] ml614 … RECORDED BUT NOT ARMED` is deliberate (see `virtual_ios.c`), not
  a regression — ml613's arming is what crashed every launch back then.

**Verified — the module guard is not the defect.** The image was classified correctly and
said so:

```
[data-align] ucrtbase.dll shifted +0x1000 so .data lands on a 16KB page
iOS JIT: copied image 0xfb8810000+0x14b000 → pool 0x31615d000
iOS JIT: NOT marking jit 0x31615d000+0x14b000 as EC (no .hexpthk section, pure x86_64)
```

`virtual_ios.c:13293` is explicit that a pure x86_64 image must *not* be marked EC, because
`arm64x_check_call` would "dispatch BL directly into the JIT-pool copy of x86_64
instructions (executed as ARM64 → garbage)" — the exact sentence that describes run #37, and
it did not fire here. So the bitmap is right and the branch that ignored it is elsewhere.

**Inferred — the branch is the ml246 trap in `arm64x_check_call`.** Wine's
`__os_arm64x_check_call` (`wine/dlls/ntdll/signal_arm64ec.c:4793`) decides EC-vs-x64 *before*
the branch, and its lookup goes through `ldr x16,[x18,#0x60]` — a PEB read via x18, which
iOS clobbers (this dump has `x18=0x0`). ml246 kept that read deliberately: correcting it
was A/B-proven to break CEF for 8 consecutive runs, and its own note says the bug that
motivated keeping it is "a direct branch into x64 bytes executed as ARM64" whose false
positive had not been found. Run #37 is that sentence, one layer down: a target that must go
through the x64 exit thunk took the `.Ldone` (EC) path instead.

**Why this trigger is new even though the trap is old.** The only two modules in the Studio
process loaded as `native` are the ARM64EC exe and
`C:\WebView2Loader\ucrtbase.dll` — Studio ships its **own pure-x64 CRT beside the exe**,
where every other process in the same log loads `C:\windows\system32\ucrtbase.dll` as
`builtin` (and got `tramp+0x4000`; this one got `tramp+0x0`). That app-local CRT is the
first x64-callee-native-caller pair the dispatch path sees, 0.6 s after init. #36's Studio
build did not have it, so "it booted on 2.1.8" and "it does not boot now" are both true and
neither is a Madeira 2.1.9–2.1.13 regression.

**Cheapest discriminator — no rebuild needed.** Make Studio use the CRT the rest of the
prefix already uses, as one line in that entry's own config (Game details › This game's
config), then relaunch:

```
env.WINEDLLOVERRIDES = ucrtbase=b
```

If Studio gets past +4 s with `Loaded L"C:\\windows\\system32\\ucrtbase.dll"` and no
`c000001d`, the trigger is confirmed as the app-local CRT and the fix is dispatch-side. If
it still dies at `ucrtbase+0x63c10`, the ml246 false positive is address-dependent and the
next step is instrumenting `arm64x_check_call` to print `x11` + the bit it read, not a revert.

**Open — reported by the user.** The last build that reached the editor was **2.1.8**, not
#36 — so no revert inside 2.1.9–2.1.13 can be the fix, and the regression window includes
the Studio update itself. `[build] v2.1.13 (4)` is the first build logging Studio's own
`WebView2Loader\ucrtbase.dll`.

**Also worth noting for the next export:** `[ir-size]` / `[ir-flush]` / `[ir-overrun]`
never appear, so ml1252's 2 MB claim was never exercised in this run — the crash happens
far too early. A `[fault_rip] rip=0x0` is the instrument gap to close if this recurs.
