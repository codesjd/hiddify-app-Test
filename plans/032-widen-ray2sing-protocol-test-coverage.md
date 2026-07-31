# Plan 032: Add malformed-input and TLS-variant coverage to `ray2sing`'s shallowest protocol tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. This plan is TEST-ONLY. When done, update the
> status row for this plan in `plans/README.md` — unless a reviewer
> dispatched you and told you they maintain the index.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 8653861f1c6b87f4833e4bc3182af4b32c53b711..HEAD -- ray2sing/ray2sing_test/vmess_test.go ray2sing/ray2sing_test/trojan_test.go ray2sing/ray2sing/vmess.go ray2sing/ray2sing/trojan.go ray2sing/ray2sing/test.go`.
> If any changed, re-read the live files before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (test-only)
- **Depends on**: none
- **Category**: tests
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`ray2sing/ray2sing_test/` has 18 protocol test files. `CheckUrlAndJson`
(`ray2sing/ray2sing/test.go:15-39`, verified directly) is a genuine test
helper, not a tautology — it does a real `reflect.DeepEqual` between the
parsed outbound and an expected JSON-decoded structure. But **a prior audit
pass's characterization of the gap needs a correction**, made during this
planning pass by actually reading the files: several "shallow" single-case
files (`vless_test.go`, `trojan_test.go`, `tuic_test.go`) already exercise a
TLS+transport-variant URL in their one test case — the audit's blanket "no
TLS/transport variant coverage" claim doesn't hold for those three. What
**is** genuinely, verifiably missing across the board: error-path coverage.
A repo-wide check
(`grep -rln "err ==\|err !=\|wantErr\|ExpectErr\|expectErr" ray2sing/ray2sing_test/*.go`)
shows only 7 of 18 test files assert on any error condition at all —
`vmess_test.go`, `vless_test.go`, `trojan_test.go`, `tuic_test.go`,
`ssh_test.go`, `hysteria_test.go`, `hysteria2_test.go`, `wiregaurd_test.go`,
`beepass_test.go` (9 of the 11 without an error assertion) test only the
happy path for a link the parser is known to handle — none of them confirm
what happens when a link is malformed, which is exactly the input class a
parser fed untrusted subscription content actually needs to be robust
against.

This plan adds: one TLS+websocket-variant case to `vmess_test.go` (the one
file, of those read directly, that genuinely only covers a plain-TCP/
no-TLS case today) and one malformed-input case each to `vmess_test.go` and
`trojan_test.go`, with the exact pattern spelled out so it can be mechanically
extended to `vless_test.go`/`tuic_test.go`/the rest of the 9 error-path-less
files next.

## Current state

**`vmess_test.go`** (read in full) has one test, `TestVmess`, covering a
plain-TCP, no-TLS vmess link (`"net":"tcp"`, `"tls":""` in the decoded JSON
payload — confirmed by base64-decoding the URL in the existing test). This
is the one file in this plan's scope that's genuinely missing a TLS variant.

**`VmessSingbox`** (`ray2sing/ray2sing/vmess.go:46-56+`) — verified
directly: it calls `decodeVmess(vmessURL)` first and returns its error
immediately on failure (`:47-50`), before touching any other field. This is
the cleanest error-path test target — a malformed base64 payload makes
`decodeVmess` fail deterministically.

**`trojan_test.go`** (read in full) already covers a TLS+websocket variant
(see `Why this matters`) — it does not need a TLS-variant addition, only an
error-path one. **`TrojanSingbox`** (`ray2sing/ray2sing/trojan.go`, in full)
calls `ParseUrl(trojanURL, 443)` first and returns its error immediately
(`:8-11`). `ParseUrl` (`ray2sing/ray2sing/url_schema.go:34-38`) itself only
errors when Go's standard `url.Parse` fails — which happens for URLs
containing invalid escape sequences or control characters, not merely
"missing" fields (a missing password/host doesn't error at this layer, it
just produces an empty string). Use an invalid percent-escape to trigger a
real `url.Parse` failure deterministically (e.g. a bare `%` not followed by
two hex digits).

**The shared helper** (`ray2sing/ray2sing/test.go:15-39`, `CheckUrlAndJson`)
does not have an error-path equivalent — it always calls `t.Fatalf` if
`Ray2Singbox` returns an error. This plan does not modify `test.go`; new
error-path tests call `ray2sing.Ray2Singbox` directly and assert on the
error themselves, matching the pattern already used to invoke the shared
helper.

**`Ray2Singbox`** (the entry point `CheckUrlAndJson`/`cmd_convert.go` both
call, confirmed at `ray2sing/test.go:17` and `ray2sing/cmd/cmd_convert.go:29`)
has signature `Ray2Singbox(ctx context.Context, url string, xrayCore bool) ([]byte, error)`
— use it directly for the new error-path tests, same as the existing helper
does internally.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Run the touched tests | `cd hiddify-core/ray2sing && go test ./ray2sing_test/... -run "TestVmess|TestTrojan" -v` | all pass |
| Run the whole `ray2sing_test` package | `cd hiddify-core/ray2sing && go test ./ray2sing_test/...` | all pass |

Note: `ray2sing` is its own Go module (has its own `go.mod`) — run these
commands from `hiddify-core/ray2sing/`, not the `hiddify-core` root.

## Scope

**In scope**:
- `hiddify-core/ray2sing/ray2sing_test/vmess_test.go` (extend)
- `hiddify-core/ray2sing/ray2sing_test/trojan_test.go` (extend)

**Out of scope**:
- Any change to `ray2sing/ray2sing/vmess.go`, `trojan.go`, `test.go`, or any
  other production parser file — test-only plan. If a new test reveals an
  actual parser bug, do NOT fix it — report it in your final summary.
- `vless_test.go`, `tuic_test.go`, `ssh_test.go`, `hysteria_test.go`,
  `hysteria2_test.go`, `wiregaurd_test.go`, `beepass_test.go` — the other 7
  files without error-path coverage. Extending them with the same
  malformed-input pattern established here (find each protocol's entry
  point, confirm what makes it error — usually a bad `ParseUrl`/base64/JSON
  decode — and add one test asserting `Ray2Singbox` returns a non-nil
  error) is a natural follow-up but not part of this plan's scope; note it
  in your final report as the next slice.
- `xray_allow_insecure_test.go`, `xdns_xicmp_test.go`, `pcs_and_anytls_test.go`,
  `naive_test.go`, `awg_url_test.go`, `amnezia_conf_test.go`,
  `xhttp_utls_test.go` — already have error-path assertions per the grep
  above; out of scope.

## Git workflow

- Branch: `advisor/032-ray2sing-protocol-test-coverage`
- One commit.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a TLS+websocket variant to `vmess_test.go`

Append this test function to `vmess_test.go` (the base64 payload below
decodes to
`{"add":"51.161.130.173","aid":"0","alpn":"","fp":"chrome","host":"vmess.example.com","id":"d43ee5e3-1b07-56d7-b2ea-8d22c44fdc66","net":"ws","path":"/vmesspath","port":"443","scy":"auto","sni":"vmess.example.com","tls":"tls","type":"none","v":"2","ps":"vmess-tls-ws-test"}`
— confirm this yourself by base64-decoding the string below before trusting
it, since a weak executor should verify inputs it's given rather than
assume they're correct):

```go
func TestVmess_TlsWebsocket(t *testing.T) {
	url := "vmess://eyJhZGQiOiI1MS4xNjEuMTMwLjE3MyIsImFpZCI6IjAiLCJhbHBuIjoiIiwiZnAiOiJjaHJvbWUiLCJob3N0Ijoidm1lc3MuZXhhbXBsZS5jb20iLCJpZCI6ImQ0M2VlNWUzLTFiMDctNTZkNy1iMmVhLThkMjJjNDRmZGM2NiIsIm5ldCI6IndzIiwicGF0aCI6Ii92bWVzc3BhdGgiLCJwb3J0IjoiNDQzIiwic2N5IjoiYXV0byIsInNuaSI6InZtZXNzLmV4YW1wbGUuY29tIiwidGxzIjoidGxzIiwidHlwZSI6Im5vbmUiLCJ2IjoiMiIsInBzIjoidm1lc3MtdGxzLXdzLXRlc3QifQo="

	expectedJSON := `
	{
		"outbounds": [
		  {
			"type": "vmess",
			"tag": "vmess-tls-ws-test § 0",
			"server": "51.161.130.173",
			"server_port": 443,
			"uuid": "d43ee5e3-1b07-56d7-b2ea-8d22c44fdc66",
			"security": "auto",
			"authenticated_length": true,
			"tls": {
			  "enabled": true,
			  "server_name": "vmess.example.com",
			  "utls": {
				"enabled": true,
				"fingerprint": "chrome"
			  }
			},
			"transport": {
			  "type": "ws",
			  "path": "/vmesspath",
			  "headers": {
				"Host": "vmess.example.com"
			  },
			  "early_data_header_name": "Sec-WebSocket-Protocol"
			}
		  }
		]
	  }
	`
	ray2sing.CheckUrlAndJson(url, expectedJSON, t)
}
```

**Run it first before trusting the expected JSON above** — this plan's
author constructed the input but did not execute the Go test suite to
confirm the exact output shape (no Go toolchain available during planning).
**If it fails**: read the actual diff `CheckUrlAndJson`'s `t.Errorf` prints
(it shows both the got and want pretty-printed JSON) and correct the
`expectedJSON` in this test to match what the parser *actually* produces for
this input — as long as the produced config is a sane, correctly-shaped TLS+ws
outbound (TLS enabled, correct server name, ws transport with the right
path/host), a small field-ordering or default-value difference from this
plan's guess is expected and should be reconciled in favor of the real
output, not treated as a bug.

**Verify**: `cd hiddify-core/ray2sing && go test ./ray2sing_test/... -run TestVmess_TlsWebsocket -v` → passes (after reconciling expected JSON if needed, per above).

### Step 2: Add a malformed-input case to `vmess_test.go`

Append:

```go
func TestVmess_MalformedBase64_ReturnsError(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	_, err := ray2sing.Ray2Singbox(ctx, "vmess://!!!not-valid-base64!!!", false)
	if err == nil {
		t.Fatal("expected an error for a vmess URL with a malformed base64 payload, got nil")
	}
}
```

Add `"github.com/sagernet/sing-box/experimental/libbox"` to the import
block (needed for `libbox.BaseContext(nil)`, matching the pattern
`ray2sing/ray2sing/test.go:16` already uses internally).

**Verify**: `cd hiddify-core/ray2sing && go test ./ray2sing_test/... -run TestVmess_MalformedBase64 -v` → passes.

### Step 3: Add a malformed-input case to `trojan_test.go`

Append:

```go
func TestTrojan_MalformedUrl_ReturnsError(t *testing.T) {
	ctx := libbox.BaseContext(nil)
	// A bare '%' not followed by two hex digits is an invalid percent-escape,
	// which makes Go's net/url.Parse (and therefore ray2sing's ParseUrl) fail.
	_, err := ray2sing.Ray2Singbox(ctx, "trojan://pass@host:443?sni=%zz", false)
	if err == nil {
		t.Fatal("expected an error for a trojan URL with an invalid percent-escape, got nil")
	}
}
```

Add the same `libbox` import if not already present after Step 2's addition
(if both files are edited, each needs its own import).

**Verify**: `cd hiddify-core/ray2sing && go test ./ray2sing_test/... -run TestTrojan_MalformedUrl -v` → passes.

**If `url.Parse` does not actually error on `%zz`** (Go's URL parser has
some tolerance for malformed escapes depending on version/position) —
try an alternative clearly-invalid input such as a URL containing a raw,
un-escaped control character (e.g. embed a literal `\x00`), and note in your
final report which input actually triggers the error, since this plan's
guess may need adjusting to the real Go stdlib behavior in this repo's Go
version.

### Step 4: Run the full `ray2sing_test` package

**Verify**: `cd hiddify-core/ray2sing && go test ./ray2sing_test/...` → all
pass, including the 3 new tests.

## Test plan

This plan's entire content is the test addition:
- `TestVmess_TlsWebsocket` (new, `vmess_test.go`) — TLS+websocket variant,
  filling the one genuine gap found in this file.
- `TestVmess_MalformedBase64_ReturnsError` (new, `vmess_test.go`) —
  malformed-input error path.
- `TestTrojan_MalformedUrl_ReturnsError` (new, `trojan_test.go`) —
  malformed-input error path.

Verification: `cd hiddify-core/ray2sing && go test ./ray2sing_test/...` →
all pass.

## Done criteria

- [ ] `vmess_test.go` has the 2 new test functions above
- [ ] `trojan_test.go` has the 1 new test function above
- [ ] `cd hiddify-core/ray2sing && go test ./ray2sing_test/...` exits 0, all tests pass
- [ ] `git status` (in the `hiddify-core` submodule) shows changes only to `ray2sing/ray2sing_test/vmess_test.go` and `ray2sing/ray2sing_test/trojan_test.go`
- [ ] `plans/README.md` status row updated, noting whether Step 1's expected JSON needed reconciling against real output

## STOP conditions

- Any function cited in "Current state" doesn't match its excerpt (drift
  since this plan was written) — re-read the live function before writing
  its test.
- Step 1's `expectedJSON` doesn't match the real parser output in a way that
  looks like an actual bug (not just field ordering/defaults) — e.g. TLS
  ends up NOT enabled, or the wrong server name is used — do not adjust the
  expectation to paper over it; report it as a finding instead.
- Step 3's malformed-URL input doesn't actually trigger a `url.Parse`
  failure — try the control-character alternative noted in Step 3; if
  nothing you try makes `ParseUrl` return an error for any malformed input,
  report that as a finding in its own right (it would mean this parser has
  no error path reachable from bad input at all, which is worth knowing).

## Maintenance notes

- The correction in "Why this matters" (several files already cover TLS
  variants; the real gap is error-path coverage) should inform any follow-up
  extending this plan's pattern to the other 7 error-path-less files — check
  each file's actual coverage before assuming it needs a TLS-variant
  addition; it likely only needs the malformed-input case.
- If `CheckUrlAndJson` (`ray2sing/ray2sing/test.go`) is ever extended with
  an error-path equivalent (e.g. `CheckUrlError(url, t)`), the 3 new tests in
  this plan could be simplified to use it — not done here since it doesn't
  exist yet and adding it would be a production-test-infrastructure change
  beyond this plan's scope.
