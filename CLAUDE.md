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
