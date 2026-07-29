# Plan 001: Make lint, analysis and tests actually run in CI

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c99aed7f..HEAD -- pubspec.yaml analysis_options.yaml Makefile .github/workflows/build.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none — **this plan must land before 003, 004 and 006**
- **Category**: dx
- **Planned at**: commit `c99aed7f`, 2026-07-28

## Why this matters

This repo has 332 hand-written Dart files under `lib/` and exactly 3 test
files. The one safety net that *could* cover all 332 — static analysis — is
configured but never runs: `analysis_options.yaml` declares a `custom_lint`
plugin and enables a Riverpod rule, but neither `custom_lint` nor
`riverpod_lint` is installed, and nothing in CI or the Makefile ever invokes
`flutter analyze`. Separately, `flutter_test` is commented out of
`dev_dependencies` and resolves only as a transitive of a *runtime* package,
so the CI test job compiles by accident and will break for an unrelated reason
the day that transitive edge disappears.

The result is that a reviewer reading `analysis_options.yaml` reasonably
believes strict lints are enforced when nothing is enforced at all. Every
other improvement plan in this directory is riskier than it needs to be until
this is fixed, which is why this plan is first.

## Current state

Files involved, each with its role:

- `pubspec.yaml` — dependency manifest. `flutter_test` commented out; no
  `custom_lint` / `riverpod_lint` / mocking library.
- `analysis_options.yaml` — declares a plugin that is not installed.
- `Makefile` — build orchestration. Has **no** `test`, `analyze`, `lint` or
  `format` target.
- `.github/workflows/build.yml` — the `test` job, the only automated gate.

`pubspec.yaml:124-137` as it exists today:

```yaml
dev_dependencies:
  # flutter_test:
  #   sdk: flutter
  lint: ^2.3.0
  build_web_compilers: ^4.0.11
  build_runner: ^2.4.13
  json_serializable: ^6.7.1
  freezed: ^2.4.7
  riverpod_generator: ^2.4.3
  drift_dev: ^2.21.0
  ffigen: ^19.1.0
  slang_build_runner: ^4.4.0
  flutter_gen_runner: ^5.4.0
  dart_mappable_builder: ^4.2.1
```

`pubspec.lock:663-667` confirms the accidental resolution:

```yaml
  flutter_test:
    dependency: transitive
    description: flutter
    source: sdk
    version: "0.0.0"
```

`analysis_options.yaml` in full:

```yaml
include: package:lint/strict.yaml

analyzer:
  plugins:
    - custom_lint
  exclude:
    - "hiddify-core/**"
    - "**.g.dart"
    - "lib/gen/**"
  errors:
    invalid_annotation_target: ignore

formatter:
  page_width: 120

linter:
  rules:
    sort_pub_dependencies: false
    sort_unnamed_constructors_first: false
    avoid_classes_with_only_static_members: false

custom_lint:
  rules:
    # Enable one rule
    - provider_parameters
```

Note the `exclude:` list omits `**.freezed.dart`, `**.mapper.dart` and
`lib/hiddifycore/generated/**`. The freezed/mapper files are generated and
gitignored, so a naive `flutter analyze` will scan them.

`Makefile:69-88` — the only verification-adjacent targets:

```make
get:
	flutter pub get

gen:
	dart run build_runner build --delete-conflicting-outputs

translate:
	dart run slang

common-prepare:  get gen translate
```

`.github/workflows/build.yml:55-58` — the entire automated gate:

```yaml
      - name: Prepare
        run: make linux-amd64-prepare
      - name: Test
        run: flutter test
```

`make linux-amd64-prepare` is `common-prepare` + `linux-amd64-libs`, and
`linux-amd64-libs` (`Makefile:480-482`) `curl`s a core tarball from a GitHub
release. No test loads that native library, so the gate is needlessly coupled
to a third-party download.

Repo conventions to match:
- The Makefile uses tab-indented recipes and simple target chaining
  (`common-prepare: get gen translate`). Match that style.
