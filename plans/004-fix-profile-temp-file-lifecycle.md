# Plan 004: Actually delete the profile temp files that hold subscription credentials

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c99aed7f..HEAD -- lib/features/profile/data/profile_repository.dart lib/features/profile/data/profile_parser.dart`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-restore-verification-baseline.md` (this plan
  changes file lifetimes with no existing coverage; a trustworthy `flutter test`
  is the minimum safety net)
- **Category**: security
- **Planned at**: commit `c99aed7f`, 2026-07-28

## Why this matters

Every time a profile is added or a subscription refreshes, this app writes the
raw subscription response — the credential-bearing document that identifies the
user's provider and grants access to it — to a temp file next to the live
profiles. The cleanup that is supposed to delete it is written in a way that
runs *before* the download it guards, so it never deletes anything.

Two consequences. First, unencrypted copies of the subscription accumulate
forever, one per add plus one per refresh (refresh runs every 15 minutes).
Second — and worse for this user base — deleting a profile removes only
`<id>.json`, so the temp copies survive the one operation a user in a hostile
environment actually relies on.

There is a correct implementation of this exact pattern a few lines away in the
same file (`addLocal`), so the fix is to make two methods match a sibling that
already works.

## Current state

Files involved:

- `lib/features/profile/data/profile_repository.dart` — `upsertRemote` and
  `offlineUpdate` have the broken cleanup; `addLocal` has the correct one.
- `lib/features/profile/data/profile_parser.dart` — `expandRemoteLinesInParallel`
  writes per-line sidecar files that nothing ever deletes.
- `lib/features/profile/data/profile_path_resolver.dart` — resolves both the
  live profile path and the temp path (same `configs/` directory).

**The bug.** `profile_repository.dart:136-185`, abridged to show the shape:

```dart
        final tempFile = _profilePathResolver.tempFile(id);
        try {
          if (profEntity != null && profEntity is RemoteProfileEntity) {
            // Update
            ...
            return _profileParser
                .updateRemote(rp: profEntity, tempFilePath: tempFile.path, cancelToken: cancelToken)
                .flatMap( ... );
          } else {
            // Add
            return _profileParser
                .addRemote( ... )
                .flatMap( ... );
          }
        } finally {
          if (tempFile.existsSync()) tempFile.deleteSync();
        }
```

`_profileParser.updateRemote(...)` returns a **`TaskEither` — a lazy
description of work, not the work itself.** The `try` block only *builds* that
object and returns it. So `finally` executes at return time, before any
download has happened and while `tempFile` does not yet exist. The file the
download subsequently writes is never removed.

`offlineUpdate` (`:229-257`) repeats the identical pattern.

**The correct pattern, in the same file.** `addLocal` at `:189-215` — note
`await task.run()` happens *inside* the `try`, so its `finally` genuinely fires
after the work:

```dart
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride}) =>
      TaskEither.tryCatch(() async {
        final id = const Uuid().v4();
        final file = _profilePathResolver.file(id);
        final tempFile = _profilePathResolver.tempFile(id);
        try {
          await tempFile.writeAsString(content);
          final task = _profileParser
              .addLocal(id: id, content: content, tempFilePath: tempFile.path, userOverride: userOverride)
              .flatMap( ... );
          return (await task.run()).getOrElse((l) => throw l);
        } finally {
          if (tempFile.existsSync()) tempFile.deleteSync();
        }
      }, ProfileFailure.unexpected);
```

The key line is `return (await task.run()).getOrElse((l) => throw l);` — it
forces execution inside the `try`, and converts a `Left` into a throw that the
enclosing `TaskEither.tryCatch` turns back into a `Left`.

**The sidecar leak.** `profile_parser.dart:213-226`, inside
`expandRemoteLinesInParallel`'s worker:

```dart
        try {
          final tmpPath = '$tempFilePath.$currentIndex';

          await httpClient.download(
            line,
            tmpPath,
            cancelToken: cancelToken,
            userAgent: ...,
          );

          results[currentIndex] = (await File(tmpPath).readAsString()).trim();
        } catch (err) {
```

