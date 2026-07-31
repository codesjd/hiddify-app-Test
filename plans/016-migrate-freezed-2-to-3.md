# Plan 016: Migrate freezed 2 → 3

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- pubspec.yaml` and
> `grep -rc "^@freezed" lib --include=*.dart | awk -F: '{sum+=$2} END{print sum}'`
> should print `44`. If it doesn't, some `@freezed` class was added/removed
> since this plan was written — re-run the discovery command in Step 2
> before proceeding rather than trusting the file list below blindly.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 001 (needs `make analyze`/`make test` to mean something)
- **Category**: migration
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

This repo pins `freezed: ^2.4.7` / `freezed_annotation: ^2.4.1`
(`pubspec.yaml`). Freezed 3 requires every `@freezed`-annotated class to be
explicitly declared `abstract` (for a single-constructor data class) or
`sealed`/keep using an already-`abstract`/`sealed` declaration (for a
union type with multiple factory constructors) — freezed 2 inferred this
automatically, freezed 3 requires it spelled out in the class declaration
itself. This repo already writes new union types as `sealed class` (see
`lib/features/connection/model/connection_status.dart`), so most of the
union types are **already** freezed-3-shaped. Of the 44 `@freezed`
declarations found in `lib/` today, this plan's own discovery step (see
below) found:

- **13 already correctly declared** — 11 already `sealed class` (unions:
  `AppUpdateFailure`, `ConnectionFailure`, `ConnectionStatus`, `LogFailure`,
  `ProfileEntity`, `ProfileFailure`, `ProxyFailure`, `ConfigOptionFailure`,
  `SettingsFailure`, `StatsFailure`, `CoreStatus`) and 2 already `abstract
  class` (`PerAppProxyBackup`, `UserOverride`) — need no change.
- **18 need exactly one keyword added** (`abstract`) — single-constructor
  data classes still declared as plain `class`.

This is cheap, mechanical, almost entirely additive debt — worth clearing
before it's the *only* freezed-2-only repo left using an EOL major version.
Doing it now, while the change is one keyword per file, is far cheaper than
doing it after more classes accumulate the same debt.

## Current state

- `pubspec.yaml` — `freezed_annotation: ^2.4.1` (dependency),
  `freezed: ^2.4.7` (dev_dependency) — the versions to bump.
- The 18 files/classes that need `abstract` added (verified directly by
  reading each file's `@freezed` declaration line — not taken from any prior
  report):

  | File | Class |
  |---|---|
  | `lib/core/model/app_info_entity.dart` | `AppInfoEntity` |
  | `lib/features/app_update/notifier/app_update_state.dart` | `AppUpdateState` |
  | `lib/features/log/model/log_entity.dart` | `LogEntity` |
  | `lib/features/log/overview/logs_overview_state.dart` | `LogsOverviewState` |
  | `lib/features/profile/add/model/free_profiles_model.dart` | `FreeProfilesModel` |
  | `lib/features/profile/details/profile_details_state.dart` | `ProfileDetailsState` |
  | `lib/features/proxy/model/proxy_entity.dart` | `ProxyGroupEntity`, `ProxyItemEntity` (2 classes, same file) |
  | `lib/features/stats/model/stats_entity.dart` | `StatsEntity` |
  | `lib/singbox/model/singbox_config_option.dart` | `SingboxConfigOption` |
  | `lib/singbox/model/singbox_outbound.dart` | `SingboxOutboundGroup`, `SingboxOutboundGroupItem` (2 classes, same file) |
  | `lib/singbox/model/singbox_rule.dart` | `SingboxRule` |
  | `lib/singbox/model/singbox_stats.dart` | `SingboxStats` |
  | `lib/utils/async_mutation.dart` | `AsyncMutation` |
  | `lib/utils/mutation_state.dart` | `MutationState<F extends Failure>` |
  | `lib/features/profile/model/profile_entity.dart` | `ProfileOptions`, `SubscriptionInfo` (2 of the 4 `@freezed` classes in this file — `ProfileEntity` is already `sealed`, `UserOverride` is already `abstract`; leave those two alone) |

  That's 18 classes across 14 files. Example of the shape to change, from
  `lib/core/model/app_info_entity.dart:6-7` today:

  ```dart
  @freezed
  class AppInfoEntity with _$AppInfoEntity {
  ```

  becomes:

  ```dart
  @freezed
  abstract class AppInfoEntity with _$AppInfoEntity {
  ```

Repo convention: this file's existing style (const private constructor,
`const factory`, `with _$ClassName`) does not change — only the class
declaration keyword.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps | `flutter pub get` | exit 0 |
| Codegen | `make gen` | exit 0 |
| Analyze | `make analyze` | no new findings vs. plan-001 baseline |
| Tests | `make test` | all pass |
| Discovery | `grep -rn "^@freezed" lib --include=*.dart -A1` | lists every declaration + its class line |

## Scope

**In scope**:
- `pubspec.yaml` (bump `freezed` / `freezed_annotation` versions)
- The 14 files listed in "Current state" (add `abstract` to the 18 listed
  classes only)

**Out of scope**:
- The 11 already-`sealed` and 2 already-`abstract` declarations — do not
  touch them, they're already freezed-3-shaped.
- `dart_mappable`-based models (3 files, per `plans/README.md`'s "Findings
  recorded but NOT planned" section) — unrelated serialization stack, not
  freezed, out of scope.
- Any `.freezed.dart` file — generated, regenerate via `make gen`, never
  hand-edit.
- Any behavioral change to these classes beyond the keyword — this is a
  mechanical version migration, not a refactor. If you notice an unrelated
  improvement opportunity in one of these files while you're in there, do
  NOT make it part of this plan — note it in your final report instead.

## Git workflow

- Branch: `advisor/016-freezed-3-migration`
- Commit 1: version bump in `pubspec.yaml` + regenerated code (do not commit
  generated files — they're gitignored, this is just to prove it builds).
- Commit 2 (or more, your choice of granularity): the 18 `abstract` keyword
  additions across 14 files.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Re-run discovery to confirm the file list hasn't drifted

**Verify**: `grep -rc "^@freezed" lib --include=*.dart | awk -F: '{sum+=$2} END{print sum}'`
returns `44`. If it doesn't, list what's different (`git diff` against this
plan's "planned at" commit for any file under `lib/` matching `@freezed`)
before proceeding — a new class may need the same treatment, or one in this
plan's list may have been removed.

### Step 2: Bump the freezed version constraints

In `pubspec.yaml`, change:

```yaml
  freezed_annotation: ^2.4.1
```

to:

```yaml
  freezed_annotation: ^3.0.0
```

and in `dev_dependencies`:

```yaml
  freezed: ^2.4.7
```

to:

```yaml
  freezed: ^3.0.0
```

**Verify**: `flutter pub get` → exit 0. If it fails with a version conflict
(another dependency constraining `freezed_annotation`/`freezed` to `<3.0.0`),
STOP and report the exact conflicting package — do not force it with
`dependency_overrides` without checking whether that package has its own
freezed-3-compatible release first.

### Step 3: Add `abstract` to the 18 classes listed in "Current state"

For each of the 14 files, add the `abstract` keyword immediately before
`class` on the `@freezed`-annotated declaration line(s) listed in the table
above. Do not add it to any declaration not in that table (the already-
`sealed`/`abstract` ones should be left exactly as they are).

**Verify** (after all 14 files are edited):
`grep -rn "^class \w" $(grep -rl "^@freezed" lib --include=*.dart) | grep -vE "abstract|sealed"`
returns no lines that correspond to one of the 18 classes in the table above
(some unrelated non-freezed `class` lines in the same files may still match
this grep loosely — cross-check against the table by class name, don't rely
on line count alone).

### Step 4: Regenerate and confirm the build is clean

**Verify**: `make gen` → exit 0 (this regenerates every `.freezed.dart` under
the new freezed 3 generator — expect this to take longer than a normal
`make gen` run since every freezed file regenerates). Then
`make analyze` → no new findings vs. the plan-001 baseline count.

**If `make gen` fails on a specific file**: read the generator's error
carefully — it usually names the exact freezed feature that changed between
major versions (e.g. a deprecated `@Default` usage, a removed helper). Fix
only what the error identifies, in the file it names; do not preemptively
"fix" files the generator didn't complain about.

### Step 5: Run the full test suite

**Verify**: `make test` → all pass. Since this is a codegen/type-declaration
change with no intended behavior difference, any test failure here means the
migration changed something real — investigate before assuming it's
unrelated flakiness.

## Test plan

This plan adds no new tests — it's a version migration expected to be
behavior-preserving. The existing suite (`make test`) is the regression net;
if any currently-passing test starts failing, that is a signal the migration
was not purely mechanical for that class and needs closer review before
this plan is considered done.

## Done criteria

- [ ] `pubspec.yaml` shows `freezed_annotation: ^3.0.0` and `freezed: ^3.0.0` (or whatever compatible 3.x versions `flutter pub get` actually resolved — record the exact resolved versions from `pubspec.lock` in your final report)
- [ ] All 18 classes in the "Current state" table are declared `abstract class ... with _$...` (or already-compliant ones remain `sealed`/`abstract` unchanged)
- [ ] `make gen` exits 0
- [ ] `make analyze` reports no new findings vs. the plan-001 baseline
- [ ] `make test` exits 0
- [ ] `git status` shows changes only to `pubspec.yaml`, `pubspec.lock`, the 14 files in "Current state", `plans/README.md`
- [ ] `plans/README.md` status row updated, including the exact resolved freezed/freezed_annotation versions

## STOP conditions

- `flutter pub get` reports a version conflict after the bump in Step 2 —
  report the exact conflicting package/constraint; do not force-resolve with
  `dependency_overrides`.
- The discovery count in Step 1 doesn't match `44` — re-derive the current
  file/class list before proceeding rather than trusting this plan's table.
- `make gen` fails with an error not explained by "this class needs
  `abstract`/`sealed`" (e.g. a genuinely removed freezed API this repo
  depends on) — report the exact generator error rather than working around
  it by downgrading or patching generated code.
- Any test fails after the migration in a way you cannot attribute to a
  specific, explainable code-generation difference — report it rather than
  modifying the test to pass.

## Maintenance notes

- After this lands, any *new* `@freezed` class must be declared `abstract`
  (single-constructor) or `sealed` (union) from the start — freezed 3 no
  longer infers this. A reviewer should flag a bare `@freezed class Foo` in
  any future PR.
- This plan does not touch `riverpod_generator`/`riverpod`, `dart_mappable`,
  or `json_serializable` — those are separate migration surfaces tracked
  elsewhere (see `plans/README.md`'s migration verdicts section, and plan 017
  for the Riverpod-adjacent prep work). Bumping freezed does not require or
  imply bumping any of those.
