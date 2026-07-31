# Plan 022: Wait for core initialization before opening the system-info stream

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat e38210d1..HEAD -- lib/hiddifycore/hiddify_core_service.dart`
> and, inside the submodule: `git -C hiddify-core diff --stat 8653861f1c..HEAD -- v2/hcore/commands.go`.
> If either changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it
> as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/001-restore-verification-baseline.md`; conceptually
  a sibling of `plans/006-fix-proxy-list-stream-startup-race.md` (same bug
  shape, different stream)
- **Category**: bug
- **Planned at**: Dart repo commit `e38210d1`, `hiddify-core` submodule
  commit `8653861f1c6b87f4833e4bc3182af4b32c53b711`, 2026-07-29

## Why this matters

`GetSystemInfoStream` (the RPC backing the stats/system-info watcher) has the
same startup-race shape that `AllProxiesInfoStream` had before plan 006 fixed
it: the Go handler waits at most 5 seconds
(`hiddify-core/v2/hcore/commands.go:84-98`, `MakeSureContextIsNew`) for a live
core context, and if the core is still starting when that window expires, it
returns a single terminal error (`commands.go:112`,
`return E.New("service not ready")`) instead of retrying.

**This is only a partial repeat of the plan-006 bug, not the full one** —
verified directly: `lib/features/stats/data/stats_repository.dart:19` already
wraps this stream in `.handleExceptions(StatsUnexpectedFailure.new)`, the same
shared extension plan 006 fixed to resume-with-backoff instead of terminating
(`lib/core/utils/exception_handler.dart:26-60`). So a core-not-ready error
here no longer kills the stream forever — Dart will re-subscribe with
exponential backoff.

What plan 006 also did, that this stream is still missing, is the **other**
half of its fix: `watchActiveGroups` (`hiddify_core_service.dart:298-306`) was
given a wait-for-`core.isInitialized()` loop *before* attempting the gRPC
call, so it does not even attempt the call — and therefore does not hit the
5-second Go-side wait and subsequent error/backoff cycle — during the common
case of the app just having started. `watchStats()`
(`hiddify_core_service.dart:324-332`), which backs `GetSystemInfoStream`, has
no such guard: it attempts the call immediately, meaning every fresh app
launch pays a 5-second stall plus at least one backoff-delayed retry (1s,
then success) before the stats card shows anything, where `watchActiveGroups`
now shows data immediately.

## Current state

`hiddify_core_service.dart:298-332` today (both methods, for comparison —
only `watchStats` needs to change):

```dart
    // Wait for core to initialize instead of completing the stream empty.
    // handleExceptions will re-subscribe on error, so returning an empty
    // completed stream here would permanently end the proxy list.
    while (!core.isInitialized()) {
      loggy.debug("core is not initialized, waiting 500ms");
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    try {
      yield* core.bgClient
          .mainOutboundsInfo(Empty())
          .map((event) {
            return latest = event.items.toList();
          })
          .startWith(latest);
    } catch (e) {
      loggy.error("error watching active groups: $e");
      rethrow;
    }
  }

  //
  // Stream<SingboxStatus> watchStatus() => _status;

  ResponseStream<SystemInfo> watchStats() {
    loggy.debug("watching stats");
    try {
      return core.bgClient.getSystemInfoStream(Empty());
    } catch (e) {
      loggy.error("error watching stats: $e");
      rethrow;
    }
  }
```

Note `watchActiveGroups` is `async*` (uses `yield*`), while `watchStats`
returns a `ResponseStream<SystemInfo>` synchronously (it is not `async*`) —
the wait-loop pattern from `watchActiveGroups` cannot be copied verbatim
because `watchStats` has no `async*` generator to `yield*` from while
waiting. See Step 1 for how this plan adapts the pattern to a non-generator
method.

`hiddify-core/v2/hcore/commands.go:84-113` today (unchanged by this plan —
included so you can confirm the Go-side shape this plan works around, per
plan 006's precedent of leaving `MakeSureContextIsNew` untouched since it is
shared by multiple RPCs):

```go
func (h *HiddifyInstance) MakeSureContextIsNew(streamContext context.Context) {
	for range 10 {
		if ctx := h.Context(); ctx != nil {
			select {
			case <-ctx.Done():
			default:
				return
			}
		}
		select {
		case <-streamContext.Done():
			return
		case <-time.After(time.Millisecond * 500):
		}
	}
}

func (h *HiddifyInstance) GetSystemInfo(stream grpc.ServerStreamingServer[SystemInfo]) error {
	h.MakeSureContextIsNew(stream.Context())
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	ctx := h.Context()
	if ctx == nil {
		return E.New("service not ready")
	}
	// ...
```

`stats_repository.dart:12-21` in full (confirms `handleExceptions` is already
applied — do not change this file):