`tmpPath` is written once per remote line inside a subscription and is never
deleted on any path.

Repo conventions to match:
- Error handling is fpdart: repositories return
  `TaskEither<ProfileFailure, T>`; `ProfileFailure.unexpected` is the standard
  catch-all mapper.
- Tests: `package:flutter_test/flutter_test.dart`, `group`/`test("Should ...")`,
  double-quoted strings. See `test/features/profile/data/profile_parser_test.dart:1-13`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps | `flutter pub get` | exit 0 |
| Codegen | `make gen` | exit 0 |
| Tests | `flutter test` | all pass |
| Analyze | `flutter analyze lib/features/profile` | no new errors |

## Scope

**In scope** (the only files you should modify):
- `lib/features/profile/data/profile_repository.dart`
- `lib/features/profile/data/profile_parser.dart`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `lib/features/profile/data/profile_path_resolver.dart` — where temp files
  live is a separate decision. Moving them to an OS temp dir is a reasonable
  follow-up but changes uninstall/backup semantics; not here.
- `addLocal` — it is already correct and is the reference implementation.
  Changing it would remove the exemplar.
- Encrypting profiles at rest — a much larger design question, noted in
  Maintenance.
- The retention/cleanup of already-leaked temp files from previous runs
  (a startup sweep) — see Maintenance; do not add it here.

## Git workflow

- Branch: `advisor/004-temp-file-lifecycle`
- One commit per step. Message style matches recent history, e.g.
  `Delete profile temp files after the download instead of before it`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix `upsertRemote`

Restructure `upsertRemote` (`profile_repository.dart`, the method containing
lines 136-185) so the task is executed inside the `try`, exactly like
`addLocal`. The shape:

```dart
        try {
          final task = /* the existing updateRemote-or-addRemote TaskEither,
                          unchanged, assigned instead of returned */;
          return (await task.run()).getOrElse((l) => throw l);
        } finally {
          if (tempFile.existsSync()) tempFile.deleteSync();
        }
```

Concretely: change both `return _profileParser...` statements to
`final task = _profileParser...`, then after the if/else, execute and unwrap as
above. The `.flatMap(...)` chains themselves must not change.

The enclosing method must already be inside a `TaskEither.tryCatch(() async {...}, ProfileFailure.unexpected)`
for the `throw l` to be converted back into a `Left`. Confirm it is; if the
enclosing wrapper is a different shape, STOP and report.

**Verify**: `flutter analyze lib/features/profile/data/profile_repository.dart`
→ no errors. `grep -c "await task.run()" lib/features/profile/data/profile_repository.dart`
returns at least `2` (addLocal's plus the new one).

### Step 2: Fix `offlineUpdate`

Apply the identical transformation to `offlineUpdate` (around `:229-257`).

**Verify**: `grep -c "await task.run()" lib/features/profile/data/profile_repository.dart`
returns at least `3`. `flutter analyze lib/features/profile/data/profile_repository.dart`
→ no errors.

### Step 3: Delete the per-line sidecar files

In `profile_parser.dart`'s `expandRemoteLinesInParallel` worker, ensure
`tmpPath` is deleted whether the download succeeds or fails. Wrap the
download-and-read in a `try`/`finally`:

```dart
          final tmpPath = '$tempFilePath.$currentIndex';
          try {
            await httpClient.download(
              line,
              tmpPath,
              cancelToken: cancelToken,
              userAgent: ...,   // unchanged
            );

            results[currentIndex] = (await File(tmpPath).readAsString()).trim();
          } finally {
            final tmp = File(tmpPath);
            if (tmp.existsSync()) tmp.deleteSync();
          }
```

Keep the existing outer `catch (err)` behavior (the cancellation check and the
`results[currentIndex] = ''` fallback) exactly as it is — the new `finally`
sits inside it.

**Verify**: `grep -n "tmp.deleteSync()\|tmpPath" lib/features/profile/data/profile_parser.dart`
shows the deletion alongside the existing uses.

### Step 4: Confirm no regression

**Verify**: `flutter test` → all tests pass, including the existing
`profile_parser_test.dart` suite.

### Step 5: Manual confirmation (required — no automated coverage exists)

This step cannot be automated with the current test infrastructure. Perform it
and report the result:

1. Run the app (`flutter run -d <platform>`).
2. Add a remote profile from any subscription URL.
3. Inspect the app's `configs/` directory (path from
   `profile_path_resolver.dart`; on desktop it is under the app support dir).
