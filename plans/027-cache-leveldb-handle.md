# Plan 027: Stop opening and closing a LevelDB handle on every single table access

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. This plan touches the retry/lock-fallback logic
> that protects against concurrent-process contention on the same database
> file — read "Why this matters" and "Current state" fully before writing
> any code, and follow the STOP conditions precisely; a naive "just cache a
> handle" change can silently drop that protection. When done, update the
> status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `cd hiddify-core && git diff --stat 8653861f1c..HEAD -- v2/db/hiddify_db.go v2/hcore/commands.go v2/profile/profile_repository.go`
> If any changed since this plan was written, re-read the live code before
> proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED — changes how every DB-backed RPC opens its storage handle;
  a mistake here affects every table, every read and write
- **Depends on**: none
- **Category**: perf
- **Planned at**: `hiddify-core` submodule commit `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`, 2026-07-29

## Why this matters

Every single call to `Table[T].Get`/`.All`/`.UpdateInsert`/`.Delete`
(`hiddify-core/v2/db/hiddify_db.go:118-219`) independently opens a fresh
LevelDB handle via `getDB` and closes it again with `defer db.Close()` —
there is no caching or connection pooling at all; a table is opened and shut
down for every individual operation. `getDB` (`:17-45`) itself has a retry
loop of up to 100 attempts × 50ms sleep (up to 5 seconds) when the open call
fails, which exists to tolerate the database being momentarily locked by
another opener.

This has a real, verified cost on the hottest path in the app: the
`GetSystemInfoStream` RPC's 1-second ticker (`hiddify-core/v2/hcore/commands.go:104-131`)
calls `readStatus` every tick, and `readStatus` (`:62-70`) opens/closes a
fresh `hcommon.AppSettings` table handle on every tick where
`prev == nil || prev.CurrentProfile == "" || message.UplinkTotal < 1000000`
— i.e., for every tick during the early part of a session, before ~1MB of
uplink traffic has passed. Under any concurrent DB contention (e.g. a
profile save happening at the same moment), that single per-tick open call
can stall for the full retry window instead of returning already-known
state. Separately, `AddByUrl` (`hiddify-core/v2/profile/profile_repository.go:203-241`)
opens/closes the DB three separate times in one gRPC call: once inside
`GetByUrl` (`:191-201`, itself calling `db.GetTable[ProfileEntity]()` then
`.All()`), once for `table.UpdateInsert(newProfile)` (`:233-236`), and once
more inside `SetActiveProfile` (`:239`, which itself opens the
`hcommon.AppSettings` table via `db.GetTable[...]().UpdateInsert(...)` per
`:162-168`) — three independent open/retry/close cycles for what is
logically one request.

## Current state

`hiddify-core/v2/db/hiddify_db.go` in the relevant parts, as it exists today:

```go
// getDB initializes the database with retry logic. If it fails after 100 attempts, it returns nil.
func getDB(name string, readOnly bool) (tmdb.DB, error) {
	// Check if the database file exists; if not, set to readOnly
	dbPath := "data/" + name + ".db"
	if _, err := os.Stat(dbPath); os.IsNotExist(err) {
		readOnly = false
	}
	const retryAttempts = 100
	const retryDelay = 50 * time.Millisecond

	var db tmdb.DB
	var err error
	defer func() {
		if r := recover(); r != nil {
			log.Printf("Recovered from panic: %v", r)
		}
	}()
	for i := 0; i < retryAttempts; i++ {
		// Set readOnly to true for the first 80 attempts
		opts := &opt.Options{ReadOnly: readOnly && i < 80}

		db, err = tmdb.NewGoLevelDBWithOpts(name, "./data", opts)
		if err == nil {
			return db, nil
		}
		log.Printf("Failed attempt %d to initialize the database: %v", i, err)
		time.Sleep(retryDelay)
	}
	return nil, err
}
```

Note the subtlety in the retry loop: for the first 80 attempts, a "read"
call (`readOnly=true`) opens with LevelDB's actual `ReadOnly` option set;
for the last 20 attempts (`i >= 80`), it drops to `ReadOnly: false` even for
a nominal read call. This looks like a deliberate last-resort "force it open
even if that means taking a write lock" fallback — **this plan must preserve
that fallback behavior for whatever the first real open of a table is**, it
must not be silently dropped just because open calls become rarer.

`Table[T].Get` today (`:207-219`, representative of all four methods —
`All`, `UpdateInsert`, and `Delete` follow the identical
open-with-getDB/defer-Close shape):

