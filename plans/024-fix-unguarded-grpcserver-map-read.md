# Plan 024: Fix the unguarded `grpcServer` map read in `Close`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**, inside the `hiddify-core` submodule:
> `git -C hiddify-core diff --stat 8653861f1c..HEAD -- v2/hcore/pause.go v2/hcore/grpc_server.go`.
> If either changed, re-read the live code before proceeding — in
> particular, plan 018 (a separate plan in this series) also edits
> `grpc_server.go` to add an auth interceptor; if that has already landed,
> confirm the `mu`/`grpcServer` declarations this plan depends on are still
> at the same shape before proceeding. On a mismatch, treat it as a STOP
> condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (independent of plan 018 and plan 023 — touches a
  different function in a shared file with plan 018; no line overlap
  expected, see Maintenance notes)
- **Category**: bug
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`hiddify-core/v2/hcore/grpc_server.go:171-176` declares:

```go
var (
	certpair   *hutils.CertificatePair
	grpcServer map[SetupMode]*grpc.Server = make(map[SetupMode]*grpc.Server)
	caCertPool                            = x509.NewCertPool()
	mu                                    = sync.Mutex{}
)
```

Every access to the `grpcServer` map elsewhere in `grpc_server.go` correctly
takes `mu.Lock()` first: `Setup` (`:51-52`), `StartGrpcServerByMode`
(`:194-197,241,244`), `CloseGrpcServer` (`:297-304`). The gRPC handler
`Close` in `pause.go:11-23`, however, reads the map **twice** with no lock at
all:

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

A concurrent `Setup`/`StartGrpcServerByMode` call (writing the map under
`mu`) racing with a client's `Close` RPC (reading it here, unguarded) is an
unsynchronized concurrent map access. In Go this is not just "might read a
stale value" — concurrent unsynchronized map read+write can trigger
`fatal error: concurrent map read and map write`, which crashes the entire
process (there is no recovering from it, unlike a panic), taking down every
in-flight RPC and the VPN connection with it, not just the `Close` call.

## Current state

- `hiddify-core/v2/hcore/pause.go:11-23` — the file/function to change (full
  excerpt above).
- `hiddify-core/v2/hcore/grpc_server.go:171-176,297-304` — the shared
  `grpcServer`/`mu` declarations and the existing correctly-locked
  `CloseGrpcServer`, for reference (not modified by this plan):

```go
func CloseGrpcServer(mode SetupMode) {
	mu.Lock()
	defer mu.Unlock()
	if server, ok := grpcServer[mode]; ok && server != nil {
		server.Stop()
		delete(grpcServer, mode)
	}
}
```

Note `Close` (`pause.go`) calling `CloseGrpcServer` **after** its own
unguarded check means simply wrapping `pause.go`'s check in `mu.Lock()`
directly would deadlock, since `CloseGrpcServer` immediately tries to take
the same non-reentrant `mu` again. The fix needs a helper that takes the
lock, checks, and releases **before** `CloseGrpcServer` is called — not a
lock held across both.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Go build | `cd hiddify-core && go build ./v2/hcore/...` | exit 0 |
| Go vet | `cd hiddify-core && go vet ./v2/hcore/...` | exit 0 |
| Go tests | `cd hiddify-core && go test ./v2/hcore/...` | all pass |

## Scope

**In scope**:
- `hiddify-core/v2/hcore/pause.go` (the `Close` method only)
- `hiddify-core/v2/hcore/grpc_server.go` (add one small helper function only
  — see Step 1)

**Out of scope**:
- `Pause()`/`Wake()` in the same file (`pause.go:25-49`) — unrelated to the
  `grpcServer` map, do not touch.
- Any change to `CloseGrpcServer` itself — it is already correct.
- The auth interceptor work in plan 018, which also touches
  `grpc_server.go` — different functions, should not conflict; if you find
  plan 018 has already landed and changed line numbers, just re-locate the
  `mu`/`grpcServer` declarations by name (`grep -n "grpcServer map\|mu  *=  *sync.Mutex"`)
  rather than assuming the line numbers in this plan are still exact.

## Git workflow

