# Plan 023: Fix inconsistent lock discipline around `HiddifyInstance.StartedService`/`HiddifyOptions`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. This plan touches the core start/stop lifecycle
> — treat every STOP condition here as real, not boilerplate. When done,
> update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**, inside the `hiddify-core` submodule:
> `git -C hiddify-core diff --stat 8653861f1c..HEAD -- v2/hcore/static_data.go v2/hcore/start.go v2/hcore/stop.go v2/hcore/custom.go v2/hcore/buildconfighelper.go v2/hcore/restart.go`.
> If any changed, re-read the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED-HIGH — this is the VPN start/stop lifecycle; a mistake here
  can hang or crash the core, or double-close a service
- **Depends on**: none, but coordinate with plan 018 (also touches
  `hiddify-core/v2/hcore/`, different file) and plan 024 (also touches
  `hiddify-core/v2/hcore/`, different file — no line overlap expected)
- **Category**: bug
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`HiddifyInstance` (`hiddify-core/v2/hcore/static_data.go:15-35`) holds
`StartedService *daemon.StartedService` and
`HiddifyOptions *config.HiddifyOptions` as plain, unguarded pointer fields on
a single shared `static` instance. A `lock sync.Mutex` field exists
specifically for these two fields — but a repo-wide grep
(`grep -rn "static\.lock" v2/hcore/*.go`) shows it is taken in **exactly two
places**: `start.go:87-88` and `stop.go:26-27`. Every other read or write of
`StartedService`/`HiddifyOptions` — `custom.go`'s `StopAndAlert`,
`buildconfighelper.go`'s `Parse`/`ChangeHiddifySettings`/`GenerateConfig`,
`restart.go`'s read of `HiddifyOptions.EnableTun` — touches these fields with
no lock at all.

