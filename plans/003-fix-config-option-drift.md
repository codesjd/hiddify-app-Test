# Plan 003: Fix the settings that never reach the core, and add a guard so it stops happening

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c99aed7f..HEAD -- lib/features/settings/data/config_option_repository.dart lib/singbox/model/singbox_config_option.dart`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-restore-verification-baseline.md` (needs a
  trustworthy `flutter test`; the guard test in Step 4 is the whole point of
  this plan and must actually run in CI)
- **Category**: bug
- **Planned at**: commit `c99aed7f`, 2026-07-28

## Why this matters

A single user setting in this app is declared in up to six separate
hand-maintained places: the preference declaration, a dotted-path map used by
settings import/reset, a `ref.watch` block that assembles the object sent to
the Go core, the freezed model whose kebab-case JSON is the actual wire
contract, an allowlist in the profile parser, and a private-keys list. Nothing
checks that these agree, and when they drift the failure is **silent** — no
compile error, no runtime error, just a setting that does nothing.

Three such drifts are in the tree right now, one of them user-visible and
security-relevant: the unblocker chain mode the user picks is discarded and the
extra-security mode is sent to the core instead. For a censorship-circumvention
client, "the traffic chain silently isn't what the UI says it is" is a
user-safety bug, not a cosmetic one.

This plan fixes the three confirmed drifts and adds one assertion-style test
that converts all future drift from silent to loud. It deliberately does **not**
attempt the larger refactor of unifying the six registries — that is a much
riskier change and the guard test is what makes it safe to attempt later.

## Current state

Files involved:

- `lib/features/settings/data/config_option_repository.dart` (569 lines) — all
  three registries live here: the preference declarations (`:19-332`), the
  dotted-path `preferences` map (`:353-423`), and the `singboxConfigOptions`
  assembler (`:469-548`).
- `lib/singbox/model/singbox_config_option.dart` — the freezed model whose
  JSON is the wire contract with the Go core.

**Drift 1 — the unblocker mode is never sent.** `config_option_repository.dart:520-533`.
Note both blocks read `extraSecurityMode`:

```dart
      extraSecurity: SingboxExtraSecurityOption(
        mode: ref.watch(extraSecurityMode),
        warp: SingboxExtraSecurityWarpOption(licenseKey: ref.watch(extraSecurityWarpLicenseKey)),
        psiphon: SingboxExtraSecurityPsiphonOption(
          region: ref.watch(extraSecurityPsiphonRegion),
          conduitPairingId: ref.watch(extraSecurityPsiphonConduitPairingId),
        ),
        profile: SingboxExtraSecurityProfileOption(id: ref.watch(extraSecurityProfileId)),
      ),
      unblocker: SingboxUnblockerOption(
        mode: ref.watch(extraSecurityMode),
        warp: SingboxUnblockerWarpOption(
          licenseKey: ref.watch(unblockerWarpLicenseKey),
```

The line inside `unblocker:` should read `ref.watch(unblockerMode)`.
`unblockerMode` is declared at `:277`, written by the UI at
`lib/features/chain/overview/chain_mode_menu.dart:44`, and read back for
display at `lib/features/chain/overview/chain_mode_button.dart:28` — so the
setting appears to work while the core receives the wrong value.

Second-order consequence: because `singboxConfigOptions` never `watch`es
`unblockerMode`, changing it does not invalidate the provider, so no
config-changed signal fires. `lib/features/connection/data/connection_repository.dart:108`
also branches on `unblocker.mode` to decide which consent dialog to show, so
the wrong mode drives the wrong licence prompt.

**Drift 2 — a TLS setting with nowhere to go.** `config_option_repository.dart:191-192`
declares it and `:393` exports it:

```dart
  static final fragmentPackets = PreferencesNotifier.create<String, String>(
    "fragment-packets",
```

```dart
    "tls-tricks.fragment-packets": fragmentPackets,
```

But `SingboxTlsTricks` (`lib/singbox/model/singbox_config_option.dart:175-182`)
has no such field:

```dart
  const factory SingboxTlsTricks({
    required bool enableFragment,
    @OptionalRangeJsonConverter() required OptionalRange fragmentSize,
    @OptionalRangeJsonConverter() required OptionalRange fragmentSleep,
    required bool mixedSniCase,
    required bool enablePadding,
    @OptionalRangeJsonConverter() required OptionalRange paddingSize,
  }) = _SingboxTlsTricks;
```

It is rendered in the UI at
`lib/features/settings/overview/sections/tls_tricks_page.dart:36`, so the user
can set a value that can never reach the core.

**Drift 3 — six options are invisible to import/reset.** These are declared as
preferences but absent from the `preferences` map at `:353-423`:

| Option | Declared at |
|---|---|
| `enable-clash-api` | `:169` |
| `enable-fake-dns` | `:183` |
| `independent-dns-cache` | `:187` |
| `chain-status` | `:240` |
| `extra-security-mode` | `:271` |
| `unblocker-mode` | `:278` |

`resetOption()` (`lib/features/settings/notifier/config_option/config_option_notifier.dart:167-172`)
iterates that map, so it silently skips these six. Export writes
`SingboxConfigOption.toJson()` while import reads through the map, so
export→import is lossy by construction.

