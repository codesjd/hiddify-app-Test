# Plan 035: Fix the missing reality-fingerprint default on the xray-core outbound path

> **Executor instructions**: Follow this plan step, in order. Step 1 is an
> investigation this plan has already completed (see "Why this matters" and
> "Investigation finding" below) — you do not need to repeat it, but you
> should spot-check the cited git history yourself before making the change,
> since this touches live connection behavior. Run every verification
> command and confirm the expected result before moving to the next step. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `cd hiddify-core/ray2sing && git diff --stat a6877a3cd..HEAD -- ray2sing/xray_common.go`.
> If it changed, re-read the live `getTLSOptionsXray`/`getRealityOptionsXray`
> functions before proceeding.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED — changes the TLS fingerprint (uTLS ClientHello shape) used
  for live reality connections on the xray-core backend; low code risk, but
  a real behavioral change to already-working connections
- **Depends on**: none
- **Category**: bug (correctness/security-adjacent — anti-detection behavior)
- **Planned at**: Dart repo commit `e38210d1`, `hiddify-core` submodule
  commit `8653861f1c6b87f4833e4bc3182af4b32c53b711`, `ray2sing` nested
  submodule commit `a6877a3cd439b2043d0dc76c5c7d9c7ef9a1f3f5`, 2026-07-29

## Why this matters

`ray2sing` builds outbound configs for two different backends from the same
parsed link: sing-box (`common.go`) and xray-core (`xray_common.go`). For a
VLESS/Reality link that doesn't specify an explicit uTLS fingerprint (no
`fp=` parameter), the two backends currently disagree on what fingerprint to
use:

- **sing-box path** (`hiddify-core/ray2sing/ray2sing/common.go`, function
  `getTLSOptions`, lines 28-92): line 29's guard includes
  `decoded["security"] == "reality"`, and lines 52-55 explicitly default the
  fingerprint:
  ```go
  fp := decoded["fp"]
  if fp == "" && decoded["security"] == "reality" {
      fp = "chrome"
  }
  ```
- **xray-core path** (`hiddify-core/ray2sing/ray2sing/xray_common.go`,
  function `getRealityOptionsXray`, lines 313-338 — a separate function from
  plain-TLS handling, since xray-core's reality config is built independently
  of its TLS config): lines 326-329 have the same shape, but the assignment
  is commented out:
  ```go
  fp := decoded["fp"]
  if fp == "" {
      // fp = "chrome"
  }
  ```
  `fp` is left as the empty string and passed straight into the returned
  `"fingerprint"` field (line 333).