4. Confirm it contains `<id>.json` and **no** `<id>.tmp.json` and **no**
   `<id>.tmp.json.<n>` sidecars.
5. Repeat with a deliberately broken URL and confirm no temp files remain after
   the failure either.

If you cannot run the app in your environment, say so explicitly in your report
rather than claiming this step passed.

## Test plan

There is no existing test harness that can drive `ProfileRepositoryImpl` (it
needs a fake `ProfileParser`, a fake HTTP client, and filesystem access, and no
mocking library is installed — see plan 001's Maintenance notes). Writing that
harness is larger than this fix and would delay a security-relevant change.

Therefore:
- **Automated**: `flutter test` must stay green (regression check only).
- **Manual**: Step 5 above is the actual verification of the fix, and its result
  must be reported.
- **Follow-up** (do not do it here): once a mocking library exists, add
  `test/features/profile/data/profile_repository_test.dart` asserting that
  after a successful add, a failed add, and a cancelled add, no file matching
  `*.tmp.json*` remains in the configs directory.

## Done criteria

Machine-checkable where possible. ALL must hold:

- [ ] `grep -c "await task.run()" lib/features/profile/data/profile_repository.dart` returns at least `3`
- [ ] No `return _profileParser` statement remains directly inside a `try` whose `finally` deletes a temp file — verify by reading `upsertRemote` and `offlineUpdate`
- [ ] `grep -c "deleteSync()" lib/features/profile/data/profile_parser.dart` returns at least `1`
- [ ] `flutter analyze lib/features/profile` reports no new errors
- [ ] `flutter test` exits 0
- [ ] `git status` shows changes ONLY to `profile_repository.dart`, `profile_parser.dart`, and `plans/README.md`
- [ ] Step 5's manual check performed and its result stated in the report (including "could not run" if that is the truth)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `upsertRemote` or `offlineUpdate` is not wrapped in
  `TaskEither.tryCatch(..., ProfileFailure.unexpected)` — the `throw l` unwrap
  pattern depends on that wrapper existing.
- Deleting the temp file breaks `validateConfig`, which reads `tempFile.path`.
  Ordering matters: the delete must happen after the whole chain including
  validation. If tests or manual runs show validation failing, the `finally` is
  firing too early — report rather than working around it.
- On Windows, `deleteSync()` throws because the file is still open. That means
  a handle is being leaked elsewhere; report it rather than swallowing the
  exception.
- The existing `profile_parser_test.dart` tests start failing — they cover
  `populateHeaders` and parsing, which this plan should not affect.

## Maintenance notes

- **Not fixed here, and still true**: temp files already leaked by previous
  versions remain on users' disks. A one-time startup sweep of
  `configs/*.tmp.json*` would clean them up, but deleting files at startup based
  on a glob is its own risk and deserves its own plan and review.
- **Related bug in the same function, deliberately out of scope**:
  `profile_parser.dart:239-242` writes `results.join("\n")` over a
  `List<String?>`, so any entry left `null` by a cancelled worker is written to
  the profile as the literal text `null`. The guard `results.any((e) => e != null)`
  is also inverted relative to intent. That is a correctness bug rather than a
  credential-lifetime bug; it is recorded in `plans/README.md` as an unplanned
  finding.
- **The larger question**: profiles and their temp copies are stored
  unencrypted in the app data directory, and on Android are additionally swept
  into cloud backup (no `android:allowBackup="false"` in the manifest — also
  recorded as an unplanned finding). Encryption at rest is the real answer for
  this threat model; this plan only stops the bleeding.
- A reviewer should check specifically that `task.run()` is awaited *inside*
  the `try` in both methods — moving it outside silently restores the original
  bug with no visible diff in the cleanup code.
