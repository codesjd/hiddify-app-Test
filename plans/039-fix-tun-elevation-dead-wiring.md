# Plan 039: Make TUN mode's Windows/Linux privilege-elevation path actually run

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 1c2af3c4a75aa4e393f33f928103491cf5a54e18..HEAD -- extension/ v2/config/builder.go v2/hcore/ platform/desktop/`.
> If it shows any changes, re-read the affected files live before proceeding
> against the excerpts below; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P0
- **Effort**: M
- **Risk**: MED — touches the extension-registration framework and the main
  desktop binary's init graph, but every change is additive/narrowly scoped
  (no existing call site is deleted, only a currently-dead path is turned on)
- **Depends on**: none
- **Category**: bug
- **Planned at**: `hiddify-core` submodule commit
  `1c2af3c4a75aa4e393f33f928103491cf5a54e18`, Dart repo commit `b3b9677a`,
  2026-07-31

## Why this matters

On Windows and Linux, enabling "TUN" mode in the app only works today if the
main Hiddify process happens to already be running with admin/root
privileges. For the overwhelming majority of users (who just double-click
the app / launch it normally), TUN mode silently fails to create the
system-wide network adapter, because the one mechanism designed to hand TUN
adapter creation off to an already-built, already-authenticated elevated
helper service (`hiddify-core/v2/hcore/tunnelservice/`, port 18020) is never
actually invoked. Three independent breaks compound to make this dead code
(not one), traced end-to-end below. This is the same class of bug that was
already found and fixed for the ICMP/xicmp feature
(`hiddify-core/v2/hcore/icmp_wiring.go`) — that fix is live and correct; this
plan applies the equivalent fix for TUN, using the mechanism that was
actually built for it (which, unlike ICMP, cannot use `icmp_wiring.go`'s
"bypass everything, call directly" shortcut — see "Why not the icmp_wiring.go
shortcut" below).

Symptom this explains: "TUN mode doesn't work properly or doesn't work at
all" — it appears to "sometimes work" only because a user who happens to run
the app elevated (or on Android, which has a completely separate, unrelated,
working code path through the OS's own `VpnService` consent flow) doesn't
hit the bug.

## Current state

### The three breaks

**Break 1 — the extension framework that would bridge this is never
registered.** `hiddify-core/extension/interface.go:124-126`:

```go
func init() {
	// service_manager.Register(&extensionService{})
}
```

`extensionService` (defined earlier in the same file) is the *only* thing
that ever calls `OnMainServicePreStart`/`OnMainServiceStart`/`OnMainServiceClose`
on registered extensions. With this line commented out,
`hiddify-core/extension/system/admin_service_vpn/admin_tun_service.go`'s
`AdminServiceExtension` (the code that calls `tunnelservice.ActivateTunnelService`)
never runs, on any platform, regardless of settings.

**Break 2 — even with Break 1 fixed, the extension looks for the wrong
inbound type.** `admin_tun_service.go:29-48`:

```go
func (b *AdminServiceExtension) OnMainServicePreStart(singconfig *option.Options) error {
	if hutils.TunAllowed() {
		return nil
	}
	newInbounds := make([]option.Inbound, 0, len(singconfig.Inbounds))
	for _, inb := range singconfig.Inbounds {
		if inb.Type == C.TypeTun {
			if d, ok := inb.Options.(option.TunInboundOptions); ok {
				b.tunInboundOptions = &d
			}
		} else {
			if inb.Type == C.TypeSOCKS {
				if d, ok := inb.Options.(option.SocksInboundOptions); ok {
					b.socksOptions = &d
				}
			}
			newInbounds = append(newInbounds, inb)
		}
	}
	singconfig.Inbounds = newInbounds
	return nil
}

