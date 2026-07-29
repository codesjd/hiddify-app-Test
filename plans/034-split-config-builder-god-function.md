# Plan 034: Delete dead code in and split up `setRoutingOptions` (config builder god function)

> **Executor instructions**: Follow this plan step by step, in order — **Step
> A (dead-code deletion) must land as its own commit before Step B
> (extraction)** so each is independently reviewable and revertible. Run
> every verification command and confirm the expected result before moving
> to the next step. If anything in "STOP conditions" occurs, stop and
> report — do not improvise, especially around rule ORDER (see Why this
> matters). When done, update the status row for this plan in
> `plans/README.md`.
>
> **Drift check (run first)**: `cd hiddify-core && git diff --stat 8653861f1c..HEAD -- v2/config/builder.go`.
> If it changed, re-read the live `setRoutingOptions` function in full before
> proceeding — this plan's line numbers and rule-append order were read
> directly from the file at the commit above and this is exactly the kind of
> function where a stale line number leads to a wrong edit.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED — the risk is entirely in Step B (rule-order preservation);
  Step A (dead code deletion) is LOW risk on its own
- **Depends on**: none required, but if `plans/029-*.md` (config builder test
  coverage, if it exists in this directory when you start) has already
  landed, its new tests give Step B a much better regression net — check
  `plans/README.md` for its status and prefer doing this plan after it if
  both are queued
- **Category**: tech-debt
- **Planned at**: Dart repo commit `e38210d1`, `hiddify-core` submodule
  commit `8653861f1c6b87f4833e4bc3182af4b32c53b711`, 2026-07-29

## Why this matters

`hiddify-core/v2/config/builder.go` is 1226 lines, and one function inside
it, `setRoutingOptions`, is 541 lines (lines 565-1105) — nearly 45% of the
whole file — handling every routing-rule special case (sniff/DNS-hijack,
BypassLAN, ad-block rulesets, region-based routing, QUIC blocking, fake-DNS,
NTP force-direct routing) as one long sequence of `append` calls with no
sub-grouping. Interleaved throughout are nine separate dead, commented-out
code regions (not one contiguous block — see Current state for the exact
list), together several dozen lines, making it harder to tell which branches
are live while reading. This is exactly the "config-building god function"
pattern that's hardest to safely modify: adding one more special case means
finding the right spot in 541 lines of undifferentiated logic, and the dead
code sitting next to live code invites a future editor to misjudge which is
which.

**The one thing that makes this risky, not just tedious**: sing-box
evaluates routing rules and DNS rules **in the order they appear** in
`options.Route.Rules` / `options.DNS.Rules`. `setRoutingOptions` builds both
slices by `append`-ing in a specific sequence before assigning them once at
the end (`options.Route = &option.RouteOptions{Rules: routeRules, ...}` at
line 980; the `dnsRules` are validated and appended into `options.DNS.Rules`
in a loop at lines 1092-1102). Splitting this function into sub-functions
must preserve that exact append order — a sub-function that looks like a
clean extraction but subtly reorders when its rules get appended relative to
another sub-function's rules would silently change routing precedence. This
is why Step B is scoped narrowly (extract-in-place, call the same
sub-functions in the same order the monolith already used) rather than any
kind of reorganization.

## Current state

Read directly from `hiddify-core/v2/config/builder.go` at the commit above.

**Dead code regions inside `setRoutingOptions`** (nine separate blocks, not
one range — delete all nine in Step A):

