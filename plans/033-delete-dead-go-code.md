# Plan 033: Delete dead/commented-out Go code in ray2sing

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule's own
> `ray2sing` nested submodule, run
> `cd hiddify-core/ray2sing && git diff --stat a6877a3cd..HEAD -- ray2sing/xrayvless.go ray2sing/xraytrojan.go ray2sing/xrayvmess.go ray2sing/xraydirect.go ray2sing/hb64.go`.
> If any of these changed, re-read the live file before proceeding; on a
> mismatch treat it as a STOP condition — the exact line ranges below were
> read directly from the files at that commit and may have shifted.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: Dart repo commit `e38210d1`, `hiddify-core` submodule
  commit `8653861f1c6b87f4833e4bc3182af4b32c53b711`, `ray2sing` nested
  submodule commit `a6877a3cd439b2043d0dc76c5c7d9c7ef9a1f3f5`, 2026-07-29

## Why this matters

Five files under `hiddify-core/ray2sing/ray2sing/` carry dead Go code that
adds nothing but reading friction: four (`xrayvless.go`, `xraytrojan.go`,
`xrayvmess.go`, `xraydirect.go`) each keep a full commented-out earlier
implementation of the same outbound-building function, superseded by the
live `map[string]any` raw-JSON approach that now sits right above it in the
same file; the fifth (`hb64.go`) defines a function, `looksLikeBase64`, that
is never called anywhere. None of this is ambiguous or requires a judgment
call — every block below was confirmed dead by direct reading (and, for
`looksLikeBase64`, an exhaustive grep for call sites). Deleting it shrinks
these files by roughly a third to half each with zero behavior change, and
removes the "which of these two implementations is the real one?" question a
future reader would otherwise have to answer by comparing both.

## Current state

Verified directly by reading each file in full at the commit above:

- **`xrayvless.go`** (102 lines) — live function `VlessXray` at lines 1-53;
  dead commented-out earlier version of the same function at **lines
  55-102** (48 lines), using `conf.OutboundDetourConfig`/`conf.VLessOutboundConfig`
  from xray-core's `infra/conf` package (an import path the live version no
  longer uses at all — confirm the file's live `import` block only lists
  `T "github.com/sagernet/sing-box/option"` before deleting, so you're not
  leaving behind an unused import).
- **`xraytrojan.go`** (101 lines) — live `TrojanXray` at lines 1-43; dead
  block at **lines 45-101** (57 lines), same `conf.*` pattern, plus a nested
  second commented alternative inside the same block (lines 80-100 within
  it) — delete the whole commented region as one unit.
- **`xrayvmess.go`** (108 lines) — live `VmessXray` at lines 1-58; dead block
  at **lines 60-108** (49 lines).
- **`xraydirect.go`** (92 lines) — live `DirectXray` at lines 1-45; **two
  separate** dead blocks, not one contiguous range: a small commented helper
  `toInt32Range` at **lines 47-56** (10 lines, itself only used by the dead
  code below it — confirm via grep that nothing live calls `toInt32Range`
  before deleting), and a second, larger commented earlier version of
  `DirectXray` at **lines 58-92** (35 lines).
- **`hb64.go`** (48 lines) — `looksLikeBase64` (lines 8-25) has **zero call
  sites** anywhere in `ray2sing/` (`grep -rn "looksLikeBase64" hiddify-core/ray2sing/`
  returns only its own definition line). Its sibling function in the same
  file, `decodeBase64FaultTolerant` (lines 27-48), **is** used (from
  `common.go` and `vmess.go`) — do not touch it, only remove
  `looksLikeBase64`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core/ray2sing && go build ./...` | exit 0 |
| Vet | `cd hiddify-core/ray2sing && go vet ./...` | exit 0 (a pre-existing, unrelated `cmd/cmd_convert.go` argument-count error may be reported separately from a different finding/plan — if you see it, confirm it's that known issue and not something this plan introduced, then proceed) |
| Tests | `cd hiddify-core/ray2sing && go test ./...` | all pass |
| Format | `cd hiddify-core/ray2sing && gofmt -l .` | no output (no files need formatting) |

## Scope

**In scope**:
- `hiddify-core/ray2sing/ray2sing/xrayvless.go`
- `hiddify-core/ray2sing/ray2sing/xraytrojan.go`
- `hiddify-core/ray2sing/ray2sing/xrayvmess.go`
- `hiddify-core/ray2sing/ray2sing/xraydirect.go`
- `hiddify-core/ray2sing/ray2sing/hb64.go`

**Out of scope**:
- `decodeBase64FaultTolerant` in `hb64.go` — live, do not touch.
- Any live (non-commented) function in the four `xray*.go` files — this plan
  deletes only the commented-out blocks identified above, it does not
  refactor or touch the live implementations.
- Any other file in `ray2sing/` — a broader sweep for other dead code was not
  performed; if you notice another obviously-dead block while here, note it
  in your final report rather than deleting it as part of this plan.

## Git workflow

- Branch: `advisor/033-delete-dead-go-code`
- One commit (all five deletions are the same class of change — pure
  removal of confirmed-dead code — a single commit is appropriate).
- Do NOT push or open a PR unless the operator instructed it.
- This repo's `ray2sing` is itself a git submodule of `hiddify-core`, which
  is itself a submodule of the Dart repo. Commit inside `hiddify-core/ray2sing/`
  first (that's where the actual file changes live), then check whether the
  operator's workflow expects the parent submodules' pointers bumped too —
  if unsure, commit at the `ray2sing` level only and report that the parent
  pointers were left unbumped, rather than guessing.

## Steps

### Step 1: Delete the dead block in `xrayvless.go`

Delete lines 55-102 (the entire commented-out earlier `VlessXray`
implementation, from the `// func VlessXray(vlessURL string)...` line through
its closing `// }`). Leave the live function (lines 1-53) and the file's
trailing newline untouched.

