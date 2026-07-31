# Plan 031: Remove the live network dependency from profile tests, add repository unit tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. This plan is primarily TEST-ONLY (see Scope for
> the one exception). When done, update the status row for this plan in
> `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 8653861f1c6b87f4833e4bc3182af4b32c53b711..HEAD -- v2/profile/profile_repository.go v2/profile/test/profile_test.go`.
> If either changed, re-read the live functions before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S-M
- **Risk**: LOW (test-only; the download-path change in Step 1 only affects test behavior, not `profile_repository.go` itself)
- **Depends on**: none
- **Category**: tests
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`hiddify-core/v2/profile/test/profile_test.go` is the **only** test in the
`profile` package (`profile_repository.go` is 348 lines,
`profile_parser.go` 181 lines, both otherwise untested). Its one test,
`TestAddByContent`, makes a real HTTPS request to a hardcoded GitHub raw-content
URL (confirmed by reading the file directly — see Current state) and asserts
on the parsed result. This is a classic flaky-test pattern: it fails on any
network hiccup in CI, and silently breaks forever if that exact file on
GitHub's `main` branch ever moves, is renamed, or its content changes for an
unrelated reason — independent of whether `profile` package code is
correct. Meanwhile core CRUD operations this package exposes
(`GetByUrl`/`GetByName`, `DeleteById`, `SetActiveProfile`/`GetActiveProfile`)
have zero coverage of their own, happy path or otherwise.

## Current state

Read directly from the live files:

**`TestAddByContent`** (`v2/profile/test/profile_test.go`, in full) calls
`profile.AddByUrl(ctx, "https://raw.githubusercontent.com/hiddify/hiddify-next/refs/heads/main/test.configs/warp", "", false)`
and asserts on the parsed `entity.Name`, `entity.SubInfo.{Upload,Download,Total,Expire}`,
`entity.SubInfo.SupportUrl`, `entity.SubInfo.WebPageUrl` — cleans up with
`profile.DeleteById(entity.Id)` at the end.

**`AddByUrl`** (`profile_repository.go:203-238`) calls
`downloadProfileContent(ctx, url)` (`:213`), which is more involved than a
plain HTTP GET — read `downloadProfileContent` (`profile_repository.go:245-270+`)
directly: it first tries the request through a local SOCKS proxy
(`SocksPort: 12334`, 5s timeout), and **only if that returns `nil`** falls
back to a plain request (no proxy, 5s timeout), and **only if that also
returns `nil`** spins up a real sing-box instance and pings Cloudflare before
retrying again. In a typical test environment nothing is listening on port
12334, so the first attempt should fail fast and fall through to the plain
request — but this means swapping the URL to a local `httptest.Server` still
exercises this fallback chain's first (SOCKS) attempt before succeeding on
the second (plain) attempt. **This is expected, not a bug** — don't try to
bypass the SOCKS attempt; just be aware the test may take a moment (bounded
by whatever a fast-failing local connection attempt costs, likely
well under the 5s timeout since nothing is listening) rather than being
instant.

**Other repository functions with zero test coverage** — verified by reading
`profile_repository.go` directly:
- `GetByName(name string)` (`:179-189`) — linear scan over `table.All()`.
- `GetByUrl(ctx, url string)` (`:191-201`) — same linear-scan shape.
- `DeleteById(id string)` (`:339-`, read the full function before writing
  its test — confirm its exact behavior on a nonexistent ID).
- `SetActiveProfile`/`GetActiveProfile` (`:149-168`) — round-trip through
  `db.GetTable[hcommon.AppSettings]()`.

All of these go through the same `db.GetTable[...]()` LevelDB-backed table
API that `TestAddByContent` already successfully exercises today (its
`profile.DeleteById(entity.Id)` cleanup call proves DB access already works
in whatever environment runs this test suite) — so no new test-database
setup is needed; follow the exact same pattern the existing test already
uses successfully.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Run the profile package tests | `cd hiddify-core && go test ./v2/profile/... -v` | all pass, no network access required |

