# Plan 021: Stop the Shadowsocks link parser from silently downgrading to no encryption

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 8653861f1c..HEAD -- ray2sing/ray2sing/shadowsocks.go ray2sing/ray2sing/url_schema.go`.
> If it shows any changes, re-read both files live before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW — the change only affects the already-broken path (a link
  that produces no usable password); well-formed links are unaffected
- **Depends on**: none
- **Category**: security
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`ShadowsocksSingbox` (`hiddify-core/ray2sing/ray2sing/shadowsocks.go:9-38`)
parses a `ss://` link into a sing-box outbound. When the parsed password is
empty, it does not fail — it silently reinterprets the *method* field as the
password and hardcodes the encryption method to `"none"`:

```go
func ShadowsocksSingbox(shadowsocksUrl string) (*T.Outbound, error) {
	u, err := ParseUrl(shadowsocksUrl, 443)
	if err != nil {
		return nil, err
	}

	decoded := u.Params

	defaultMethod := u.Username
	pass:=u.Password
	if u.Password == "" {
		pass = u.Username
		defaultMethod = "none"
	}

	result := T.Outbound{
		Type: "shadowsocks",
		Tag:  u.Name,
		Options: &T.ShadowsocksOutboundOptions{
			ServerOptions: u.GetServerOption(),
			Method:        defaultMethod,
			Password:      pass,
			Plugin:        decoded["plugin"],
			PluginOptions: decoded["pluginopts"],
		},
	}

	return &result, nil
}
```

`u.Password` comes from `ParseUrl` (`ray2sing/ray2sing/url_schema.go:34-73`),
which only populates a real method+password pair when the URL's userinfo is
base64 and, after decoding, contains at least one `:` (`:50-65` —
`SplitN(userInfo, ":", 2)`, `len(userDetails) == 2`). Standard SIP002-format
`ss://` links (`ss://BASE64(method:password)@host:port`) hit this path
correctly, as do Shadowsocks-2022 EIH links carrying additional colons in
the identity chain (per the comment at `:56-59`, deliberately using
`SplitN(..., 2)` so extra colons stay in the password). But **any link
where the decoded userinfo has no colon at all** — a malformed or
non-standard link, e.g. one that encodes only a PSK with no method prefix —
falls through with `data.Password` left at whatever `ParseUrl` initialized it
to (empty), which is exactly the condition `ShadowsocksSingbox` treats as
"use no encryption" instead of "this link is malformed."

This matters more than a typical parse-error path because the failure mode
is silent: instead of the profile failing to load (loud, visible, gets
reported), the client generates a working-looking `shadowsocks` outbound
with `method: "none"`. If the destination server also happens to accept
unauthenticated/plaintext Shadowsocks connections (not all do, but some
permissive setups might), traffic proxied through it is sent with **no
encryption at all**, silently. This is a plausible root cause for the
standing "SS2022 doesn't work in proxy mode" user report — the generated
outbound would connect but not actually apply SS2022 encryption — but this
plan does **not** claim to have confirmed that specific report's link
string; it fixes a real, independently-verifiable silent-downgrade bug
either way.

## Current state

- `hiddify-core/ray2sing/ray2sing/shadowsocks.go` — the file to change
  (`ShadowsocksSingbox`, shown in full above).
- `hiddify-core/ray2sing/ray2sing/url_schema.go:34-73` (`ParseUrl`) — read
  for context only, not modified by this plan.
- `hiddify-core/ray2sing/ray2sing/beepass.go:65` — the only other caller of
  `ShadowsocksSingbox`, already propagates `(*T.Outbound, error)` up its own
  call chain unchanged, so returning a real error here requires no change on
  the caller side.
