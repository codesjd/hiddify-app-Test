# Plan 026: Fix nil-pointer panics in DeleteProfile/SetActiveProfile's not-found path

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `cd hiddify-core && git diff --stat 8653861f1c..HEAD -- v2/profile/profile_repository.go v2/hcore/grpc_server.go`
> If either file changed since this plan was written, re-read the current
> `GetProfile`/`DeleteProfile`/`SetActiveProfile` bodies before proceeding;
> on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: `hiddify-core` submodule commit `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`, 2026-07-29

## Why this matters

`DeleteProfile` and `SetActiveProfile` (`hiddify-core/v2/profile/profile_repository.go`)
both have a fallback branch, used whenever the gRPC request doesn't set
`Id` (e.g. it identifies the profile by `Name` or `Url` instead), that calls
`GetProfile` and then immediately dereferences its result without checking
whether the call itself failed:

```go
profile, err1 := s.GetProfile(ctx, req)
if profile.Profile == nil {
```

`GetProfile` (`profile_repository.go:25-45`) returns `(nil, error)` — not a
non-nil struct with a nil `.Profile` field — on every one of its failure
paths: an unrecognized request shape (`:37`, `return nil, fmt.Errorf(...)`)
and a lookup failure (`:41`, same). So the common case this branch exists to
handle — "the caller asked for a profile by name/URL and it doesn't exist" —
is exactly the case where `profile` itself is `nil`, and `profile.Profile`
on the very next line is a nil-pointer dereference, not a graceful "not
found" response.

Verified directly in this pass: **no panic-recovery interceptor is
registered anywhere in the gRPC server this handler runs under.**
`grep -rn "UnaryInterceptor\|StreamInterceptor\|recover()" hiddify-core/v2/hcore/*.go`
(excluding `_test.go`) returns nothing; the only `recover()` in the whole
module scoped to this concern is inside `db.getDB`
(`v2/db/hiddify_db.go:28-32`), unrelated to this handler. `grpc-go`'s default
behavior for an unrecovered panic in a handler goroutine is to crash the
whole process (there's no per-call isolation without an explicit recovery
interceptor). So the practical impact of this bug is: any client request to
delete or activate a profile by name/URL that doesn't match an existing
profile **crashes the entire core process** — taking down the active VPN
connection and every other in-flight RPC, not just returning a "not found"
error to the one caller who mistyped a name.

## Current state

`hiddify-core/v2/profile/profile_repository.go` — the file to change. The
three relevant functions as they exist today:

`GetProfile` (`:25-45`):

```go
func (s *ProfileRepositoryServer) GetProfile(ctx context.Context, req *ProfileRequest) (*ProfileResponse, error) {
	var profile *ProfileEntity
	var err error

	switch {
	case req.Id != "":
		profile, err = GetById(req.Id)
	case req.Name != "":
		profile, err = GetByName(req.Name)
	case req.Url != "":
		profile, err = GetByUrl(ctx, req.Url)
	default:
		return nil, fmt.Errorf("invalid request: %v", req)
	}

	if err != nil {
		return nil, fmt.Errorf("error fetching profile: %v", err)
	}

	return &ProfileResponse{Profile: profile}, nil
}
```

`DeleteProfile` (`:68-88`):

```go
func (s *ProfileRepositoryServer) DeleteProfile(ctx context.Context, req *ProfileRequest) (*hcommon.Response, error) {
	var err error
	switch {
	case req.Id != "":
		err = DeleteById(req.Id)
	default:
		profile, err1 := s.GetProfile(ctx, req)

		if profile.Profile == nil {
			err = fmt.Errorf("error deleting profile: %v", err1)
		} else {
			err = DeleteById(profile.Profile.Id)
		}
	}

	if err != nil {
		return &hcommon.Response{Message: err.Error(), Code: hcommon.ResponseCode_FAILED}, fmt.Errorf("error deleting profile: %v", err)
	}

	return &hcommon.Response{Code: hcommon.ResponseCode_OK}, nil
}
```