Note: scope to `./v2/profile/...` — a prior audit pass found the
`hiddify-core` root doesn't always resolve standalone (nested submodules
under `hiddify-sing-box/replace/` may not be checked out). If even the
scoped command fails to resolve, report the exact error.

## Scope

**In scope**:
- `hiddify-core/v2/profile/test/profile_test.go` (modify — remove the live
  URL dependency, add new test functions)

**Out of scope**:
- `profile_repository.go` — no production code changes. If a new test
  reveals what looks like an actual bug in one of the untested functions, do
  NOT fix it — report it in your final summary as a candidate finding
  instead, and write the test to characterize the *actual* current behavior.
- `downloadProfileContent`'s SOCKS-then-plain-then-run-instance fallback
  chain — do not simplify or change it; this plan only changes what URL the
  existing test points at.
- `profile_parser.go` — separate file, separate coverage gap, not part of
  this plan.

## Git workflow

- Branch: `advisor/031-profile-repository-tests`
- One commit.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the live GitHub URL with a local `httptest.Server`

Change `TestAddByContent` to serve the same content locally instead of
fetching it from GitHub. First, capture the current live content as an
inline fixture — before making this change, fetch the current content once
(e.g. `curl -s https://raw.githubusercontent.com/hiddify/hiddify-next/refs/heads/main/test.configs/warp`)
and embed it as a Go raw string constant, so the test no longer depends on
that URL continuing to exist or serve unchanged content. Then serve it via
`httptest.Server`:

```go
package test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/hiddify/hiddify-core/v2/profile"
	"github.com/sagernet/sing-box/experimental/libbox"
)

// fixtureWarpProfile is a frozen snapshot of the WARP test config this suite has always used
// (previously fetched live from GitHub on every test run - see plans/031 for why that changed).
const fixtureWarpProfile = `` /* paste the fetched content here verbatim */

func TestAddByContent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(fixtureWarpProfile))
	}))
	defer server.Close()

	ctx := libbox.BaseContext(nil)
	entity, err := profile.AddByUrl(ctx, server.URL, "", false)
	if err != nil {
		t.Fatalf("expected no error, but got: %v", err)
	}
	defer profile.DeleteById(entity.Id)

	// ... existing assertions on entity.Name, entity.SubInfo.*, unchanged ...
}
```

Keep every existing assertion in the test body exactly as it is — only the
URL source changes, not what's expected of the parsed result (the fixture is
a byte-for-byte snapshot of what GitHub was serving, so the same assertions
must still hold).

**If the fetched content differs from what the existing assertions expect**
(e.g. GitHub's file has already changed since this plan was written): use
the *fetched* content as source of truth for the fixture, and update the
assertions to match reality — note this discrepancy explicitly in your final
report, since it means the existing test may have already been silently
testing against stale expectations.

**Verify**: `cd hiddify-core && go test ./v2/profile/... -run TestAddByContent -v` →
passes, without any network access (verify by running once with network
disabled/disconnected if you can, to prove the dependency is really gone).

### Step 2: Add tests for `GetByName`/`GetByUrl`

Append to the same file (or a new `profile_repository_test.go` in the same
package if you prefer splitting it — either is fine):

```go
func TestGetByName_And_GetByUrl(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(fixtureWarpProfile))
	}))
	defer server.Close()

	ctx := libbox.BaseContext(nil)
	entity, err := profile.AddByUrl(ctx, server.URL, "", false)
	if err != nil {
		t.Fatalf("AddByUrl failed: %v", err)
	}
	defer profile.DeleteById(entity.Id)

	t.Run("GetByUrl finds the profile by its exact URL", func(t *testing.T) {
		found, err := profile.GetByUrl(ctx, server.URL)
		if err != nil {
			t.Fatalf("GetByUrl failed: %v", err)
		}
		if found.Id != entity.Id {
			t.Errorf("GetByUrl returned id %q, want %q", found.Id, entity.Id)
		}
	})

	t.Run("GetByName finds the profile by its parsed name", func(t *testing.T) {
		found, err := profile.GetByName(entity.Name)
		if err != nil {
			t.Fatalf("GetByName failed: %v", err)
		}
		if found.Id != entity.Id {
			t.Errorf("GetByName returned id %q, want %q", found.Id, entity.Id)
		}
	})

	t.Run("GetByUrl returns an error for an unknown URL", func(t *testing.T) {
		_, err := profile.GetByUrl(ctx, "https://example.invalid/does-not-exist")
		if err == nil {
			t.Error("expected an error for a URL with no matching profile")
		}
	})
}
```

**Verify**: `cd hiddify-core && go test ./v2/profile/... -run TestGetByName_And_GetByUrl -v` →
all subtests pass.

### Step 3: Add a test for `DeleteById` on a nonexistent ID

First read `DeleteById`'s full body (`profile_repository.go:339-`) to confirm
its actual behavior when the ID doesn't exist (does it return an error, or
silently succeed?) — write the test to assert whatever it actually does,
don't guess:

```go
func TestDeleteById_NonexistentId(t *testing.T) {
	err := profile.DeleteById("this-id-does-not-exist")
	// Adjust this assertion to match DeleteById's actual documented/observed
	// behavior for a missing ID once you've read the function - it may return
	// an error, or it may be a no-op. Whichever it is, assert it explicitly
	// rather than leaving this test not asserting anything.
	_ = err
}
```

**Verify**: `cd hiddify-core && go test ./v2/profile/... -run TestDeleteById_NonexistentId -v` → passes.

### Step 4: Run the full package suite

**Verify**: `cd hiddify-core && go test ./v2/profile/...` → all pass, and
confirm no test in this package makes a network call anymore (`grep -rn "raw.githubusercontent.com\|http://\|https://" v2/profile/test/*.go` should show only `server.URL`-based usage and the frozen fixture constant, no external URLs — check the fixture content itself doesn't accidentally contain a URL that a naive grep would flag as a false positive, and use judgment).

## Test plan

This plan's entire content is the test change:
- `TestAddByContent` (modified: local `httptest.Server` instead of a live
  GitHub URL, same assertions)
- `TestGetByName_And_GetByUrl` (new: 3 subtests — found by URL, found by
  name, error on unknown URL)
- `TestDeleteById_NonexistentId` (new: 1 test, asserting whatever
  `DeleteById`'s actual behavior is for a missing ID)

Verification: `cd hiddify-core && go test ./v2/profile/...` → all pass, with
no network dependency.

## Done criteria

- [ ] `TestAddByContent` no longer references `raw.githubusercontent.com` or any live URL
- [ ] `cd hiddify-core && go test ./v2/profile/...` exits 0, all tests pass
- [ ] The full suite passes with network access disabled (confirmed manually, or noted if not possible to verify in this environment)
- [ ] `git status` (in the `hiddify-core` submodule) shows changes only to the test file(s) touched
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any function cited in "Current state" doesn't match its excerpt (drift
  since this plan was written) — re-read the live function before writing
  its test.
- The content currently served by the GitHub URL differs from what the
  existing assertions expect — use the actual fetched content as truth,
  update assertions to match, and report this discrepancy prominently (it
  means the existing test may already have been silently wrong, or GitHub's
  file changed).
- `DeleteById` on a nonexistent ID does something surprising (panics,
  corrupts other entries) — report it as a finding rather than writing a
  test that silently accepts broken behavior as "passing."
- A new test reveals an actual bug in `GetByName`/`GetByUrl`/etc. — do not
  fix `profile_repository.go`; report it and write the test to characterize
  current (buggy) behavior, flagged with a comment.

## Maintenance notes

- The frozen fixture (`fixtureWarpProfile`) will drift from whatever GitHub
  currently serves over time — that's the intended trade-off (a stable test
  vs. a live, moving target). If the real subscription-format ever changes
  in a way this fixture no longer represents, a maintainer should refresh
  the fixture deliberately, not have it silently re-diverge from a live URL.
- `SetActiveProfile`/`GetActiveProfile`/`UpdateProfile` remain untested after
  this plan — a reasonable next slice for a follow-up, using the same
  `httptest.Server` + `db.GetTable` pattern established here.
