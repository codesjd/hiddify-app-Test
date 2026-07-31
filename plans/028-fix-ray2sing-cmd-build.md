# Plan 028: Fix the broken build in ray2sing's CLI (`ray2sing/cmd`)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `cd hiddify-core/ray2sing && go vet ./...`
> Reproduce the current error text before making any change — if it differs
> from "Current state" below (different file/line/message), re-diagnose
> from the actual current error rather than assuming this plan's excerpt
> still applies.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: `hiddify-core` submodule commit `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`, 2026-07-29

## Why this matters

`ray2sing/cmd` — the standalone CLI for converting a proxy share-link to a
sing-box outbound — does not compile. Reproduced directly in this pass:

```
$ cd hiddify-core/ray2sing && go vet ./...
# github.com/hiddify/ray2sing/cmd
# [github.com/hiddify/ray2sing/cmd]
vet.exe: cmd\cmd_convert.go:29:51: not enough arguments in call to ray2sing.Ray2Singbox
	have (string, bool)
	want (context.Context, string, bool)
```

Beyond the CLI itself being broken, this means there is currently **no
working one-command way to know the `ray2sing/cmd` package still builds**
after any change to `ray2sing`'s public API (`Ray2Singbox`'s exported
signature is exactly what every protocol parser in this module feeds into).
A signature change elsewhere in `ray2sing` that happens to also break this
call site would go unnoticed, because this package already doesn't build —
`go build ./...`/`go vet ./...` for this module reports the *same* failure
whether or not a new regression was just introduced here.

## Current state

`hiddify-core/ray2sing/cmd/cmd_convert.go` in full today:

```go
package main

import (
	"fmt"

	"github.com/hiddify/ray2sing/ray2sing"
	"github.com/sagernet/sing-box/log"

	"github.com/spf13/cobra"
)

var commandConvert = &cobra.Command{
	Use:   "convert",
	Short: "Convert link to sing-box outbound",
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		err := convert(args[0])
		if err != nil {
			log.Fatal(err)
		}
	},
}

func init() {
	mainCommand.AddCommand(commandConvert)
}

func convert(link string) error {
	outbound, err := ray2sing.Ray2Singbox(link, false)
	if err != nil {
		return err
	}

	fmt.Printf("%s\n", outbound)
	return err
}
```

`Ray2Singbox`'s actual signature (`hiddify-core/ray2sing/ray2sing/convert.go:247`):

```go
func Ray2Singbox(ctx context.Context, configs string, useXrayWhenPossible bool) (out []byte, err error) {
```

The call at `cmd_convert.go:29` is missing the leading `context.Context`
argument. Two other call sites in the same module show the two ways this is
correctly done elsewhere:

- `hiddify-core/ray2sing/main.go:130`: `ray2sing.Ray2Singbox(libbox.BaseContext(nil), configs, false)`
- `hiddify-core/ray2sing/ray2sing/test.go:17`: `Ray2Singbox(ctx, url, false)` (where `ctx` is a test-local context)

Since `cmd_convert.go` is a standalone CLI entry point with no surrounding
request/cancellation context to plumb through, the simplest correct fix is
`context.Background()` — there's nothing to cancel or propagate here, unlike
`main.go`'s use of `libbox.BaseContext(nil)` (that one's part of the core's
own lifecycle context, not applicable to a one-shot CLI invocation).

**Also noted, not fixed by this plan**: `hiddify-core/ray2sing/wasm.go:25`
has the exact same bug (`ray2sing.Ray2Singbox(input)`, one argument, and
additionally a return-type mismatch — the function declares
`(string, error)` but assigns directly from `Ray2Singbox`'s actual
`([]byte, error)` return). That file carries a `//go:build ignoreunix` tag
(`wasm.go:1-2`), a build constraint that never matches any real `GOOS`, so
it is excluded from every normal build — `go vet ./...` didn't even surface
it in the reproduction above. It's dead code under its current build tag;
see Scope for why this plan doesn't touch it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Vet (reproduce + verify fix) | `cd hiddify-core/ray2sing && go vet ./...` | exit 0 after the fix |
| Build | `cd hiddify-core/ray2sing && go build ./...` | exit 0 |
| Tests | `cd hiddify-core/ray2sing && go test ./...` | all pass |

## Scope

**In scope**:
- `hiddify-core/ray2sing/cmd/cmd_convert.go` (the one call site)

**Out of scope**:
- `hiddify-core/ray2sing/wasm.go` — same bug shape, but already excluded
  from every real build via its `//go:build ignoreunix` tag; fixing dead
  code under a tag that never matches anything provides no verification
  value and isn't part of what's actually broken today. If you'd like to
  flag it for cleanup (either fix it to keep it buildable under a real tag,
  or delete it if wasm output is no longer needed), note that in your final
  report as a separate, tiny follow-up rather than touching it here.
