# Plan 017: Riverpod v3 prep — stop referencing generated per-provider `Ref` typedefs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- lib/core/app_info/app_info_provider.dart lib/features/app_update/data/app_update_data_providers.dart lib/features/log/data/log_data_providers.dart lib/features/stats/data/stats_data_providers.dart lib/utils/riverpod_utils.dart`
> If any of these changed since this plan was written, re-read the live
> function signatures before proceeding; on a mismatch, treat it as a STOP
> condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none — safe to do on the current Riverpod 2 codebase; this
  plan explicitly does NOT upgrade Riverpod itself (see Why this matters)
- **Category**: migration
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

This is **not** a Riverpod 2→3 upgrade — that is explicitly not recommended
right now (see `plans/README.md`'s migration-verdicts section: 155/332 files,
933 `ref.*` call sites, a forced `flutter_hooks` bump, and a behavior change
in default provider-retry semantics make it a real gamble for a VPN client
with thin test coverage today). This plan is the small, safe piece of prep
that *is* worth doing on Riverpod 2, because it costs nothing now and removes
one of the two hardest breaking changes for whenever the team does decide to
upgrade.

`riverpod_generator` currently generates a per-provider `Ref` subtype-alias
for every `@riverpod` function (e.g. `EnvironmentRef`, `LogRepositoryRef`) in
each provider's `.g.dart` file. Riverpod 3 removes these generated typedefs
entirely in favor of the single generic `Ref`/`AutoDisposeRef` types. Most
hand-written code in this repo already uses the generic `Ref` — but five
function signatures reference the generated typedef **by name**, which means
they will fail to compile the moment `riverpod_generator` stops emitting it.
Since `Ref` already accepts the same usage on Riverpod 2 today, switching now
has no behavior change and removes this specific break pre-emptively.

Separately, `lib/utils/riverpod_utils.dart:5` defines an extension on
`AutoDisposeRef<T>` — Riverpod 3 also removes/deprecates this type in favor
of `Ref<T>` with capability checked at runtime; this is the second of the
"two hardest breaks" the migration-verdicts note calls out.

## Current state

The five hand-written call sites using a generated per-provider `Ref` alias
by name (verified directly, not from a prior report — the generated
`.g.dart` files themselves are correctly out of scope, see below):

- `lib/core/app_info/app_info_provider.dart:12`:
  ```dart
  Environment environment(EnvironmentRef ref) => throw Exception("override environmentProvider");
  ```
- `lib/features/app_update/data/app_update_data_providers.dart:8`:
  ```dart
  AppUpdateRepository appUpdateRepository(AppUpdateRepositoryRef ref) {
  ```
- `lib/features/log/data/log_data_providers.dart:10`:
  ```dart
  Future<LogRepository> logRepository(LogRepositoryRef ref) async {
  ```
- `lib/features/log/data/log_data_providers.dart:20`:
  ```dart
  LogPathResolver logPathResolver(LogPathResolverRef ref) {
  ```
- `lib/features/stats/data/stats_data_providers.dart:8`:
  ```dart
  StatsRepository statsRepository(StatsRepositoryRef ref) {
  ```

Each of `EnvironmentRef`, `AppUpdateRepositoryRef`, `LogRepositoryRef`,
`LogPathResolverRef`, `StatsRepositoryRef` is a `typedef ... = ProviderRef<T>`
(or `FutureProviderRef<T>`/etc.) generated into the corresponding `.g.dart`
file next to each of these source files — confirmed present today at, e.g.,
`lib/core/app_info/app_info_provider.g.dart:25`. These are exactly the kind
of generated per-provider alias Riverpod 3 removes.

`lib/utils/riverpod_utils.dart` in full today:

```dart
import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';

extension RefLifeCycle<T> on AutoDisposeRef<T> {
  void disposeDelay(Duration duration) {
    final link = keepAlive();
    Timer? timer;

    onCancel(() {
      timer?.cancel();
      timer = Timer(duration, link.close);
    });

    onDispose(() {
      timer?.cancel();
    });

    onResume(() {
      timer?.cancel();
    });
  }
}
```

`Ref` (the generic, non-generated type) already exposes `keepAlive()`,
`onCancel()`, `onDispose()`, and `onResume()` on Riverpod 2 — this extension
can be retargeted at `Ref<T>` with no functional change; every current call
site of `.disposeDelay(...)` is on a provider `ref` that is already a `Ref`
(or a subtype of it), so widening the extension's target type does not break
any caller.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Analyze | `make analyze` | no new findings vs. plan-001 baseline |
| Tests | `make test` | all pass |

## Scope

**In scope**:
- `lib/core/app_info/app_info_provider.dart`
- `lib/features/app_update/data/app_update_data_providers.dart`
- `lib/features/log/data/log_data_providers.dart`
- `lib/features/stats/data/stats_data_providers.dart`
- `lib/utils/riverpod_utils.dart`

**Out of scope**:
- Any `.g.dart` file — generated, will simply stop emitting the now-unused
  typedefs' usages once the source no longer references them by name (the
  typedefs themselves keep being generated regardless on Riverpod 2 — that's
  fine, they're just unused after this change).
