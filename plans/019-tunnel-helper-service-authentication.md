# Plan 019: Require a per-launch token on the elevated Tunnel helper's gRPC service

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 8653861f1c..HEAD -- v2/hcore/tunnelservice/`. If it shows
> any changes, re-read `tunnel_platform_service.go`, `tunnel_service.go`, and
> `admin_service_commander.go` live before proceeding; on a mismatch, treat
> it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED — this is the elevated helper that installs a system-wide TUN
  adapter; a broken auth check could either leave the hole open or block the
  app's own legitimate control flow (install/start/stop/uninstall)
- **Depends on**: none (independent of plan 018, which covers a different
  gRPC server — the main core control channel, not this helper)
- **Category**: security
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`hiddify-core/v2/hcore/tunnelservice/` runs a persistent, elevated OS service
(`"HiddifyTunnelService"`, installed via `github.com/kardianos/service` with
`RunAtLoad: true` — it can be running before the main app even starts) that
exposes a gRPC server on `127.0.0.1:18020` with **zero authentication**:

`tunnel_platform_service.go:22-41` (`StartTunnelGrpcServer`):

```go
func (m *hiddifyNext) StartTunnelGrpcServer(listenAddressG string) (*grpc.Server, error) {
	lis, err := net.Listen("tcp", listenAddressG)
	if err != nil {
		log.Printf("failed to listen: %v", err)
		return nil, err
	}
	s := grpc.NewServer()
	m.tunnelService = &TunnelService{}
	RegisterTunnelServiceServer(s, m.tunnelService)
	// ... s.Serve(lis) in a goroutine, no credentials, no interceptor
```

`tunnel_service.go:22-39` (`Start`) takes a fully caller-controlled
`TunnelStartRequest` — server address, port, username, password — and builds
a TUN inbound with `AutoRoute: true` (`:52-59`) whose only outbound is a
SOCKS5 client pointed at exactly what the caller specified
(`:62-75`), **not** restricted to hiddify's own local proxy:

```go
func (s *TunnelService) Start(ctx context.Context, in *TunnelStartRequest) (*TunnelResponse, error) {
	if in.ServerPort == 0 {
		in.ServerPort = 12334
	}
	option := makeTunnelConfig(in)
	box, err := hcore.NewService(ctx, option)
	// ...
```

and `Exit` (`:131-142`) unconditionally schedules `os.Exit(0)` on the whole
elevated process with no check at all. Net effect: **any unprivileged local
process** on the machine can connect to `127.0.0.1:18020` and either
redirect all system traffic through an attacker-chosen SOCKS server (no UAC
prompt needed — the service is already running elevated) or kill the helper
outright. The legitimate caller,
`admin_service_commander.go:66,90,111` (`startTunnelRequest`,
`stopTunnelRequest`, `ExitTunnelService`), itself dials with
`grpc.WithInsecure()` and no credentials — confirming there is currently no
auth mechanism anywhere in this path to preserve, only one to add.

## Current state

Files this plan touches:

- `hiddify-core/v2/hcore/tunnelservice/tunnel_platform_service.go` — starts
  the gRPC server (`StartTunnelGrpcServer`) and the OS service lifecycle
  (`Start`/`Stop`, `:43-56`).
- `hiddify-core/v2/hcore/tunnelservice/tunnel_service.go` — the RPC handlers
  (`Start`, `Stop`, `Exit`, `Status`).
- `hiddify-core/v2/hcore/tunnelservice/admin_service_commander.go` — the
  legitimate in-process caller (`startTunnelRequest`, `stopTunnelRequest`,
  `ExitTunnelService`, all using `tunnelServiceAddress` at `:20`).
- `hiddify-core/v2/hcore/icmpservice/icmp_service.go:40-44` — existing,
  directly reusable pattern for token generation in this codebase:

  ```go
  func newSessionID() string {
  	var b [16]byte
  	_, _ = rand.Read(b[:])
  	return hex.EncodeToString(b[:])
  }
  ```

  (uses `crypto/rand` + `encoding/hex`, no new dependency). Reuse this exact
  shape for the auth token rather than inventing a different generator.

No file-based token/secret mechanism exists anywhere in `v2/hcore/tunnelservice`
or `v2/hcore/icmpservice` today — this plan introduces the first one, in a
new shared helper (see Step 1) since plan 020 (the ICMP helper, same
unauthenticated-loopback shape, different service) needs the identical
mechanism and duplicating it would be the wrong rung of effort for two
call sites doing the exact same thing.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core && go build ./v2/hcore/...` | exit 0 |
| Vet | `cd hiddify-core && go vet ./v2/hcore/...` | exit 0 (note: a prior audit pass found `go vet`/`go list -m all` can fail to resolve standalone from the `hiddify-core` root because nested submodules under `hiddify-sing-box/replace/` aren't checked out in this environment — if that happens, scope the command to `./v2/hcore/tunnelservice/...` and `./v2/hutils/...` specifically, which don't depend on that replace directive, rather than trying to fix the unrelated submodule checkout) |
| Test | `cd hiddify-core && go test ./v2/hcore/tunnelservice/... ./v2/hutils/...` | all pass, including the new tests from Step 4 |

## Scope

**In scope**:
- `hiddify-core/v2/hutils/` (new file, e.g. `service_token.go` — a small
  shared token-generate/persist/read helper used by this plan and plan 020)
- `hiddify-core/v2/hcore/tunnelservice/tunnel_platform_service.go`
- `hiddify-core/v2/hcore/tunnelservice/tunnel_service.go` (only if the
  interceptor needs a hook here rather than purely in
  `tunnel_platform_service.go` — prefer keeping the interceptor entirely in
  `tunnel_platform_service.go`'s `StartTunnelGrpcServer` via
  `grpc.ChainUnaryInterceptor`, so `tunnel_service.go`'s RPC handlers don't
  need to change at all)
- `hiddify-core/v2/hcore/tunnelservice/admin_service_commander.go`

**Out of scope**:
- `hiddify-core/v2/hcore/icmpservice/` — planned separately (plan 020),
  which will import and reuse the shared helper this plan adds to `hutils`,
  but do not modify icmpservice files from this plan.
- `hiddify-core/v2/hcore/grpc_server.go` (the main core control channel) —
  plan 018's concern, a fully separate server/port. Do not touch it or its
  interceptor from this plan.
- Any change to `TunnelStartRequest`'s proto fields, or to
  `makeTunnelConfig`'s routing logic.
- Windows-ACL hardening of the token file beyond standard file permissions —
  a deeper OS-specific hardening pass is a reasonable follow-up, not part of
  this plan (see Maintenance notes).

## Git workflow

- Branch: `advisor/019-tunnel-service-auth`
- Commit 1: shared token helper in `hutils`. Commit 2: server-side
  interceptor + token generation/persistence in `tunnel_platform_service.go`.
  Commit 3: client-side (`admin_service_commander.go`) reads and sends the
  token.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a shared token helper in `hutils`

Create `hiddify-core/v2/hutils/service_token.go`:

```go
package hutils

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
)

// GenerateAndPersistServiceToken creates a new random token and writes it to
// a file named "<name>.token" next to the given directory, with permissions
// restricting it to the current user (0600). Call this once, from the
// elevated service process itself, when it starts.
func GenerateAndPersistServiceToken(dir, name string) (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	token := hex.EncodeToString(b[:])
	path := filepath.Join(dir, name+".token")
	if err := os.WriteFile(path, []byte(token), 0o600); err != nil {
		return "", err
	}
	return token, nil
}

// ReadServiceToken reads back a token written by GenerateAndPersistServiceToken.
func ReadServiceToken(dir, name string) (string, error) {
	path := filepath.Join(dir, name+".token")
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
```

**Verify**: `cd hiddify-core && go build ./v2/hutils/...` → exit 0.

### Step 2: Generate the token when the service starts, and check it via an interceptor

In `tunnel_platform_service.go`, generate the token in `(m *hiddifyNext) Start`
(the OS-service lifecycle entry point, `:43-46`) before calling
`StartTunnelGrpcServer`, using `getCurrentExecutableDirectory()` (already
defined at `:58-68`) as the directory:

```go
func (m *hiddifyNext) Start(s service.Service) error {
	token, err := hutils.GenerateAndPersistServiceToken(getCurrentExecutableDirectory(), "tunnel")
	if err != nil {
		return err
	}
	_, err = m.StartTunnelGrpcServer(fmt.Sprintf("127.0.0.1:%d", port), token)
	return err
}
```

Change `StartTunnelGrpcServer`'s signature to accept the token and wire a
unary interceptor rejecting any call whose incoming gRPC metadata `token` key
doesn't match (constant-time compare via `crypto/subtle.ConstantTimeCompare`):

```go
func (m *hiddifyNext) StartTunnelGrpcServer(listenAddressG string, token string) (*grpc.Server, error) {
	lis, err := net.Listen("tcp", listenAddressG)
	if err != nil {
		log.Printf("failed to listen: %v", err)
		return nil, err
	}
	s := grpc.NewServer(grpc.ChainUnaryInterceptor(tokenAuthInterceptor(token)))
	m.tunnelService = &TunnelService{}
	RegisterTunnelServiceServer(s, m.tunnelService)
	// ... unchanged below
```

Add `tokenAuthInterceptor` (same file or a new small `auth.go` in this
package):

```go
func tokenAuthInterceptor(expected string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		md, ok := metadata.FromIncomingContext(ctx)
		if !ok || subtle.ConstantTimeCompare([]byte(strings.Join(md.Get("token"), "")), []byte(expected)) != 1 {
			return nil, status.Error(codes.Unauthenticated, "missing or invalid token")
		}
		return handler(ctx, req)
	}
}
```

Add the needed imports (`context`, `crypto/subtle`, `strings`,
`google.golang.org/grpc/metadata`, `google.golang.org/grpc/codes`,
`google.golang.org/grpc/status`, and `github.com/hiddify/hiddify-core/v2/hutils`).

**Verify**: `cd hiddify-core && go build ./v2/hcore/tunnelservice/...` → exit 0.
`grep -n "tokenAuthInterceptor" v2/hcore/tunnelservice/tunnel_platform_service.go`
shows it defined and passed into `grpc.NewServer(...)`.

### Step 3: Have the legitimate client read and send the token

In `admin_service_commander.go`, read the token file (written by Step 2) and
attach it as outgoing gRPC metadata on every call. Add a small helper:

```go
func dialTunnelService() (*grpc.ClientConn, context.Context, context.CancelFunc, error) {
	token, err := hutils.ReadServiceToken(getCurrentExecutableDirectory(), "tunnel")
	if err != nil {
		return nil, nil, nil, fmt.Errorf("read tunnel service token: %w", err)
	}
	conn, err := grpc.Dial(tunnelServiceAddress, grpc.WithInsecure())
	if err != nil {
		return nil, nil, nil, err
	}
	ctx := metadata.AppendToOutgoingContext(context.Background(), "token", token)
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	return conn, ctx, cancel, nil
}
```

`getCurrentExecutableDirectory()` is defined in `tunnel_platform_service.go`
in the same package — no new import needed for that symbol. Replace each of
`startTunnelRequest`, `stopTunnelRequest`, `ExitTunnelService`'s manual
`grpc.Dial` + `context.WithTimeout(context.Background(), ...)` pairs with a
call to this helper, keeping each function's original timeout duration
(5s / 20s / 1s respectively — pass the duration in, or keep per-call
`context.WithTimeout` wrapping the token-bearing context this helper
returns, whichever is the smaller diff against the existing code).

**Verify**: `cd hiddify-core && go build ./v2/hcore/tunnelservice/...` → exit 0.
`grep -c "ReadServiceToken" v2/hcore/tunnelservice/admin_service_commander.go`
returns at least `1`.

### Step 4: Add tests

Add `hiddify-core/v2/hutils/service_token_test.go`:

```go
package hutils

import "testing"

func TestGenerateAndPersistServiceToken_RoundTrips(t *testing.T) {
	dir := t.TempDir()
	token, err := GenerateAndPersistServiceToken(dir, "test")
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	if len(token) != 32 { // 16 bytes hex-encoded
		t.Fatalf("expected 32-char hex token, got %d chars", len(token))
	}
	read, err := ReadServiceToken(dir, "test")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if read != token {
		t.Fatalf("expected %q, got %q", token, read)
	}
}
```

Add `hiddify-core/v2/hcore/tunnelservice/tunnel_platform_service_test.go`
asserting the interceptor rejects a call with no/wrong token metadata and
accepts one with the correct token — start a real
`StartTunnelGrpcServer` on an ephemeral port (`"127.0.0.1:0"`, then read back
the actual assigned port from the listener) inside the test, dial it with
`grpc.WithInsecure()`, and call `Status` (the least side-effecting RPC) with
and without correct metadata.

**Verify**: `cd hiddify-core && go test ./v2/hutils/... ./v2/hcore/tunnelservice/...`
→ all pass, including the 2 new test functions.

## Test plan

- `hutils/service_token_test.go`: round-trip generate → read, per Step 4.
- `tunnelservice/tunnel_platform_service_test.go`: interceptor rejects
  missing/wrong token, accepts correct token, per Step 4. Model the gRPC
  test-server harness after any existing `*_test.go` in `v2/hcore/` that
  starts a real server (check `start_test.go` for this repo's convention on
  spinning up a server in a test).
- Verification: `go test ./v2/hutils/... ./v2/hcore/tunnelservice/...` → all
  pass.

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/hutils/... ./v2/hcore/tunnelservice/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/hutils/... ./v2/hcore/tunnelservice/...` passes, including the 2 new test files
- [ ] A call to `Start`/`Stop`/`Exit` on the tunnel service without the correct `token` metadata is rejected with `codes.Unauthenticated` (proven by the new test)
- [ ] `startTunnelRequest`/`stopTunnelRequest`/`ExitTunnelService` in `admin_service_commander.go` all send the token
- [ ] `git status` shows changes only to the files in Scope, plus `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any of the three source files don't match the excerpts in "Current state"
  (drift since this plan was written) — re-read the live code before
  proceeding.
- `go build`/`go vet` fails for a reason unrelated to this change (e.g. the
  nested-submodule checkout issue noted in the Commands table) — scope
  commands narrower rather than trying to fix an unrelated checkout gap.
- The token file location (next to the executable) turns out to be
  unwritable in practice on one of the two supported OSes (`isSupportedOS()`
  at `admin_service_commander.go:24-26` — windows and linux) because the
  install directory requires elevation to write and the service runs under a
  different effective user than expected — if you can determine this from
  reading `service.Config`'s `Option` map or `kardianos/service`'s docs,
  choose an OS-appropriate writable-by-both-service-and-caller location
  instead (e.g. a per-machine ProgramData/`/etc` path) and note the change;
  if you can't determine this confidently, STOP and report rather than
  guessing a path that might not work on one OS.
- A test you add fails and you can't explain why from reading the code once
  more — report the failure rather than weakening the interceptor to make it
  pass.

## Maintenance notes

- The token file's permissions (`0o600`) restrict it on Linux; on Windows,
  `os.WriteFile` with a mode argument does not set NTFS ACLs the way POSIX
  permissions imply — the practical protection on Windows comes from the
  file living in a directory only an admin can write to (the same directory
  as the installed service executable, typically Program-Files-equivalent).
  A future hardening pass could set an explicit Windows ACL on the token
  file; not done here to keep this plan's blast radius to the actual
  vulnerability (unauthenticated RPCs), not a broader Windows-security
  investment.
- Plan 020 (the ICMP helper) reuses `hutils.GenerateAndPersistServiceToken`/
  `ReadServiceToken` added here — if this plan's helper API changes shape
  during implementation (e.g. different parameter order), update plan 020's
  excerpts to match before executing it, or note the mismatch when that
  plan runs.
- If the tunnel service is ever reinstalled/upgraded while a stale token file
  from a previous version exists, the new service instance's `Start` always
  regenerates the token (overwriting the file), so there's no stale-token
  window across upgrades — only across a service restart is there a brief
  window where old clients holding a stale in-memory token would fail (they
  re-read the file per-call in this design, so this isn't actually an issue,
  but worth knowing why the design reads-per-call rather than caching the
  token in the client).
