# Plan 025: Fix the unguarded `ipMaps` read and make it actually short-circuit the DNS lookup

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**, inside the `hiddify-core` submodule:
> `git -C hiddify-core diff --stat 8653861f1c..HEAD -- v2/config/builder.go`.
> If it changed, re-read the live `getIPs`/`ipMaps` code before proceeding;
> on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S-M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug / perf (combined — same few lines fix both)
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`hiddify-core/v2/config/builder.go:1121-1166` (`getIPs`, plus its guarding
`ipMaps`/`ipMapsMutex` package vars) has two problems in the same few lines,
both fixed by the same small change:

1. **A real data race.** `ipMapsMutex sync.Mutex` (`:1123`) exists
   specifically to guard the `ipMaps` map, and the *write* at `:1161-1163`
   correctly takes it. But the *read* two lines above, at `:1158`
   (`if len(res) == 0 && ipMaps[domains[0]] != nil`), reads the same map with
   no lock at all. `getIPs` is called from `isBlockedDomain`
   (`:1168-1189`), which is reachable from `setExperimental`
   (`:381`) — invoked on every `BuildConfig` call, i.e. every
   `StartService`/`Restart` gRPC call — so concurrent invocations (e.g. an
   app restarting the VPN while a previous config build is still finishing)
   race an unguarded read against a locked write on the same map, risking
   `fatal error: concurrent map read and map write` (a process crash, not a
   recoverable panic).
2. **The cache is only ever a fallback, never a shortcut.** Even though
   `ipMaps` exists specifically to avoid redundant work, it is populated on
   every call (`:1162`) but only *read* when the live lookup returns zero
   results (`:1158`). A successful prior resolution is never reused to skip
   the live DNS round trip — every single call to `getIPs` pays a real
   `net.DefaultResolver.LookupIP` call (bounded by a 500ms timeout,
   `:1129`) even when a fresh answer for the exact same domain was already
   cached seconds ago. Since this runs on every VPN start/restart for the
   connection-test URL's domain (which rarely changes between starts), this
   is unconditional latency the cache was seemingly built to prevent but
   doesn't.

## Current state

`hiddify-core/v2/config/builder.go:1121-1166` in full, as it exists today:

```go
var (
	ipMaps      = map[string][]string{}
	ipMapsMutex sync.Mutex
)

func getIPs(domains ...string) []string {
	var wg sync.WaitGroup
	resChan := make(chan string, len(domains)*10) // Collect both IPv4 and IPv6
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	for _, d := range domains {
		wg.Add(1)
		go func(domain string) {
			defer wg.Done()
			ips, err := net.DefaultResolver.LookupIP(ctx, "ip", domain)
			if err != nil {
				return
			}
			for _, ip := range ips {
				ipStr := ip.String()
				if !isBlockedIP(ipStr) {
					resChan <- ipStr
				}
			}
		}(d)
	}

	go func() {
		wg.Wait()
		close(resChan)
	}()

	var res []string
	for ip := range resChan {
		res = append(res, ip)
	}
	if len(res) == 0 && ipMaps[domains[0]] != nil {
		return ipMaps[domains[0]]
	}
	ipMapsMutex.Lock()
	ipMaps[domains[0]] = res
	ipMapsMutex.Unlock()

	return res
}

func isBlockedDomain(domain string) bool {
	if strings.HasPrefix("full:", domain) {
		return false
	}
	if strings.Contains(domain, "instagram") || strings.Contains(domain, "facebook") || strings.Contains(domain, "telegram") || strings.Contains(domain, "t.me") {
		return true
	}
	ips := getIPs(domain)
	if len(ips) == 0 {
		return true
	}
	return false
}
```