- Any other `Ref`/`AutoDisposeRef` usage in the codebase not listed above —
  a repo-wide grep found exactly these 5 hand-written call sites referencing
  a generated typedef by name, and exactly this 1 file referencing
  `AutoDisposeRef` directly; if your own verification finds more, note them
  in your final report as candidates for a follow-up rather than expanding
  this plan's scope silently.
- Upgrading `riverpod`/`riverpod_generator`/`hooks_riverpod` itself — not
  part of this plan (see Why this matters).

## Git workflow

- Branch: `advisor/017-riverpod-v3-prep`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Replace generated per-provider Ref typedefs with plain Ref (Riverpod 3 prep)`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the 5 generated `*Ref` typedef usages with `Ref`

In each of the 4 files, replace the generated typedef name with the generic
`Ref` type in the function signature:

- `app_info_provider.dart:12`: `EnvironmentRef ref` → `Ref ref`
- `app_update_data_providers.dart:8`: `AppUpdateRepositoryRef ref` → `Ref ref`
- `log_data_providers.dart:10`: `LogRepositoryRef ref` → `Ref ref`
- `log_data_providers.dart:20`: `LogPathResolverRef ref` → `Ref ref`
- `stats_data_providers.dart:8`: `StatsRepositoryRef ref` → `Ref ref`

Add `import 'package:hooks_riverpod/hooks_riverpod.dart';` to any of these
files that doesn't already import it (check first — most already do, since
they're `@riverpod` provider files).

**Verify**: `grep -rn "EnvironmentRef\|AppUpdateRepositoryRef\|LogRepositoryRef\|LogPathResolverRef\|StatsRepositoryRef" lib --include=*.dart | grep -v "\.g\.dart"`
returns no matches.

### Step 2: Retarget the `riverpod_utils.dart` extension at `Ref`

Change `lib/utils/riverpod_utils.dart`:

```dart
extension RefLifeCycle<T> on AutoDisposeRef<T> {
```

to:

```dart
extension RefLifeCycle<T> on Ref<T> {
```

**Verify**: `grep -n "on Ref<T>" lib/utils/riverpod_utils.dart` returns 1
match, and `grep -c "AutoDisposeRef" lib/utils/riverpod_utils.dart` returns
`0`.

### Step 3: Regenerate and confirm every call site still resolves

**Verify**: `make gen` → exit 0. `make analyze` → no new findings vs. the
plan-001 baseline (in particular, no "the getter/method X isn't defined for
the type Y" errors at any `.disposeDelay(...)` call site — a repo-wide grep
for `.disposeDelay(` will show you every call site to spot-check if analyze
raises anything here).

### Step 4: Confirm the full suite still passes

**Verify**: `make test` → all pass.

## Test plan

No new tests — this plan is a type-signature-only change with no behavior
difference on Riverpod 2 today (both `Ref` and the generated typedefs it
replaces, and both `AutoDisposeRef<T>` and `Ref<T>` for this extension's
actual call sites, expose the same members). Verification is entirely
`make analyze` + `make test` passing, confirming nothing broke.

## Done criteria

- [ ] `grep -rn "EnvironmentRef\|AppUpdateRepositoryRef\|LogRepositoryRef\|LogPathResolverRef\|StatsRepositoryRef" lib --include=*.dart | grep -v "\.g\.dart"` returns no matches
- [ ] `grep -c "AutoDisposeRef" lib/utils/riverpod_utils.dart` returns `0`
- [ ] `make analyze` reports no new findings vs. the plan-001 baseline
- [ ] `make test` exits 0
- [ ] `git status` shows changes only to the 5 in-scope files, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any of the 5 files' function signatures don't match the excerpts above
  (drift since this plan was written) — re-read the live signature and
  confirm it's still the generated-typedef pattern before changing it.
- `make analyze` reports a new error at any `.disposeDelay(...)` call site
  after Step 2 — this would mean some caller relies on an
  `AutoDisposeRef`-specific member not present on the generic `Ref`; report
  the exact error and the call site rather than reverting silently.
- A repo-wide grep for `AutoDisposeRef\b` (word boundary, to avoid matching
  `AutoDisposeProviderRef` etc. if that's a separate concern) turns up
  additional hand-written usages this plan didn't account for — note them in
  your final report as a follow-up candidate rather than expanding scope.

## Maintenance notes

- This does not upgrade Riverpod. It only removes 2 of the concrete breaking
  changes a future 2→3 upgrade would otherwise hit. The other 933 `ref.*`
  call sites, 84 `StateNotifierProvider` instantiations, and the
  `flutter_hooks` 0.20→0.21 forced bump remain exactly as much work as before
  — see `plans/README.md`'s migration-verdicts section for the full picture
  and why the upgrade itself is not recommended yet.
- Any new `@riverpod` provider function written after this plan lands should
  use `Ref` directly rather than whatever typedef `riverpod_generator` offers
  to auto-import — this is now the established convention in this repo, not
  just an incidental fix.
