# Plan 007: Let nullable preferences actually be cleared

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- lib/core/utils/preferences_utils.dart`
> If this file changed since this plan was written, compare the "Current
> state" excerpt below against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 001 (needs `make test` to mean something)
- **Category**: bug
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

`PreferencesEntry.write` (`lib/core/utils/preferences_utils.dart`) is the single
choke point every preference in the app goes through
(`ConfigOptions.*`, `extraSecurityProfileId`, `unblockerProfileId`,
`windowPosition`, `autoAppsSelectionLastUpdate`, etc. — see
`lib/features/settings/data/config_option_repository.dart` for the full list
of call sites using `PreferencesNotifier.create`). Its `switch` has arms for
`String`, `bool`, `int`, `double`, and `List<String>`, and a
`_ => throw const FormatException("Invalid Type")` default. Any nullable
preference (`T` is e.g. `String?`) that is set to `null` to mean "cleared"
hits that default, throws, gets caught two lines up, logs a warning, and
`write` returns `false` — so `state` never updates and the preference is
never actually cleared. A user picking "none" for `extraSecurityProfileId` or
`unblockerProfileId` silently keeps the old value.

## Current state

- `lib/core/utils/preferences_utils.dart` — the file to change.

`preferences_utils.dart:42-66` as it exists today:

```dart
  Future<bool> write(T value) async {
    Object? mapped = value;
    if (mapTo != null) {
      mapped = mapTo!(value);
    }
    loggy.debug("updating preference [$key]($T) to [$mapped]");
    try {
      if (!(validator?.call(value) ?? true)) {
        loggy.warning("invalid value [$value] for preference [$key]($T)");
        return false;
      }

      return switch (mapped) {
        final String value => await preferences.setString(key, value),
        final bool value => await preferences.setBool(key, value),
        final int value => await preferences.setInt(key, value),
        final double value => await preferences.setDouble(key, value),
        final List<String> value => await preferences.setString(key, value.join(";")),
        _ => throw const FormatException("Invalid Type"),
      };
    } catch (e, stackTrace) {
      loggy.warning("error updating preference[$key]: $e", e, stackTrace);
      return false;
    }
  }
```

Note `remove()` already exists and does the right thing
(`preferences_utils.dart:79-85`) — it is just never reached from `write(null)`.
`read()` already handles a missing key by falling back to `defaultValue`
(`preferences_utils.dart:16-40`), so removing the key on a `null` write is
consistent with how reads already behave.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Tests | `make test` (or `flutter test test/core/utils/preferences_utils_test.dart`) | all pass |
| Analyze | `make analyze` | no new findings vs. the Step-5-of-plan-001 baseline count |

## Scope

**In scope**:
- `lib/core/utils/preferences_utils.dart`
- `test/core/utils/preferences_utils_test.dart` (create)

**Out of scope**:
- `lib/features/settings/data/config_option_repository.dart` and every other
  call site — they don't need to change; they already pass through whatever
  value the UI gives them, including `null`. This plan only fixes the shared
  `write` method they all route through.
- Adding null-handling to `read()` — it already has correct null/default
  handling.

## Git workflow

- Branch: `advisor/007-nullable-preference-clear`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Handle null in PreferencesEntry.write so nullable prefs can be cleared`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a `null` arm to the `write` switch

In `preferences_utils.dart`, change the `switch (mapped)` in `write` to handle
`null` by removing the key, before the `String`/`bool`/... arms (order
matters — `null` must be checked first since it's not itself one of the typed
patterns, but Dart evaluates switch patterns top-to-bottom regardless, so
placement anywhere before the `_` default works; put it first for clarity):

```dart
      return switch (mapped) {
        null => await preferences.remove(key),
        final String value => await preferences.setString(key, value),
        final bool value => await preferences.setBool(key, value),
        final int value => await preferences.setInt(key, value),
        final double value => await preferences.setDouble(key, value),
        final List<String> value => await preferences.setString(key, value.join(";")),
        _ => throw const FormatException("Invalid Type"),
      };
```

`SharedPreferences.remove` returns `Future<bool>`, matching the other arms'
return type, so no other signature changes are needed.

**Verify**: `grep -n "null => await preferences.remove" lib/core/utils/preferences_utils.dart`
returns exactly 1 match.

### Step 2: Add a regression test

Create `test/core/utils/preferences_utils_test.dart`. Use
`SharedPreferences.setMockInitialValues` (bundled with the `shared_preferences`
package — no new dependency needed) to back a real `SharedPreferences`
instance in-memory:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('write(null) removes the key instead of throwing', () async {
    SharedPreferences.setMockInitialValues({'my-key': 'existing-value'});
    final prefs = await SharedPreferences.getInstance();
    final entry = PreferencesEntry<String?, String?>(
      preferences: prefs,
      key: 'my-key',
      defaultValue: null,
    );

    expect(prefs.containsKey('my-key'), isTrue);

    final result = await entry.write(null);

    expect(result, isTrue);
    expect(prefs.containsKey('my-key'), isFalse);
    expect(entry.read(), isNull);
  });

  test('write(non-null) still round-trips normally', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final entry = PreferencesEntry<String?, String?>(
      preferences: prefs,
      key: 'my-key',
      defaultValue: null,
    );

    expect(await entry.write('value'), isTrue);
    expect(entry.read(), equals('value'));
  });
}
```

**Verify**: `flutter test test/core/utils/preferences_utils_test.dart` →
both tests pass.

## Test plan

- New file: `test/core/utils/preferences_utils_test.dart` (see Step 2 for the
  exact two cases: clearing a previously-set nullable value, and a normal
  non-null round trip so the fix doesn't regress the happy path).
- Model the file structure after `test/core/utils/ip_utils_test.dart` (single
  `main()`, plain `test()` blocks, no groups needed for two cases).
- Verification: `make test` → all pass, including the 2 new tests.

## Done criteria

- [ ] `make test` exits 0
- [ ] `test/core/utils/preferences_utils_test.dart` exists with 2 passing tests
- [ ] `grep -n "null => await preferences.remove" lib/core/utils/preferences_utils.dart` returns 1 match
- [ ] `git status` shows changes only to `lib/core/utils/preferences_utils.dart`, `test/core/utils/preferences_utils_test.dart`, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- The code at `preferences_utils.dart:54-61` doesn't match the excerpt above
  (drift since this plan was written) — re-read the current `write` method
  and confirm the `null` case is still unhandled before proceeding.
- `flutter test` fails on the new test for a reason unrelated to the fix
  itself (e.g. `SharedPreferences.setMockInitialValues` API has changed) —
  report the exact error rather than reworking the test to pass.
- Any existing test starts failing because of this change — that would mean
  some call site relies on `write(null)` returning `false` today, which is
  worth surfacing rather than silently working around.

## Maintenance notes

- Any future preference type added to the `switch` (e.g. a `Map` or custom
  enum) should keep `null` handled first — a reviewer adding a new arm should
  not accidentally reintroduce the throw-on-null behavior by inserting before
  it carelessly (order doesn't actually matter for correctness here since
  patterns are mutually exclusive, but keep `null` visually first for
  readability).
- This does not change `writeRaw`/`updateRaw` (`preferences_utils.dart:68-77`),
  which go through `mapFrom` before reaching `write` — if a `mapFrom` function
  can itself throw on unexpected input, that's a separate, unrelated call path.