- Workflow steps use `- name:` + `run:` with two-space YAML indentation.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps | `flutter pub get` | exit 0, writes `pubspec.lock` |
| Codegen | `make gen` | exit 0 |
| Translations | `make translate` | exit 0 |
| Analyze | `flutter analyze` | exit 0 once the backlog is triaged |
| Custom lints | `dart run custom_lint` | exit 0 once triaged |
| Format check | `dart format --set-exit-if-changed --line-length 120 lib test` | exit 0 |
| Tests | `flutter test` | all pass |

## Scope

**In scope** (the only files you should modify):
- `pubspec.yaml`
- `analysis_options.yaml`
- `Makefile`
- `.github/workflows/build.yml`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- Any file under `lib/` — this plan adds the gate; it does **not** fix the
  violations the gate reports. Fixing lint findings in the same change makes
  the diff unreviewable and mixes mechanical churn with a policy change.
- `pubspec.lock` by hand — let `flutter pub get` regenerate it.
- The `hiddify-core/` submodule.
- Adding a mocking library — that belongs to the test-writing plans.

## Git workflow

- Branch: `advisor/001-verification-baseline`
- One commit per step. Message style matches this repo's recent history
  (see `git log`): short imperative subject, e.g.
  `Declare flutter_test explicitly instead of relying on a transitive`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Declare `flutter_test` explicitly

In `pubspec.yaml`, uncomment the two `flutter_test` lines so
`dev_dependencies` begins:

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  lint: ^2.3.0
```

**Verify**: `flutter pub get` → exit 0. Then
`grep -A2 "^dev_dependencies:" pubspec.yaml` shows `flutter_test` uncommented,
and `grep -A1 "^  flutter_test:" pubspec.lock` no longer says
`dependency: transitive` (it should read `dependency: "direct dev"`).

**If `flutter pub get` fails with a version conflict**: that conflict is the
reason the line was commented out. Do not re-comment it. STOP and report the
exact conflict.

### Step 2: Install the lint packages the config already references

Add to `dev_dependencies` in `pubspec.yaml`:

```yaml
  custom_lint: ^0.7.0
  riverpod_lint: ^2.6.0
```

`riverpod_lint` is the package that owns the `provider_parameters` rule
enabled at the bottom of `analysis_options.yaml`. `custom_lint` is the plugin
host. Without both, that rule cannot run.

**Verify**: `flutter pub get` → exit 0; `grep -c "custom_lint:\|riverpod_lint:" pubspec.yaml`
returns `2`.

### Step 3: Exclude generated files from analysis

In `analysis_options.yaml`, extend the existing `exclude:` list to:

```yaml
  exclude:
    - "hiddify-core/**"
    - "**.g.dart"
    - "**.freezed.dart"
    - "**.mapper.dart"
    - "lib/gen/**"
    - "lib/hiddifycore/generated/**"
```

**Verify**: `grep -c '\- "' analysis_options.yaml` returns at least `6`.

### Step 4: Add Makefile verification targets

Append these targets to the `Makefile` (recipes must be TAB-indented):

```make
# Codegen without downloading platform native libs - enough to analyze and test.
verify-prepare: get gen translate

analyze: verify-prepare
	flutter analyze
	dart run custom_lint

format-check:
	dart format --set-exit-if-changed --line-length 120 lib test

test: verify-prepare
	flutter test

check: analyze format-check test
```

**Verify**: `grep -nE "^(verify-prepare|analyze|format-check|test|check):" Makefile`
returns 5 lines.

### Step 5: Record the analysis backlog without blocking on it

Run `make analyze` and capture the output. **Do not fix the findings.**

Count them: `flutter analyze 2>&1 | tail -5` reports a total.

- If the total is **0**, go to Step 6 and wire the gate as blocking.
- If the total is **greater than 0**, still wire it in Step 6 but with
  `continue-on-error: true` on the analyze step, and record the exact count in
  your final report plus in the `plans/README.md` notes, so a follow-up plan
  can burn the backlog down before the gate is made blocking.

**Verify**: you can state a specific number of analyzer findings.

### Step 6: Wire the gate into CI and decouple the test job from the core download

In `.github/workflows/build.yml`, change the `test` job's steps
(currently lines 55-58) to:

```yaml
      - name: Prepare
        run: make verify-prepare
      - name: Analyze
        run: make analyze
        continue-on-error: true   # remove once the backlog from step 5 is cleared
      - name: Format check
        run: make format-check
        continue-on-error: true   # remove once formatting is normalized
      - name: Test
        run: flutter test