func (b *AdminServiceExtension) OnMainServiceStart() error {
	if b.tunInboundOptions == nil || b.socksOptions == nil {
		return nil
	}
	// ... calls tunnelservice.ActivateTunnelService using b.socksOptions.Users[0]
}
```

It only populates `b.socksOptions` when it finds a `C.TypeSOCKS` inbound.
But `hiddify-core/v2/config/builder.go` **never emits a SOCKS inbound** for
the main proxy — it emits `C.TypeMixed` (confirmed by direct read,
`builder.go:500-521`):

```go
for _, bind := range binds {
	addr := badoption.Addr(netip.MustParseAddr(bind))
	options.Inbounds = append(
		options.Inbounds,
		option.Inbound{
			Type: C.TypeMixed,
			Tag:  InboundMixedTag + bind,
			Options: &option.HTTPMixedInboundOptions{
				ListenOptions: option.ListenOptions{
					Listen:     &addr,
					ListenPort: hopt.MixedPort,
				},
				SetSystemProxy: hopt.SetSystemProxy,
			},
		},
	)
	...
```

(`InboundMixedTag = "mixed-in"`, `hiddify-core/v2/config/builder.go:51`.)

Note it's a **pointer** (`&option.HTTPMixedInboundOptions{...}`), not a value
— the type assertion in the fix must match (`*option.HTTPMixedInboundOptions`),
matching how `inb.Options.(option.TunInboundOptions)` above is *also* wrong in
the same way for the TUN side (`setInbound` in `builder.go:458-463` stores
`Options: &opts` — a pointer too). Both existing type assertions in
`admin_tun_service.go` are checking the non-pointer type and would never
succeed even with Break 1 fixed; this has apparently never been noticed
because Break 1 already prevented this code from running at all.

Since `builder.go` never populates a `Users` field on the Mixed inbound (grep
confirms: `grep -n "Users:" hiddify-core/v2/config/builder.go` returns
nothing), the extracted username/password will legitimately be empty
strings — that's correct and matches the Mixed inbound's own current
lack of authentication, not a bug to fix here.

**Break 3 — even with 1 and 2 fixed, nothing ever imports the package that
registers this extension.** `admin_service_vpn`'s `init()` (which calls
`ex.RegisterExtension(...)`, `admin_tun_service.go:84-93`) only runs if
something imports the package (even with a blank `_` import) so its package
initializer executes. Confirmed by grep
(`grep -rn "admin_service_vpn" hiddify-core --include=*.go`): the only
references are the package's own files. No `platform/desktop`, `platform/mobile`,
or `cmd/` file imports it.

### Why the fix must go through this framework (not a direct call like `icmp_wiring.go`)

`icmp_wiring.go` fixed the equivalent ICMP bug by calling
`icmpservice.ProxiedListenICMP` directly from `hcore.StartService`, bypassing
the extension framework entirely — that works for ICMP because `icmpservice`
does **not** import `hcore`. TUN's helper is different:
`hiddify-core/v2/hcore/tunnelservice/tunnel_service.go:14,28` imports
`hcore` (`hcore.NewService(ctx, option)`) so that the elevated helper process
can spin up its own small sing-box instance. That means **`hcore` cannot
import `tunnelservice`** — doing so would create an import cycle
(`hcore → tunnelservice → hcore`) and fail to build. The
`extension`/`service_manager` indirection exists specifically to let
`hcore` invoke extension code without importing it directly (extensions
register themselves via `init()` into a package-level map; `hcore` only ever
calls the generic `service_manager.OnMainServiceStart()` etc., never
`tunnelservice` by name). This is why this plan fixes the existing
indirection rather than adding a new direct call.

This is also correctly positioned in the startup sequence already: sing-box
calls back into `hiddifyMainServiceManager.Start(stage)`
(`hiddify-core/v2/hcore/service_manager_callback.go:13-18`) only once
`stage == adapter.StartStateStarted` — i.e., **after** the box's own inbounds
(including the Mixed proxy inbound the elevated helper's SOCKS5 outbound
dials back into) are already listening. No new ordering/race logic is
needed; wire through the existing hook and this ordering is already correct.

### The enable/disable gate must not block this extension

`hiddify-core/extension/interface.go:39-50` (`loadExtension`) only loads an
extension if a per-extension DB row's `Enable` flag is `true`, and
`Init()` (`:58-82`) creates that row defaulted to `Enable: false` the first
time it sees a new extension ID, with no UI anywhere that ever sets it to
`true`. There is no user-facing "enable TUN helper" toggle and there should
not be one — same reasoning `icmp_wiring.go`'s own comment gives for its
unconditional wiring: "no user-facing enable/disable toggle... an
unconditional wire-up has no cost for users who never touch [the feature]."
This plan adds a way for a specific extension factory to mark itself as
always-enabled, independent of the DB toggle, so the pattern generalizes for
extensions like this that are load-bearing bug fixes, not opt-in add-ons.

### A related, already-dead, do-not-touch file in the same package

`hiddify-core/extension/system/admin_service_vpn/admin_icmp_service.go`
registers a *separate* extension (`AdminIcmpExtension`, ID
`.../admin_service_xicmp`) that is now fully superseded by `icmp_wiring.go`
(confirmed: `icmp_wiring.go`'s own comment says so, and `icmp_wiring.go` is
called unconditionally from `hcore.StartService`, verified at
`hiddify-core/v2/hcore/start.go:97`). This plan's Step 4 blank-imports the
`admin_service_vpn` package (for its TUN half's `init()` to run) — this will
also cause `AdminIcmpExtension`'s `init()`/`RegisterExtension` to run again,
but since **Step 1's `AlwaysEnabled` field defaults to `false`** and this
plan does not set it on the ICMP factory, and no DB row ever sets that
extension's `Enable` to `true` either, `AdminIcmpExtension` will register but
never load — a harmless no-op, not a regression, not a duplicate of
`icmp_wiring.go`'s live fix. **Do not set `AlwaysEnabled: true` on the ICMP
factory in this plan** — that would resurrect a dead, superseded code path
alongside the live one.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build (non-cgo packages) | `cd hiddify-core && go build ./extension/... ./v2/hcore/... ./v2/config/...` | exit 0 |
| Build (desktop cgo binary) | `cd hiddify-core && go build ./platform/desktop/...` | exit 0 — requires a C toolchain (cgo); if unavailable in your environment, note this in your report and rely on the non-cgo build + `go vet` instead |
| Vet | `cd hiddify-core && go vet ./extension/... ./v2/hcore/... ./v2/config/...` | exit 0 |
| Test | `cd hiddify-core && go test ./extension/... ./v2/hcore/...` | all pass, including new tests from Step 5 |

If any command fails with an unrelated nested-submodule/build-tag error
(known pre-existing gap, see `plans/README.md`'s "New findings" section on
`-tags with_wireguard`), scope the command narrower to just the packages you
changed rather than trying to fix that unrelated gap.

## Scope

**In scope**:
- `hiddify-core/extension/extension.go` — add `AlwaysEnabled bool` to `ExtensionFactory`
- `hiddify-core/extension/interface.go` — uncomment the `Register` call; honor `AlwaysEnabled` in the load-gate
- `hiddify-core/extension/system/admin_service_vpn/admin_tun_service.go` — fix the inbound type assertions; set `AlwaysEnabled: true`
- `hiddify-core/platform/desktop/` — add one new file with a blank import
- New test file(s) under `hiddify-core/extension/` and/or
  `hiddify-core/extension/system/admin_service_vpn/`

**Out of scope** (do NOT touch):
- `hiddify-core/extension/system/admin_service_vpn/admin_icmp_service.go` — dead/superseded, see above; do not set it `AlwaysEnabled`, do not delete it either (out of scope for this plan; deletion is a separate tech-debt cleanup)
- `hiddify-core/v2/hcore/icmp_wiring.go` and anything under `hiddify-core/v2/hcore/icmpservice/` — unrelated feature, covered by plan 040
- `hiddify-core/v2/hcore/tunnelservice/` internals (`tunnel_service.go`, `admin_service_commander.go`, the proto files) — already correct and already token-authenticated (plan 019); this plan only makes sure they get *called*
- `hiddify-core/platform/mobile/` — Android/iOS use their own OS-level TUN consent flow (`libbox.PlatformInterface.OpenTun`, see `hiddify-core/v2/hcore/platform_interface.go:41-47`) and never touch `tunnelservice`; do not add the blank import there
- The macOS elevation gap (no entitlements, no helper tool at all) — separate, larger design question, covered by plan 041
- `lib/` (Dart) — no Dart-side change is needed; the Dart client already sends `enableTun`/`tunImplementation`/`mtu`/`strictRoute` correctly (verified end-to-end during this investigation)

## Git workflow

- Branch: `advisor/039-tun-elevation-wiring`
- Suggested commits: (1) `AlwaysEnabled` field + gate + registration uncomment, (2) inbound type-assertion fix in `admin_tun_service.go`, (3) blank import in `platform/desktop`, (4) tests
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add an `AlwaysEnabled` escape hatch to the extension framework

In `hiddify-core/extension/extension.go`, add a field to `ExtensionFactory`
(currently `:160-165`):

```go
type ExtensionFactory struct {
	Id          string
	Title       string
	Description string
	Builder     func() Extension
	// AlwaysEnabled, when true, makes this extension load unconditionally,
	// bypassing the per-extension DB "Enable" toggle. Use only for
	// extensions with no user-facing enable/disable UI, where the extension
	// itself is a bug fix / required behavior rather than an opt-in add-on.
	AlwaysEnabled bool
}
```

In `hiddify-core/extension/interface.go`, update the load condition inside
`Init()` (currently `:74-78`):

```go
		if data.Enable {
			if err := loadExtension(factory); err != nil {
				return fmt.Errorf("failed to load extension %s: %w", data.Id, err)
			}
		}
```

to:

```go
		if data.Enable || factory.AlwaysEnabled {
			if err := loadExtension(factory); err != nil {
				return fmt.Errorf("failed to load extension %s: %w", data.Id, err)
			}
		}
```

**Verify**: `cd hiddify-core && go build ./extension/...` → exit 0.

### Step 2: Turn the extension bridge on

In `hiddify-core/extension/interface.go`, change (currently `:124-126`):

```go
func init() {
	// service_manager.Register(&extensionService{})
}
```

to:

```go
func init() {
	service_manager.Register(&extensionService{})
}
```

**Verify**: `cd hiddify-core && go build ./extension/...` → exit 0 (this will
fail to compile if `service_manager` isn't already imported in this file —
it is, per the existing `import` block at the top of `interface.go`; if for
some reason it isn't, add
`"github.com/hiddify/hiddify-core/v2/service_manager"` to the imports).

### Step 3: Fix the inbound type assertions and mark the extension always-enabled

In `hiddify-core/extension/system/admin_service_vpn/admin_tun_service.go`,
change the struct field and both type assertions from SOCKS to Mixed:

```go
type AdminServiceExtension struct {
	ex.Base[AdminServiceExtensionData]
	tunInboundOptions *option.TunInboundOptions
	mixedOptions      *option.HTTPMixedInboundOptions
}

func (b *AdminServiceExtension) OnMainServicePreStart(singconfig *option.Options) error {
	if hutils.TunAllowed() {
		return nil
	}
	newInbounds := make([]option.Inbound, 0, len(singconfig.Inbounds))

	for _, inb := range singconfig.Inbounds {
		if inb.Type == C.TypeTun {
			if d, ok := inb.Options.(*option.TunInboundOptions); ok {
				b.tunInboundOptions = d
			}
		} else {
			if inb.Type == C.TypeMixed {
				if d, ok := inb.Options.(*option.HTTPMixedInboundOptions); ok {
					b.mixedOptions = d
				}
			}
			newInbounds = append(newInbounds, inb)
		}
	}

	singconfig.Inbounds = newInbounds
	return nil
}
```

Update `OnMainServiceStart` and `OnMainServiceClose` to use `b.mixedOptions`
instead of `b.socksOptions` (same shape — `b.mixedOptions.Users` instead of
`b.socksOptions.Users`, `b.mixedOptions.ListenPort` for the port):

```go
func (b *AdminServiceExtension) OnMainServiceStart() error {
	if b.tunInboundOptions == nil || b.mixedOptions == nil {
		return nil
	}
	username := ""
	password := ""
	if len(b.mixedOptions.Users) > 0 {
		username = b.mixedOptions.Users[0].Username
		password = b.mixedOptions.Users[0].Password
	}
	return tunnelservice.ActivateTunnelService(&tunnelservice.TunnelStartRequest{
		Ipv6:                   len(b.tunInboundOptions.Address) > 1,
		ServerPort:             int32(b.mixedOptions.ListenPort),
		ServerUsername:         username,
		ServerPassword:         password,
		StrictRoute:            b.tunInboundOptions.StrictRoute,
		Stack:                  b.tunInboundOptions.Stack,
		EndpointIndependentNat: b.tunInboundOptions.EndpointIndependentNat,
	})
}

func (b *AdminServiceExtension) OnMainServiceClose() error {
	if b.tunInboundOptions == nil || b.mixedOptions == nil {
		return nil
	}
	return tunnelservice.DeactivateTunnelService()
}
```

(`len(b.tunInboundOptions.Address) > 1` replaces the previous
hardcoded `Ipv6: true` — `builder.go:476-479` appends a second, IPv6 prefix
to `Address` only `if ipv6Enable`, so checking the slice length is the
correct live signal. If `option.TunInboundOptions` doesn't have an `Address`
field with this shape when you check the live struct, STOP and report
rather than guessing a different field name.)

Also update `init()` at the bottom of the file to mark this factory
always-enabled:

```go
func init() {
	ex.RegisterExtension(
		ex.ExtensionFactory{
			Id:            "github.com/hiddify/hiddify-core/extension/system/admin_service_vpn",
			Title:         "Admin Service",
			Description:   "System Extension",
			Builder:       NewAdminServiceExtension,
			AlwaysEnabled: true,
		},
	)
}
```

**Verify**: `cd hiddify-core && go build ./extension/...` → exit 0.
`grep -c "socksOptions\|SocksInboundOptions\|C.TypeSOCKS" hiddify-core/extension/system/admin_service_vpn/admin_tun_service.go` → `0`.

### Step 4: Make the extension's `init()` actually run in the desktop binary

Create a new file `hiddify-core/platform/desktop/extensions.go`:

```go
package main

// Blank-imported so admin_service_vpn's init() registers its TUN-elevation
// extension (see plans/039-fix-tun-elevation-dead-wiring.md) — without this
// import, the package's RegisterExtension call in its own init() never runs
// and the extension stays invisible to hiddify-core/extension's registry.
import (
	_ "github.com/hiddify/hiddify-core/extension/system/admin_service_vpn"
)
```

**Verify**: `cd hiddify-core && go build ./platform/desktop/...` → exit 0
(requires a C toolchain for cgo; if your environment lacks one, instead run
`grep -n "admin_service_vpn" hiddify-core/platform/desktop/extensions.go`
and confirm it matches the content above, and rely on Step 5's tests to
prove the registration logic itself is correct).

### Step 5: Add tests

Add `hiddify-core/extension/system/admin_service_vpn/admin_tun_service_test.go`,
modeled after the existing `admin_icmp_service_test.go` in the same package
(same package name, same style of testing the extension struct directly
without spinning up the full framework):

- `TestOnMainServicePreStart_StripsTunAndCapturesMixedInbound`: build a
  `*option.Options` with two inbounds — one `{Type: C.TypeTun, Options:
  &option.TunInboundOptions{...}}` and one `{Type: C.TypeMixed, Options:
  &option.HTTPMixedInboundOptions{ListenOptions: option.ListenOptions{ListenPort: 1080}}}`.
  Construct `&AdminServiceExtension{}`, call `OnMainServicePreStart`. If the
  test's own `hutils.TunAllowed()` returns `true` on this machine/OS (likely
  true in most CI/dev sandboxes — same caveat the existing ICMP test already
  documents about running as an already-privileged user), the function
  returns immediately without stripping anything; skip the strip-behavior
  assertions in that case (`t.Skip(...)`, matching
  `admin_icmp_service_test.go`'s own pattern) but still assert the function
  returns no error. Where `TunAllowed()` is `false`, assert:
  `singconfig.Inbounds` no longer contains the TUN inbound, has exactly the
  Mixed inbound left, and `ext.tunInboundOptions`/`ext.mixedOptions` are both
  non-nil and hold the right values.
- `TestOnMainServiceStart_NoMixedInboundIsNoop`: `&AdminServiceExtension{}`
  with `tunInboundOptions` set but `mixedOptions` left `nil` (simulating "no
  Mixed inbound found") — `OnMainServiceStart()` must return `nil` without
  attempting to dial the tunnel service (no network call, no panic).
- In `hiddify-core/extension/interface_test.go` (new file), add
  `TestAlwaysEnabledExtensionLoadsWithoutDBRow`: register a fake
  `ExtensionFactory` with `AlwaysEnabled: true` and a `Builder` returning a
  minimal `ex.Base[struct{}]`-embedding stub, call the package's `Init()`
  path (or the smallest exercisable unit of it — read `interface.go` for the
  right entry point, likely constructing an `extensionService` and calling
  its `Init()` method directly against a temp/in-memory DB table if that's
  how existing DB-backed tests in this repo are structured; check
  `hiddify-core/v2/db` test helpers for the established pattern before
  inventing a new one), and assert the extension ends up in
  `enabledExtensionsMap` even though no DB row was ever set to `Enable: true`.

**Verify**: `cd hiddify-core && go test ./extension/... ./extension/system/admin_service_vpn/...` → all pass, including the 3 new tests.

## Test plan

- New tests: the 3 listed in Step 5.
- Structural pattern to follow: `admin_icmp_service_test.go` in the same
  package (already exists, already handles the "this test machine might
  already be privileged" caveat correctly — reuse that reasoning rather than
  re-deriving it).
- Verification: `cd hiddify-core && go test ./extension/...` → all pass.
- Not covered by automated tests (documented limitation, same as plan 019/020):
  the actual UAC-elevation + real Windows-service install/start round trip —
  that requires a real, non-elevated Windows user session and is not
  something this repo's test suite exercises anywhere today.

## Done criteria

- [ ] `cd hiddify-core && go build ./extension/... ./v2/hcore/... ./v2/config/...` exits 0
- [ ] `cd hiddify-core && go vet ./extension/... ./v2/hcore/... ./v2/config/...` exits 0
- [ ] `cd hiddify-core && go test ./extension/... ./extension/system/admin_service_vpn/...` passes, including the 3 new tests
- [ ] `grep -n "service_manager.Register(&extensionService{})" hiddify-core/extension/interface.go` matches (not commented out)
- [ ] `grep -c "SocksInboundOptions\|C.TypeSOCKS" hiddify-core/extension/system/admin_service_vpn/admin_tun_service.go` returns `0`
- [ ] `grep -n "admin_service_vpn" hiddify-core/platform/desktop/extensions.go` matches
- [ ] `git status` (inside `hiddify-core`) shows changes only to the files in Scope
- [ ] `plans/README.md` status row updated for plan 039

## STOP conditions

- Any excerpt in "Current state" doesn't match the live code — re-read
  before proceeding; this plan's line numbers may have drifted.
- `option.TunInboundOptions` doesn't have an `Address []netip.Prefix`-shaped
  field when you check it live — report the actual field name/shape instead
  of guessing at the IPv6-detection logic in Step 3.
- Uncommenting `service_manager.Register(&extensionService{})` causes a
  build failure for a reason other than a missing import (e.g. a genuine
  interface-satisfaction mismatch) — this would mean `extensionService` has
  drifted out of sync with `service_manager.HService`'s interface since this
  plan was written; report the exact compiler error rather than changing
  the interface to paper over it.
- `go build ./platform/desktop/...` fails for a reason unrelated to this
  change (e.g. no C toolchain available at all) — note this as an
  environment limitation (matching plan 018's Android/Xcode caveat) and rely
  on the non-cgo build + tests to verify the logic; don't attempt to install
  a C toolchain as part of this plan.
- You find evidence the shipped Windows/Linux installers already run the
  main app elevated by some mechanism outside this repo (contradicting this
  plan's "Why this matters") — report this rather than proceeding, since it
  would mean the actual bug (and its user impact) is different from what's
  described here.

## Maintenance notes

- If a future change adds a real "enable this extension" UI toggle for
  something else, the `AlwaysEnabled` field added in Step 1 should remain
  `false` for those — it's specifically for load-bearing, non-optional
  extensions like this one, not a general escape hatch to skip the
  DB-backed opt-in system.
- `hiddify-core/extension/system/admin_service_vpn/admin_icmp_service.go`
  (the now-fully-dead ICMP half of this same package) is a good target for
  a future small tech-debt cleanup (delete it, since `icmp_wiring.go`
  supersedes it) — explicitly out of scope here to keep this plan's blast
  radius limited to the TUN fix.
- The macOS gap (plan 041) and the smaller TUN robustness items (plan 042)
  are independent of this plan and can land in any order relative to it.
- If `windows/packaging/exe/inno_setup.sas`'s installer is ever changed to
  actually install `HiddifyTunnelService` at install time (finding 6 from
  the original investigation, not fixed by this plan), re-check whether
  `runTunnelService`'s current on-demand
  `hutils.ExecuteCmd(executablePath, false, "tunnel", "install")` fallback
  (`tunnelservice/admin_service_commander.go:147-160`) becomes redundant or
  starts conflicting with a pre-installed service of the same name.
