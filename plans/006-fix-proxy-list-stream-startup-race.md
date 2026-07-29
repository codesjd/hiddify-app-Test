# Plan 006: Stop the proxy-list stream from dying permanently when the core is slow to start

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat c99aed7f..HEAD -- lib/core/utils/exception_handler.dart lib/hiddifycore/hiddify_core_service.dart`
> and in the submodule: `git -C hiddify-core diff --stat 8653861..HEAD -- v2/hcore/proxy_info.go v2/hcore/commands.go`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-restore-verification-baseline.md`
- **Category**: bug
- **Planned at**: commit `c99aed7f` (app) / `8653861` (hiddify-core submodule), 2026-07-29

## Why this matters

A user reports that in TUN mode "the proxy list doesn't load properly and takes
a long time to appear." This is not a rendering problem — it is a stream that
**terminates permanently** on the first error and never recovers.

The full chain, verified across both languages:

1. The Dart UI opens a server-streaming gRPC call for the proxy list.
2. On the Go side, that handler waits up to **5 seconds** for a live core
   context. TUN-mode startup is slower than proxy mode (TUN device creation,
   route table setup), so this window is much more likely to expire.
3. When it expires, the handler does **not** retry or send an empty list — it
   returns an error, ending the stream.
4. On the Dart side that error propagates into a shared helper that uses
   rxdart's `onErrorReturnWith`, which emits one value **and then completes the
   stream**.
5. Nothing re-subscribes. The proxy list stays empty for the rest of the
   session unless the user navigates away and back.

Step 4 is the load-bearing bug and it is not specific to the proxy list: the
same helper wraps the log stream, the stats stream, the active-profile watcher,
and more. Any transient gRPC hiccup — a core restart, a reconnect — silently
kills those streams for the process lifetime. That is very likely behind other
"the UI stopped updating until I restarted the app" reports too.

## Current state

### Dart side — the helper that terminates streams

`lib/core/utils/exception_handler.dart:14-30` (read the whole file; the key
line is the `onErrorReturnWith`):

```dart
  Stream<Either<F, R>> handleExceptions<F, R>(
    F Function(Object error, StackTrace stackTrace) onError,
  ) {
    return map(right<F, R>).onErrorReturnWith((error, stackTrace) => Left(onError(error, stackTrace)));
  }
```

rxdart's `onErrorReturnWith` emits the replacement item **and then terminates
the stream**. It is not a resume operator.

Call sites (all long-lived watches — confirm with
`grep -rn "handleExceptions" lib/`):
- `lib/features/log/data/log_repository.dart:49`
- `lib/features/profile/data/profile_repository.dart` (active profile + others)
- `lib/features/proxy/data/proxy_repository.dart` (the proxy list)
- `lib/features/stats/data/stats_repository.dart`

### Dart side — no retry at the call site

`lib/hiddifycore/hiddify_core_service.dart:298-316`:

```dart
    loggy.info("watching active groups");

    if (!core.isInitialized()) {
      loggy.debug("core is not initialized, returning empty group stream");
      return;
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
```

The `catch` logs and rethrows. There is no reconnect. Note also the early
`return` when the core is not yet initialized — that yields an **empty,
already-completed** stream, another way the list can end up permanently empty.

### Go side — the 5-second window, then an error

`hiddify-core/v2/hcore/proxy_info.go:189-248`, abridged:

```go
func (h *HiddifyInstance) AllProxiesInfoStream(stream grpc.ServerStreamingServer[OutboundGroupList], onlyMain bool) error {
	h.MakeSureContextIsNew(stream.Context())

	if ctx, urlTestHistory := h.Context(), h.UrlTestHistory(); ctx != nil && urlTestHistory != nil {
		monitor := monitoring.Get(ctx)

		stream.Send(h.GetAllProxiesInfo(monitor.OutboundsHistory(""), onlyMain))
		...
		for {
			// ... streams updates until context done
		}
	}

	return E.New("hiddify service not found")
}
```

The immediate `stream.Send` inside the `if` is good — the list does **not**
block on health checks completing. But if `h.Context()` or
`h.UrlTestHistory()` is still nil when `MakeSureContextIsNew` gives up, the
entire block is skipped and the function returns an error.

`hiddify-core/v2/hcore/commands.go:84-99` — the bounded wait:

```go
func (h *HiddifyInstance) MakeSureContextIsNew(streamContext context.Context) {
	for range 10 {
		if ctx := h.Context(); ctx != nil {
			select {
			case <-ctx.Done(): //if old context is done waiting for new context
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
```

10 iterations × 500 ms = **5 seconds maximum**, then it returns regardless of
whether the context ever became ready.