- `hiddify-core/ray2sing/ray2sing_test/shadowsocks_test.go` — the existing 3
  tests (`TestShadowsocks`, `TestShadowsocksEIHBase64`, `TestShadowsocksEIHPlain`),
  confirmed by reading them directly: all 3 use links whose decoded userinfo
  contains a colon, so none exercise the empty-password fallback branch this
  plan removes. This plan's new test does not conflict with or duplicate
  them.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core/ray2sing && go build ./...` | exit 0 |
| Test | `cd hiddify-core/ray2sing && go test ./ray2sing_test/... ./ray2sing/...` | all pass, including the new test |

## Scope

**In scope**:
- `hiddify-core/ray2sing/ray2sing/shadowsocks.go`
- `hiddify-core/ray2sing/ray2sing_test/shadowsocks_test.go` (extend)

**Out of scope**:
- `hiddify-core/ray2sing/ray2sing/url_schema.go` — `ParseUrl`'s decode/split
  logic is not the bug; do not change it.
- `hiddify-core/ray2sing/ray2sing/beepass.go` — already correctly propagates
  errors; no change needed.
- Any attempt to reproduce or confirm the specific "SS2022 doesn't work in
  proxy mode" user report's exact link — out of scope; see Why this matters.
- Any change to how `xrayvless.go`/`xraytrojan.go` etc. handle analogous
  cases — this plan is scoped to the Shadowsocks (sing-box backend) parser
  only.

## Git workflow

- Branch: `advisor/021-shadowsocks-silent-downgrade`
- One commit.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Return an error instead of silently downgrading

Change `ShadowsocksSingbox` to return an error when no usable password was
recovered, instead of falling back to `method: "none"`:

```go
func ShadowsocksSingbox(shadowsocksUrl string) (*T.Outbound, error) {
	u, err := ParseUrl(shadowsocksUrl, 443)
	if err != nil {
		return nil, err
	}

	if u.Password == "" {
		return nil, fmt.Errorf("shadowsocks: link missing password (malformed or unsupported userinfo encoding): %s", shadowsocksUrl)
	}

	decoded := u.Params

	result := T.Outbound{
		Type: "shadowsocks",
		Tag:  u.Name,
		Options: &T.ShadowsocksOutboundOptions{
			ServerOptions: u.GetServerOption(),
			Method:        u.Username,
			Password:      u.Password,
			Plugin:        decoded["plugin"],
			PluginOptions: decoded["pluginopts"],
		},
	}

	return &result, nil
}
```

Add `"fmt"` to the file's import block (currently only imports
`T "github.com/sagernet/sing-box/option"`).

**Do not include the raw `shadowsocksUrl` in the error message if it may
contain credentials** — check what `u.GetServerOption()`/similar error paths
elsewhere in `ray2sing` do (e.g. grep for `fmt.Errorf` in sibling files like
`vless.go`/`trojan.go` for the established convention) and match it; if the
convention there omits the raw URL from error text for this reason, do the
same here instead of the exact message shown above.

**Verify**: `cd hiddify-core/ray2sing && go build ./...` → exit 0.
`grep -n "u.Password == \"\"" ray2sing/shadowsocks.go` shows the new early
return, and `grep -c "\"none\"" ray2sing/shadowsocks.go` returns `0`.

### Step 2: Add a regression test for the malformed-link path

Add to `ray2sing_test/shadowsocks_test.go`:

```go
func TestShadowsocksMissingPasswordReturnsError(t *testing.T) {
	// No colon anywhere recoverable from the userinfo: not valid base64,
	// and even if it were, has nothing to split on. This must not silently
	// produce a "method: none" outbound.
	url := "ss://not-valid-base64-and-no-colon@5.35.34.107:55990#test"

	_, err := ray2sing.ShadowsocksSingbox(url)
	if err == nil {
		t.Fatalf("expected an error for a shadowsocks link with no recoverable password, got nil")
	}
}
```

Confirm this input actually exercises the empty-password path rather than
failing earlier in `ParseUrl` for an unrelated reason (e.g. URL parse
failure) — if `url.Parse` itself rejects the test URL, adjust it to
something that parses successfully as a URL but still fails
`isBase64CharsOnly`/produces no colon after decode, and add a one-line
comment explaining why that specific string was chosen.

**Verify**: `cd hiddify-core/ray2sing && go test ./ray2sing_test/... -run TestShadowsocks`
→ all 4 Shadowsocks tests pass (3 existing + 1 new).

### Step 3: Confirm the full ray2sing suite still passes

**Verify**: `cd hiddify-core/ray2sing && go test ./...` → all pass.

## Test plan

- New test: `TestShadowsocksMissingPasswordReturnsError` in
  `ray2sing_test/shadowsocks_test.go`, per Step 2 — proves a link with no
  recoverable password now errors instead of silently producing an
  unencrypted outbound.
- Model the test file's existing structure (`package ray2sing_test`, direct
  call to the exported parser function) from the 3 tests already in the
  same file.
- Verification: `go test ./ray2sing_test/... ./ray2sing/...` → all pass,
  including the 1 new test.

## Done criteria

- [ ] `cd hiddify-core/ray2sing && go build ./...` exits 0
- [ ] `cd hiddify-core/ray2sing && go test ./...` passes, including the new test
- [ ] `grep -c "\"none\"" ray2sing/shadowsocks.go` returns `0`
- [ ] The 3 pre-existing Shadowsocks tests (`TestShadowsocks`, `TestShadowsocksEIHBase64`, `TestShadowsocksEIHPlain`) still pass unchanged
- [ ] `git status` shows changes only to `ray2sing/shadowsocks.go`, `ray2sing_test/shadowsocks_test.go`, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- `shadowsocks.go`'s current code doesn't match the excerpt above (drift
  since this plan was written) — re-read the live function before changing
  it.
- Any of the 3 existing Shadowsocks tests starts failing after this change —
  that would mean a well-formed link is somehow hitting the
  now-error-returning path, which means this plan's understanding of when
  `u.Password` is empty is incomplete; STOP and report rather than loosening
  the check to make the existing tests pass again.
- The test string in Step 2 doesn't actually reach the empty-password branch
  (e.g. it fails earlier in `url.Parse`) — adjust the input as instructed in
  Step 2, don't skip the test.
- You find evidence (e.g. in `beepass.go` or another caller) that some
  *legitimate* code path intentionally relies on the `method: "none"`
  fallback — STOP and report rather than removing behavior something else
  depends on.

## Maintenance notes

- This fix does not touch `ray2sing/xray_common.go`'s Xray-core-backend
  Shadowsocks handling (if one exists) — check whether an analogous
  silent-fallback pattern exists there; if so, it's a separate finding, not
  covered by this plan.
- If the actual "SS2022 doesn't work in proxy mode" report is later
  reproduced with a specific link, re-run that link through
  `ShadowsocksSingbox` after this plan lands — if it now returns the new
  error, that confirms this was the root cause (and the link itself was
  malformed, worth surfacing to the user with a clearer message upstream of
  this function); if it still fails differently, this fix was a real but
  unrelated improvement and the original report needs further
  investigation elsewhere (sing-box's own outbound dial path, or
  system-proxy wiring, as a prior audit pass already flagged as remaining
  possibilities).
