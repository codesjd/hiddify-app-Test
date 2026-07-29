# Plan 005: Stop re-sorting the whole proxy list and re-parsing the whole log buffer on every core tick

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c99aed7f..HEAD -- lib/features/proxy/overview/proxies_overview_notifier.dart lib/features/log/data/log_repository.dart lib/features/log/overview/logs_overview_notifier.dart`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/001-restore-verification-baseline.md` (only for a
  trustworthy `flutter test`; the changes themselves are independent)
- **Category**: perf
- **Planned at**: commit `c99aed7f`, 2026-07-28

## Why this matters

Two hot paths in this app do expensive work at the Go core's native emission
rate and then throw most of it away.

The proxy list re-runs a full comparator sort over every outbound and rebuilds
the whole grid on every emission — with a few hundred proxies streaming live
latency updates, that is continuous O(n log n) work plus a full widget rebuild
on the UI isolate. A throttle for exactly this used to exist and is currently
commented out.

The log pipeline parses the entire ≤300-entry buffer into `LogEntity` objects
*before* a 250 ms throttle that discards nearly all of it — so while the logs
page is open, every incoming core line costs ~300 object allocations of which
at most four batches per second survive.

Both fixes are small and mechanical. Neither changes what the user sees, only
how often it is recomputed.

## Current state

### Proxy list — the throttle is commented out

`lib/features/proxy/overview/proxies_overview_notifier.dart:64-93`. The dead
code and the live code are adjacent:

```dart
    final sortBy = ref.watch(proxiesSortNotifierProvider);
    // yield* ref
    //     .watch(proxyRepositoryProvider)
    //     .watchProxies()
    //     .throttleTime(
    //       const Duration(milliseconds: 100),
    //       leading: false,
    //       trailing: true,
    //     )
    //     .map(
    //       (event) => event.getOrElse(
    //         (err) {
    //           loggy.warning("error receiving proxies", err);
    //           throw err;
    //         },
    //       ),
    //     )
    //     .asyncMap((proxies) async => _sortOutbounds(proxies, sortBy));
    return ref
        .watch(proxyRepositoryProvider)
        .watchProxies()
        .map(
          (event) => event.getOrElse((err) {
            loggy.warning("error receiving proxies", err);
            throw err;
          }),
        )
        .asyncMap((proxies) async => await _sortOutbounds(proxies, sortBy));
  }
```

`_sortOutbounds` (same file, around `:142-165`) runs a full `sortedWith`
comparator sort per emission. `lib/features/proxy/overview/proxies_overview_page.dart:20`
watches the whole provider, so each emission rebuilds the `GridView.builder`
subtree.

### Log pipeline — parse happens before the throttle

`lib/features/log/data/log_repository.dart:44-53`:

```dart
  @override
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs() {
    return singbox
        .watchLogs(logPathResolver.coreFile().path)
        .map((event) => event.map(LogParser.parseLogProto).toList())
        .handleExceptions((error, stackTrace) {
          loggy.warning("error watching logs", error, stackTrace);
          return LogFailure.unexpected(error, stackTrace);
        });
  }
```

The consumer throttles *after* that map,
`lib/features/log/overview/logs_overview_notifier.dart:50-55`:

```dart
        .read(logRepositoryProvider)
        .requireValue
        .watchLogs()
        .throttle((_) => Stream.value(_listener?.isPaused ?? false), leading: false, trailing: true)
        .throttleTime(const Duration(milliseconds: 250), leading: false, trailing: true)
        .asyncMap((event) async {
```

Repo conventions to match:
- `rxdart` is already a dependency (`pubspec.yaml`) and `throttleTime` is
  already used in `logs_overview_notifier.dart:54`, so the import and idiom
  exist in-repo.
- Providers in this file are Riverpod codegen (`@riverpod`) returning `Stream`s.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps | `flutter pub get` | exit 0 |
| Codegen | `make gen` | exit 0 |
| Tests | `flutter test` | all pass |
| Analyze | `flutter analyze lib/features/proxy lib/features/log` | no new errors |

## Scope

**In scope** (the only files you should modify):
- `lib/features/proxy/overview/proxies_overview_notifier.dart`
- `lib/features/log/data/log_repository.dart`
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `lib/features/log/overview/logs_overview_notifier.dart` — its existing
  throttles stay exactly as they are. This plan moves work *earlier* in the
  pipeline; it does not remove the downstream throttling.
- `lib/hiddifycore/hiddify_core_service.dart` — there is a commented-out
  throttle there too (`:291-294`). Throttling at the source would affect every
  consumer of `watchGroup()`, which is a wider behavioral change. Not here.
- `_sortOutbounds`'s in-place mutation of the received protobuf
  (`:174-176`) — a real separate bug (it makes previous and next state the same
  object, so `select`/equality cannot distinguish them). Recorded as an
  unplanned finding; fixing it changes state-identity semantics and needs its
  own verification.
- Adding `select()` to widgets that watch the whole active-proxy provider —
  also recorded separately.

## Git workflow

- Branch: `advisor/005-throttling`
- One commit per step. Message style matches recent history, e.g.
  `Throttle the outbounds stream before sorting`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reinstate the proxy stream throttle

In `proxies_overview_notifier.dart`, add a `throttleTime` to the **live**
return statement, between `watchProxies()` and `.map(`:

