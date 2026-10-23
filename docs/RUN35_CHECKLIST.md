# Run #35 verification checklist — Madeira 2.1.9

Two questions, in order, and the second one only counts if the first passes:

1. **Boot** — does Studio get to its editor at all? (#34 could not, because of the
   slice-encoding spin.)
2. **Place load** — does `File > New` / opening a `.rbxl` stop hanging at the
   spinner? This is the first run where the ml1322 slice healer executes at its
   intended 250 ms cadence, so it is the first real test of the theory.

Nothing in this run depends on the submodule copy of `server.c`; the slice loop
that runs is the one in `build/ntdll-unix/server_ios.c`.

## What changed since #34

Exactly one behavioural change: the slice deadline is now folded against the
monotonic clock (`slice = -2500000 - now.QuadPart`) instead of being sent as a
bare `-2500000`, which `abstime_to_timeout()` in the server resolved to
"already expired" and turned into a busy re-select loop. Version string is
`2.1.9` so this build is identifiable in the log head.

Baseline numbers from #34 (2.1.8), for comparison:

| Marker | #34 observed |
|---|---|
| `[xp-api] ... slices` | 320k–415k/s, essentially all `empty` |
| `slices ... cum` | 16,672,884 after 58 s |
| `[srv-req]` | `req29=199976` per 0.5 s (select) |
| `[xp] ... cpu=` | 828–1071 (`thr` same order) on an 8-core device |
| `[wineserver-fd] iter=` | 6,400,000 |
| Runtime captured | 67 s, ends mid-stream, no clean exit |

## Before starting

- [ ] Sideload 2.1.9 and confirm the **first** line group contains
      `[build] v2.1.9 (4)`. If it still says `2.1.8`, stop — you are testing the
      old IPA.
- [ ] JIT on (`[jit-on-play] JIT is on`, `[OK] JIT enabled!`), debugger detached
      (`[OK] [early-detach]`).
- [ ] Log export starts **before** launching Studio, so the boot sequence is
      captured from `[wineserver] starting`.
- [ ] Nothing else changed: same prefix, same `madeira.cfg`, same Studio build,
      same device. One variable per run.

## Phase A — launch (≈90 s)

- [ ] App reaches the frontend (`[frontend] choice=`), wineserver starts
      (`[wineserver] starting init`), JIT pool is up
      (`[OK] JIT pool: RX=..., RW=...`).
- [ ] **CPU sanity** — read the first few `[xp]` rows after Studio launches:
      `cpu=` should sit at a small fraction of the #34 values (tens, not ~1000).
      This is the single fastest check that the spin is gone.
- [ ] **Slice rate** — `[xp-api] ... | slices N/s ... cum M`:
      - healthy: a few hundred per second **at most** (≈4/s per parked thread;
        #34 had ~100 parked select users, so expect an aggregate in the low
        hundreds);
      - still broken: tens of thousands per second or more, `cum` climbing by
        millions per minute.
- [ ] `[srv-req] ... req29=` is no longer ~200k per 0.5 s.
- [ ] `[wineserver-fd] iter=` grows at a sane rate (thousands, not millions).

Note: `empty` ≈ `slices` is **expected even when healthy** — a parked thread's
slice always times out empty. The tell is the *rate*, not the empty fraction.

If Phase A fails, stop and export: the place-load phase cannot be interpreted.

## Phase B — Studio boot (to editor)

- [ ] Studio reaches the editor (or at least past the boot spinner).
- [ ] Record the wall-clock time to first frame, and whether it differed between
      attempts.
- [ ] `[thread-sample]` / `[thread-stacks]` passes while it is up: no thread
      pinned at 100% in `select`/`server_select`.

If boot works, this run has already fixed #34's regression. Everything below is
the question that has been open since #30.

## Phase C — the actual repro

- [ ] Do **one** of: `File > New`, or open a known-good `.rbxl`. Write down
      which one — they exercise different paths and the next run should not mix
      them.
- [ ] Wait **≥ 5 minutes** at the spinner before exporting. The healer's whole
      claim is that a swallowed wake is repaired within 250 ms; a short wait
      cannot distinguish "heals" from "hasn't wedged yet".
- [ ] Note whether the place eventually loads, loads partially, or never moves,
      and the timestamp when it stops changing.
- [ ] Export the full log, not a tail.

### One attempt per launch

