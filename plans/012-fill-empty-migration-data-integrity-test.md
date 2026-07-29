# Plan 012: Fill in the empty v1→v2 migration data-integrity test

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- test/drift/db/migration_test.dart lib/core/db/db.dart`
> If either file changed since this plan was written, re-read the current
> `from1To2` migration step and the current test body before proceeding; on
> a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 001 (needs `make test` to mean something)
- **Category**: tests
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

`test/drift/db/migration_test.dart:49-72` has a generated-template test that
was never filled in:

```dart
    test('migration from v1 to v2 does not corrupt data', () async {
      // Add data to insert into the old database, and the expected rows after the
      // migration.
      // TODO: Fill these lists
      final oldProfileEntriesData = <v1.ProfileEntriesData>[];
      final expectedNewProfileEntriesData = <v2.ProfileEntriesData>[];

      await verifier.testWithDataIntegrity(
        oldVersion: 1,
        newVersion: 2,
        createOld: v1.DatabaseAtV1.new,
        createNew: v2.DatabaseAtV2.new,
        openTestedDatabase: Db.new,
        createItems: (batch, oldDb) {
          batch.insertAll(oldDb.profileEntries, oldProfileEntriesData);
        },
        validateItems: (newDb) async {
          expect(
            expectedNewProfileEntriesData,
            await newDb.select(newDb.profileEntries).get(),
          );
        },
      );
    });
```

With both lists empty, `expect([], [])` trivially passes regardless of
whether the migration actually preserves data correctly — this test currently
provides zero signal. The migration it's meant to guard
(`lib/core/db/db.dart:36-44`, `from1To2`) adds a `type` column to
`profileEntries` via a `TableMigration` with a `columnTransformer` that sets
every existing row's `type` to the constant `"remote"` — a real, if simple,
data transform worth actually asserting on.

## Current state

- `test/drift/db/migration_test.dart` — the file to change (only the one
  test body).
- `lib/core/db/db.dart:36-44` — the migration under test, for reference only
  (do not modify):

```dart
        from1To2: (m, schema) async {
          await m.alterTable(
            TableMigration(
              schema.profileEntries,
              columnTransformer: {schema.profileEntries.type: const Constant<String>("remote")},
              newColumns: [schema.profileEntries.type],
            ),
          );
        },