| Lines | What it is |
|---|---|
| 570-595 | Commented Android/Windows TUN bypass-route rules |
| 597-607 | Commented DNS rule (`DNSStaticTag` route action) |
| 653-666 | Commented `ClashMode: "Direct"`/`"Global"` route rules (ends with a stray `}` inside the comment block — delete it too, it's dead either way) |
| 688-726 | Commented `for _, rule := range opt.Rules` loop — an entire earlier rule-processing approach |
| 732-740 | Commented connection-test-url DNS rule |
| 988 | Commented `OverrideAndroidVPN` field in the `option.RouteOptions{}` literal |
| 991-996 | Commented `GeoIP`/`Geosite` path options in the same literal |
| 998, 1103 | Commented `if opt.EnableDNSRouting {` / matching `// }` wrapper (a matched open/close pair — delete both lines) |
| 1043-1090 | Four commented `dnsRules = append(...)` blocks (`DNSRemoteTagFallback`, `DNSTricksDirectTag`, `DNSDirectTag`, `DNSLocalTag`) |

**Live logic, in the exact order it currently executes** (this is the
sequence Step B's extraction must preserve):

1. `addForceDirect(options, hopt)` (line 608) — already its own function,
   unchanged, called first; its result is appended into `dnsRules` (line 613).
2. Sniff rule + DNS-hijack rule appended to `routeRules` (lines 615-633).
3. Hardcoded `10.10.34.0/24` / matching IPv6 CIDR route appended to
   `routeRules` (lines 635-652).
4. `if hopt.BypassLAN` — private-IP direct route appended to `routeRules`
   (lines 668-686).
5. NTP-server force-direct route: builds `forceDirectRoute` from
   `options.NTP.Server` (lines 727-730), then if non-empty appends a DNS rule
   and a route rule (lines 742-773).
6. `if hopt.BlockAds` — 6 remote rulesets (ads/malware/phishing/cryptominers
   geosite+geoip) appended to `rulesets`, plus a reject route rule and a
   reject DNS rule (lines 781-876).
7. `if hopt.Region != "other"` — region domain-suffix DNS+route rules, region
   geosite/geoip rulesets, and a combined route rule (lines 877-963).
8. `if hopt.RouteOptions.BlockQuic` — QUIC reject rule (lines 964-979).
9. `options.Route = &option.RouteOptions{...}` assembly (lines 980-997,
   after Step A's deletions shrink this to just the live fields).
10. `if hopt.EnableFakeDNS` — fake-DNS query-type DNS rule (lines 999-1028).
11. Final catch-all remote DNS rule, unconditional (lines 1030-1042).
12. Validate-and-append loop: for each `dnsRules` entry, if
    `dnsRule.IsValid()`, append into `options.DNS.Rules` (lines 1092-1102).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core && go build ./v2/config/...` | exit 0 |
| Vet | `cd hiddify-core && go vet ./v2/config/...` | exit 0 |
| Tests | `cd hiddify-core && go test ./v2/config/...` | all pass |
| Format | `cd hiddify-core && gofmt -l v2/config/` | no output |

Note: a full `go build ./v2/...`/`go list -m all` from the `hiddify-core`
root may not resolve standalone if nested `hiddify-sing-box/replace/*`
submodules aren't checked out in your environment (a known limitation from a
prior audit pass) — if so, scope commands to `./v2/config/...` as above
rather than trying to fix the checkout.

## Scope

**In scope**:
- `hiddify-core/v2/config/builder.go` — only `setRoutingOptions` and its new
  extracted sub-functions (which live in the same file).

**Out of scope**:
- Any other function in `builder.go` (`BuildConfig`, `setOutbounds`,
  `setExperimental`, `setInbound`, etc.) — do not touch them, even though
  some are also large.
- Any change to rule *content* or *order* — this plan is a pure
  code-organization change. If you find what looks like an actual bug while
  reading (e.g. a rule that seems misplaced), do NOT fix it here — note it
  in your final report as a separate finding.
- `patchHiddifyWarpFromConfig`, `getIPs`, `isBlockedDomain` and the other
  functions after `setRoutingOptions` in the same file — unrelated, do not
  touch.

## Git workflow

- Branch: `advisor/034-split-config-builder`
- **Commit 1 (Step A)**: delete all nine dead-code regions, nothing else.
- **Commit 2 (Step B)**: the extraction into sub-functions.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step A: Delete the nine dead-code regions (own commit)

Delete each of the nine regions listed in the "Current state" table above,
working from the bottom of the file upward (so earlier deletions don't shift
the line numbers you still need for later ones). After deleting, re-read the
resulting function once fully to confirm it still reads coherently (no
dangling braces, no orphaned blank lines that used to separate a comment
block from live code).

**Verify**: `go build ./v2/config/...` → exit 0. `go test ./v2/config/...` →
all pass (dead code deletion should not change any test's outcome — if one
does, STOP, see below). `grep -c "ClashMode\|DNSStaticTag\|DNSRemoteTagFallback\|DNSTricksDirectTag" hiddify-core/v2/config/builder.go`
returns `0` (these identifiers only appeared in the deleted dead blocks).

### Step B: Extract `setRoutingOptions` into ordered sub-functions

Working from the live-logic sequence in "Current state", extract each
numbered item into its own function that `setRoutingOptions` calls **in the
same order**, threading `routeRules`, `dnsRules`, and `rulesets` through as
parameters/return values (Go doesn't have closures-over-locals across
top-level functions, so each extracted function should take the slices it
needs to read/append to as parameters and return the updated slices — match
whatever parameter-passing style is already used by the existing
`addForceDirect` function in this same file, since that's the established
convention for this exact kind of extraction in this codebase).

Suggested function names (adjust if the actual code structure suggests a
better boundary once you're editing it — the names aren't load-bearing, the
*order* is):

1. `addSniffAndDNSHijackRules` (item 2)
2. `addStaticSubnetRoute` (item 3)
3. `addBypassLANRule` (item 4)
4. `addNTPForceDirectRules` (item 5)
5. `addAdBlockRules` (item 6)
6. `addRegionRules` (item 7)
7. `addBlockQuicRule` (item 8)
8. `addFakeDNSRule` (item 10)
9. `addFinalRemoteDNSRule` (item 11)

`setRoutingOptions` itself becomes a short function that declares
`dnsRules`/`routeRules`/`rulesets`, calls `addForceDirect` (unchanged, item
1), then each of the 9 new functions above **in exactly this order**,
assembles `options.Route` (item 9), and runs the final validate-and-append
loop (item 12).

**After each individual extraction**, run the build/test verification below
before moving to the next one — do not extract all nine and then test once;
that makes it much harder to isolate which extraction introduced a problem.

**Verify** (after each extraction, and again after all nine): `go build ./v2/config/...`
→ exit 0. `go vet ./v2/config/...` → exit 0. `go test ./v2/config/...` → all
pass, with identical output to the Step A baseline (same tests, same
results — a routing-rule order change would most likely surface as a
`BuildConfig`-level test difference if `plans/029`'s tests exist by now, or
otherwise may not be caught by tests at all, which is exactly why this step
says "in exactly this order" three times).

## Test plan

- No new tests are required by this plan, but if `plans/029-*.md`
  (config-builder test coverage) has already landed, re-run its test suite
  after Step B and confirm zero behavioral difference — that is the
  strongest available regression net for "did the rule order actually stay
  the same."
- If `plans/029` has *not* landed yet, at minimum manually diff the
  generated `option.Options.Route.Rules` / `options.DNS.Rules` slices for a
  representative `HiddifyOptions` input before and after Step B (e.g. via a
  throwaway `go run` snippet or `fmt.Printf("%+v", ...)` in a scratch test —
  do not commit a scratch test, just use it to confirm equivalence, then
  delete it) — this is the closest thing to a regression check available
  without plan 029's harness.

## Done criteria

- [ ] Step A commit exists separately from Step B commit
- [ ] `go build ./v2/config/...`, `go vet ./v2/config/...` exit 0 after both steps
- [ ] `go test ./v2/config/...` passes identically after Step A and after Step B
- [ ] `gofmt -l hiddify-core/v2/config/` produces no output
- [ ] All nine dead-code regions are gone (grep check in Step A passes)
- [ ] `setRoutingOptions` calls the 9 extracted functions (plus the unchanged `addForceDirect`) in the exact order listed in Step B
- [ ] `git status` shows changes only to `hiddify-core/v2/config/builder.go`, `plans/README.md`
- [ ] `plans/README.md` status row updated, noting whether plan 029's tests were available as a regression net

## STOP conditions

- The live-logic sequence in "Current state" doesn't match what you find on
  re-reading the current `setRoutingOptions` (drift since this plan was
  written) — re-derive the current order yourself; do not assume this
  plan's list is still accurate.
- Any test's result changes after Step A (dead-code deletion) — this would
  mean something claimed dead was not actually dead; revert that specific
  deletion and report it rather than investigating further within this plan.
- Extracting any of the 9 functions would require appending its rules in a
  different relative order than the monolith did (e.g. because two of the
  numbered items' logic is more intertwined than this plan assumed once you
  read it closely) — STOP and report the specific entanglement rather than
  reordering to make the extraction cleaner.
- You cannot express the parameter-passing pattern consistently with
  `addForceDirect`'s existing style — report the mismatch rather than
  inventing a third pattern in the same file.

## Maintenance notes

- The 9 extracted functions are deliberately NOT reordered relative to each
  other or to `addForceDirect` — a future change that wants to reorder
  routing precedence should do so explicitly and with its own test/manual
  verification, not incidentally as part of further refactoring this area.
- If `plans/029` (config builder tests) lands after this plan instead of
  before, retroactively verify its new tests still pass against the
  now-split function — the split should be invisible to any test written
  against `BuildConfig`'s public behavior.
- This plan does not address `setOutbounds` (`builder.go:130-363`, 234
  lines) or `BuildConfig` itself, both of which could benefit from similar
  treatment — out of scope here, worth a follow-up if this pattern proves
  valuable.