The failure does not clear: the window greys out (owner window disabled while a
modal/synchronous operation never returns) and stays that way. So an "attempt"
is an **app launch**, not a click — a failed click can only be escaped by
relaunching. Do not plan a rapid-fire loop of ten attempts in one session.

If repeatability is worth the relaunches, five is enough to separate "every
time" from "sometimes", and each one needs only: launch, click the repro, wait
until grey, export. Record it as:

| launch | repro | seconds to grey | still grey after 5 min | notes |
|---|---|---|---|---|
| 1 | `File > New` | | | |
| 2 | `File > New` | | | |

Stop after two clean greys if the log already answers the question below — the
relaunches only buy probability, not a new mechanism.

### Capture while it is greyed, not after a restart

Greyed is the only state where the blocked thread still exists. Before anything
is closed, these three blocks matter:

1. `[xp-api] ... slices N/s ... cum X` — is the healer still cycling while the
   window is grey, or has the count frozen?
2. `[srv-queues]` (dumped every ~10 s) — find Studio's UI thread. Three readings:
   - `send_pend=N` on the receiver and `awaiting reply: ... replied=0` on the
     sender — the UI thread is blocked in a cross-thread `SendMessage`, and the
     reply is what never arrives.
   - `recv_in_prog=1` with `post=0` — the UI thread is idle in its message
     pump, i.e. **not** blocked in the load; then the greyed window is an
     invisible/never-shown modal and the load path is innocent.
   - `wake=00000000/00000000` with `post>0` — messages piled up and no wake was
     delivered (the ml584 shape behind the Start-button bug).
3. `[srv-stuck]` for that same tid — its `caller=`/`ret_pc` and handle types say
   what it is parked on, and LINKED vs NO-WAIT says whether the server even has
   a wait for it.

A log exported after a restart contains none of this — the interesting state is
gone.

## Decision matrix

Judge from these four markers only: `slices`/`cum` rate, `[srv-stuck]`,
`[evt-life]`, and whether the place loaded.

| # | Place loads? | `cum` still climbing? | Meaning | Next step |
|---|---|---|---|---|
| 1 | yes | yes (slow) | **Theory confirmed.** Symptom fixed at 250 ms cadence; who loses the wake is still unknown. | Close the wedge as mitigated; keep root-cause forensics separate. |
| 2 | no | yes, ~4/s per stuck thread | Loop is alive, so the swallow also eats **timeout replies** — the client parks inside slice #0 and cannot re-issue. | Next target is the reply path (`wait_select_reply`), not the wait path. Add reply-side telemetry. |
| 3 | no | frozen / not growing | The loop is not running for that thread (not compiled in, or a wait path that bypasses `server_wait`). | Prove which path the stuck thread is in via `[srv-stuck] caller=` before touching anything else. |
| 4 | — (no boot) | — | Regression not fixed. | Export the first 90 s and re-check the slice rate before anything else. |

### The stuck-wait signature to look for (outcome 2)

```
[srv-stuck] tid=.... op=1 ... timeout=9223372036854775807
[srv-stuck]   h[0]=... type=Event ... signaled=0 ... state=NO-WAIT
[evt-life] obj=... SET=<n> reset=0 ... | signals=<n> releases=0
```

The distinguishing detail is `SET=<n>` with **n > 0** and `releases=0` on the
same object, with a waiter still linked. That is the lost wake.

## Known non-signals — do not chase these in #35

- `[ERR] [no-footprint] pool applied=false` / `pool stays jetsam-counted` —
  present in #34 at 17:45:04, unrelated to the wait path.
- `[evt-life] ... <-- NEVER SET BY ANYONE` — startup/shutdown events that are
  legitimately never signalled. #34's `[srv-stuck]` rows were exactly this case,
  which is why they are not evidence of the bug.
- `err:` lines from Wine (`mprotect_exec`, `init_syscall_frame`,
  `NtTerminateProcess`) — normal for this build.
- `[pool-freechk] POISONED AT FREE` — module-lifetime accounting, not the wedge.
- `[va-scan] ... iOS REFUSED A FREE ADDRESS` — address-space probing noise.

## Attach with the log

- [ ] `[build]` line (version + build number).
- [ ] Phase C choice: `File > New` or the specific `.rbxl`.
- [ ] Time-to-editor, and time spent at the spinner before export.
- [ ] Whether the app was force-closed, and at what timestamp — a log that ends
      mid-stream without an exit line is normally a kill, not a crash.
