# Plan 008: Stop cancelled profile-line expansion from writing literal "null" into profile content

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- lib/features/profile/data/profile_parser.dart`
> If this file changed since this plan was written, compare the "Current
> state" excerpt below against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. In particular, this function was
> touched by plan 004 (temp-file lifecycle) — make sure you're reading the
> live version, not assuming this excerpt still matches line-for-line.

## Status

- **Priority**: P1
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: 001 (needs `make test` to mean something), independent of 004
- **Category**: bug
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

`ProfileParser.expandRemoteLinesInParallel` (`lib/features/profile/data/profile_parser.dart`)
expands `http(s)://` lines inside a profile's content (used for
config-inclusion / "sub-link" style profiles) by downloading each in
parallel and substituting the fetched content in place. Its `results` list is
`List<String?>` — a slot stays `null` if a worker never got to claim that
line's index before the shared `CancelToken` was cancelled (e.g. the user
cancels an in-progress profile add/update, or a sibling download in the same
batch fails and cancels the group). The write guard only checks whether *any*
slot is non-null:

```dart
if (results.any((e) => e != null)) {
  final newContent = results.join("\n");
  await File(tempFilePath).writeAsString(newContent);
}
```

`List<String?>.join` calls `toString()` on every element, and `null.toString()`
is the four-character string `"null"`. So a partially-cancelled expansion
writes the literal text `null` as a standalone line into the profile file that
gets parsed next — silently corrupting the profile's actual proxy
configuration with garbage lines, not just failing loudly. This is on the
same untrusted-content code path plan 011 adds characterization tests for.

## Current state

- `lib/features/profile/data/profile_parser.dart` — the file to change,
  specifically `expandRemoteLinesInParallel` (currently around lines
  185–247; use the drift check above to find the live line numbers).

The function as it exists today:

```dart
  Future<void> expandRemoteLinesInParallel({
    required String tempFilePath,
    required DioHttpClient httpClient,
    required CancelToken cancelToken,
    required Ref ref,
    int parallelism = 4,
  }) async {
    final content = await File(tempFilePath).readAsString();
    final lines = content.split('\n');

    final results = List<String?>.filled(lines.length, null);

    int index = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelToken.isCancelled) return;

        final currentIndex = index++;
        if (currentIndex >= lines.length) return;

        final line = lines[currentIndex];

        // Non-URL
        if (!line.startsWith('http://') && !line.startsWith('https://')) {
          results[currentIndex] = line.trim();
          continue;
        }

        try {
          final tmpPath = '$tempFilePath.$currentIndex';
          try {
            await httpClient.download(
              line,
              tmpPath,
              cancelToken: cancelToken,
              userAgent: ref.read(ConfigOptions.useXrayCoreWhenPossible)
                  ? httpClient.userAgent.replaceAll('HiddifyNext', 'HiddifyNextX')
                  : null,
            );

            results[currentIndex] = (await File(tmpPath).readAsString()).trim();
          } finally {
            final tmp = File(tmpPath);
            if (tmp.existsSync()) tmp.deleteSync();
          }
        } catch (err) {
          if (err is DioException && CancelToken.isCancel(err)) {
            return;
          }
          results[currentIndex] = '';
        }
      }
    }

    // Start workers
    await Future.wait(List.generate(parallelism, (_) => worker()));

    if (results.any((e) => e != null)) {
      final newContent = results.join("\n");
      await File(tempFilePath).writeAsString(newContent);
    }
  }
```

Repo conventions: `ProfileParser` methods use `TaskEither`/`Either` for
recoverable failures elsewhere in this file, but this particular method
returns `void` and communicates failure only by leaving the temp file
unchanged — match that existing shape rather than introducing a new return
type, to keep this a minimal, targeted fix.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Tests | `flutter test test/features/profile/data/profile_parser_test.dart` | all pass |
| Full suite | `make test` | all pass |

## Scope

**In scope**:
- `lib/features/profile/data/profile_parser.dart` (only the guard/write logic
  inside `expandRemoteLinesInParallel`)
- `test/features/profile/data/profile_parser_test.dart` (extend)

**Out of scope**:
- The retry/error-message behavior for a fully-cancelled expansion (returning
  early without writing) — this plan only fixes the *partial*-cancellation
  case that currently corrupts the file; a fully cancelled expansion already
  correctly leaves the file untouched today (all-null `results` fails the
  `any` check) and that behavior should not change.
- `expandRemoteLinesInParallel`'s temp-file cleanup (`tmp.deleteSync()`) —
  already correct and unrelated to this bug; do not touch it.
- Anything in `addLocal`/`addRemote`/`updateRemote`/`offlineUpdate` (the
  methods that call this one) — they don't need to change.

## Git workflow

- Branch: `advisor/008-profile-expansion-null-corruption`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Don't write literal "null" into profile content on partial cancellation`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Only write when every line resolved

Change the guard from "any non-null" to "all non-null" — a partially
cancelled/failed expansion should behave the same as a fully cancelled one
(leave the file untouched) rather than writing a mix of real content and the
literal string `"null"`:

```dart
    if (results.every((e) => e != null)) {
      final newContent = results.join("\n");
      await File(tempFilePath).writeAsString(newContent);
    }
```

