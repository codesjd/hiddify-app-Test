# Plan 030: Add narrow, harness-free tests for `v2/hcore`'s control-plane RPCs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. This plan is TEST-ONLY. When done, update the
> status row for this plan in `plans/README.md` — unless a reviewer
> dispatched you and told you they maintain the index.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 8653861f1c6b87f4833e4bc3182af4b32c53b711..HEAD -- v2/hcore/stop.go v2/hcore/restart.go v2/hcore/pause.go v2/hcore/coreinfo.go v2/hcore/static_data.go`.
> If any changed, re-read the live functions before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S (deliberately narrow — see Why this matters)
- **Risk**: LOW (test-only)
- **Depends on**: none
- **Category**: tests
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`v2/hcore/`'s only two test files today —
`log_interface_test.go` and `start_test.go` — were read in full during this
planning pass and are both legitimate, non-tautological tests:
`TestLogInterfaceWriteMessageDoesNotRecurse` reproduces a real documented
production incident (a 166,000-frame logging recursion) with a genuine
fake-logger + subscriber-channel assertion, and
`TestBuildConfig_StartServicePanic` asserts both an error return and that
`static.CoreState` stays `STOPPED` after a bad config. But that's 2 of
roughly 24 files in this package — the control-plane RPCs that every client
calls to start/stop/restart/pause the VPN (`Stop`, `Restart`, `Close`,
`Pause`/`Wake`) have zero coverage.

Full coverage of these would need a fake or stubbed sing-box instance (an L
effort in its own right — `static.StartedService` is a real
`*daemon.StartedService` from the vendored sing-box fork, not easily faked).
This plan deliberately does **not** attempt that. Instead it covers the
cheapest, highest-value slice: the state-machine behavior of these RPCs
**before any core instance has started** — which is itself a real, exercised
path (every fresh app launch, every "stop when already stopped" double-tap)
and currently has zero coverage of its own.

## Current state

Read directly from the live files:

**`Stop()`** (`stop.go:15-44`) — when called with no started service
(`static.StartedService == nil`, the state on a fresh process — see
`static_data.go:37-38`, `CoreState: CoreStates_STOPPED` and
`StartedService` left as its zero value `nil`), returns immediately without
touching the (nonexistent) service:

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
	// ... (not reached when ss is nil) ...
}
```

**`SetCoreStatus`** (`coreinfo.go:10-25`) returns a `*CoreInfoResponse` with
fields `CoreState`, `MessageType`, `Message` (confirmed at
`hcore.pb.go:324-332`), and as a side effect sets `static.CoreState = state`
and publishes to `static.coreInfoObserver`.

**`(*CoreService).Close`** (`pause.go:11-23`) — handles two "nothing to do"
cases without touching the (guarded-elsewhere, see the CORRECTNESS finding
already recorded for this file) `grpcServer` map in a way that panics:

```go
func (s *CoreService) Close(ctx context.Context, closeReq *CloseRequest) (*hcommon.Empty, error) {
	if closeReq == nil {
		return nil, nil
	}
	mode := closeReq.Mode
	if grpcServer[mode] == nil {
		Log(LogLevel_WARNING, LogType_CORE, "grpcServer already stoped")
		return nil, nil
	}
	CloseGrpcServer(mode)
	return &hcommon.Empty{}, nil
}
```

**`Restart`** (`restart.go:15-46`) calls `Stop()` first (so it inherits the
"already stopped" no-op path above when nothing is running), then — only if
`static.HiddifyOptions.EnableTun` is true — waits 1s or for context
cancellation, then calls `StartService(ctx, in)`. Since
`static.HiddifyOptions` is `nil` on a fresh instance (see `static_data.go`'s
zero-value struct literal — `HiddifyOptions` is never initialized there),
`static.HiddifyOptions.EnableTun` on a never-configured instance would be a
**nil pointer dereference** — this is worth confirming directly as part of
this plan's first test (see Step 3's note).

`static` is a package-level singleton (`static_data.go:37-44`) shared across
all tests in this package (already true of the existing `start_test.go`,
which relies on the same shared state) — write new tests to be safe to run
in any order relative to each other and the existing two, not to assume a
pristine reset.

Repo convention for this package: `testify/require` is imported and used
(`start_test.go:9`, `require.Error`, `require.Equal`) — unlike `v2/config`
(plain stdlib `testing`), this package already depends on `testify`. Match
this package's convention and use `require` here too.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Run the new tests | `cd hiddify-core && go test ./v2/hcore/... -run "TestStop|TestClose|TestRestart" -v` | all new tests pass |
| Run the whole package's tests | `cd hiddify-core && go test ./v2/hcore/...` | all pass, including the 2 existing tests |