```go
func (tbl *Table[T]) Get(id any) (*T, error) {
	db, err := getDB(tbl.name, true)
	if db == nil {
		return nil, fmt.Errorf("failed to open database %s, error: %w", tbl.name, err)
	}
	defer db.Close()

	b, err := db.Get(getIdBytes(id))
	if err != nil {
		return nil, err
	}
	return Deserialize[T](b)
}
```

`readStatus`'s per-tick DB access (`hiddify-core/v2/hcore/commands.go:62-70`):

```go
		if prev == nil || prev.CurrentProfile == "" || message.UplinkTotal < 1000000 {
			settings := db.GetTable[hcommon.AppSettings]()
			lastName, err := settings.Get("lastStartRequestName")
			if err == nil {
				message.CurrentProfile = lastName.Value.(string)
			}
		} else {
			message.CurrentProfile = prev.CurrentProfile
		}
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd hiddify-core && go build ./v2/...` | exit 0 |
| Vet | `cd hiddify-core && go vet ./v2/...` | exit 0 |
| Tests | `cd hiddify-core && go test ./v2/db/... ./v2/hcore/... ./v2/profile/...` | all pass |

## Scope

**In scope**:
- `hiddify-core/v2/db/hiddify_db.go` (the caching change itself)

**Out of scope**:
- `hiddify-core/v2/hcore/commands.go`, `hiddify-core/v2/profile/profile_repository.go` —
  no caller needs to change; the whole point of caching inside `getDB`/
  `Table[T]` is that every existing call site benefits automatically without
  being touched. Do not "optimize" `AddByUrl`'s 3 separate calls by merging
  them into one transaction — that's a different, larger change (would need
  a real multi-operation transaction API this package doesn't currently
  expose) and not required once the underlying handle is cached.
- Changing LevelDB to a different storage engine — out of scope, this is a
  caching fix, not a migration.
- Removing the retry/backoff logic in `getDB` — it must still run on the
  *first* open of each table (see STOP conditions); this plan only stops
  re-running it on *every subsequent* access to an already-open table.

## Git workflow

- Branch: `advisor/027-cache-leveldb-handle`
- One commit, or a few small logical commits (e.g. one for the cache
  structure, one for wiring all four methods through it).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a process-wide cache of open handles, keyed by table name

In `hiddify-core/v2/db/hiddify_db.go`, add a package-level cache and a
wrapper that opens-or-reuses:

```go
var (
	dbHandles   = map[string]tmdb.DB{}
	dbHandlesMu sync.Mutex
)

// getOrOpenDB returns a cached handle for name, opening it (with getDB's
// existing retry/fallback logic) only the first time or after a prior
// handle failed. All access is read-write; a single process-owned handle
// serves both reads and writes safely since tm-db serializes access
// internally — the readOnly distinction getDB still supports is only
// exercised on this first-open path, matching its original fallback
// behavior for external lock contention.
func getOrOpenDB(name string) (tmdb.DB, error) {
	dbHandlesMu.Lock()
	defer dbHandlesMu.Unlock()

	if db, ok := dbHandles[name]; ok {
		return db, nil
	}

	db, err := getDB(name, false)
	if err != nil {
		return nil, err
	}
	dbHandles[name] = db
	return db, nil
}
```

Add `"sync"` to the file's imports.

**Verify**: `cd hiddify-core && go build ./v2/db/...` → exit 0 (this step
alone doesn't wire anything through yet, so nothing should change
behaviorally — this just confirms the new code compiles in isolation).

### Step 2: Route all four `Table[T]` methods through the cache, and stop closing per-call

Change `Get`, `All`, `UpdateInsert`, and `Delete` to call `getOrOpenDB`
instead of `getDB`, and remove the `defer db.Close()` in each (the handle is
now owned by the cache, not by the individual call):

```go
func (tbl *Table[T]) Get(id any) (*T, error) {
	db, err := getOrOpenDB(tbl.name)
	if db == nil {
		return nil, fmt.Errorf("failed to open database %s, error: %w", tbl.name, err)
	}

	b, err := db.Get(getIdBytes(id))
	if err != nil {
		return nil, err
	}
	return Deserialize[T](b)
}
```

Apply the same shape to `All`, `UpdateInsert`, `Delete` — replace their
`getDB(tbl.name, <bool>)` + `defer db.Close()` pair with
`getOrOpenDB(tbl.name)` and no `Close()`.

