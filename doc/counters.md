# Safe counters and `stats counters`

## Problem

A statistics counter implemented as a single-byte (or other narrow) integer
accumulates until it reaches its natural limit and then silently wraps back to
zero. Any ratio computed from two such counters can therefore go negative:
the numerator may have wrapped while the denominator has not, so a "hit rate"
of `hits / lookups` can turn into a small or negative number even though both
quantities are physically still growing.

This facility removes that class of defect while leaving every existing
statistics field and command unchanged.

## What was added

- `counter.h` / `counter.c`: a small, thread-safe monotonic counter module.
  Every counter is stored in a `uint64_t`, but it carries a *declared width*
  (`u8`, `u16`, `u32`, `u64`) that documents the magnitude the counter is
  expected to cover and defines its saturation limit.
- `mc_counter_add()` saturates at the declared limit instead of wrapping, and
  latches an overflow event each time an increment would cross the limit, so
  overflow is always discoverable through `overflow_events` / `overflowed`.
- `mc_counter_observe()` wraps counters that are owned by another subsystem.
  A source value that moves backwards (the signature of a narrow wrap) is
  latched as overflow while the safe view stays monotonic.
- `mc_counter_sample()` records time-windowed growth: per-window delta,
  elapsed seconds, growth rate per second, remaining headroom, and an
  estimated seconds-to-limit (ETA).
- `mc_counter_delta()` computes a wrap-safe difference that is never
  negative, so derived ratios (for example hit rate) stay in `[0, 1]`.
- A new text subcommand, `stats counters`, exposes the data. The classic
  `stats` output, `stats reset`, and every existing field name are untouched.

## Type selection by magnitude

The declared width is chosen for the real traffic magnitude. Storage is
always 64-bit, so a counter can never wrap at runtime; the width only drives
the reported limit, headroom and overflow bookkeeping.

| Width | Natural limit          | Typical magnitude                        |
|-------|------------------------|------------------------------------------|
| u8    | 255                    | small/legacy single-byte counter         |
| u16   | 65,535                 | tens of thousands                        |
| u32   | 4,294,967,295          | billions; request counters on busy hosts |
| u64   | 18,446,744,073,709,551,615 | default for long-running request/byte counters |

All counters exposed by `stats counters` are declared `u64` because request
and byte counters on a long-running device exceed 32-bit headroom.

## Overflow is detected, never silent

Boundary behaviour measured against the real implementation
(`doc/records/overflow-numbers.txt`):

| Width | Limit                  | Raw narrow `limit+1` | Safe value | Overflow event |
|-------|------------------------|----------------------|------------|----------------|
| u8    | 255                    | 0 (wrapped)          | 255        | 1              |
| u16   | 65,535                 | 0 (wrapped)          | 65,535     | 1              |
| u32   | 4,294,967,295          | 0 (wrapped)          | 4,294,967,295 | 1           |
| u64   | 18,446,744,073,709,551,615 | n/a (no wider storage) | 18,446,744,073,709,551,615 | 1 |

The raw narrow column reproduces the original defect (`255 + 1 -> 0`). The
safe counter stays at the exact limit and records the event instead.

## Time windows, growth rate and time-to-limit

Each `stats counters` call advances a per-counter window. The fields are:

- `<name>:value` current monotonic value
- `<name>:limit` declared-width maximum
- `<name>:headroom` `limit - value`
- `<name>:overflow_events` saturating / wrapping events observed
- `<name>:window_delta` growth since the previous sample
- `<name>:window_seconds` seconds since the previous sample
- `<name>:rate_per_sec` `window_delta / window_seconds` (integer, rounded down)
- `<name>:eta_seconds` `ceil(headroom / rate_per_sec)`, or `unknown` when
  the rate is zero or the counter is already saturated

Deterministic numeric example (`doc/records/window-eta-numbers.txt`),
using a u32 counter with an injected clock:

| Window            | Delta  | Rate     | Headroom        | ETA (seconds) |
|-------------------|--------|----------|-----------------|---------------|
| baseline          | 0      | 0/s      | 4,294,967,295   | unknown       |
| +10,000 / 100 s   | 10,000 | 100/s    | 4,294,957,295   | 42,949,573    |
| +5,000 / 100 s    | 5,000  | 50/s     | 4,294,952,295   | 85,899,046    |

The ETA recomputes from the most recent window, so a change in traffic rate
immediately moves the predicted fill time. Operators watch
`rate_per_sec` and `eta_seconds` to predict when a counter would fill.

### "Months before hitting the limit", with numbers

Time to limit at a sustained rate is `headroom / rate`. Reference points
using a 30-day month (2,592,000 seconds):

| Counter width | At 1,000 ops/s            | At 10,000 ops/s           | At 100,000 ops/s          |
|---------------|---------------------------|---------------------------|---------------------------|
| u8 (255)      | 0.26 s                    | 0.03 s                    | 0.003 s                   |
| u16 (65,535)  | 65.5 s (~1.1 min)         | 6.55 s                    | 0.66 s                    |
| u32 (4.29e9)  | 49.7 days (~1.66 months)  | 4.97 days                 | 11.93 hours               |
| u64 (1.84e19) | ~584,542 million years    | ~58,454 million years     | ~5,845 million years      |

This is why a u8/u16/u32 counter is unsafe on a device that runs for months:
a u32 counter at 10,000 operations per second wraps in roughly five days,
and at 1,000 operations per second in about 1.66 months. A u64 counter has
no realistic wrap horizon, which is the width used for the live counters.

## Why hit rates can no longer be negative

Hit rate is a ratio of two monotonic deltas. `mc_counter_delta(older,
newer)` returns `newer - older` when the values are monotonic and clamps to
`0` if `newer` wrapped below `older`. A ratio built from these deltas is
therefore always in `[0, 1]`. This is asserted by the
`counter_hit_rate_sign` unit test, which feeds a wrapped u8 hit counter
(`255 -> 3`) alongside a still-growing lookup counter and verifies a
non-negative, bounded rate instead of the old negative result.

## Compatibility

- No existing `stats` field is renamed, removed or retyped.
- No existing command changes behaviour. `stats reset` still returns `RESET`
  and zeroes the classic fields; it also rebuilds the counter view so the
  observability data stays aligned with the reset.
- `stats counters` is a new subcommand, following the existing
  `stats <subcommand>` dispatch, so older clients that never send it see no
  difference.

## How to verify (reviewable records)

- C unit tests live in `testapp.c` (`counter_saturation`,
  `counter_observe_wrap`, `counter_window_eta`, `counter_hit_rate_sign`,
  `counter_registry`) and run as part of `./testapp`. Recorded output:
  `doc/records/testapp-counters.txt`.
- End-to-end Perl test: `t/stats-counters.t` (run with
  `prove t/stats-counters.t`). It drives a real server through a normal
  read/write workload and compares the counter view against the classic
  stats fields. A recorded run is in `doc/records/e2e-stats-counters.txt`.
- Numeric boundary table: `doc/records/overflow-numbers.txt`.
- Numeric window/ETA table: `doc/records/window-eta-numbers.txt`.
- Raw protocol sample: `doc/records/raw-stats-counters.txt`.

The saturation tests push each width past its limit (for example a u8
counter is taken to 255 and incremented again) and assert the value equals
the limit with a recorded overflow event, rather than wrapping to zero.