Repo conventions to match:
- Dart: repositories return `Stream<Either<XFailure, T>>`; fpdart for error
  channels; `rxdart` is already a dependency and imported in these files.
- Go: `E.New(...)` from `sing/common/exceptions` for errors; `Log(LogLevel_*, LogType_CORE, ...)`
  for logging in `hcore`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps | `flutter pub get` | exit 0 |
| Codegen | `make gen` | exit 0 |
| Dart tests | `flutter test` | all pass |
| Dart analyze | `flutter analyze lib/core/utils lib/hiddifycore` | no new errors |
| Go build | `cd hiddify-core && go build ./v2/...` | exit 0 |
| Go tests | `cd hiddify-core && go test ./v2/hcore/...` | all pass |

## Scope

**In scope**:
- `lib/core/utils/exception_handler.dart`
- `lib/hiddifycore/hiddify_core_service.dart` (the `watchActiveGroups` method only)
- `test/core/utils/exception_handler_test.dart` (create)
- `plans/README.md` (status row only)

**Optionally in scope — see Step 4 before touching**:
- `hiddify-core/v2/hcore/proxy_info.go`

**Out of scope** (do NOT touch):
- `hiddify-core/v2/hcore/commands.go` — `MakeSureContextIsNew` is called by
  several other streams (`GetSystemInfo` and others). Changing its timing
  affects all of them; the Dart-side fix makes that unnecessary.
- `common/monitoring/**` — the health-check startup cost is a separate,
  already-recorded finding. The `stream.Send` above proves the list does not
  wait on it.
- Any other `handleExceptions` behavior change beyond resume-with-backoff.
- The `hiddify-core` submodule pointer in the parent repo (do not commit a
  submodule bump unless Step 4 is taken and the operator asked for it).

## Git workflow

- Branch: `advisor/006-proxy-list-stream`
- Commit per step. Message style matches recent history, e.g.
  `Resume watched streams after a transient error instead of terminating`.
- Do NOT push or open a PR unless the operator instructed it.
- If Step 4 is taken, the submodule has its own commit on its own branch —
  do not bump the parent pointer without being asked.

## Steps

### Step 1: Make `handleExceptions` resume instead of terminate

In `lib/core/utils/exception_handler.dart`, change the operator so the stream
emits the `Left` **and keeps going**, with a backoff so a persistently-down
core is not hot-looped.

Target behavior:
- On error: emit `Left(onError(e, st))`, wait a backoff interval, then
  re-subscribe to the source.
- Backoff: start at 1 second, double up to a 30-second cap. Reset the backoff
  after any successful emission.
- The stream must still complete normally when the source completes normally.

`rxdart` provides `onErrorResume` (which takes a `Stream` to switch to) and
`RetryWhenStream`. Either is acceptable. The requirement is the behavior above,
not a specific operator.

**Verify**:
`grep -c "onErrorReturnWith" lib/core/utils/exception_handler.dart` returns `0`.
`flutter analyze lib/core/utils` → no errors.

### Step 2: Test the resume behavior

Create `test/core/utils/exception_handler_test.dart`. This is testable with
plain `Stream` values — no mocks, no `ProviderContainer`.

Cover at minimum:
- A source that emits `1`, then errors, then (on re-subscribe) emits `2` →
  the wrapped stream yields `Right(1)`, `Left(...)`, `Right(2)` and does **not**
  complete after the error.
- A source that completes normally → the wrapped stream completes normally.
- A source that errors repeatedly → emissions are spaced by the backoff and the
  stream does not complete (use a short backoff override or fake timers; if the
  backoff is not injectable, make it a named parameter with a default so the
  test can pass a small value).

Model the file structure on `test/features/profile/data/profile_parser_test.dart:1-13`
(imports, `group`/`test("Should ...")` naming, double quotes).

**Verify**: `flutter test test/core/utils/exception_handler_test.dart` → all pass.

### Step 3: Remove the permanently-empty-stream path in `watchActiveGroups`

In `lib/hiddifycore/hiddify_core_service.dart`, the early
`if (!core.isInitialized()) { ...; return; }` yields a completed empty stream
that never recovers once the core does start.

Change it so the stream waits for initialization rather than completing: poll
`core.isInitialized()` on a short interval (500 ms) before proceeding to the
gRPC call. Keep the existing log line.

Do **not** remove the `try`/`catch`/`rethrow` — with Step 1 in place, the
rethrow is now caught by a resuming handler rather than a terminating one.

**Verify**: `grep -n "isInitialized" lib/hiddifycore/hiddify_core_service.dart`
shows the check is now inside a wait loop, not an early `return`.
`flutter analyze lib/hiddifycore` → no errors.