**If an operation fails after this change** (e.g. `db.Get`/`db.Set`
returns an error that looks like a stale/broken handle, not just "key not
found"): consider whether `getOrOpenDB` should evict the cached handle on
certain error classes so a future call re-opens rather than reusing a
possibly-broken handle. Only add that eviction if you can identify a
specific error condition from `tm-db`'s API that indicates the handle itself
(not just the requested key) is bad — don't add speculative retry logic for
errors you can't characterize.

**Verify**: `cd hiddify-core && go build ./v2/... && go vet ./v2/...` → both
exit 0. `grep -c "defer db.Close()" v2/db/hiddify_db.go` returns `0`.
`grep -c "getOrOpenDB(tbl.name)" v2/db/hiddify_db.go` returns `4` (one per
method).

### Step 3: Confirm the retry/fallback behavior is preserved for the first open

Re-read the final `getOrOpenDB` + `getDB` pairing and confirm: the first
call for any given table name still goes through `getDB`'s full retry loop
(100 attempts, 50ms delay, `ReadOnly` dropped after 80 attempts) exactly as
before — only *subsequent* calls for that same table name skip straight to
the cached handle. This is a read-through-code check, not a command; state
in your final report that you've confirmed this explicitly.

### Step 4: Run the test suite

**Verify**: `cd hiddify-core && go test ./v2/db/... ./v2/hcore/... ./v2/profile/...`
→ all pass.

## Test plan

- Add a test in `hiddify-core/v2/db/` (new file, e.g. `hiddify_db_test.go`,
  if one doesn't already exist) asserting: (a) two sequential `Get` calls on
  the same table name return a handle from the cache the second time (you
  can test this indirectly by writing a value with `UpdateInsert`, then
  reading it back with `Get` in a separate call, and confirming the read
  succeeds — this exercises the shared-handle path since a naive
  open-close-per-call implementation would also pass this, but the point is
  a regression test that basic read/write still works correctly after the
  caching change); (b) a `Delete` followed by a `Get` on the same key
  correctly returns "not found", proving writes and reads through the
  shared handle stay consistent with each other.
- Model the test's setup/teardown (temp directory, cleanup) after whatever
  pattern this repo's existing Go tests use for filesystem-backed state —
  check `v2/hcore/start_test.go` first.
- Verification: `cd hiddify-core && go test ./v2/db/...` → all pass,
  including the new test(s).

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/...` exits 0
- [ ] `cd hiddify-core && go vet ./v2/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/db/... ./v2/hcore/... ./v2/profile/...` passes
- [ ] `grep -c "defer db.Close()" v2/db/hiddify_db.go` returns `0`
- [ ] `grep -c "getOrOpenDB(tbl.name)" v2/db/hiddify_db.go` returns `4`
- [ ] Your final report explicitly confirms the first-open retry/fallback behavior (Step 3) was verified, not assumed
- [ ] `git status` (inside `hiddify-core/`) shows changes only to `v2/db/hiddify_db.go` and the new test file
- [ ] `plans/README.md` (Dart repo root) status row for plan 027 updated

## STOP conditions

- `getDB`/`Table[T]`'s methods don't match the excerpts above (drift since
  this plan was written) — re-read the live file; the retry/readOnly
  fallback logic is exactly the part that must not be silently lost, so
  confirm its current shape carefully before changing anything around it.
- You find evidence that two separate OS processes (not just goroutines
  within one process) can legitimately hold open the same table's LevelDB
  file concurrently in normal operation (e.g. a CLI tool, a second core
  instance, or an elevated helper process each independently calling
  `db.GetTable[...]`) — if so, a single process-wide cached handle per
  table name is still correct (each process gets its own cache; the
  contention this fixes is *within* one process's repeated open/close, not
  across processes), but confirm this understanding explicitly in your
  final report rather than assuming it, since if it's wrong, caching a
  write-locked handle across an unexpected concurrent opener could turn
  today's *slow* contention into a *hard failure*.
- Any test starts failing after this change in a way not explained by "a
  handle is now shared instead of freshly opened" — investigate before
  assuming it's unrelated; this is exactly the kind of change where a subtle
  behavior difference (e.g. LevelDB iterator semantics on a long-lived vs.
  freshly-opened handle) could surface as a flaky or incorrect test.

## Maintenance notes

- If a future need arises to explicitly close/reopen a table's handle (e.g.
  for a backup/restore flow that needs exclusive access), add a
  `closeTable(name string)` helper that removes it from `dbHandles` under
  the same mutex, rather than reaching back into `Table[T]` for a one-off
  `Close()` call.
- This cache is process-lifetime — handles are never explicitly closed on
  normal shutdown. If the process exits cleanly today without calling
  `db.Close()` on anything (check whether it did before this change — if
  the old code's `defer db.Close()` only ever ran per-call, the previous
  behavior already left no table open across requests, so there's no
  "graceful shutdown" regression to worry about), this is a behavior-neutral
  change in that respect; if there is graceful-shutdown code elsewhere that
  assumed no live DB handles persist between calls, that assumption is now
  invalid and should be revisited.