Repo conventions to match:
- Preference declarations are `static final <name> = PreferencesNotifier.create<T, P>("kebab-key", default)`.
- The `preferences` map keys are dotted JSON paths matching the nesting in
  `SingboxConfigOption.toJson()`, e.g. `"tls-tricks.enable-fragment"`.
- Tests: `package:flutter_test/flutter_test.dart`, `group("<unit>")` wrapping
  `test("Should ...")`, double-quoted strings. See
  `test/features/profile/data/profile_parser_test.dart:1-13`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps | `flutter pub get` | exit 0 |
| Codegen (required after model edits) | `make gen` | exit 0 |
| Tests | `flutter test` | all pass |
| Targeted test | `flutter test test/features/settings/data/config_option_drift_test.dart` | all pass |
| Analyze | `flutter analyze lib/features/settings lib/singbox` | no new errors |

## Scope

**In scope** (the only files you should modify):
- `lib/features/settings/data/config_option_repository.dart`
- `test/features/settings/data/config_option_drift_test.dart` (create)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `lib/singbox/model/singbox_config_option.dart` — **do not add a
  `fragmentPackets` field.** That model's JSON is the live wire contract with
  the Go core, which is not checked out here and cannot be verified. Adding a
  field the core does not expect is a protocol change, not a client fix. See
  Step 2 for the correct handling.
- The Go core / `hiddify-core/` submodule.
- Unifying the six registries into one table. That is the real long-term fix
  and it is explicitly deferred — the guard test from Step 4 is the
  prerequisite that makes it attemptable.
- `lib/features/settings/notifier/config_option/config_option_notifier.dart`.

## Git workflow

- Branch: `advisor/003-config-option-drift`
- One commit per step so each drift fix is separately revertable. Message
  style matches recent history, e.g.
  `Send the unblocker mode the user actually selected`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Send the correct unblocker mode

In `lib/features/settings/data/config_option_repository.dart`, inside the
`unblocker: SingboxUnblockerOption(` block (around `:531`), change:

```dart
        mode: ref.watch(extraSecurityMode),
```

to:

```dart
        mode: ref.watch(unblockerMode),
```

Leave the `extraSecurity:` block above it unchanged — its use of
`extraSecurityMode` is correct.

**Verify**: `grep -n "ref.watch(unblockerMode)" lib/features/settings/data/config_option_repository.dart`
returns exactly one line, and
`grep -c "ref.watch(extraSecurityMode)" lib/features/settings/data/config_option_repository.dart`
returns `1` (down from 2).

### Step 2: Resolve the orphaned `fragment-packets` option

`fragmentPackets` has no destination in the wire model. There are two honest
options and you must pick based on evidence, not guess:

Run `grep -rn "fragmentPackets\|fragment-packets" lib/` and read every hit.

- **If the only hits are the declaration (`:191`), the map entry (`:393`), and
  the settings UI (`tls_tricks_page.dart`)** — i.e. nothing consumes it — then
  remove the `preferences` map entry at `:393` only, and add a comment above
  the declaration at `:191`:

  ```dart
  // NOTE: not part of SingboxTlsTricks and therefore never reaches the core.
  // Kept because the settings UI still renders it; removing the UI control is
  // a separate product decision. Do not add it back to the `preferences` map
  // until the core accepts it - export would emit a key import cannot restore.
  ```

  Removing the map entry stops export from emitting a key that import cannot
  round-trip.

- **If something else does consume it**, STOP and report what — the analysis
  behind this plan may be wrong.

**Verify**: `grep -c '"tls-tricks.fragment-packets"' lib/features/settings/data/config_option_repository.dart`
returns `0`, and `grep -c "fragmentPackets" lib/features/settings/data/config_option_repository.dart`
returns at least `1` (the declaration survives).

### Step 3: Add the six missing options to the `preferences` map

In the `preferences` map (`:353-423`), add entries for the six options listed
in "Current state" — Drift 3. The map key must be the dotted JSON path
matching where that value appears in `SingboxConfigOption.toJson()`.

Determine each path by reading `lib/singbox/model/singbox_config_option.dart`
and matching the field's `@JsonKey`/kebab name and nesting. For example, if
`enableClashApi` serializes as a top-level `"enable-clash-api"`, the entry is:

```dart
    "enable-clash-api": enableClashApi,
```

and if the chain mode serializes nested under `"extra-security"`, it is:

```dart
    "extra-security.mode": extraSecurityMode,
```

**Do not guess a path.** For each of the six, confirm against the model. If any
of the six has no corresponding field in `SingboxConfigOption` (i.e. it is
another Drift-2 case), do **not** add it to the map — instead apply the Step 2
comment treatment and list it in your report.

**Verify**: `flutter test test/features/settings/data/config_option_drift_test.dart`
(written in Step 4) passes — that test is the real check on this step.

### Step 4: Add the drift guard test

Create `test/features/settings/data/config_option_drift_test.dart`. Its job is
to assert the registries agree, so future drift fails CI instead of shipping.

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';