This is a real, verified data race, not a theoretical one:
`StopAndAlert` (`custom.go:14-21`) reads and nils `static.StartedService`
without the lock, and is called from a panic-recovery `defer` inside `Parse`
and `GenerateConfig` (`buildconfighelper.go:51-54`, `:146-149`) — both
gRPC-exposed handlers that can run concurrently with an in-flight
`Start`/`Stop` holding the lock. `ChangeHiddifySettings`
(`buildconfighelper.go:88-139`) replaces the whole `HiddifyOptions` pointer
and then mutates nested fields on it (`.Warp.WireguardConfig`,
`.Warp2.WireguardConfig`) with no lock, while `start.go:109` reads
`static.HiddifyOptions == nil` under the lock and `restart.go:38` reads
`static.HiddifyOptions.EnableTun` with no lock at all. Best case this causes
a stale read; worst case (per Go's memory model) it's undefined behavior on
a pointer field, and if the Go race detector were ever run against this code
under concurrent load it would flag it immediately.

**The straightforward fix (a single mutex taken everywhere) does not work
here without care**: `errorWrapper` (`start.go:8-12`) calls `StopAndAlert`,
and `errorWrapper` is itself called from *within* `Stop()`
(`stop.go:38`, `return errorWrapper(...)`) **while `Stop()` still holds
`static.lock`** (`stop.go:26-27`, `defer static.lock.Unlock()` hasn't run
yet at that point in the function). If `StopAndAlert` were changed to also
take `static.lock`, this exact call path would deadlock the process. Any fix
must account for this re-entrancy, not just sprinkle `Lock()`/`Unlock()`
around every access site.

## Current state

`static_data.go:15-35` — the struct (excerpt):

```go
type HiddifyInstance struct {
	StartedService *daemon.StartedService
	HiddifyOptions *config.HiddifyOptions
	// ...
	lock                      sync.Mutex
	// ...
}
```

`start.go:8-21` — `errorWrapper` and `StopAndAlert`, the re-entrancy hazard:

```go
func errorWrapper(state MessageType, err error) (*CoreInfoResponse, error) {
	Log(LogLevel_FATAL, LogType_CORE, err.Error())
	StopAndAlert(MessageType_UNEXPECTED_ERROR, err.Error())
	return SetCoreStatus(CoreStates_STOPPED, state, err.Error()), err
}

func StopAndAlert(msgType MessageType, message string) {
	SetCoreStatus(CoreStates_STOPPED, msgType, message)

	if ss := static.StartedService; ss != nil {
		ss.CloseService()
		static.StartedService = nil
	}
}
```

`stop.go:15-44` — `Stop()`, showing the lock is held across the call to
`errorWrapper` → `StopAndAlert` (line 38, before the deferred unlock at line
27 fires):

```go
func Stop() (coreResponse *CoreInfoResponse, err error) {
	defer config.DeferPanicToError("stop", func(recovered_err error) {
		coreResponse, err = errorWrapper(MessageType_UNEXPECTED_ERROR, recovered_err)
	})

	static.lock.Lock()
	defer static.lock.Unlock()

	SetCoreStatus(CoreStates_STOPPING, MessageType_EMPTY, "")
	ss := static.StartedService
	if ss == nil {
		return SetCoreStatus(CoreStates_STOPPED, MessageType_ALREADY_STOPPED, ""), nil
	}

	if err := ss.CloseService(); err != nil {
		static.StartedService = nil
		dumpGoroutinesToFile(fmt.Sprint(sWorkingPath, "/data/goroutine-stop.log"))
		return errorWrapper(MessageType_UNEXPECTED_ERROR, err)
	}
	static.StartedService = nil

	return SetCoreStatus(CoreStates_STOPPED, MessageType_EMPTY, ""), nil
}
```

`start.go:178` (inside `StartService`, under the same `static.lock` acquired
at `:87-88` — confirm by reading the full function) sets
`static.StartedService = instance`.

All `static.HiddifyOptions`/`static.StartedService`/`static.lock` references
in the package (confirmed exhaustively via
`grep -rn "static\.lock\|static\.StartedService\|static\.HiddifyOptions" v2/hcore/*.go`
— re-run this yourself to catch any drift):
`buildconfighelper.go:33,40,61,89,91,121,126,127,132,133,150,151,153`,
`custom.go:17,19`, `restart.go:38`, `start.go:87,88,109,178`,
`stop.go:26,27,30,36,41`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Go build | `cd hiddify-core && go build ./v2/...` | exit 0 |
| Go vet | `cd hiddify-core && go vet ./v2/hcore/... ./v2/config/...` | exit 0 |
| Go tests | `cd hiddify-core && go test ./v2/hcore/...` | all pass |

(If `go build`/`go vet` against the full `./v2/...` doesn't resolve
standalone due to nested submodules under `hiddify-sing-box/replace/` not
being checked out in this environment — a known limitation from a prior
audit pass — narrow to `./v2/hcore/... ./v2/config/...` instead of trying to
fix the checkout.)

## Scope

**In scope**:
- `hiddify-core/v2/hcore/static_data.go` (struct field types + remove `lock`)
- `hiddify-core/v2/hcore/start.go`
- `hiddify-core/v2/hcore/stop.go`
- `hiddify-core/v2/hcore/custom.go`
- `hiddify-core/v2/hcore/buildconfighelper.go`
- `hiddify-core/v2/hcore/restart.go` (the one read of `HiddifyOptions`)

**Out of scope**:
- `hiddify-core/v2/hcore/grpc_server.go`'s `mu`/`grpcServer` map lock — a
  separate mutex guarding a separate concern, fixed independently in
  plan 024. Do not touch it here.
- `hiddify-core/v2/hcore/proxy_info.go`'s read-only access to
  `h.Context()`/`h.UrlTestHistory()` — those go through their own accessor
  methods already (confirm by reading `h.Context()`'s definition before
  assuming otherwise); if you find they ALSO touch `StartedService`/`HiddifyOptions`
  unguarded, note it in your final report as a candidate follow-up rather
  than silently expanding this plan's scope.
- Any change to `config.HiddifyOptions`'s own internal structure (its fields,
  JSON tags, etc.) — only how the *pointer to it* is read/written/replaced
  changes.

## Git workflow

- Branch: `advisor/023-hiddifyinstance-lock-discipline`
- Commit 1: `StartedService` → `atomic.Pointer`. Commit 2:
  `HiddifyOptions` → guarded by a dedicated `sync.RWMutex`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Convert `StartedService` to `atomic.Pointer[daemon.StartedService]`

This sidesteps the re-entrancy problem entirely: `atomic.Pointer` has no
`Lock`/`Unlock` to deadlock on, and Go's `sync/atomic` package (Go 1.19+;
confirm the `go.mod` Go version supports generics-based `atomic.Pointer[T]`,
it requires Go 1.19+) provides exactly the safe-swap semantics this field
needs — a `daemon.StartedService` is only ever whole-pointer-replaced or
nil'd, never mutated through the field in place, which is the case atomic
pointers handle cleanly.

In `static_data.go`, change:

```go
	StartedService *daemon.StartedService
```

to:

```go
	StartedService atomic.Pointer[daemon.StartedService]
```