```

- `test/drift/db/generated/schema_v1.dart:183-208` —
  `v1.ProfileEntriesData` has no `type` field (it doesn't exist yet at v1):

```dart
class ProfileEntriesData extends DataClass
    implements Insertable<ProfileEntriesData> {
  final String id;
  final bool active;
  final String name;
  final String url;
  final DateTime lastUpdate;
  final int? updateInterval;
  final int? upload;
  final int? download;
  final int? total;
  final DateTime? expire;
  final String? webPageUrl;
  final String? supportUrl;
  const ProfileEntriesData({
    required this.id,
    required this.active,
    required this.name,
    required this.url,
    required this.lastUpdate,
    this.updateInterval,
    this.upload,
    this.download,
    this.total,
    this.expire,
    this.webPageUrl,
    this.supportUrl,
  });
```

- `test/drift/db/generated/schema_v2.dart:195-209` — `v2.ProfileEntriesData`
  adds `type` as the second field (`required this.type`), and `url` becomes
  nullable at v2 (it's non-nullable at v1).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Tests | `flutter test test/drift/db/migration_test.dart` | all pass |
| Full suite | `make test` | all pass |

## Scope

**In scope**:
- `test/drift/db/migration_test.dart` (only the
  `'migration from v1 to v2 does not corrupt data'` test body)

**Out of scope**:
- `lib/core/db/db.dart` — the migration itself is not being changed, only
  tested.
- Any other test in this file (the `simple database migrations` group and the
  `_columnExists`-backed migration tests below it) — leave them untouched.
- `test/drift/db/generated/*` — these are generated schema snapshots; do not
  hand-edit them.

## Git workflow

- Branch: `advisor/012-fill-migration-data-integrity-test`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Fill in the v1-to-v2 migration data-integrity test`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fill in the old (v1) row(s)

Replace the empty `oldProfileEntriesData` list with one representative row —
note `url` is non-nullable at v1, and there is no `type` field yet:

```dart
      final oldProfileEntriesData = <v1.ProfileEntriesData>[
        v1.ProfileEntriesData(
          id: 'profile-1',
          active: true,
          name: 'My Profile',
          url: 'https://example.com/sub',
          lastUpdate: DateTime.utc(2024, 1, 1),
          updateInterval: null,
          upload: 100,
          download: 200,
          total: 1000,
          expire: null,
          webPageUrl: null,
          supportUrl: null,
        ),
      ];
```

**Verify**: `flutter analyze test/drift/db/migration_test.dart` reports no
new errors on this line range (it will still fail until Step 2, since
`expectedNewProfileEntriesData` is still empty and the row count now
mismatches — that's expected at this point).

### Step 2: Fill in the expected (v2) row(s)

The migration only adds `type` (constant `"remote"`) — every other field is
preserved as-is. Add the corresponding expected row:

```dart
      final expectedNewProfileEntriesData = <v2.ProfileEntriesData>[
        v2.ProfileEntriesData(
          id: 'profile-1',
          type: 'remote',
          active: true,
          name: 'My Profile',
          url: 'https://example.com/sub',
          lastUpdate: DateTime.utc(2024, 1, 1),
          updateInterval: null,
          upload: 100,
          download: 200,
          total: 1000,
          expire: null,
          webPageUrl: null,
          supportUrl: null,
        ),
      ];
```

**Verify**: `flutter test test/drift/db/migration_test.dart --plain-name "migration from v1 to v2 does not corrupt data"`
→ passes.

**If it fails on a field mismatch**: read the actual error carefully — it
means either the field values above don't round-trip exactly as assumed (e.g.
`DateTime` precision/timezone handling in SQLite), or the migration does
something to a field this plan didn't account for. Adjust the expected row to
match reality only if you can explain *why* from reading `db.dart`'s
migration step; if you can't explain a mismatch, STOP and report it — it may
be an actual migration bug, not a bad expectation.

### Step 3: Remove the now-stale TODO comments

Delete the `// TODO: Fill these lists` comment (and the surrounding
generated-template explanation comment block, lines 40-48, if it now reads
oddly next to filled-in data — use judgment on how much of the template
prose to keep; the important part is the `TODO` itself is gone since it's
been actioned).

**Verify**: `grep -c "TODO: Fill these lists" test/drift/db/migration_test.dart`
returns `0`.

### Step 4: Confirm the full suite still passes

**Verify**: `make test` → all pass.

## Test plan

This plan's entire content is the test fix — one previously-empty test now
asserts a real before/after row for the `from1To2` migration. No new test
files are created.

Verification: `flutter test test/drift/db/migration_test.dart` → all pass,
including the now-meaningful `'migration from v1 to v2 does not corrupt data'`
test; `make test` → full suite still passes.

## Done criteria

- [ ] `make test` exits 0
- [ ] `grep -c "TODO: Fill these lists" test/drift/db/migration_test.dart` returns `0`
- [ ] `flutter test test/drift/db/migration_test.dart` shows the v1→v2 data-integrity test passing with non-empty lists
- [ ] `git status` shows changes only to `test/drift/db/migration_test.dart`, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- The `from1To2` migration step in `lib/core/db/db.dart` doesn't match the
  excerpt above (drift since this plan was written) — re-read it and adjust
  the expected row's `type` value (or add more assertions) to match the
  *actual* transform, rather than assuming the constant `"remote"` still
  applies.
- The test fails with a field-level mismatch you cannot explain from reading
  the migration step and the generated schema files — report the exact
  failure rather than adjusting field values until it passes.
- `v1.ProfileEntriesData` or `v2.ProfileEntriesData`'s constructors don't
  match the field lists shown above (schema regeneration drift) — re-read the
  live generated files under `test/drift/db/generated/` and adjust field
  names/types accordingly.

## Maintenance notes

- This is a data-integrity test for one specific migration step
  (`from1To2`). It does not add equivalent coverage for `from2To3` through
  `from5To6` — those are only covered by the schema-only "simple database
  migrations" group above it in the same file, which checks the migration
  runs without error but not that data survives correctly. Adding
  data-integrity tests for the later migrations (especially `from4To5`, which
  renames and drops columns) would be a reasonable follow-up but is out of
  scope here.
- If `from1To2` is ever changed to do something more than set a constant
  (e.g. inferring `type` from another field), this test's expected row must
  be updated to match — it is a characterization test tied to the current
  migration logic, not an independent specification of what the migration
  *should* do.