Note: scope commands to `./v2/hcore/...` — a prior audit pass found the
`hiddify-core` root doesn't always resolve standalone (nested
`hiddify-sing-box/replace/*` submodules may not be checked out). If even the
scoped command fails to resolve, report the exact error.

## Scope

**In scope**:
- `hiddify-core/v2/hcore/control_plane_test.go` (create — this plan's only
  file)

**Out of scope**:
- Any production code change, including the nil-pointer-dereference risk
  noted above in `Restart` — if Step 3's test confirms that risk is real (a
  panic, not a clean error), do NOT fix it here; report it clearly in your
  final summary as a distinct, higher-severity finding (it would mean
  `Restart` crashes the whole process on a fresh instance with
  `EnableTun` ever having been configured true from a prior run, since
  `HiddifyOptions` persists across restarts via the DB per `Setup`'s logic in
  `grpc_server.go`) and write the test to characterize what actually happens
  (pass if it errors cleanly, and clearly mark/skip with a comment
  explaining why if it would panic the test binary — see Step 3).
- Building any fake/stub sing-box instance — out of scope for this pass,
  see Why this matters. A full-coverage follow-up for `Pause`/`Wake` (which
  both no-op safely when `static.Instance()` is nil, per `pause.go:26,41` —
  actually already safe to call with no instance, feel free to add a cheap
  test for these two in this same file since they need no harness at all,
  see Step 4) and the streaming RPCs (`proxy_info.go`,
  `GetSystemInfoStream`) is a larger, separate effort.
- `log_interface_test.go`, `start_test.go` — already covered, don't modify.

## Git workflow

- Branch: `advisor/030-hcore-control-plane-tests`
- One commit.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Test `Stop()` when nothing is started

Create `hiddify-core/v2/hcore/control_plane_test.go`:

```go
package hcore

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestStop_WhenNotStarted_ReturnsAlreadyStopped(t *testing.T) {
	static.lock.Lock()
	static.StartedService = nil
	static.lock.Unlock()

	resp, err := Stop()

	require.NoError(t, err)
	require.NotNil(t, resp)
	require.Equal(t, CoreStates_STOPPED, resp.CoreState)
	require.Equal(t, MessageType_ALREADY_STOPPED, resp.MessageType)
	require.Equal(t, CoreStates_STOPPED, static.CoreState)
}
```

**Verify**: `cd hiddify-core && go test ./v2/hcore/... -run TestStop_WhenNotStarted -v` → passes.

### Step 2: Test `Close()`'s two no-op paths

Append:

```go
func TestClose_NilRequest_ReturnsNilNoError(t *testing.T) {
	resp, err := (&CoreService{}).Close(context.Background(), nil)
	require.NoError(t, err)
	require.Nil(t, resp)
}

func TestClose_UnstartedMode_ReturnsNilNoError(t *testing.T) {
	// Use a mode that (per this test file's isolation) has no live grpcServer entry.
	resp, err := (&CoreService{}).Close(context.Background(), &CloseRequest{Mode: SetupMode_GRPC_BACKGROUND})
	require.NoError(t, err)
	require.Nil(t, resp)
}
```

Add `"context"` to the import block.

**If `TestClose_UnstartedMode_ReturnsNilNoError` fails** because
`SetupMode_GRPC_BACKGROUND` happens to have a live server in
`grpcServer` (e.g. if tests run in a process where `Setup` was already
called by some other test) — pick a `SetupMode` value you've confirmed has
no entry by reading `grpcServer` at the point of the test, or add a
`t.Cleanup` that removes it first; do not assume `grpcServer` is empty
without checking.

**Verify**: `cd hiddify-core && go test ./v2/hcore/... -run TestClose -v` → both pass.

### Step 3: Test `Restart()` when nothing is started

This is the test that also answers the nil-pointer-dereference question
raised in "Current state". Write it defensively so it reports the actual
behavior rather than crashing the test binary if a panic occurs:

