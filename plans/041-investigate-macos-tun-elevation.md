# Plan 041: Investigate — how should macOS get TUN privilege elevation? (spike, no code change)

> **Executor instructions**: Follow this plan step by step. This is an
> investigate-only plan: the deliverable is a written recommendation
> document, not a code change. Do not implement any of the options below —
> that is explicitly out of scope for this plan. When done, update the
> status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b3b9677a..HEAD -- macos/`
> (Dart repo) and, inside `hiddify-core`,
> `git diff --stat 1c2af3c4a75aa4e393f33f928103491cf5a54e18..HEAD -- v2/hutils/`.
> If either shows changes, re-read the affected files live before proceeding.

## Status

- **Priority**: P2
- **Effort**: S–M (spike)
- **Risk**: LOW — produces a document, not a code change
- **Depends on**: plan 039 (recommended context, not a hard dependency) —
  the elevated-helper architecture plan 039 fixes on Windows/Linux is one of
  the options this spike should weigh reusing vs. rejecting for macOS
- **Category**: direction
- **Planned at**: `hiddify-core` submodule commit
  `1c2af3c4a75aa4e393f33f928103491cf5a54e18`, Dart repo commit `b3b9677a`,
  2026-07-31

## Why this matters

Unlike Windows (which has a fully-built, just-disconnected elevated
Tunnel Helper Service, see plan 039) and Linux (which at least has a real
`CAP_NET_ADMIN` capability check even though nothing currently acts on it),
**macOS has no privilege-elevation code path for TUN at all**. Confirmed by
direct read:

- `macos/Runner/Release.entitlements:15-30` — every NetworkExtension-related
  entitlement (`com.apple.developer.networking.vpn.api`,
  `com.apple.developer.networking.networkextension` with
  `packet-tunnel-provider` etc., `com.apple.developer.system-extension.install`)
  is commented out. `com.apple.security.app-sandbox` (`:9-10`) is `false`.
- There is no `SMJobBless`/privileged-helper-tool code, no
  `NetworkExtension`/`NEPacketTunnelProvider` Swift code, and no
  `osascript`/`sudo`-shelling code anywhere under `macos/`.
- `hiddify-core/v2/hutils` has no `darwin_utils.go` defining `TunAllowed()`
  for macOS — it falls back to `stub_utils.go:7-9`
  (`func TunAllowed() bool { return false }`), meaning even after plan 039's
  fix, macOS would always be told "not allowed" and would always try to
  route through the elevated Tunnel Helper Service the same way Windows
  does. But that helper service (`hiddify-core/v2/hcore/tunnelservice/`) has
  no macOS-specific process-elevation mechanism either — it dials/spawns
  `HiddifyCli` (`getTunnelServicePath()`,
  `tunnelservice/admin_service_commander.go:162-177`, `darwin` case falls
  through to the same `HiddifyCli` binary name as the default case) but
  nothing grants *that* process elevated privileges on macOS — Windows gets
  this via `ShellExecute(..., "runas", ...)` (`hutils/windows_utils.go:49`),
  and there is no macOS equivalent implemented (`hutils`'s darwin build
  would fall to `stub_utils.go`'s `ExecuteCmd`, which just returns `"", nil`
  without actually launching anything, if no `darwin_utils.go` exists —
  **verify this file really doesn't exist before treating it as fact; that
  is Step 1 below**).

So even with plan 039 landed, TUN mode on macOS today can only work if the
whole app is already running with sufficient privilege by some means
outside this repo (or not at all). This needs a product decision before any
code gets written, because the real options have meaningfully different
cost/UX/maintenance tradeoffs — that's what this spike is for.

## What to investigate

1. **Confirm the current state** (don't take the "Why this matters" section
   above purely on faith — it was written from a single investigation pass,
   verify it yourself):
   - `find hiddify-core/v2/hutils -iname "*darwin*"` — confirm no
     `darwin_utils.go` (or equivalent) exists, and if one does, read it and
     correct this plan's understanding before proceeding.
   - `grep -rn "SMJobBless\|NetworkExtension\|NEPacketTunnelProvider\|systemextensiond" macos/` — confirm no existing helper-tool/system-extension code.
   - Check whether the shipped macOS `.app` (if you have access to a build
     artifact, DMG, or the CI workflow that produces one —
     `.github/workflows/build.yml`'s macOS-related steps, even if currently
     commented out per `plans/README.md`'s "Findings recorded but NOT
     planned" section noting most non-Windows platforms are commented out
     of the Build job) does anything at packaging time that might grant
     elevated rights (e.g., a signed installer package with a postinstall
     script, rather than a plain `.app` drag-install) — this changes what's
     actually possible without an in-app helper.

2. **Enumerate the real options**, each with a rough effort/risk bracket and
   what it would require:
   - **(a) NetworkExtension / `NEPacketTunnelProvider` system extension** —
     Apple's sanctioned, App-Store-compatible mechanism for a VPN-style TUN
     interface without ever needing root/sudo; the user grants one-time
     consent via a system dialog (similar in spirit to Android's
     `VpnService`). Requires: enabling the commented-out entitlements,
     writing a Swift/ObjC `NEPacketTunnelProvider` extension target, wiring
     packet I/O between it and the existing Go core (likely via the same
     `libbox.PlatformInterface.OpenTun` pattern already used for
     Android/iOS — see `hiddify-core/v2/hcore/platform_interface.go:41-47`,
     `MobilePlatformInterface.OpenTun` — investigate whether this interface
     is already OS-agnostic enough to reuse directly for a macOS system
     extension, since that would mean macOS's problem is "wire up the same
     interface iOS/Android already use," not "invent a new one"), an Apple
     Developer Program entitlement request
     (`com.apple.developer.networking.networkextension`), and a real Mac to
     test provisioning/notarization on (this is the one option this spike
     itself cannot fully validate without one).
   - **(b) A privileged helper tool via `SMJobBless`/`SMAppService`** —
     closer to how the Windows Tunnel Helper Service works (a small
     separate, elevated process the main app talks to over a local
     socket/gRPC), reusing plan 039's architecture almost directly if it
     lands first. Requires: a helper tool target, code-signing +
     `SMJobBless`/`SMAppService` plist wiring, and a one-time
     admin-password prompt (macOS's UAC-equivalent) rather than Windows's
     per-launch "runas" — investigate whether macOS's helper-install prompt
     is truly one-time (survives app updates/relaunches) or, like Windows's
     `ShellExecute("runas")`, needs re-prompting under some condition, since
     that materially changes the UX story vs. option (a).
   - **(c) Require the app to run with elevated rights via a different
     mechanism** (e.g., ship a `.pkg` installer with a postinstall script
     that sets a capability/ACL, or simply document that users must
     right-click "Run as different user"/enter their password once via
     `sudo` from a terminal) — lowest engineering effort, worst UX, and the
     kind of thing that would get flagged in App Store review if this app
     is ever distributed that way; note whether this app is currently
     distributed via the Mac App Store or only direct-download (check
     `macos/Runner.xcodeproj` / any `ExportOptions.plist` for
     `method: app-store` vs `developer-id`) since that materially affects
     whether (c) is even viable long-term.
   - **(d) Do nothing / explicitly unsupported** — document that TUN mode
     is Windows/Linux/Android/iOS-only for now, and macOS users get
     System-Proxy mode instead (`ServiceMode.systemProxy`, already a
     first-class option in the Dart UI per
     `lib/singbox/model/singbox_config_enum.dart`). Cheapest, but forecloses
     a real feature gap — note this option's user-facing cost concretely
     (how does the Settings UI currently behave if a macOS user selects TUN
     mode today? Does it show an error, silently do nothing, or crash? This
     is worth checking directly rather than assuming, since "what actually
     happens today" is part of what a maintainer needs to decide with).

3. **Cross-check against plan 039's architecture**: if (b) is chosen, how
   much of plan 039's `tunnelservice` package, `TunnelStartRequest` proto,
   and token-auth pattern (plan 019) can be reused verbatim vs. needs a
   macOS-specific variant? `tunnelservice/admin_service_commander.go:25-27`
   (`isSupportedOS`) already excludes macOS from the "supported" list
   (`runtime.GOOS == "windows" || runtime.GOOS == "linux"`) — is that because
   it was never implemented, or because something about the design is
   Windows/Linux-specific in a way that wouldn't port? Read
   `tunnel_platform_service.go`'s use of `kardianos/service` (a
   cross-platform Go service-manager library that already claims macOS
   `launchd` support) to judge how much of the "persistent installed
   service" shape could realistically extend to macOS with (b).

## Commands you will need

| Purpose | Command | Expected result |
|---|---|---|
| Confirm no darwin hutils file | `find hiddify-core/v2/hutils -iname "*darwin*"` | no output (confirms the gap), or a file to read if one exists |
| Confirm no NetworkExtension code | `grep -rln "NetworkExtension\|NEPacketTunnelProvider\|SMJobBless\|SMAppService" macos/` | no output (confirms the gap), or files to read |
| Check kardianos/service's macOS support | `grep -rn "launchd\|darwin" hiddify-core/go.sum hiddify-core/go.mod` (then inspect the actual vendored/module source if available) | informational |

No build/test commands — this plan produces a document, not a code change.

## Scope

**In scope**: read-only investigation across `macos/`, `hiddify-core/v2/hutils/`,
`hiddify-core/v2/hcore/tunnelservice/`, `hiddify-core/v2/hcore/platform_interface.go`,
and CI/packaging config for macOS. Writing one new file:
`hiddify-core/docs/macos-tun-elevation-spike.md` (matching the existing
convention: `hiddify-core/docs/protocol-builder-consolidation-spike.md`,
`hiddify-core/docs/hcore-abstraction-boundary-spike.md`).

**Out of scope**: implementing any of options (a)-(d); touching any
`macos/` entitlements, Xcode project files, or Swift/ObjC code; touching
`hiddify-core/v2/hutils/` or `tunnelservice/`; the Windows/Linux fix (plan
039) or the xicmp timing fix (plan 040) — independent work.

## Git workflow

- Branch: `advisor/041-macos-tun-spike`
- One commit: the spike doc.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Verify the current-state claims in "Why this matters"

Run the three commands in "Commands you will need." Confirm or correct each
claim before writing the spike doc — if you find a `darwin_utils.go` or any
NetworkExtension code this plan missed, the spike doc must reflect the real
current state, not this plan's assumptions.

**Verify**: you can state, with a `file:line` or "confirmed absent" for
each of the three claims in "Why this matters," whether it still holds.

### Step 2: Investigate the four options

Work through each of (a)-(d) above. For each, write 3-5 sentences covering:
what it requires, its rough effort bracket (S/M/L/XL — this is likely M-XL
for (a)/(b), S for (c)/(d)), what's uncertain/needs a real Mac to validate,
and one clear risk.

**Verify**: you have a paragraph for each of (a), (b), (c), (d).

### Step 3: Check what happens today when a macOS user selects TUN mode

Read `lib/features/settings/data/config_option_repository.dart` and
`lib/features/settings/overview/sections/inbound_options_page.dart` (Dart
repo) — is `ServiceMode.tun` selectable in the UI regardless of platform, or
is it already gated to certain platforms? If selectable, trace what the Go
core does when `EnableTun=true` on `runtime.GOOS == "darwin"` today (per
"Why this matters," it likely just tries the raw sing-box tun inbound and
fails at the OS level) — is that failure surfaced to the user as a
comprehensible error, or does it fail silently/confusingly? State this
plainly in the spike doc's "current user-facing behavior" section — a
maintainer choosing between (a)-(d) needs to know how bad the status quo
actually is.

**Verify**: the spike doc has a "Current user-facing behavior on macOS"
section with a concrete answer, not a guess.

### Step 4: Write the recommendation

Write `hiddify-core/docs/macos-tun-elevation-spike.md` with:
- A summary of the confirmed current state (Step 1).
- The four options (Step 2), each with its effort/risk/uncertainty.
- The current user-facing behavior (Step 3).
- A recommendation — even a soft one ("(b) is probably the better ROI
  because it reuses plan 039's architecture, but (a) is the only option
  that survives a future Mac App Store distribution goal, if that's ever a
  target — worth confirming with whoever owns the release channel decision
  before committing engineering time") is more useful than "it depends."
- An explicit "not decided here" flag — this is a spike, not an approval;
  say so at the top of the doc, matching plans 036/037's own framing.

**Verify**: `test -f hiddify-core/docs/macos-tun-elevation-spike.md` and the
file contains all four sections above.

## Test plan

None — this plan produces documentation only, no testable code changes.

## Done criteria

- [ ] `hiddify-core/docs/macos-tun-elevation-spike.md` exists and covers all four sections from Step 4
- [ ] Every claim in "Why this matters" has been independently re-verified (Step 1) and the doc states any correction found
- [ ] `git status` (both repos) shows only the one new doc file changed
- [ ] `plans/README.md` status row updated for plan 041

## STOP conditions

- You find that macOS TUN elevation is, in fact, already handled by some
  mechanism this plan's investigation missed (e.g. a packaging-time
  postinstall script, or a `darwin_utils.go` that does exist) — if so, the
  premise of this whole plan may be wrong; write that finding into the spike
  doc as the headline result instead of forcing the four-option framing.

## Maintenance notes

- This spike unblocks a future decision; nothing currently in
  `plans/README.md` depends on that decision being made by any particular
  date.
- If (b) is eventually chosen, re-read plan 039's final landed code first —
  it will be the concrete pattern to reuse or diverge from, not this spike
  doc's necessarily-coarser description of it.