Result: the exact same reality link produces a `fp="chrome"` uTLS
fingerprint on the sing-box backend but an **empty** fingerprint on the
xray-core backend (reached when the user has `useXrayCoreWhenPossible`
enabled, or certain protocol/transport combinations force the xray-core
path — see `convert.go`'s backend-selection logic). An empty/missing
fingerprint on a reality connection is not just cosmetically different: it
changes the TLS ClientHello's shape, which is exactly what reality's
anti-fingerprinting design depends on being consistent and browser-like —
this is a real behavioral divergence between backends for identical input,
not a style nit.

**Investigation finding (this plan's Step 1)**: this is not a deliberate,
documented decision to disable the default — it is an oversight present
since the file's original authoring. `git -C hiddify-core/ray2sing log -p -- ray2sing/xray_common.go`
shows the file (and both `getTLSOptionsXray` and `getRealityOptionsXray`,
each with their own copy of the same dead `// fp = "chrome"` line) was
created whole in commit `8acc89f46131336b3d9c3ce36175599fbd0d0670`
("new: add xray fragment option" — a commit message about an unrelated
feature, not about disabling a fingerprint default), and the commented-out
line has been carried forward unchanged and unexplained through every
subsequent commit that touched this file. There is no companion commit
message, code comment, or ADR anywhere in this repo's history explaining an
intentional decision to omit the default. Proceed to the fix (Step 2 below)
rather than treating this as settled.

Note also: `getTLSOptionsXray`'s guard (line 259) only matches
`tls`/`security==tls`, not `reality` — reality is handled entirely by the
separate `getRealityOptionsXray`. This means `getTLSOptionsXray`'s own copy
of the same dead `if fp == "" { // fp = "chrome" } ` (lines 271-274) is
**not** the same bug: sing-box's `getTLSOptions` also does **not** default
`fp` for plain (non-reality) TLS — only for reality. So
`getTLSOptionsXray`'s dead comment is currently a no-op that happens to
already match sing-box's behavior for the plain-TLS case; it doesn't need a
fingerprint fix, only a small dead-code cleanup (see Step 3 — optional,
bundled here since it's the same file and same investigation, not because
it's the same bug).

## Current state

`hiddify-core/ray2sing/ray2sing/xray_common.go:313-338` in full today:

```go
func getRealityOptionsXray(decoded map[string]string) map[string]any {
	if !(decoded["security"] == "reality") {
		return nil
	}
	serverName := decoded["sni"]
	if serverName == "" {
		serverName = decoded["add"]
	}
	// alpn := []string{"h2", "http/1.1"}
	// if alpnlink, ok := decoded["alpn"]; ok && alpnlink != "" {
	// 	alpn = strings.Split(alpnlink, ",")
	// }

	fp := decoded["fp"]
	if fp == "" {
		// fp = "chrome"
	}

	return map[string]any{
		"serverName":  serverName,
		"fingerprint": fp,
		"shortId":     decoded["sid"],
		"spiderX":     decoded["spx"],
		"publicKey":   decoded["pbk"],
	}
}
```

`xray_common.go:258-274` (`getTLSOptionsXray`, for Step 3's optional
cleanup only — do not add a fingerprint default here, see Why this matters):

```go
func getTLSOptionsXray(decoded map[string]string) map[string]any {
	if !(decoded["tls"] == "tls" || decoded["security"] == "tls") {
		return nil
	}
	// ...
	fp := decoded["fp"]
	if fp == "" {
		// fp = "chrome"
	}
	// ...
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core/ray2sing && go build ./...` | exit 0 |
| Tests | `cd hiddify-core/ray2sing && go test ./...` | all pass |
| Targeted test | `cd hiddify-core/ray2sing && go test ./ray2sing_test/... -run Reality` | passes (case-sensitive test name — check `pcs_and_anytls_test.go` and any reality-specific test file for the actual test function names first) |

## Scope

**In scope**:
- `hiddify-core/ray2sing/ray2sing/xray_common.go` — `getRealityOptionsXray`
  (the fix) and, optionally, `getTLSOptionsXray`'s dead comment (cleanup
  only, no behavior change there).

**Out of scope**:
- `hiddify-core/ray2sing/ray2sing/common.go`'s `getTLSOptions` — already
  correct, do not touch.
- Any other TLS/fingerprint-related option in either file (ECH, ALPN,
  pinned-cert handling) — unrelated to this specific finding.
- Consolidating the two backends' TLS-option-building into a shared helper
  (this was raised by the audit as a separate, larger finding — duplicated
  protocol builders across backends — and is being tracked as its own
  design-spike plan, not this one). This plan fixes the one concrete
  behavioral divergence; it does not attempt the larger consolidation.

## Git workflow

- Branch: `advisor/035-unify-reality-fingerprint`
- One commit.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: (Already done — investigation) Confirm the git-history finding yourself

Run `cd hiddify-core/ray2sing && git log -p -- ray2sing/xray_common.go | grep -n "^commit\|fp = \"chrome\""`
and confirm the earliest occurrence of the commented-out line is in the
file's original creating commit (`8acc89f4...`), with no later commit's
message explaining a deliberate removal. If you find a commit message this
plan's investigation missed that explains an intentional decision to keep
this disabled, STOP and report it — do not proceed with Step 2.

### Step 2: Uncomment the fingerprint default in `getRealityOptionsXray`

Change:

```go
	fp := decoded["fp"]
	if fp == "" {
		// fp = "chrome"
	}
```

to:

```go
	fp := decoded["fp"]
	if fp == "" {
		fp = "chrome"
	}
```

**Verify**: `grep -n "fp = \"chrome\"" hiddify-core/ray2sing/ray2sing/xray_common.go`
shows it uncommented in `getRealityOptionsXray`'s body (check the line
number falls within that function, not `getTLSOptionsXray`'s).

### Step 3 (optional cleanup, same investigation): Remove the no-op dead comment in `getTLSOptionsXray`

This one is inert either way (see Why this matters — sing-box's own
non-reality TLS path also never defaults `fp`), so this is pure dead-code
tidiness, not a behavior fix. If you make this change, do it as a second,
clearly-labeled commit or a separate hunk so a reviewer can see it's
unrelated to Step 2's actual fix:

```go
	fp := decoded["fp"]
	// intentionally left empty for non-reality TLS - matches sing-box's getTLSOptions,
	// which also only defaults the fingerprint for reality (see getRealityOptionsXray).
```

(i.e. delete the dead `if fp == "" { // fp = "chrome" }` block and replace it
with a one-line comment explaining why there's no default here, so a future
reader doesn't reintroduce this plan's Step 2 fix in the wrong function.)

**Verify**: `grep -c "// fp = \"chrome\"" hiddify-core/ray2sing/ray2sing/xray_common.go`
returns `0` (both dead-comment copies are now gone: one turned live in Step
2, one deleted-with-explanation in Step 3).

### Step 4: Confirm build and tests pass

**Verify**: `cd hiddify-core/ray2sing && go build ./... && go test ./...` →
exit 0 / all pass.

## Test plan

- Check whether an existing test in `ray2sing_test/` already covers a
  reality link with no `fp=` parameter through the xray-core path (search
  for `security=reality` or `getRealityOptionsXray` references in
  `pcs_and_anytls_test.go` and any other reality-related test file). If one
  exists, confirm its expected fixture now includes `"fingerprint": "chrome"`
  and update the fixture if it currently asserts an empty fingerprint
  (that assertion would have been encoding the bug this plan fixes).
- If no such test exists, add one: a reality link with no `fp=` parameter,
  parsed through the xray-core path, asserting the resulting outbound's
  `realitySettings.fingerprint` equals `"chrome"`. Follow the existing
  `CheckUrlAndJson` helper pattern (`ray2sing/test.go:15-39`) used throughout
  `ray2sing_test/` for exact-struct comparison — don't hand-roll a different
  assertion style.
- Verification: `go test ./ray2sing_test/...` → all pass, including the
  new/updated reality case.

## Done criteria

- [ ] `getRealityOptionsXray` now sets `fp = "chrome"` (uncommented) when the link has no explicit `fp=`
- [ ] `go build ./...` and `go test ./...` (from `hiddify-core/ray2sing`) exit 0 / all pass
- [ ] A test exists (new or updated) asserting the xray-core reality path defaults the fingerprint to `"chrome"` when unset
- [ ] `git status` (inside `hiddify-core/ray2sing`) shows changes only to `ray2sing/xray_common.go` and its test file, plus `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- The git-history investigation in Step 1 turns up a commit message
  explaining a deliberate decision to omit the reality fingerprint default —
  do not apply Step 2; report this as a settled decision instead.
- `getRealityOptionsXray`'s current code doesn't match the excerpt above
  (drift since this plan was written) — re-read the live function.
- Any existing test's fixture explicitly (and, on inspection, intentionally)
  expects an empty fingerprint for a no-`fp=` reality link — this would
  contradict this plan's premise; STOP and report rather than overriding a
  possibly-intentional fixture.

## Maintenance notes

- If the two backends' TLS/reality option builders are ever consolidated
  into one shared implementation (see the separate design-spike plan on
  duplicated protocol builders), this specific fingerprint-default logic
  should be one of the first things unified, since it's now the second time
  it's drifted (once by omission, potentially again by future edits to
  either copy independently).
- The `"chrome"` default itself is not something this plan questions — it
  matches the sing-box path's existing, presumably deliberate choice; this
  plan only makes the xray-core path consistent with it, not re-litigate
  whether `"chrome"` is the right fingerprint to default to.