`isBlockedDomain` is called from `isBlockedConnectionTestUrl`
(`:364-379` — read it yourself to confirm), which `setExperimental`
(`:381`) calls; `setExperimental` runs as part of every `BuildConfig`, which
runs on every `StartService`/`Restart` (confirmed via
`hiddify-core/v2/hcore/buildconfighelper.go:28-44`, `BuildConfig` calling
`config.BuildConfig`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Go build | `cd hiddify-core && go build ./v2/config/...` | exit 0 |
| Go vet | `cd hiddify-core && go vet ./v2/config/...` | exit 0 |
| Go tests | `cd hiddify-core && go test ./v2/config/...` | all pass |

## Scope

**In scope**:
- `hiddify-core/v2/config/builder.go` (only the `ipMaps`/`ipMapsMutex`
  package vars and the `getIPs` function — lines ~1121-1166)

**Out of scope**:
- `isBlockedDomain`/`isBlockedConnectionTestUrl`/`setExperimental` — callers,
  unchanged by this plan (their behavior toward callers is identical: same
  return values, just faster on a cache hit and race-free).
- `isBlockedIP` (`:1191-1196`) — unrelated helper, do not touch.
- Any change to the 500ms lookup timeout — out of scope; this plan is about
  reusing a cached answer to *avoid* the lookup, not about changing the
  lookup itself.

## Git workflow

- Branch: `advisor/025-ipmaps-race-and-cache-shortcircuit`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Lock the ipMaps read and check it before the live DNS lookup`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Check the cache first, under the lock, before doing a live lookup

Restructure `getIPs` so a cache hit skips the network round trip entirely,
and every access to `ipMaps` (read and write) goes through the same lock:

```go
func getIPs(domains ...string) []string {
	if len(domains) == 0 {
		return nil
	}

	ipMapsMutex.Lock()
	if cached, ok := ipMaps[domains[0]]; ok {
		ipMapsMutex.Unlock()
		return cached
	}
	ipMapsMutex.Unlock()

	var wg sync.WaitGroup
	resChan := make(chan string, len(domains)*10) // Collect both IPv4 and IPv6
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	for _, d := range domains {
		wg.Add(1)
		go func(domain string) {
			defer wg.Done()
			ips, err := net.DefaultResolver.LookupIP(ctx, "ip", domain)
			if err != nil {
				return
			}
			for _, ip := range ips {
				ipStr := ip.String()
				if !isBlockedIP(ipStr) {
					resChan <- ipStr
				}
			}
		}(d)
	}

	go func() {
		wg.Wait()
		close(resChan)
	}()

	var res []string
	for ip := range resChan {
		res = append(res, ip)
	}

	if len(res) > 0 {
		ipMapsMutex.Lock()
		ipMaps[domains[0]] = res
		ipMapsMutex.Unlock()
	}

	return res
}
```

Notes on the behavior change, deliberate and worth stating in your commit
message:
- A cache hit now **always** short-circuits (no TTL/expiry) — this trades
  freshness for speed on the assumption the connection-test/ad-block domains
  this guards rarely change IP within a single app process's lifetime (the
  cache is in-memory only, cleared on restart). This matches the finding's
  own suggested fix. `// ponytail: no TTL — the cache is process-lifetime
  only and this domain rarely changes; add a TTL if staleness becomes a
  reported problem` is a reasonable comment to leave at the cache-hit check.
- A **failed** lookup (`len(res) == 0`) no longer falls back to a stale
  cached value the way the old code did (the old code's fallback-to-cache
  branch only fired when `len(res) == 0`, i.e. on failure) — because now a
  cache hit is checked *first* and unconditionally returned, the old
  "fall back to cache on failure" branch is subsumed: if there was a cache
  entry, it would already have been returned before attempting the live
  lookup at all. A failed lookup with **no** prior cache entry still
  correctly returns `nil`/empty, same as before.

**Verify**: `cd hiddify-core && go build ./v2/config/...` → exit 0.
`grep -n "ipMapsMutex.Lock()" v2/config/builder.go` shows it taken at both
the read (top of function) and write (bottom), and
`grep -n "ipMaps\[domains\[0\]\]" v2/config/builder.go` shows no access
outside a locked section.

### Step 2: Test the cache short-circuit and the race fix

Add a test in `hiddify-core/v2/config/` (extend the existing
`parser_test.go` or create `builder_test.go`) that:
- Calls `getIPs` for a domain, manually seeds `ipMaps` with a known fake
  entry beforehand (same package, so this is a direct map write in the test
  under `ipMapsMutex`), and asserts `getIPs` returns the seeded value
  **without** attempting a real DNS lookup (verifiable by using a domain
  that would fail to resolve, e.g. `"this-domain-does-not-exist.invalid"` —
  if the seeded cache value comes back instead of an empty result, the
  short-circuit worked).
- If the Go race detector is available: run
  `go test -race ./v2/config/... -run TestGetIPs` (or whatever name you give
  the test) with two goroutines calling `getIPs` concurrently for the same
  domain, confirming no race is reported.

**Verify**: `cd hiddify-core && go test ./v2/config/...` → all pass,
including the new test.

## Test plan

- New test (see Step 2) proving: (a) a cache hit returns the cached value
  without a live lookup, (b) concurrent calls don't race (via `-race` where
  available).
- Model the test file's structure after the existing
  `hiddify-core/v2/config/parser_test.go` (table-driven where it makes
  sense, `package config`, standard `testing` + whatever assertion style
  that file already uses).
- Verification: `go test ./v2/config/...` → all pass.

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/config/...` exits 0
- [ ] `cd hiddify-core && go vet ./v2/config/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/config/...` passes, including the new test
- [ ] `grep -n "ipMapsMutex.Lock()" v2/config/builder.go` shows the read is now inside a locked section
- [ ] `git status` shows changes only to `v2/config/builder.go`, a new/extended test file, and `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- The code at `builder.go:1121-1166` doesn't match the excerpt above (drift
  since this plan was written) — re-read the live function and re-derive the
  fix against what's actually there.
- You find another caller of `getIPs` that depends on it re-resolving fresh
  IPs on every call (i.e. relies on the old no-short-circuit behavior) —
  report it rather than silently breaking that caller's assumption; per the
  evidence gathered for this plan, `isBlockedDomain` is the only caller, but
  re-confirm with `grep -rn "getIPs(" v2/config/*.go` before proceeding.
- Any existing test starts failing after this change in a way not explained
  by "a domain now resolves from cache instead of a live lookup" —
  investigate before assuming it's unrelated.

## Maintenance notes

- If domain-IP staleness ever becomes a real reported problem (e.g. a CDN
  domain's IP rotates and blocking decisions become wrong for the rest of a
  long-running process), the fix is a TTL on the cache entry (store a
  timestamp alongside the IPs, re-resolve if older than some threshold) —
  intentionally not built here since there's no evidence it's needed yet
  (see the `ponytail:` comment left in the code).
- This cache is process-lifetime only (an in-memory map, never persisted) —
  a fresh app launch always starts with an empty cache and pays the first
  lookup's cost, same as before this plan.