**Verify**: `grep -c "conf.OutboundDetourConfig" hiddify-core/ray2sing/ray2sing/xrayvless.go`
returns `0`.

### Step 2: Delete the dead block in `xraytrojan.go`

Delete lines 45-101 (the entire commented-out earlier `TrojanXray`
implementation, including its nested inner alternative).

**Verify**: `grep -c "conf.OutboundDetourConfig" hiddify-core/ray2sing/ray2sing/xraytrojan.go`
returns `0`.

### Step 3: Delete the dead block in `xrayvmess.go`

Delete lines 60-108 (the entire commented-out earlier `VmessXray`
implementation).

**Verify**: `grep -c "conf.OutboundDetourConfig" hiddify-core/ray2sing/ray2sing/xrayvmess.go`
returns `0`.

### Step 4: Delete both dead blocks in `xraydirect.go`

Delete lines 47-56 (`toInt32Range`, after confirming via
`grep -rn "toInt32Range" hiddify-core/ray2sing/` that nothing live calls it)
and lines 58-92 (the commented-out earlier `DirectXray`). These are two
separate blocks with one blank/comment line of separation — delete both,
leaving the live `DirectXray` (lines 1-45) untouched.

**Verify**: `grep -c "conf.OutboundDetourConfig\|toInt32Range" hiddify-core/ray2sing/ray2sing/xraydirect.go`
returns `0`.

### Step 5: Delete `looksLikeBase64` from `hb64.go`

Delete lines 8-25 (the `looksLikeBase64` function only). Leave the file's
package declaration, imports, and `decodeBase64FaultTolerant` untouched —
re-check the imports afterward (`encoding/base64`, `strings`) are both still
used by `decodeBase64FaultTolerant` alone (they are, per the current file),
so no import needs removing.

**Verify**: `grep -c "func looksLikeBase64" hiddify-core/ray2sing/ray2sing/hb64.go`
returns `0`, and `grep -c "func decodeBase64FaultTolerant" hiddify-core/ray2sing/ray2sing/hb64.go`
returns `1` (unchanged).

### Step 6: Confirm everything still builds and tests pass

**Verify**: `cd hiddify-core/ray2sing && go build ./... && go test ./...` →
both exit 0 / all pass. `gofmt -l .` → no output.

## Test plan

No new tests — this is pure deletion of unreachable code with no behavior
change. The existing `ray2sing_test/` suite (Step 6) is the regression net;
if anything in it fails after these deletions, that means one of the
"dead" blocks was not actually dead, which would be a STOP condition (see
below), not something to work around.

## Done criteria

- [ ] `cd hiddify-core/ray2sing && go build ./...` exits 0
- [ ] `cd hiddify-core/ray2sing && go test ./...` all pass
- [ ] `gofmt -l hiddify-core/ray2sing` produces no output
- [ ] All five `grep` checks in Steps 1-5 return the expected counts
- [ ] `git status` (inside `hiddify-core/ray2sing`) shows changes only to the 5 files in Scope
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any of the five files don't match the line ranges in "Current state"
  (drift since this plan was written) — re-read the live file and identify
  the actual dead-code boundaries yourself rather than deleting by line
  number blindly.
- `go build`/`go test` fails after a deletion — this means the "dead" code
  was not actually dead (e.g. a build tag or reflection-based reference this
  plan's grep-based verification missed). Revert that specific deletion and
  report it rather than trying to fix the build around it.
- `toInt32Range` (Step 4) turns out to have a live caller you find during
  your own verification, contradicting this plan's claim — do not delete it;
  report the discrepancy.

## Maintenance notes

- This plan does not address `xray_common.go`'s own dead `// fp = "chrome"`
  comments (a related but distinct finding — see plan 035, which investigates
  and fixes that as a behavioral question, not a pure-deletion cleanup).
- If a future protocol file in `ray2sing/` accumulates the same
  "superseded implementation left commented out" pattern, prefer deleting it
  in the same commit that supersedes it, rather than letting it linger for a
  later cleanup pass like this one.