```dart
class StatsRepositoryImpl with ExceptionHandler, InfraLogger implements StatsRepository {
  StatsRepositoryImpl({required this.singbox});

  final HiddifyCoreService singbox;

  @override
  Stream<Either<StatsFailure, SystemInfo>> watchStats() {
    return singbox.watchStats().handleExceptions(StatsUnexpectedFailure.new);
  }
}
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Analyze | `make analyze` | no new findings vs. plan-001 baseline |
| Tests | `make test` | all pass |

## Scope

**In scope**:
- `lib/hiddifycore/hiddify_core_service.dart` (the `watchStats` method only)

**Out of scope**:
- `hiddify-core/v2/hcore/commands.go` / `MakeSureContextIsNew` — shared by
  multiple RPCs; per plan 006's precedent, the Dart-side fix (this plan) plus
  the already-fixed `handleExceptions` resume behavior make a Go-side change
  unnecessary. Do not touch the submodule in this plan.
- `watchActiveGroups` — already fixed by plan 006, do not re-touch.
- `lib/features/stats/data/stats_repository.dart` — already correctly wraps
  the stream in `handleExceptions`, no change needed.
- `lib/core/utils/exception_handler.dart` — already fixed by plan 006.

## Git workflow

- Branch: `advisor/022-systeminfo-stream-init-wait`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Wait for core init before opening the system-info stream`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add an init-wait guard to `watchStats`

`watchStats` is not an `async*` generator (it returns `ResponseStream<SystemInfo>`
directly, not `Stream<SystemInfo>` via `yield*`), so it can't wait
synchronously the way `watchActiveGroups` does. Convert it to build the
underlying stream lazily via `StreamController`/`Stream.fromFuture` composition,
or the simplest option consistent with this codebase's style: change the
method to `async*` returning `Stream<SystemInfo>` instead of
`ResponseStream<SystemInfo>` and check whether `ResponseStream`-specific
members (e.g. a `.cancel()`) are used by any caller before doing so (see STOP
conditions). If a caller needs `ResponseStream` specifically, instead wrap
with `Stream.fromFuture(_waitForInit()).asyncExpand((_) => core.bgClient.getSystemInfoStream(Empty()))`:

```dart
  Stream<SystemInfo> watchStats() {
    loggy.debug("watching stats");
    return Stream<void>.fromFuture(_waitUntilInitialized())
        .asyncExpand((_) => core.bgClient.getSystemInfoStream(Empty()))
        .handleError((Object e) {
          loggy.error("error watching stats: $e");
          throw e;
        });
  }

  Future<void> _waitUntilInitialized() async {
    while (!core.isInitialized()) {
      loggy.debug("core is not initialized, waiting 500ms");
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
```

Check the return type change (`ResponseStream<SystemInfo>` →
`Stream<SystemInfo>`) doesn't break `stats_repository.dart`'s
`singbox.watchStats()` call — `Stream<SystemInfo>` is a supertype of
`ResponseStream<SystemInfo>` so a caller only using `Stream` methods
(`.map`, `.handleExceptions`, etc.) is unaffected; only a caller calling a
`ResponseStream`-specific method would break.

**Verify**: `grep -n "_waitUntilInitialized\|isInitialized" lib/hiddifycore/hiddify_core_service.dart`
shows the new wait logic inside `watchStats`'s call chain, not an early
`return` that skips it. `make analyze` → no new findings.

### Step 2: Confirm the full suite passes

**Verify**: `make test` → all pass.

### Step 3: Manual confirmation (timing bug — recommended, not required)

If you can run the app: launch it fresh, immediately open the screen showing
the stats card, and confirm it populates within about 1-2 seconds rather than
waiting 5+ seconds for a first failed attempt. If no device is available,
skip this step and say so explicitly in your final report.

## Test plan

No new automated test — this is the same category of timing fix as plan
006's Step 3, which also had no automated test for the specific wait-loop
(only for the shared `handleExceptions` resume behavior, which is unchanged
by this plan and already tested in `test/core/utils/exception_handler_test.dart`).
Verification is `make analyze` + `make test` passing, plus the manual check
in Step 3 where possible.

## Done criteria

- [ ] `make analyze` reports no new findings vs. plan-001 baseline
- [ ] `make test` exits 0
- [ ] `watchStats` no longer calls `core.bgClient.getSystemInfoStream(Empty())` before waiting for `core.isInitialized()`
- [ ] `git status` shows changes only to `lib/hiddifycore/hiddify_core_service.dart`, `plans/README.md`
- [ ] `plans/README.md` status row updated, noting whether Step 3's manual check was performed or skipped

## STOP conditions

- Any other call site depends on `watchStats()` returning a `ResponseStream<SystemInfo>`
  specifically (not just `Stream<SystemInfo>`) — grep for `.watchStats()` call
  sites and any `ResponseStream`-specific member use before changing the
  return type; if one exists, keep the return type as `ResponseStream` and
  find a different way to defer the call (e.g. a wrapper class), or report
  back rather than silently narrowing an API another caller depends on.
- The code at `hiddify_core_service.dart:324-332` doesn't match the excerpt
  above (drift since this plan was written) — re-read the live method before
  changing it.
- `make test` shows a previously-passing test failing after this change —
  investigate before assuming it's unrelated; a return-type change is exactly
  the kind of edit that can surface a hidden dependency on the old type.

## Maintenance notes

- This plan intentionally does not touch the Go-side `MakeSureContextIsNew`
  5-second window — see plan 006's own maintenance notes: "if those show
  similar symptoms, fix it there once rather than adding waits per caller."
  If a third stream shows this same shape, that is the signal to finally fix
  it once in Go rather than adding a fourth Dart-side wait-loop.
- If `watchStats`'s return type is narrowed from `ResponseStream<SystemInfo>`
  to `Stream<SystemInfo>`, any future code that needs `ResponseStream`-specific
  behavior (e.g. explicit cancellation) will need a different approach — flag
  this in code review if it comes up.