`SetActiveProfile` (the gRPC handler method, `:90-117` — note there is also a
package-level function of the same name at `:162-168`, a different thing;
don't confuse the two):

```go
func (s *ProfileRepositoryServer) SetActiveProfile(ctx context.Context, req *ProfileRequest) (*hcommon.Response, error) {
	var err error
	switch {
	case req.Id != "":

		var profile *ProfileEntity
		profile, err = GetById(req.Id)
		if err == nil {
			err = SetActiveProfile(profile)
		}
	default:

		var profile *ProfileResponse
		profile, err = s.GetProfile(ctx, req)

		if profile.Profile == nil {
			err = fmt.Errorf("error setting profile as active: %v", err)
		} else {
			err = SetActiveProfile(profile.Profile)
		}
	}

	if err != nil {
		return &hcommon.Response{Message: err.Error(), Code: hcommon.ResponseCode_FAILED}, fmt.Errorf("error setting profile as active: %v", err)
	}

	return &hcommon.Response{Code: hcommon.ResponseCode_OK}, nil
}
```

In both `default` branches, `profile` is the direct return value of
`s.GetProfile(...)` — when that call takes its error path, `profile` is
`nil` (a nil `*ProfileResponse`), and `profile.Profile` is a nil-pointer
dereference (reading a field off a nil pointer), not "reads `nil`
successfully". This is exactly the same bug shape in both handlers.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core && go build ./v2/...` | exit 0 |
| Vet | `cd hiddify-core && go vet ./v2/...` | exit 0 |
| Tests | `cd hiddify-core && go test ./v2/profile/...` | all pass |

(`go list -m all`/whole-module commands may not resolve standalone in this
environment — nested submodules under `hiddify-sing-box/replace/` are not
checked out here. That's a pre-existing environment limitation, not
something to fix as part of this plan.)

## Scope

**In scope**:
- `hiddify-core/v2/profile/profile_repository.go` (only the two `default`
  branches in `DeleteProfile` and `SetActiveProfile`)

**Out of scope**:
- Adding a panic-recovery interceptor to the gRPC server — that would be a
  reasonable defense-in-depth follow-up (it protects against *any* future
  unhandled panic in *any* handler, not just this one), but is a separate,
  broader change than fixing this specific bug; note it in your final
  report as a candidate follow-up rather than adding it here.
- `GetProfile` itself — its behavior (returning `nil, error` on failure) is
  reasonable and idiomatic Go; the bug is in how its two callers use the
  result, not in `GetProfile`.
- The package-level `SetActiveProfile` function (`:162-168`) — different
  function, not affected by this bug, do not touch it.
- `GetById`/`GetByName`/`GetByUrl` — not affected, do not touch them.

## Git workflow

- Branch: `advisor/026-fix-nil-pointer-profile-handlers`
- One commit. Message style: short imperative subject, e.g.
  `Fix nil pointer dereference in DeleteProfile/SetActiveProfile not-found path`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix `DeleteProfile`'s `default` branch

Change:

```go
	default:
		profile, err1 := s.GetProfile(ctx, req)

		if profile.Profile == nil {
			err = fmt.Errorf("error deleting profile: %v", err1)
		} else {
			err = DeleteById(profile.Profile.Id)
		}
	}
```

to check the error (or nil-ness of `profile` itself) before dereferencing:

```go
	default:
		profile, err1 := s.GetProfile(ctx, req)

		if err1 != nil || profile == nil || profile.Profile == nil {
			err = fmt.Errorf("error deleting profile: %v", err1)
		} else {
			err = DeleteById(profile.Profile.Id)
		}
	}
```

**Verify**: `cd hiddify-core && go build ./v2/profile/...` → exit 0.
`grep -n "err1 != nil || profile == nil || profile.Profile == nil" v2/profile/profile_repository.go`
returns at least 1 match (this exact fix appears in `DeleteProfile`).

### Step 2: Fix `SetActiveProfile`'s `default` branch

Apply the identical pattern:

```go
	default:

		var profile *ProfileResponse
		profile, err = s.GetProfile(ctx, req)

		if err != nil || profile == nil || profile.Profile == nil {
			err = fmt.Errorf("error setting profile as active: %v", err)
		} else {
			err = SetActiveProfile(profile.Profile)
		}
	}
```

Note this branch reuses the outer `err` variable (unlike `DeleteProfile`,
which used a separate `err1`) — keep that existing convention, just add the
nil guard.

**Verify**: `grep -c "err1 != nil || profile == nil || profile.Profile == nil" v2/profile/profile_repository.go`
returns `1` (only `DeleteProfile` uses `err1`) and
`grep -n "err != nil || profile == nil || profile.Profile == nil" v2/profile/profile_repository.go`
returns at least 1 match (in `SetActiveProfile`).

### Step 3: Build and vet the whole package

**Verify**: `cd hiddify-core && go build ./v2/... && go vet ./v2/...` → both
exit 0.

## Test plan

- Add a test file `hiddify-core/v2/profile/profile_repository_test.go` (if
  one doesn't already exist — check first) covering:
  - `DeleteProfile` with a request that has no `Id` and a `Name`/`Url` that
    doesn't match any stored profile → asserts the call returns a
    `hcommon.ResponseCode_FAILED` response and a non-nil error, and — most
    importantly — does not panic.
  - `SetActiveProfile` with the same not-found shape → same assertion.
  - Model the test's database setup (if any fixture/in-memory DB helper
    already exists in this package or `v2/db`) after whatever pattern
    `hiddify-core`'s existing Go tests use — check `v2/hcore/start_test.go`
    or `v2/hcore/log_interface_test.go` for this repo's Go test conventions
    before inventing a new one.
- Verification: `cd hiddify-core && go test ./v2/profile/...` → all pass,
  including the new tests, and specifically confirm the test process does
  not crash/panic on the not-found path (a panic in a Go test surfaces as a
  test failure with a stack trace, not a silent pass — visually confirm the
  new test's output shows a clean pass, not a recovered panic).

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/...` exits 0
- [ ] `cd hiddify-core && go vet ./v2/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/profile/...` passes, including new not-found-path tests for both handlers
- [ ] `git status` (inside `hiddify-core/`) shows changes only to `v2/profile/profile_repository.go` and the new test file
- [ ] `plans/README.md` (Dart repo root) status row for plan 026 updated

## STOP conditions

- `GetProfile`, `DeleteProfile`, or `SetActiveProfile` don't match the
  excerpts above (drift since this plan was written) — re-read the live
  functions and confirm the nil-dereference pattern is still present before
  applying the fix.
- A test you write reveals a *different* bug in `GetProfile`/`GetByName`/
  `GetByUrl`'s error-message formatting (e.g. `GetByName`'s error message at
  `:188` reads `"error fetching profile by ID"` even for a name-based
  lookup — a message-wording issue, not a crash) — note it in your final
  report as a separate, minor finding rather than fixing it as part of this
  plan (out of scope, see Scope).
- `go test` for this package requires infrastructure (a running LevelDB
  fixture, etc.) you cannot set up in this environment — write the test
  file anyway with clear setup code, note in your final report that it
  could not be run here, and do not claim it passes without having actually
  run it.

## Maintenance notes

- This fix does not add a panic-recovery interceptor to the gRPC server —
  that would catch *any* future unhandled panic across *every* handler
  (turning a process crash into a per-request `Internal` error), which is
  real defense-in-depth worth doing but is a broader change than this
  specific bug. Flag it as a follow-up: search for where `grpc.NewServer(...)`
  is constructed (`hiddify-core/v2/hcore/grpc_server.go`) and consider
  `grpc.UnaryInterceptor`/`grpc.ChainUnaryInterceptor` with a
  panic-recovery middleware (e.g. `google.golang.org/grpc/recovery` or a
  small hand-written one) as a repo-wide safety net.
- If `ProfileRequest` ever gains a new identifying field beyond
  `Id`/`Name`/`Url`, both `GetProfile`'s `switch` and this fix's nil-guard
  pattern in its two callers should be reviewed together — they're coupled
  by the same "how does `GetProfile` signal not-found" contract.