### Step 4 (OPTIONAL — read this before doing it): make the Go handler retry rather than error

With Steps 1–3 the Dart client now recovers on its own, so this is
defence-in-depth, not required. Take it **only** if the operator wants the
submodule touched in this change.

In `hiddify-core/v2/hcore/proxy_info.go`, `AllProxiesInfoStream` currently falls
through to `return E.New("hiddify service not found")` when the context is not
ready within 5 seconds. Better behavior: loop — re-run `MakeSureContextIsNew`
and re-check, exiting only when `stream.Context()` is done.

If you take this step, the submodule needs its own commit on its own branch,
and the parent repo's submodule pointer must **not** be bumped unless asked.

**Verify**: `cd hiddify-core && go build ./v2/... && go test ./v2/hcore/...`
→ exit 0.

### Step 5: Full verification

**Verify**: `flutter test` → all pass. `flutter analyze lib/` → no new errors.

### Step 6: Manual confirmation (required — this is a timing bug)

Automated tests cover Step 1's operator, not the end-to-end symptom. Perform
and report:

1. Run the app on Windows with **TUN mode enabled** and a profile with many
   proxies.
2. Connect, and open the proxy list **immediately** — before the core finishes
   starting.
3. Confirm the list populates within a few seconds and continues updating.
4. Then switch config while connected and confirm the list repopulates.
5. Repeat in proxy (non-TUN) mode to confirm no regression.

If you cannot run the app on Windows, say so explicitly rather than claiming
this passed.

## Test plan

- New `test/core/utils/exception_handler_test.dart` covering resume-after-error,
  normal completion, and repeated-error backoff (see Step 2).
- Pattern to follow: `test/features/profile/data/profile_parser_test.dart`.
- The end-to-end symptom is verified manually (Step 6) — there is no harness
  that can drive a real gRPC stream in this repo today.
- Verification: `flutter test` → all pass including the new tests.

## Done criteria

Machine-checkable where possible. ALL must hold:

- [ ] `grep -c "onErrorReturnWith" lib/core/utils/exception_handler.dart` returns `0`
- [ ] `test/core/utils/exception_handler_test.dart` exists; `flutter test` on it exits 0
- [ ] A test proves the stream continues emitting after an error (not just that it emits a `Left`)
- [ ] `grep -n "isInitialized" lib/hiddifycore/hiddify_core_service.dart` shows no early `return` that completes the stream
- [ ] `flutter test` exits 0
- [ ] `flutter analyze lib/` reports no new errors
- [ ] If Step 4 was taken: `cd hiddify-core && go build ./v2/...` exits 0, and the parent repo's submodule pointer is unchanged unless explicitly requested
- [ ] `git status` shows no unexpected files modified
- [ ] Step 6 performed and result stated (including "could not run")
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Changing `handleExceptions` breaks a caller that **relies** on termination —
  check each of the call sites listed in "Current state" for code that treats
  stream completion as a meaningful signal (e.g. a `.last`, an `await for` that
  expects to exit). If any does, report it before proceeding.
- The backoff cannot be made injectable without changing the public signature
  of `handleExceptions` in a way that breaks callers.
- `flutter test` shows previously-passing tests failing after Step 1 — the
  resume semantics may be leaking into something that polled these streams.
- Step 6 shows the proxy list still fails to populate in TUN mode. That means
  the 5-second Go-side window is not the (only) trigger; report the observed
  timing and the app-log lines around it rather than guessing at another fix.

## Maintenance notes

- **Step 1 is the high-value change and it is repo-wide.** `handleExceptions`
  wraps the log, stats, proxy and profile watchers. Making it resume fixes a
  whole class of "UI froze until restart" behavior, and correspondingly it is
  the change most likely to have surprising second-order effects. A reviewer
  should look specifically for callers that depended on the stream ending.
- The backoff cap matters: without it, a core that is down (rather than slow)
  turns this into a reconnect hot-loop against a dead gRPC endpoint. 30 seconds
  is a starting point, not a measured value.
- Related, deliberately not fixed here and recorded separately in
  `plans/README.md`: the monitoring subsystem tests every outbound against up
  to 4 fallback URLs with 10 workers and a 5s timeout, retrying the whole list
  per URL when a round fully fails — roughly 90 seconds of churn for ~45
  outbounds against an unreachable server. That does not block the list (the
  `stream.Send` proves it), but it is real load and it is worth its own plan.
- `MakeSureContextIsNew`'s 5-second bound is shared by other streams. If those
  show similar symptoms, fix it there once rather than adding waits per caller.