```dart
    return ref
        .watch(proxyRepositoryProvider)
        .watchProxies()
        .throttleTime(
          const Duration(milliseconds: 250),
          leading: true,
          trailing: true,
        )
        .map(
          (event) => event.getOrElse((err) {
            loggy.warning("error receiving proxies", err);
            throw err;
          }),
        )
        .asyncMap((proxies) async => await _sortOutbounds(proxies, sortBy));
```

Note `leading: true` — differing from the commented-out version's
`leading: false`. With `leading: false` the very first emission is delayed by
the full window, which makes the proxy list appear to load slowly. `leading: true`
emits the first value immediately and then throttles.

Then **delete the commented-out block** (`:67-83`) — it is now misleading, and
leaving two versions of the same pipeline is exactly how the throttle got lost
in the first place.

Confirm `rxdart` is imported in this file; if not, add
`import 'package:rxdart/rxdart.dart';` alongside the existing imports.

**Verify**: `grep -c "throttleTime" lib/features/proxy/overview/proxies_overview_notifier.dart`
returns `1`; `grep -c "// yield\* ref" lib/features/proxy/overview/proxies_overview_notifier.dart`
returns `0`; `flutter analyze lib/features/proxy` → no errors.

### Step 2: Move the log parse after the throttle

In `log_repository.dart`, throttle before mapping:

```dart
  @override
  Stream<Either<LogFailure, List<LogEntity>>> watchLogs() {
    return singbox
        .watchLogs(logPathResolver.coreFile().path)
        .throttleTime(
          const Duration(milliseconds: 250),
          leading: true,
          trailing: true,
        )
        .map((event) => event.map(LogParser.parseLogProto).toList())
        .handleExceptions((error, stackTrace) {
          loggy.warning("error watching logs", error, stackTrace);
          return LogFailure.unexpected(error, stackTrace);
        });
  }
```

Add `import 'package:rxdart/rxdart.dart';` if not already present.

The downstream throttle in `logs_overview_notifier.dart:54` stays. It is now
mostly redundant but harmless, and removing it is a behavior change to the
pause-aware `throttle` above it — leave it alone.

**Verify**: `grep -c "throttleTime" lib/features/log/data/log_repository.dart`
returns `1`; `flutter analyze lib/features/log` → no errors.

### Step 3: Confirm no regression

**Verify**: `flutter test` → all tests pass.

### Step 4: Manual smoke check (required — no automated coverage)

Neither path has test coverage. Perform and report:

1. Run the app, connect to any profile with several proxies.
2. Open the proxy list. Confirm it populates **immediately** (this is what
   `leading: true` buys) and that latency numbers still update live.
3. Open the logs page with the core log level raised. Confirm lines still
   stream and the page is responsive.

If you cannot run the app, say so explicitly rather than claiming this passed.

## Test plan

- **Automated**: `flutter test` stays green (regression check only — neither
  file has direct coverage).
- **Manual**: Step 4.
- **Follow-up** (not here): a stream test asserting that N rapid source
  emissions produce at most ceil(N × interval / 250ms) downstream emissions
  would pin this properly, but it needs a fake `ProxyRepository` and no mocking
  library is installed yet (see plan 001).

## Done criteria

Machine-checkable where possible. ALL must hold:

- [ ] `grep -c "throttleTime" lib/features/proxy/overview/proxies_overview_notifier.dart` returns `1`
- [ ] `grep -c "// yield\* ref" lib/features/proxy/overview/proxies_overview_notifier.dart` returns `0`
- [ ] `grep -c "throttleTime" lib/features/log/data/log_repository.dart` returns `1`
- [ ] In `log_repository.dart`, `throttleTime` appears on a line *before* the `.map((event) => event.map(LogParser.parseLogProto)` line
- [ ] `flutter analyze lib/features/proxy lib/features/log` reports no new errors
- [ ] `flutter test` exits 0
- [ ] `git status` shows changes ONLY to the two source files and `plans/README.md`
- [ ] Step 4's manual check performed and result stated (including "could not run")
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The commented-out throttle block is already gone or a `throttleTime` is
  already present in `proxies_overview_notifier.dart` — someone changed this;
  report current state before editing.
- Adding the throttle makes the proxy list visibly slow to populate. That means
  `leading` is set wrong; confirm it is `true` and report if the symptom
  persists.
- `rxdart`'s `throttleTime` signature does not accept `leading`/`trailing` named
  parameters in the installed version — report the actual signature rather than
  guessing an equivalent.
- Any existing test starts failing.

## Maintenance notes

- 250 ms is a judgment call, not a measured optimum: fast enough that latency
  numbers feel live, slow enough to collapse bursts. If proxy latency updates
  feel laggy in real use, lower it before removing it.
- **Do not re-comment code you are replacing.** The commented-out throttle in
  `proxies_overview_notifier.dart` is precisely why this regression was
  invisible — two versions of a pipeline, one live, one not, and no way to tell
  from a diff which is which. Delete, and let git history hold the old version.
- There is a third commented-out throttle at
  `lib/hiddifycore/hiddify_core_service.dart:291-294`. Throttling there would
  make this plan's Step 1 redundant but affects every `watchGroup()` consumer —
  if someone enables it later, revisit the throttle added here rather than
  stacking both.
- A reviewer should check the *ordering* in Step 2 specifically: a
  `throttleTime` placed after the `.map` compiles fine and looks correct while
  fixing nothing.
