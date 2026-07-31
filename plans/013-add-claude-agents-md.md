# Plan 013: Add a CLAUDE.md / AGENTS.md so agents stop tripping over codegen

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- Makefile pubspec.yaml .gitignore`
> If any of these changed since this plan was written, re-verify the Makefile
> targets and codegen setup referenced below against the live files before
> proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: 001 (the `make verify-prepare`/`analyze`/`test`/`check` targets this doc documents were added by that plan)
- **Category**: dx
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

This repo has no `CLAUDE.md` or `AGENTS.md`. That matters specifically for
agent-executed work (including every other plan in this directory): 69 files
declare a `.g.dart` part and dozens more a `.freezed.dart`/`.mapper.dart`
part, none of them committed (`.gitignore:40-42` excludes all three
patterns), and nothing compiles until `make gen` (build_runner) and
`make translate` (slang) run once. An agent that clones this repo, edits a
file under `lib/`, and immediately runs `flutter test` or `flutter analyze`
gets a wall of "Target of URI doesn't exist" errors for every generated part
file — and without this context, a plausible-looking "fix" is to start
hand-writing `.g.dart`/`.freezed.dart` files, which is always wrong and wastes
the whole session. The team already has an agent-facing doc
(`SLANG.md`, a Claude Code custom-command spec for the translation workflow,
wired into `.aider.conf.yml:388-389`) but it's aider-specific and Claude
Code's own tooling (this `improve` skill included) doesn't discover it. A
`CLAUDE.md` fixes that by being the first thing read.

## Current state

Facts this doc needs to encode, gathered from the repo as it exists today:

- **Codegen is mandatory before anything compiles.** `make verify-prepare`
  (`Makefile:79`) runs `get` (`flutter pub get`) + `gen`
  (`dart run build_runner build --delete-conflicting-outputs`) + `translate`
  (`dart run slang`) — added by plan 001 specifically so analysis/tests can
  run without also downloading platform native libraries.
- **Verification commands** (all added by plan 001, `Makefile:69-94`):
  - `make verify-prepare` — codegen only, no native lib download
  - `make analyze` — `flutter analyze` (custom_lint is currently disabled;
    see the `ponytail:` comment at `Makefile:81-82` — do not re-enable it
    without checking whether the `analyzer_plugin` version pin it refers to
    in `pubspec.yaml` has been resolved upstream)
  - `make format-check` — `dart format --set-exit-if-changed --line-length 120 lib test`
  - `make test` — `flutter test`
  - `make check` — all three of the above
- **The `hiddify-core` directory is a git submodule** (the Go backend); it is
  not needed to build/test the Dart app's unit tests, but a fresh clone won't
  have it checked out until `git submodule update --init --recursive` runs.
  `CONTRIBUTING.md` (see plan 014, landing alongside this one) does not
  mention this step at all today.
- **Directory layout**: `lib/core/` (cross-cutting infra: db, preferences, http
  client, router, theming), `lib/features/*` (one directory per feature,
  each typically split into `data/` (repositories/parsers), `model/`
  (freezed entities), `notifier/` (Riverpod state), and a UI widget
  directory), `lib/singbox/` (the Dart-side model/bridge for the Go core's
  config format), `lib/hiddifycore/` (generated gRPC/protobuf client for the
  Go core — do not hand-edit `lib/hiddifycore/generated/`).
- **State management**: Riverpod 2 (`hooks_riverpod`) with code generation
  (`riverpod_generator`) is standard, but plenty of hand-written
  `StateNotifierProvider`s exist too — check the nearest sibling file in the
  same feature directory for which style to match before adding a new
  provider.
- **Data classes**: `freezed` for immutable models (see
  `lib/core/model/app_info_entity.dart` for a single-variant example, or
  `lib/features/connection/model/connection_status.dart` for a `sealed
  class` union-type example). `dart_mappable` is used in exactly 3 files as a
  legacy exception — don't use it for anything new (see the "Findings
  recorded but NOT planned" section of `plans/README.md` for context).
- **Testing**: `flutter_test` only, no mocking library is installed
  (deliberately deferred — see plan 001's maintenance notes). Prefer
  subclass-and-override fakes (see `test/features/profile/data/profile_parser_test.dart`
  after plan 008 lands, for one example) or `SharedPreferences.setMockInitialValues`
  for preferences-backed code, over reaching for a new dependency.
- **Localization**: `slang` (`make translate`), source strings live under
  `assets/translations/`; see `SLANG.md` at the repo root for the existing
  (aider-specific) translation workflow doc — this new `CLAUDE.md` should
  point to it rather than duplicating it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Analyze | `make analyze` | runs to completion |
| Tests | `make test` | all pass |

## Scope

**In scope**:
- `CLAUDE.md` (create, at repo root)

**Out of scope**:
- `AGENTS.md` — creating both would just be two copies of the same content to
  keep in sync; `CLAUDE.md` is the more specific, already-precedented name in
  this ecosystem (this very plan file is itself part of a Claude Code skill's
  output). If the operator wants an `AGENTS.md` as well, that's a follow-up
  decision, not part of this plan.
- `CONTRIBUTING.md`'s content — that's plan 014; don't fix its inaccuracies
  here, only reference it.
- `SLANG.md` — do not modify it; `CLAUDE.md` should point to it, not replace
  or duplicate its content.
- Any actual code, lint, or test fixes — this plan only adds documentation.

## Git workflow

- Branch: `advisor/013-add-claude-md`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Add CLAUDE.md documenting codegen and verification workflow for agents`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `CLAUDE.md`

Create `CLAUDE.md` at the repo root with this content (adjust only if a Step
2 verification below reveals something has drifted from what's asserted
here):

```markdown
# CLAUDE.md

Guidance for AI coding agents working in this repo (Hiddify's Flutter
client). If you are a human, `CONTRIBUTING.md` is also relevant.

## Before anything else: generate code

Nothing compiles until codegen runs once. 69+ files declare a `.g.dart` part
and dozens more a `.freezed.dart`/`.mapper.dart` part — none are committed
(gitignored). If you see "Target of URI doesn't exist" errors for a file
ending in `.g.dart`/`.freezed.dart`/`.mapper.dart`, this is why — **do not
hand-write these files**, run codegen instead:

    make verify-prepare   # flutter pub get + build_runner + slang — no native lib download

## Verification commands

    make verify-prepare   # codegen only (fast, no platform downloads)
    make analyze          # flutter analyze
    make format-check     # dart format --set-exit-if-changed --line-length 120 lib test
    make test             # flutter test
    make check            # all three of the above

Run the narrowest one that covers your change before considering it done. Do
not run the platform-specific `make <platform>-prepare` targets unless you
are specifically working on native/platform integration — they download
prebuilt core binaries and are unrelated to Dart-level tests.

## The `hiddify-core` submodule

`hiddify-core/` is a git submodule (the Go backend: gRPC service, sing-box/
xray-core forks, `ray2sing` link parsers). It is not required for Dart unit
tests. If you need it, initialize with:

    git submodule update --init --recursive

## Directory layout

- `lib/core/` — cross-cutting infrastructure: db (drift), preferences, http
  client, router, theming.
- `lib/features/<feature>/` — one directory per feature, typically split
  into `data/` (repositories, parsers), `model/` (freezed entities),
  `notifier/` (Riverpod state), and a UI widget directory. Match the nearest
  sibling feature's structure when adding a new one.
- `lib/singbox/` — Dart-side model for the Go core's config format.
- `lib/hiddifycore/` — generated gRPC/protobuf client for the Go core.
  `lib/hiddifycore/generated/` is generated from `.proto` files — never
  hand-edit it.

## Conventions

- **State management**: Riverpod 2 (`hooks_riverpod`), mostly code-generated
  providers (`riverpod_generator`) alongside some hand-written
  `StateNotifierProvider`s. Match whichever style the nearest sibling
  provider in the same feature uses.
- **Data classes**: `freezed`. See `lib/core/model/app_info_entity.dart` for
  a single-variant example, `lib/features/connection/model/connection_status.dart`
  for a `sealed class` union-type example. `dart_mappable` exists in exactly
  3 legacy files — do not use it for anything new.
- **Testing**: `flutter_test` only, no mocking library installed
  (deliberately — see `plans/001-restore-verification-baseline.md`'s
  maintenance notes if that directory still exists). Prefer a subclass that
  overrides the one method you need (see
  `test/features/profile/data/profile_parser_test.dart`) or
  `SharedPreferences.setMockInitialValues` for preferences-backed code,
  before reaching for a new test dependency.
- **Localization**: `slang` (`make translate`); see `SLANG.md` at the repo
  root for the existing translation workflow.
- **Error handling**: `fpdart`'s `Either`/`TaskEither` for recoverable
  failures in data/repository layers — see
  `lib/features/profile/data/profile_parser.dart` for the pattern.

## What NOT to do

- Don't hand-edit any generated file: `*.g.dart`, `*.freezed.dart`,
  `*.mapper.dart`, `lib/gen/**`, `lib/hiddifycore/generated/**`.
- Don't add a new state-management, serialization, or mocking library without
  checking whether an existing one already covers it (this repo already has
  more serialization stacks — freezed, json_serializable, dart_mappable —
  than it needs; don't add a fourth).
- Don't run `flutter pub upgrade` casually — several dependencies are
  version-pinned deliberately (see comments in `pubspec.yaml`).
```

**Verify**: `test -f CLAUDE.md && echo exists` → prints `exists`.

### Step 2: Confirm every command referenced in the new doc actually works

Run each command listed in the "Verification commands" section of the new
`CLAUDE.md` and confirm it behaves as documented:

**Verify**: `make verify-prepare` → exit 0. `make analyze` → runs to
completion (exit code may be non-zero if the plan-001 analyzer backlog is
still non-empty — that's expected, the doc says "runs to completion", not
"exits 0"). `make test` → all pass.

**If any command fails to run at all** (not just reports findings, but
errors out or isn't found): the doc is wrong about that command — fix the
`CLAUDE.md` text to match reality rather than leaving a broken instruction in
place, and note the discrepancy in your final report.

## Test plan

No automated test applies to a documentation file. Verification is entirely
Step 2 above: every command the doc tells an agent to run must actually run.

## Done criteria

- [ ] `CLAUDE.md` exists at the repo root
- [ ] Every command in its "Verification commands" section was run once during this plan and behaved as documented
- [ ] `git status` shows changes only to `CLAUDE.md`, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any Makefile target referenced in the doc doesn't exist or behaves
  differently than plan 001 described (drift since this plan was written) —
  re-read the live `Makefile` and correct the doc to match before finishing,
  rather than publishing an inaccurate doc.
- You're unsure whether to also create `AGENTS.md` — don't guess; this plan
  explicitly scoped that out (see Scope), leave it for the operator to
  request separately.

## Maintenance notes

- This doc will drift the same way any doc does — whoever changes the
  Makefile's verification targets, the directory layout, or the state
  management convention should update `CLAUDE.md` in the same change. There
  is no automated check for this; it relies on the next contributor (human or
  agent) noticing and fixing drift, same as `CONTRIBUTING.md` did before plan
  014.
- If `AGENTS.md` is added later as a separate decision, consider making one
  of the two files a thin pointer to the other rather than maintaining
  duplicate content.