```

`make verify-prepare` replaces `make linux-amd64-prepare`, dropping the core
tarball download the tests never used.

If Step 5 reported 0 findings, omit the `continue-on-error` line on Analyze.
Apply the same logic to Format check by running `make format-check` locally
first.

**Verify**: `grep -n "verify-prepare\|make analyze\|format-check" .github/workflows/build.yml`
shows the three new references, and `grep -c "linux-amd64-prepare" .github/workflows/build.yml`
returns `0` for the `test` job (other jobs may legitimately still use it —
check the line numbers reported and confirm none of them are inside the
`test:` job block, which starts at `build.yml:42`).

### Step 7: Confirm the suite still passes

**Verify**: `make test` → all tests pass (3 test files: `ip_utils_test.dart`,
`profile_parser_test.dart`, `migration_test.dart`).

## Test plan

This plan adds no new tests — it makes the existing ones trustworthy and adds
static analysis. Verification is entirely through the commands above.

The one behavioral assertion: after Step 1, `flutter test` must still pass
using an explicitly-declared `flutter_test` rather than a transitive one.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -A2 "^dev_dependencies:" pubspec.yaml` shows `flutter_test:` uncommented
- [ ] `grep -A1 "^  flutter_test:" pubspec.lock` shows `dependency: "direct dev"`
- [ ] `grep -c "custom_lint:" pubspec.yaml` returns `1` and `grep -c "riverpod_lint:" pubspec.yaml` returns `1`
- [ ] `grep -c 'freezed.dart' analysis_options.yaml` returns `1`
- [ ] `make test` exits 0
- [ ] `make analyze` runs to completion (exit code may be non-zero if the backlog is non-empty — that is recorded, not fixed)
- [ ] `grep -c "verify-prepare" .github/workflows/build.yml` returns at least `1`
- [ ] `git status` shows changes ONLY to `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `Makefile`, `.github/workflows/build.yml`, `plans/README.md`
- [ ] `plans/README.md` status row updated, including the analyzer finding count from Step 5

## STOP conditions

Stop and report back (do not improvise) if:

- `flutter pub get` fails with a dependency conflict after uncommenting
  `flutter_test` (Step 1) or after adding the lint packages (Step 2). Report
  the exact conflicting constraints. Do NOT resolve it by re-commenting the
  dependency or by adding `dependency_overrides`.
- `flutter analyze` reports more than 300 findings — that is large enough that
  the exclude list is probably still wrong (most likely generated files are
  being scanned). Report the top 10 findings and which files they are in.
- `dart run custom_lint` fails to start (plugin load error) rather than simply
  reporting findings.
- `make test` fails after Step 1 when it passed before. The declared
  `flutter_test` version may differ from the transitive one.
- Any step would require editing a file under `lib/`.

## Maintenance notes

- The `continue-on-error: true` flags added in Step 6 are temporary. They exist
  so this plan can land without a giant lint-fixing diff. A follow-up should
  burn the backlog down and remove them — until then the gate reports but does
  not enforce, and a reviewer must not mistake a green check for a clean tree.
- `flutter analyze` does **not** run `custom_lint`; it needs its own
  `dart run custom_lint` invocation. Both are in the `analyze` target — keep
  them together if that target is ever refactored.
- The `test` job no longer downloads the prebuilt core. If a future test needs
  the native library, it will fail with a load error; that test should use
  `linux-amd64-prepare` explicitly rather than reverting this change for
  everyone.
- Deliberately deferred: adding a mocking library (`mocktail`). It is only
  needed once tests that require fakes are written, and bundling it here would
  widen this plan's blast radius for no immediate gain.
