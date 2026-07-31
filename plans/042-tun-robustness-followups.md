# Plan 042: TUN robustness follow-ups — explicit interface name and Stack validation at the config-import boundary

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 1c2af3c4a75aa4e393f33f928103491cf5a54e18..HEAD -- v2/config/builder.go`.
> If it shows changes, re-read `setInbound` live before proceeding.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (independent of plans 039-041)
- **Category**: bug (Step 2 is defense-in-depth at a real trust boundary;
  Step 1 is a small robustness/diagnostics improvement, not a bug fix)
- **Planned at**: `hiddify-core` submodule commit
  `1c2af3c4a75aa4e393f33f928103491cf5a54e18`, Dart repo commit `b3b9677a`,
  2026-07-31

## Why this matters

Two small, independent gaps were found while investigating why TUN mode
doesn't work reliably (see plan 039 for the main, high-confidence root
cause — this plan covers smaller items that are real but lower-impact and
lower-confidence):

1. **The TUN inbound never gets an explicit interface name.** The adapter
   ends up with whatever sing-tun's per-OS default name-generation produces,
   which makes it harder to diagnose ("which adapter is Hiddify's TUN
   interface?" has no fixed answer across runs) and means the name can't be
   relied on by anything else (firewall rules, diagnostics, support
   instructions) the way `tunnelservice/tunnel_service.go:57`'s own embedded
   tun config already does (`InterfaceName: "HiddifyTunnel"`).
2. **`hopt.TUNStack` (the sing-tun stack implementation: `mixed`/`system`/
   `gvisor`) reaches `setInbound` with no validation.** In normal UI use this
   is a non-issue — the Dart enum `TunImplementation`
   (`lib/singbox/model/singbox_config_enum.dart:112-115`) only has 3 members
   and its raw `.name` is what gets sent, so the app UI itself cannot
   produce a bad value. But this repo has a config-option **import**
   feature (JSON import/export, `SingboxConfigOption` deserialization) that
   is not enum-constrained the same way — an imported or hand-edited config
   file could carry an arbitrary string in this field, and today that would
   surface as whatever error sing-tun's own `New()` happens to produce deep
   inside adapter construction, rather than a clear, early, actionable
   rejection at the boundary where untrusted input actually enters the
   system.

## Current state

`hiddify-core/v2/config/builder.go:438-483` (`setInbound`, relevant part):

```go
func setInbound(options *option.Options, hopt *HiddifyOptions) {
	ipv6Enable := isIPv6Supported()
	if hopt.EnableTun {
		opts := option.TunInboundOptions{
			Stack:       hopt.TUNStack,
			MTU:         hopt.MTU,
			AutoRoute:   true,
			StrictRoute: hopt.StrictRoute,
		}
		tunInbound := option.Inbound{
			Type: C.TypeTun,
			Tag:  InboundTUNTag,
			Options: &opts,
		}
		opts.Address = []netip.Prefix{netip.MustParsePrefix("172.19.0.1/28")}
		if ipv6Enable {
			opts.Address = append(opts.Address, netip.MustParsePrefix("fdfe:dcba:9876::1/126"))
		}
		...
```

No `InterfaceName` field is set anywhere in this function (confirmed:
`grep -n "InterfaceName" hiddify-core/v2/config/builder.go` returns nothing).

`hiddify-core/v2/hcore/tunnelservice/tunnel_service.go:41-60`
(`makeTunnelConfig`, the elevated helper's *own*, separate embedded tun
config — already sets a name):

```go
Options: option.TunInboundOptions{
	EndpointIndependentNat: in.EndpointIndependentNat,
	StrictRoute:            in.StrictRoute,
	AutoRoute:              true,
	Address:                ips,
	InterfaceName:          "HiddifyTunnel",
	Stack:                  in.Stack,
},
```

This confirms `option.TunInboundOptions` does have an `InterfaceName` field
of this shape — you don't need to guess its type.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core && go build ./v2/config/...` | exit 0 |
| Vet | `cd hiddify-core && go vet ./v2/config/...` | exit 0 |
| Test | `cd hiddify-core && go test ./v2/config/...` | all pass, including the new test from Step 2 |

## Scope

**In scope**:
- `hiddify-core/v2/config/builder.go` — `setInbound` only
- A new/extended test file under `hiddify-core/v2/config/`

**Out of scope**:
- `hiddify-core/v2/hcore/tunnelservice/tunnel_service.go` — its
  `InterfaceName: "HiddifyTunnel"` is already correct and unrelated to this
  plan; **do not reuse the exact same name for the main inbound** (pick a
  different one, e.g. `"HiddifyTun"`) so the two adapters are
  distinguishable in OS network-interface listings if both code paths are
  ever active in different processes at different times (they should never
  be simultaneously active for the same connection per plan 039's design,
  but distinct names cost nothing and remove any ambiguity from logs/support
  requests).
- The Dart-side `TunImplementation` enum or any UI change — not needed,
  the gap is specifically at the JSON-import boundary, which is a Go-side
  concern once the value reaches `HiddifyOptions`.
- The `restart.go` fixed 1-second TUN-teardown-settling sleep
  (`hiddify-core/v2/hcore/restart.go:44-50`) — a real, already-mitigated,
  already-documented (in its own comment) tradeoff between correctness and
  complexity; replacing it with a real completion signal would need
  evidence the 1-second window is actually insufficient somewhere, which
  this investigation didn't find. Not touched by this plan.

## Git workflow

- Branch: `advisor/042-tun-robustness`
- Suggested commits: (1) `InterfaceName`, (2) `TUNStack` validation + test
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Set an explicit interface name

In `setInbound`, add `InterfaceName` to the `opts` literal:

```go
	opts := option.TunInboundOptions{
		Stack:         hopt.TUNStack,
		MTU:           hopt.MTU,
		AutoRoute:     true,
		StrictRoute:   hopt.StrictRoute,
		InterfaceName: "HiddifyTun",
	}
```

**Verify**: `cd hiddify-core && go build ./v2/config/...` → exit 0.
`grep -n 'InterfaceName: "HiddifyTun"' hiddify-core/v2/config/builder.go` matches.

### Step 2: Validate `TUNStack` at the point it's consumed

Still in `setInbound`, before constructing `opts`, reject an unrecognized
stack value with a clear error rather than letting it reach sing-tun
unchecked. First check how `setInbound`'s caller signature handles errors
today — if `setInbound` currently returns nothing (`func setInbound(options
*option.Options, hopt *HiddifyOptions)`, no error return), you have two
options, in order of preference:

1. **Preferred**: change `setInbound` to return an `error`, and update its
   one caller (find it: `grep -n "setInbound(" hiddify-core/v2/config/builder.go`)
   to propagate it, matching how sibling `setXxx` functions in this same
   file already return errors where applicable (check `setLog`,
   `setInbound`'s neighbors for the established convention before deciding
   this is safe — if every other `setXxx` function in this file is
   void-returning by convention and only `setInbound` would differ, that's
   a signal to use option 2 instead, to stay consistent with the file's own
   style).
2. **Fallback**: if changing the return signature ripples too far (e.g. the
   caller is itself void-returning and used in many places), instead log a
   clear warning via this package's existing logging convention (check
   `setLog`/other functions in `builder.go` for how they log, e.g. via
   `option.LogOptions`/whatever logger this package already uses) and fall
   back to a safe default (`"mixed"`, matching the Go-side
   `DefaultHiddifyOptions`'s own default at
   `hiddify-core/v2/config/hiddify_option.go:129`) rather than silently
   passing the bad value through.

Either way, the accepted set is exactly `{"mixed", "system", "gvisor"}` —
confirmed as sing-tun's valid stack identifiers by cross-referencing the
Dart enum's three members (`lib/singbox/model/singbox_config_enum.dart:112-115`),
which exist specifically to match what the Go side accepts.

**Verify**: `cd hiddify-core && go build ./v2/config/...` → exit 0.

### Step 3: Add a test

Add a test in `hiddify-core/v2/config/builder_test.go` (extend if it
already exists — check first) covering:
- A valid `TUNStack` (e.g. `"gvisor"`) produces a `TunInboundOptions` with
  that `Stack` value and `InterfaceName == "HiddifyTun"`.
- An invalid `TUNStack` (e.g. `"bogus"`) is rejected/falls back per however
  you implemented Step 2 — assert whichever concrete behavior you chose
  (returned error, or silent fallback to `"mixed"` — the test must match
  the real implemented behavior, not both).

**Verify**: `cd hiddify-core && go test ./v2/config/...` → all pass, including the new test(s).

## Test plan

- New test(s) from Step 3, in `hiddify-core/v2/config/builder_test.go`.
- Verification: `cd hiddify-core && go test ./v2/config/...` → all pass.

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/config/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/config/...` passes, including the new tests
- [ ] `grep -n 'InterfaceName: "HiddifyTun"' hiddify-core/v2/config/builder.go` matches
- [ ] An unrecognized `TUNStack` value no longer reaches `option.TunInboundOptions.Stack` unchanged and unchecked (proven by the Step 3 test)
- [ ] `git status` (inside `hiddify-core`) shows changes only to `v2/config/builder.go` and its test file
- [ ] `plans/README.md` status row updated for plan 042

## STOP conditions

- The `setInbound` excerpt doesn't match the live code — re-read before proceeding.
- Changing `setInbound`'s signature to return an error would require
  touching more than 2-3 call sites — fall back to Step 2's option 2
  (log + safe default) instead of a wider refactor; this plan's blast
  radius should stay small.
- You can't find how this file/package logs warnings today (no established
  convention) — pick the simplest option (`fmt.Printf`/standard `log`
  package, matching whatever's least out-of-place among this file's
  existing imports) rather than introducing a new logging dependency.

## Maintenance notes

- If plan 039 lands, note it also reads `TunInboundOptions` fields
  (`Address`, `StrictRoute`, `Stack`, `EndpointIndependentNat`) from the
  *stripped* tun inbound to build a `TunnelStartRequest` — if this plan's
  Step 1 adds `InterfaceName` to that same struct, plan 039's extraction
  code doesn't need it (the elevated helper sets its own
  `InterfaceName: "HiddifyTunnel"` independently in
  `tunnel_service.go:makeTunnelConfig`), so no coordination is needed
  between the two plans either way.
- The `restart.go` 1-second sleep noted as out-of-scope above is worth
  revisiting for real if a future bug report describes "TUN mode reconnect
  fails intermittently on a slow/loaded machine" — that would be the
  concrete evidence needed to justify replacing a fixed sleep with a real
  completion signal.