/// Flattens a nested json map into dotted paths, e.g. {"a": {"b": 1}} -> {"a.b"}.
Set<String> flattenKeys(Map<String, dynamic> json, [String prefix = ""]) {
  final keys = <String>{};
  json.forEach((key, value) {
    final path = prefix.isEmpty ? key : "$prefix.$key";
    if (value is Map<String, dynamic>) {
      keys.addAll(flattenKeys(value, path));
    } else {
      keys.add(path);
    }
  });
  return keys;
}

void main() {
  group("ConfigOptions.preferences", () {
    test("Should only contain keys that exist in the wire model", () {
      // Every dotted path registered for import/reset must correspond to a real
      // key in SingboxConfigOption's json. A key here that the model does not
      // have is an option that can be exported but never restored.
      final modelKeys = flattenKeys(defaultConfigOptionsJsonForTest);
      final registered = ConfigOptions.preferences.keys.toSet();
      final orphaned = registered.difference(modelKeys);
      expect(
        orphaned,
        isEmpty,
        reason: "these preference paths have no field in SingboxConfigOption: $orphaned",
      );
    });
  });
}
```

You need `defaultConfigOptionsJsonForTest` — a `SingboxConfigOption` instance
serialized to JSON. Build it in the test file from the model's defaults. If
constructing one requires a `ProviderContainer` (because every field is
`required` and sourced from `ref.watch`), instead construct a
`SingboxConfigOption` literal in the test with arbitrary valid values — the
test only cares about the *key shape*, not the values.

If the test fails on keys you did not touch, that is a real pre-existing drift:
record each one in your report and add it to `plans/README.md` notes. Fix only
the six from Step 3 in this plan.

**Verify**: `flutter test test/features/settings/data/config_option_drift_test.dart`
→ passes.

### Step 5: Full suite

**Verify**: `flutter test` → all tests pass. `flutter analyze lib/features/settings lib/singbox`
→ no new errors.

## Test plan

- New file `test/features/settings/data/config_option_drift_test.dart`
  asserting every key in the `preferences` map resolves to a real field path in
  `SingboxConfigOption`'s JSON.
- Structural pattern: `test/features/profile/data/profile_parser_test.dart`.
- This test is the durable deliverable of the plan. The three drift fixes are
  one-time; the test is what prevents the fourth.
- Verification: `flutter test` → all pass, including the new test.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "ref.watch(unblockerMode)" lib/features/settings/data/config_option_repository.dart` returns `1`
- [ ] `grep -c "ref.watch(extraSecurityMode)" lib/features/settings/data/config_option_repository.dart` returns `1`
- [ ] `grep -c '"tls-tricks.fragment-packets"' lib/features/settings/data/config_option_repository.dart` returns `0`
- [ ] `test/features/settings/data/config_option_drift_test.dart` exists and `flutter test` on it exits 0
- [ ] `flutter test` exits 0
- [ ] `flutter analyze lib/features/settings lib/singbox` reports no new errors
- [ ] `git status` shows changes ONLY to `config_option_repository.dart`, the new test file, and `plans/README.md`
- [ ] `plans/README.md` status row updated, listing any pre-existing drift the new test surfaced

## STOP conditions

Stop and report back (do not improvise) if:

- Step 1's line already reads `ref.watch(unblockerMode)` — someone fixed it;
  verify the rest still applies.
- `grep` in Step 2 shows something *does* consume `fragmentPackets` beyond the
  declaration, map entry, and settings page.
- Any of the six options in Step 3 has no corresponding field in
  `SingboxConfigOption` — do not invent a field or a path.
- The Step 4 test fails on more than ~5 keys you did not touch. That means the
  drift is wider than this plan assumed and the scope needs re-cutting.
- You find yourself wanting to edit `singbox_config_option.dart` for any
  reason. That file is the wire contract; changing it needs the Go core, which
  is out of scope.

## Maintenance notes

- **The real fix is still pending.** Six registries define one option, and this
  plan only fixes today's three drifts plus adds a partial guard. The guard
  test covers `preferences` map ↔ model. It does **not** yet cover: the
  `ref.watch` assembler picking the wrong preference (Drift 1's exact shape —
  that one is only catchable by a golden test over the assembled
  `SingboxConfigOption`), nor `allowedOverrideConfigs` in
  `lib/features/profile/data/profile_parser.dart:38-45`, nor
  `privatePreferencesKeys` at `:347-351`. A follow-up plan should add the
  golden test, which would have caught Drift 1.
- A reviewer should scrutinize Step 3's dotted paths specifically — a wrong
  path passes the new test only if it coincidentally matches another field.
- When adding any new setting to this file, the checklist is: declare it, add
  it to `preferences`, wire it into `singboxConfigOptions`, add the field to
  `SingboxConfigOption`, and if it is credential-grade add it to
  `privatePreferencesKeys`. The new test catches step 2-vs-4 mismatches only.
- Drift 1's fix changes runtime behavior for existing users who had an
  unblocker mode selected: the core will now actually receive it. That is
  correct, but it means someone whose unblocker silently did nothing may see a
  different chain after upgrading. Worth a release note.