(add `"sync/atomic"` to the imports). Remove the now-unused `lock
sync.Mutex` field only after Step 2 also stops needing it (see Step 2 — do
not remove it yet if `HiddifyOptions` still needs a mutex; you may end up
keeping a mutex, just possibly renamed/repurposed for `HiddifyOptions` only —
decide in Step 2).

Update every call site:

- `start.go:178`: `static.StartedService = instance` → `static.StartedService.Store(instance)`
- `stop.go:30`: `ss := static.StartedService` → `ss := static.StartedService.Load()`
- `stop.go:36,41`: `static.StartedService = nil` → use `static.StartedService.Store(nil)`,
  but see the race note below — prefer `Swap` where the old value matters.
- `custom.go:17-20` (`StopAndAlert`) — this is the one call site with a
  genuine concurrent-double-close risk: two goroutines could both read a
  non-nil pointer via `Load()`, and both call `CloseService()` on the same
  `*daemon.StartedService`. Use `Swap(nil)` instead, which atomically
  retrieves-and-clears in one step so only the caller that gets the non-nil
  return value proceeds to close it:

  ```go
  func StopAndAlert(msgType MessageType, message string) {
  	SetCoreStatus(CoreStates_STOPPED, msgType, message)

  	if ss := static.StartedService.Swap(nil); ss != nil {
  		ss.CloseService()
  	}
  }
  ```

- `stop.go`'s `Stop()` function: apply the same `Swap`-based pattern for the
  `ss.CloseService()` error path (line 36) — after `Swap(nil)` returns the
  service to close, `static.lock` is no longer needed around this part of
  `Stop()` at all for the `StartedService` field specifically (only for
  `HiddifyOptions`, if Step 2 still needs it — see Step 2).

**Verify**: `cd hiddify-core && go build ./v2/hcore/...` → exit 0.
`grep -n "static.StartedService" v2/hcore/*.go` shows only `.Load()`/`.Store()`/`.Swap()`
calls, no direct field assignment/read.

### Step 2: Guard `HiddifyOptions` with a dedicated mutex (not `atomic.Pointer`)

`HiddifyOptions` cannot use the same `atomic.Pointer` treatment as
`StartedService` — `ChangeHiddifySettings` (`buildconfighelper.go:88-139`)
replaces the pointer AND then mutates nested fields through it
(`.Warp.WireguardConfig`, `.Warp2.WireguardConfig` via `json.Unmarshal`),
which an atomic pointer swap does not make safe (a concurrent reader that
already loaded the old pointer, or even the same new pointer mid-mutation,
could observe a partially-populated struct). This needs an actual
read/write-locked critical section around the group of operations, not just
a pointer swap.

Add a dedicated mutex (verified via the exhaustive grep in "Current state"
that none of `Parse`, `ChangeHiddifySettings`, `GenerateConfig`, or
`restart.go`'s read call each other or call `StopAndAlert` while holding a
`HiddifyOptions`-specific lock — there is no re-entrancy risk here the way
there was for `StartedService`, since these are independent leaf-level RPC
handlers). Reuse the existing `lock sync.Mutex` field on `HiddifyInstance`
for this (rename it `optionsLock` for clarity, since it will no longer guard
`StartedService`) rather than adding a second field:

In `static_data.go`:
```go
	HiddifyOptions *config.HiddifyOptions // still guarded by optionsLock below
	// ...
	optionsLock sync.Mutex // guards HiddifyOptions only
```//remove the old bare `lock sync.Mutex` field, replacing it with this one.

Update every read/write site to take `optionsLock`:

- `buildconfighelper.go:40` (`BuildConfig`, reads `static.HiddifyOptions`):
  wrap the read in `static.optionsLock.Lock(); opts := static.HiddifyOptions; static.optionsLock.Unlock()`
  and pass `opts` to `config.BuildConfig(...)` instead of reading the field
  inline — do this consistently at every read site (`:61`, `:150-153`,
  `restart.go:38`) rather than holding the lock across the whole function
  body (holding it only long enough to snapshot the pointer is sufficient
  for the *pointer* race; the nested-field mutation race during
  `ChangeHiddifySettings` is handled by that function holding the lock for
  its entire body — see below).
- `buildconfighelper.go:88-139` (`ChangeHiddifySettings`) — take
  `static.optionsLock.Lock()` at the top of the function and
  `defer static.optionsLock.Unlock()`, since this function both replaces the
  pointer (`:89`) and mutates nested fields through it (`:127`, `:133`) — the
  whole sequence needs to be one critical section so no reader observes a
  half-updated `HiddifyOptions`.
