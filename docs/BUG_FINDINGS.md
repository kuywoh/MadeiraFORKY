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
| #35 | 2.1.9 | Pending | First honest test of the healer — see `docs/RUN35_CHECKLIST.md` |

#33 is second-hand (as reported); #34 was measured directly from the device log.

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

## Files changed for 2.1.9 (uncommitted)

- `build/ntdll-unix/server_ios.c` — slice folded against `NtQueryPerformanceCounter()`,
  comment records the encoding trap and the #34 numbers.
- `app/Madeira.xcodeproj/project.pbxproj` — `MARKETING_VERSION = 2.1.9`.
- `docs/RUN35_CHECKLIST.md` — the device procedure.
- `docs/BUG_FINDINGS.md` — this file.