- Branch: `advisor/024-fix-unguarded-grpcserver-read`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Guard the grpcServer map read in Close with the existing mutex`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a small locked-read helper in `grpc_server.go`

Add this function near the other `grpcServer`/`mu`-related functions (e.g.
right after `CloseGrpcServer`):

```go
// grpcServerExists reports whether a server is currently registered for mode,
// taking mu for the duration of the check only (does not hold the lock across
// any caller-side follow-up action, to avoid deadlocking with functions like
// CloseGrpcServer that also take mu).
func grpcServerExists(mode SetupMode) bool {
	mu.Lock()
	defer mu.Unlock()
	return grpcServer[mode] != nil
}
```

**Verify**: `grep -n "func grpcServerExists" v2/hcore/grpc_server.go` returns
1 match.

### Step 2: Use the helper in `Close`

In `pause.go`, change:

```go
	mode := closeReq.Mode
	if grpcServer[mode] == nil {
		Log(LogLevel_WARNING, LogType_CORE, "grpcServer already stoped")
		return nil, nil
	}
```

to:

```go
	mode := closeReq.Mode
	if !grpcServerExists(mode) {
		Log(LogLevel_WARNING, LogType_CORE, "grpcServer already stoped")
		return nil, nil
	}
```

(There is a small, accepted TOCTOU window between this check and the
subsequent `CloseGrpcServer(mode)` call — a server could theoretically be
closed by another goroutine in between. This is not new: `CloseGrpcServer`
itself already handles a missing/nil entry safely — see its `if server, ok :=
grpcServer[mode]; ok && server != nil` guard. The fix here removes the *data
race*, not the pre-existing, already-safe TOCTOU gap.)

**Verify**: `grep -n "grpcServerExists(mode)" v2/hcore/pause.go` returns 1
match, and `grep -c "grpcServer\[mode\]" v2/hcore/pause.go` returns `0`.

### Step 3: Build and test

**Verify**: `cd hiddify-core && go build ./v2/hcore/... && go vet ./v2/hcore/...`
→ exit 0. `go test ./v2/hcore/...` → all pass.

## Test plan

- Add a test in `hiddify-core/v2/hcore/` (extend an existing test file such
  as `start_test.go`, or create `grpc_server_test.go`) that calls
  `grpcServerExists` for a mode with no registered server and asserts
  `false`, then (if a lightweight way to register a fake entry exists without
  starting a real listener — e.g. directly manipulating the `grpcServer` map
  under `mu` from the test, since the test is in the same package) asserts
  `true` for a mode with an entry present.
- If the Go race detector (`-race`) is available in this environment, run
  `go test -race ./v2/hcore/...` and confirm no race is reported (this won't
  catch the *original* bug retroactively without a concurrent reproduction,
  but confirms the fix doesn't introduce a new one).
- Model the test file's structure after `start_test.go` (`package hcore`,
  `testify/require`).

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/hcore/...` exits 0
- [ ] `cd hiddify-core && go vet ./v2/hcore/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/hcore/...` passes, including the new test
- [ ] `grep -n "func grpcServerExists" v2/hcore/grpc_server.go` returns 1 match
- [ ] `grep -c "grpcServer\[mode\]" v2/hcore/pause.go` returns `0`
- [ ] `git status` shows changes only to `v2/hcore/pause.go`, `v2/hcore/grpc_server.go`, plus a new/extended test file, and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- The code at `pause.go:11-23` or `grpc_server.go:171-176,297-304` doesn't
  match the excerpts above (drift since this plan was written, possibly from
  plan 018 landing first) — re-read the live file and re-locate the relevant
  declarations by name rather than trusting line numbers.
- Adding `grpcServerExists` causes a naming collision with an existing
  function — rename it (e.g. `hasGrpcServer`) rather than skipping the fix.
- Any existing test fails after this change — investigate; this should be a
  behavior-preserving change (same net effect, just race-free).

## Maintenance notes

- If a similar direct `grpcServer[...]` read is ever added elsewhere in this
  package, it should go through `grpcServerExists` (or a similarly locked
  accessor) rather than reading the map directly — this map is a shared,
  mutable, cross-goroutine-accessed value, not a read-only lookup table.
- This plan and plan 023 (which restructures `HiddifyInstance`'s
  `StartedService`/`HiddifyOptions` locking) are independent — they touch
  different mutexes (`mu` here vs. `optionsLock`/`atomic.Pointer` there) in
  different files. No coordination is needed between them beyond both being
  safe to land in either order.