- `Ray2Singbox`'s signature itself, or any other `ray2sing` public API —
  not being changed, only this one caller.
- Any other file in `ray2sing/cmd/` — check whether other cobra subcommands
  in that directory have similar bugs (a quick `go vet ./...` after this fix
  will surface any that remain), but only fix what the drift-check/vet
  reproduction in this plan actually names; if `go vet` reports a *different*
  error in a different file after this fix, that's a separate finding — note
  it, don't silently expand this plan to cover it.

## Git workflow

- Branch: `advisor/028-fix-ray2sing-cmd-build`
- One commit. Message style: short imperative subject, e.g.
  `Pass context.Background() to Ray2Singbox in ray2sing/cmd`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reproduce the current failure

**Verify**: `cd hiddify-core/ray2sing && go vet ./...` → reports the exact
error shown in "Why this matters" (confirm it matches; if the error text or
location differs, STOP and re-diagnose from what you actually see rather
than applying this plan's fix blindly).

### Step 2: Fix the call site

Add `"context"` to `cmd_convert.go`'s imports, and change:

```go
func convert(link string) error {
	outbound, err := ray2sing.Ray2Singbox(link, false)
```

to:

```go
func convert(link string) error {
	outbound, err := ray2sing.Ray2Singbox(context.Background(), link, false)
```

**Verify**: `cd hiddify-core/ray2sing && go build ./... && go vet ./...` →
both exit 0.

### Step 3: Confirm the CLI actually runs

**Verify**: build the CLI binary and run its `convert` subcommand against a
trivial/well-formed test link (reuse one from
`hiddify-core/ray2sing/ray2sing_test/` if convenient, e.g. a simple `vless://`
or `trojan://` URL already used as a test fixture) —
`cd hiddify-core/ray2sing && go run . convert "<link>"` → prints a JSON
outbound to stdout and exits 0, rather than erroring.

## Test plan

No new automated test is required for a one-line call-site fix in a `main`
package (Go doesn't typically unit-test `main`/CLI wiring beyond a build
check) — the existing `ray2sing_test/` suite already covers `Ray2Singbox`
itself extensively. Verification is Steps 1-3 above: reproduce the build
failure, fix it, confirm both `go vet` and an actual CLI invocation succeed.

## Done criteria

- [ ] `cd hiddify-core/ray2sing && go vet ./...` exits 0
- [ ] `cd hiddify-core/ray2sing && go build ./...` exits 0
- [ ] `cd hiddify-core/ray2sing && go test ./...` passes (unaffected by this change, confirms nothing else broke)
- [ ] `go run . convert "<a test link>"` (from `hiddify-core/ray2sing/`) prints output and exits 0
- [ ] `git status` (inside `hiddify-core/`) shows changes only to `ray2sing/cmd/cmd_convert.go`
- [ ] `plans/README.md` (Dart repo root) status row for plan 028 updated, including the exact `go vet` output you reproduced in Step 1 and confirmed fixed in Step 2

## STOP conditions

- The error reproduced in Step 1 doesn't match "Why this matters" (different
  file, line, or message) — the codebase has drifted since this plan was
  written; diagnose and report the actual current error instead of applying
  this plan's specific fix to a bug that may no longer be there in this
  exact shape.
- `go build`/`go vet` for the whole `hiddify-core` module (not just
  `ray2sing/`) fails for an unrelated reason (e.g. the nested-submodule
  checkout issue noted in prior audit passes: `hiddify-sing-box/replace/*`
  not initialized) — that's a pre-existing environment limitation; verify
  scoped to `ray2sing/` as its own module (as the Commands table does) and
  don't attempt to fix the unrelated module-resolution issue as part of this
  plan.

## Maintenance notes

- `wasm.go`'s identical bug (noted in Current state) was deliberately left
  unfixed since it's unreachable under its current build tag. If wasm
  output is ever needed again, whoever revives that file should fix both the
  missing-context-argument bug and the `(string, error)` vs `([]byte, error)`
  return-type mismatch together, and should also give it a working build
  tag (`ignoreunix` matches nothing) so a working `go vet`/`go build` can
  actually catch future regressions in it.
- Now that `ray2sing/cmd` builds again, consider (as a separate, larger
  follow-up beyond this plan) whether it's worth adding it to whatever CI
  step already runs `go build`/`go vet` for the rest of `hiddify-core`, so
  this specific regression can't silently recur.