**Verify**: `grep -n "results.every((e) => e != null)" lib/features/profile/data/profile_parser.dart`
returns 1 match, and `grep -c "results.any((e) => e != null)" lib/features/profile/data/profile_parser.dart`
returns `0`.

### Step 2: Add a regression test

Add a test to `test/features/profile/data/profile_parser_test.dart` in a new
`group("expandRemoteLinesInParallel", ...)` block. This needs a `Ref` (the
method reads `ConfigOptions.useXrayCoreWhenPossible` off it for URL lines) and
a `DioHttpClient` whose `download` call can be made to cancel mid-flight
without hitting the network — build both without adding a mocking dependency:

```dart
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Cancels the shared token the instant a download is attempted, instead of
// making a real network call, to deterministically reproduce a
// partial-cancellation mid-expansion.
class _CancelOnDownloadClient extends DioHttpClient {
  _CancelOnDownloadClient() : super(timeout: const Duration(seconds: 1), userAgent: 'test', debug: false);

  @override
  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
  }) async {
    cancelToken?.cancel();
    throw DioException(requestOptions: RequestOptions(path: url), type: DioExceptionType.cancel);
  }
}

void main() {
  // ... existing group("parse", ...) above ...

  group("expandRemoteLinesInParallel", () {
    test("does not write literal 'null' when cancelled mid-expansion", () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);
      final refProvider = Provider<Ref>((ref) => ref);
      final ref = container.read(refProvider);

      final tempFile = await File(
        '${Directory.systemTemp.path}/expand_test_${DateTime.now().microsecondsSinceEpoch}.txt',
      ).create();
      addTearDown(() {
        if (tempFile.existsSync()) tempFile.deleteSync();
      });
      await tempFile.writeAsString('line-a\nhttp://example.invalid/x\nline-b');

      final parser = ProfileParser(ref: ref, httpClient: _CancelOnDownloadClient());
      final cancelToken = CancelToken();

      await parser.expandRemoteLinesInParallel(
        tempFilePath: tempFile.path,
        httpClient: _CancelOnDownloadClient(),
        cancelToken: cancelToken,
        ref: ref,
        parallelism: 1,
      );

      final finalContent = await tempFile.readAsString();
      expect(finalContent, equals('line-a\nhttp://example.invalid/x\nline-b'));
      expect(finalContent.contains('null'), isFalse);
    });
  });
}
```

Note `sharedPreferencesProvider` needs importing from wherever it's declared
(`lib/core/preferences/preferences_provider.dart` — check the existing import
in `config_option_repository.dart` for the exact path) — add that import
alongside the others.

**Verify**: `flutter test test/features/profile/data/profile_parser_test.dart`
→ all tests pass, including the new one.

### Step 3: Confirm the full suite still passes

**Verify**: `make test` → all tests pass.

## Test plan

- New test: "does not write literal 'null' when cancelled mid-expansion" in
  `test/features/profile/data/profile_parser_test.dart`, per Step 2 — proves
  the exact corruption scenario (one line resolved, one cancelled mid-download,
  one never claimed) no longer writes `"null"` into the file.
- Model the file's existing structure (`group`/`test`, `ProfileEntity.remote`
  construction) from the current `group("parse", ...)` block in the same file.
- Verification: `flutter test test/features/profile/data/profile_parser_test.dart`
  → all pass, including the 1 new test.

## Done criteria

- [ ] `make test` exits 0
- [ ] `grep -n "results.every((e) => e != null)" lib/features/profile/data/profile_parser.dart` returns 1 match
- [ ] `grep -c "results.any((e) => e != null)" lib/features/profile/data/profile_parser.dart` returns `0`
- [ ] New test in `test/features/profile/data/profile_parser_test.dart` passes
- [ ] `git status` shows changes only to `lib/features/profile/data/profile_parser.dart`, `test/features/profile/data/profile_parser_test.dart`, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- The code at `expandRemoteLinesInParallel` doesn't match the excerpt above
  (drift since this plan was written, e.g. from plan 004's changes to nearby
  code) — re-read the live function and confirm the `any`/`join` pattern is
  still present before proceeding.
- The new test fails to compile because `sharedPreferencesProvider` or
  `ProfileParser`'s constructor signature has changed — report the exact
  compile error rather than guessing a replacement API.
- `DioHttpClient` has been marked `final` or `sealed` since this plan was
  written (making it non-subclassable) — report this and ask whether a
  different fake strategy (e.g. wrapping instead of subclassing) is
  acceptable, since that would change the shape of Step 2's test.

## Maintenance notes

- The fix intentionally makes "any line failed/cancelled" behave the same as
  "the whole expansion was cancelled": don't write anything, leave the caller
  to retry the whole operation. If a future requirement needs partial writes
  (e.g. "keep what succeeded, mark failed lines"), that's a product decision
  requiring a different data shape than a flat `List<String?>` join, and
  should not be smuggled into a bug-fix plan.
- This function is also exercised indirectly by plan 004's temp-file lifecycle
  fix and plan 011's characterization-test work on the same file — if those
  land first, re-run this plan's drift check before starting.
