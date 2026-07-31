# Plan 040: Give xicmp's elevated ICMP helper enough time for a human to click through UAC

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 1c2af3c4a75aa4e393f33f928103491cf5a54e18..HEAD -- v2/hcore/icmpservice/ v2/hcore/icmp_wiring.go`.
> If it shows any changes, re-read `admin_service_commander.go` and
> `icmp_platform_service.go` live before proceeding; on a mismatch, treat it
> as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW — both changes are constant-value tweaks plus one comment
  fix, no control-flow restructuring
- **Depends on**: none
- **Category**: bug
- **Planned at**: `hiddify-core` submodule commit
  `1c2af3c4a75aa4e393f33f928103491cf5a54e18`, Dart repo commit `b3b9677a`,
  2026-07-31

## Why this matters

The xicmp transport's Windows elevation path (added by an earlier fix,
`hiddify-core/v2/hcore/icmp_wiring.go`, confirmed live — called
unconditionally from `hcore.StartService`, `start.go:97`) is structurally
correct: parsing works, the helper process launches, the token-auth round
trip is consistent. But two timing values make it fail or annoy users in
practice even when everything is wired correctly:

1. **`EnsureIcmpHelperRunning` gives the elevated helper only 5 seconds to
   become reachable after firing a UAC ("Run as administrator") prompt.**
   That window has to cover the OS rendering the dialog, a human noticing
   and clicking "Yes," `HiddifyCli.exe` cold-starting a fresh Go runtime,
   and its gRPC listener coming up — routinely more than 5 seconds on a real
   machine, especially the first time. Net effect: the very first xicmp
   connection attempt after a cold start can fail with "helper process did
   not become reachable" even though the helper would have come up moments
   later.
2. **The helper self-exits after 8 minutes of no open sessions, and Windows
   does not cache "runas" approval across separate process launches** — so
   every subsequent xicmp connection after 8+ minutes of inactivity
   re-triggers a fresh UAC prompt. The code's own comment in
   `icmp_wiring.go` currently claims the helper "only elevates... the first
   time an xicmp outbound is actually dialed," which is misleading: it's
   first-time-per-idle-cycle, not first-time-ever.

## Current state

`hiddify-core/v2/hcore/icmpservice/admin_service_commander.go:36-70`
(`EnsureIcmpHelperRunning`):

```go
func EnsureIcmpHelperRunning() error {
	elevationMu.Lock()
	declined := elevationDeclined
	elevationMu.Unlock()
	if declined {
		return ErrElevationDeclined
	}

	if pingHelper() == nil {
		return nil
	}

	if err := launchHelper(); err != nil {
		if isElevationDeclined(err) {
			elevationMu.Lock()
			elevationDeclined = true
			elevationMu.Unlock()
			return ErrElevationDeclined
		}
		return fmt.Errorf("xicmp: failed to launch elevated helper: %w", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		if lastErr = pingHelper(); lastErr == nil {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("xicmp: helper process did not become reachable: %w", lastErr)
}
```

`launchHelper()` (same file, `:119-129`) fires `windows.ShellExecute(0,
"runas", ...)` (`hutils/windows_utils.go:49`), which returns as soon as the
OS accepts the elevation *request* — it does not wait for the user to
actually approve the UAC dialog or for the new process to finish starting.
All of that happens after `launchHelper()` already returned, inside the
5-second polling loop above.

`hiddify-core/v2/hcore/icmpservice/icmp_platform_service.go:26-31`:

```go
// idleTimeout is how long the helper waits with zero open sessions before exiting on its own.
// Unlike TUN (installed as a persistent Windows Service since it's commonly active for an entire
// session), xicmp is one obfuscation transport among several and likely used far less
// continuously - a lingering elevated process for a rarely-used feature is not a proportionate
// permanent footprint, so this helper prefers to just exit and be re-elevated on demand next time.
const idleTimeout = 8 * time.Minute
```

`hiddify-core/v2/hcore/icmp_wiring.go:12-19` (the comment to correct):

```go
// wireIcmpElevationOnce runs unconditionally, with no user-facing enable/disable toggle: on
// Windows, an unelevated process can't open xicmp's unprivileged ("dgram") ICMP sockets at all, so
// without this override every xicmp config simply fails outright for the overwhelming majority of
// users, who don't run the app as Administrator. There's nothing to opt into - the helper it wires
// up is itself lazy (icmpservice.EnsureIcmpHelperRunning only elevates, prompting UAC, the first
// time an xicmp outbound is actually dialed), so an unconditional wire-up has no cost for users who
// never touch xicmp.
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core && go build ./v2/hcore/icmpservice/... ./v2/hcore/...` | exit 0 |
| Vet | `cd hiddify-core && go vet ./v2/hcore/icmpservice/... ./v2/hcore/...` | exit 0 |
| Test | `cd hiddify-core && go test ./v2/hcore/icmpservice/...` | all pass, including the new test from Step 3 |

## Scope

**In scope**:
- `hiddify-core/v2/hcore/icmpservice/admin_service_commander.go` — the 5-second deadline
- `hiddify-core/v2/hcore/icmpservice/icmp_platform_service.go` — the idle timeout (Step 2 is optional, see below)
- `hiddify-core/v2/hcore/icmp_wiring.go` — the misleading comment
- A new/extended test file under `hiddify-core/v2/hcore/icmpservice/`

**Out of scope**:
- Anything under `hiddify-core/v2/hcore/tunnelservice/` — unrelated service, covered by plan 039
- `hiddify-core/hiddify-sing-box/replace/xray-core/transport/internet/finalmask/xicmp/` — the transport itself is not broken (confirmed: parses correctly, real xray-core instance starts, "outermost level" check is satisfiable) and is a vendored fork; do not touch it
- Restructuring `EnsureIcmpHelperRunning`'s control flow, retry policy, or the `elevationDeclined` caching logic — only the numeric deadline changes
- Any Dart/`lib/` change — this is entirely a Go-side timing issue

## Git workflow

- Branch: `advisor/040-xicmp-uac-timing`
- Suggested commits: (1) extend the helper-startup deadline, (2) optional idle-timeout change, (3) comment fix + test
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Extend the helper-startup deadline

In `admin_service_commander.go`, change:

```go
	deadline := time.Now().Add(5 * time.Second)
```

to:

```go
	// 45s covers UAC dialog render + a human noticing/clicking "Yes" + HiddifyCli.exe's Go
	// runtime cold-starting + its gRPC listener coming up - 5s (the previous value) routinely
	// wasn't enough for the human-reaction-time part alone, causing the first xicmp connection
	// after a cold start to fail even though the helper would come up moments later.
	deadline := time.Now().Add(45 * time.Second)
```

(45 seconds is a judgment call, not a measured value — if you have a way to
verify a more precise number against a real Windows UAC prompt, prefer that;
otherwise this value errs toward "definitely long enough" since the cost of
waiting a bit longer on a rare cold-start path is far smaller than the cost
of a confusing hard failure.)

**Verify**: `cd hiddify-core && go build ./v2/hcore/icmpservice/...` → exit 0.

### Step 2 (optional — use judgment): Reconsider the idle timeout

The 8-minute `idleTimeout` (`icmp_platform_service.go:31`) is a deliberate
footprint-vs-UX tradeoff, not an obvious bug — the existing comment's
reasoning (don't leave an elevated process running indefinitely for a
rarely-used feature) is legitimate. Re-prompting for UAC every 8 minutes of
xicmp inactivity is a real, user-visible cost on the other side of that
tradeoff, but this plan does not mandate a specific new value because the
right number depends on product judgment about typical xicmp session
patterns this repo's own docs don't state anywhere.

If you want to act on this, the lowest-risk change is raising the constant
(e.g. to `30 * time.Minute`) rather than removing the idle-exit behavior
entirely — same mechanism, just less eager. If you're not confident about
the right value, **skip this step** and only do Step 3's comment fix, which
is correct regardless of what `idleTimeout` ends up being.

**Verify (if you make this change)**: `cd hiddify-core && go build ./v2/hcore/icmpservice/...` → exit 0.

### Step 3: Fix the misleading "only elevates once" comment

In `icmp_wiring.go`, change the sentence:

```
the helper it wires
up is itself lazy (icmpservice.EnsureIcmpHelperRunning only elevates, prompting UAC, the first
time an xicmp outbound is actually dialed), so an unconditional wire-up has no cost for users who
never touch xicmp.
```

to:

```
the helper it wires
up is itself lazy (icmpservice.EnsureIcmpHelperRunning only elevates, prompting UAC, when no
already-running helper is reachable - which in practice means the first xicmp dial after a cold
start, and again after every idleTimeout-driven self-exit, see icmp_platform_service.go), so an
unconditional wire-up has no cost for users who never touch xicmp.
```

**Verify**: `grep -n "idleTimeout-driven self-exit" hiddify-core/v2/hcore/icmp_wiring.go` matches.

### Step 4: Add a test proving the deadline is what you think it is

Add a test in `hiddify-core/v2/hcore/icmpservice/admin_service_commander_test.go`
(new file, or extend an existing test file in this package if one already
exists with a suitable pattern — check first) that doesn't require a real
Windows elevation round trip (this repo's test suite doesn't do that
anywhere, per plan 020's own test-plan notes — don't be the first to try).
Instead, assert the deadline constant directly stays a build-time constant
you can reason about: if `EnsureIcmpHelperRunning`'s deadline is extracted
into a named constant (recommended, if it isn't already — e.g.
`const helperStartupTimeout = 45 * time.Second`, used in place of the
inline literal from Step 1), write:

```go
func TestHelperStartupTimeoutIsGenerouslyLong(t *testing.T) {
	if helperStartupTimeout < 30*time.Second {
		t.Fatalf("helperStartupTimeout = %v, want at least 30s to cover a human UAC click-through", helperStartupTimeout)
	}
}
```

This is a deliberately weak test (a floor check, not a behavior test) —
its only job is to fail loudly if a future edit accidentally shrinks the
timeout back down without anyone noticing, not to validate the UAC flow
itself (which needs a real Windows session, out of reach for this repo's
test suite).

**Verify**: `cd hiddify-core && go test ./v2/hcore/icmpservice/...` → all pass, including this new test.

## Test plan

- `TestHelperStartupTimeoutIsGenerouslyLong` (Step 4) — regression guard
  against the timeout silently shrinking back down.
- No test exercises the real UAC/elevation flow — same documented
  limitation as plans 019/020, this repo's test suite has no real-Windows
  interactive-elevation harness.
- Verification: `cd hiddify-core && go test ./v2/hcore/icmpservice/...` → all pass.

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/hcore/icmpservice/... ./v2/hcore/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/hcore/icmpservice/...` passes, including the new test
- [ ] `grep -n "45 \* time.Second\|helperStartupTimeout" hiddify-core/v2/hcore/icmpservice/admin_service_commander.go` matches
- [ ] `grep -n "idleTimeout-driven self-exit" hiddify-core/v2/hcore/icmp_wiring.go` matches
- [ ] `git status` (inside `hiddify-core`) shows changes only to files in Scope
- [ ] `plans/README.md` status row updated for plan 040

## STOP conditions

- The excerpts above don't match the live code — re-read before proceeding.
- You find an existing caller of `DialRemoteICMP`/`EnsureIcmpHelperRunning`
  that itself has a *shorter* timeout wrapping the call (e.g. a context
  deadline under 45s imposed by xray-core's own outbound-dial machinery) —
  if so, a 45s inner deadline would never get the chance to matter, and
  you should report this rather than silently picking a smaller number;
  this plan's investigation did not find such a wrapping timeout in
  `xicmp/client.go`'s `NewConnClient` (it calls `ListenICMP` synchronously
  with no surrounding deadline), but a caller further up the stack (e.g.
  inside xray-core's dialer) was not exhaustively audited.

## Maintenance notes

- If plan 039 (TUN elevation) lands first or concurrently, note both plans
  touch Windows UAC-elevation flows but different helper processes
  (`tunnelservice` port 18020 vs `icmpservice` port 18021) and different
  files — no overlap.
- If a future change makes xicmp's helper a persistent installed service
  (like the Tunnel service) instead of launched-on-demand, both the
  deadline and idle-timeout logic touched here become obsolete — re-derive
  from scratch rather than adapting these values.