- `start.go:109` (`if static.HiddifyOptions == nil`) — wrap in the same
  lock/unlock-around-the-read pattern.

**Verify**: `cd hiddify-core && go build ./v2/hcore/...` → exit 0.
`grep -n "optionsLock" v2/hcore/*.go` shows it taken at every read/write site
listed above, and `grep -c "static.lock" v2/hcore/*.go` returns `0` (the old
field name is gone).

### Step 3: Confirm nothing else references the old `lock` field name

**Verify**: `grep -rn "\.lock\b" v2/hcore/*.go | grep -v optionsLock` — review
any remaining matches by hand to confirm they're unrelated (e.g. a different
type's own `lock` field, not `HiddifyInstance`'s).

### Step 4: Build and test

**Verify**: `cd hiddify-core && go build ./v2/hcore/... && go test ./v2/hcore/...`
→ exit 0, all tests pass, including the new test from the Test plan below.

## Test plan

- Add a test in `hiddify-core/v2/hcore/` (new file, e.g.
  `static_data_test.go`, or extend `start_test.go`) that starts two
  goroutines concurrently calling `StopAndAlert` (or exercises `Stop()`
  concurrently with itself) against the same `static` instance and asserts
  no panic/race — run with `go test -race ./v2/hcore/...` specifically for
  this test if the Go race detector is available in this environment (it
  requires cgo; if unavailable, note that in your report rather than
  skipping the test entirely — the test should still assert the *behavioral*
  invariant, e.g. "only one of two concurrent Swaps gets the non-nil
  service", even without `-race` confirming the absence of a data race).
- Model the test file's structure after the existing `start_test.go`
  (`package hcore`, `testify/require`, no mocking framework).
- Verification: `go test ./v2/hcore/...` → all pass, including the new
  concurrency test. If `-race` is available: `go test -race ./v2/hcore/...`
  → passes with no race reported.

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/hcore/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/hcore/...` passes, including the new concurrency test
- [ ] `grep -n "static.StartedService"` shows only `.Load()`/`.Store()`/`.Swap()` usage, no direct field access
- [ ] `grep -c "static.lock"` (old field name) returns `0`
- [ ] `grep -n "optionsLock"` shows it taken at every `HiddifyOptions` read/write site listed in Step 2
- [ ] `git status` shows changes only to the files in Scope, plus `plans/README.md`
- [ ] `plans/README.md` status row updated, noting whether `-race` was available to verify with

## STOP conditions

- Any file's current content doesn't match the excerpts in "Current state"
  (drift since this plan was written) — re-read the live code; this is a
  concurrency-sensitive fix where a stale assumption about lock ordering
  could reintroduce the exact deadlock this plan is designed to avoid.
- You find a call site where `optionsLock` would be acquired while already
  held (a reentrancy case this plan's analysis didn't account for) — STOP
  and report the exact call chain rather than guessing a fix (e.g. don't
  reach for a recursive mutex as a quick patch; report it so the call
  structure itself can be reconsidered).
- `go.mod`'s Go version is below 1.19 (no generic `atomic.Pointer[T]`
  support) — report this rather than backporting an equivalent by hand;
  the fallback (a plain `*daemon.StartedService` behind a dedicated mutex,
  same pattern as Step 2's `HiddifyOptions` fix) is an acceptable substitute
  if so, but confirm the Go version first rather than assuming.
- Any existing test starts failing after these changes — investigate before
  assuming unrelated flakiness; a lock-discipline change is exactly the kind
  of edit likely to surface a hidden ordering dependency.

## Maintenance notes

- Any future field added to `HiddifyInstance` that is read/written from more
  than one goroutine (gRPC handlers run on their own goroutines per-call)
  needs the same treatment: either an `atomic.Pointer` (whole-value swap
  semantics only) or a dedicated mutex around the group of operations that
  must appear atomic together (nested-field mutation, replace-then-mutate
  sequences). Don't add a new field and assume the struct's existing
  concurrency safety extends to it automatically.
- The `Swap(nil)`-based fix for `StopAndAlert`/`Stop()`'s double-close
  protection depends on `daemon.StartedService.CloseService()` being safe to
  call at most once per instance (which is why `Swap` matters — it hands the
  service to exactly one caller). If `CloseService()` is ever changed to be
  idempotent/safe-to-call-twice upstream, this plan's guard becomes
  belt-and-suspenders rather than load-bearing — that's fine, don't remove it
  just because it becomes redundant.