```go
func TestRestart_WhenNotStarted_DoesNotPanic(t *testing.T) {
	static.lock.Lock()
	static.StartedService = nil
	static.lock.Unlock()

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("Restart panicked instead of returning an error: %v (this indicates static.HiddifyOptions is nil-dereferenced in restart.go's EnableTun check when the instance was never configured — report this as a correctness finding, do not fix it in this test-only plan)", r)
		}
	}()

	_, err := Restart(context.Background(), &StartRequest{ConfigContent: "{}"})
	// Not asserting a specific error here - the point of this test is that a fresh,
	// never-configured instance can call Restart without crashing the process.
	// If it happens to succeed or fail cleanly, both are acceptable; only a panic is not.
	_ = err
}
```

**Verify**: `cd hiddify-core && go test ./v2/hcore/... -run TestRestart_WhenNotStarted -v` →
passes. **If it fails with the `t.Fatalf` panic message above**: that
confirms the nil-pointer-dereference risk is real. Do not fix
`restart.go` — leave the test as committed (it will show as a failure,
which is itself the point — a red test flagging a real bug is more valuable
here than a green test that silently works around it), and report this
prominently and specifically in your final summary as a new, higher-priority
finding: "`Restart()` panics on a freshly-started instance whose
`HiddifyOptions` was never set, via a nil pointer dereference on
`static.HiddifyOptions.EnableTun` at `restart.go`'s EnableTun check."

### Step 4: Test `Pause()`/`Wake()` no-op safely with no instance

Both already guard on `static.Instance()` being non-nil
(`pause.go:26,41`) — cheap to confirm they don't panic with no core running:

```go
func TestPauseWake_NoInstance_DoesNotPanic(t *testing.T) {
	require.NotPanics(t, func() {
		Pause()
		Wake()
	})
}
```

**Verify**: `cd hiddify-core && go test ./v2/hcore/... -run TestPauseWake -v` → passes.

### Step 5: Run the full package test suite

**Verify**: `cd hiddify-core && go test ./v2/hcore/...` → all pass (2
existing + 6 new tests), UNLESS Step 3 revealed the panic, in which case the
full suite will show that one failure — that is the expected, correct
outcome per Step 3's instructions; report it rather than silencing it.

## Test plan

This plan's entire content is the test addition — 6 new test functions in
`hiddify-core/v2/hcore/control_plane_test.go`:
`TestStop_WhenNotStarted_ReturnsAlreadyStopped`,
`TestClose_NilRequest_ReturnsNilNoError`,
`TestClose_UnstartedMode_ReturnsNilNoError`,
`TestRestart_WhenNotStarted_DoesNotPanic`,
`TestPauseWake_NoInstance_DoesNotPanic` (5 — recount matches Steps 1,2×2,3,4).
Verification: `cd hiddify-core && go test ./v2/hcore/...` → all pass (or,
per Step 3, one intentional failure surfacing a real bug — report it, don't
suppress it).

## Done criteria

- [ ] `hiddify-core/v2/hcore/control_plane_test.go` exists with the 5 test functions above
- [ ] `cd hiddify-core && go test ./v2/hcore/...` runs to completion (exit 0 expected; a Step-3 panic-turned-failure is an acceptable, reportable outcome — see Step 3)
- [ ] `git status` (in the `hiddify-core` submodule) shows changes only to `v2/hcore/control_plane_test.go`
- [ ] `plans/README.md` status row updated, explicitly noting whether Step 3 surfaced the nil-pointer-dereference finding

## STOP conditions

- Any function cited in "Current state" doesn't match its excerpt (drift
  since this plan was written) — re-read the live function before writing
  its test.
- A test other than the intentional Step-3 case fails unexpectedly — do not
  modify production code to make it pass; report the failure.
- Running the new tests corrupts shared `static` state in a way that makes
  the two *existing* tests (`start_test.go`, `log_interface_test.go`) start
  failing when run in the same `go test` invocation — if so, add
  `t.Cleanup` calls to restore whatever fields your new tests mutated
  (`static.StartedService`, `static.CoreState`) to their prior values, rather
  than leaving cross-test pollution.

## Maintenance notes

- This plan is intentionally narrow (S effort) — see Why this matters. A
  comprehensive follow-up covering `GetAllProxiesInfo`/`AllProxiesInfoStream`
  (`proxy_info.go`) and the streaming RPCs would need a fake/stub sing-box
  instance and is a substantially larger effort; not attempted here.
- If Step 3 confirmed the `Restart`/`HiddifyOptions` nil-dereference bug,
  that is now a documented, reproducible, committed failing test — whoever
  picks up the fix has a regression test already written; they should only
  need to add a nil-check (or ensure `static.HiddifyOptions` is
  never-nil-by-construction) and watch this test go green.
