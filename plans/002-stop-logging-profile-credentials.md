# Plan 002: Stop writing proxy credentials into logs and crash telemetry

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c99aed7f..HEAD -- lib/features/profile/details/profile_details_notifier.dart lib/core/analytics/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (can land in parallel with 001)
- **Category**: security
- **Planned at**: commit `c99aed7f`, 2026-07-28

## Why this matters

Hiddify is a censorship-circumvention client. A user's proxy outbound block
contains the server host, port, and the per-user credential for that server
(vmess/vless UUIDs, trojan/hysteria/shadowsocks passwords, SSH keys). Leaking
one is equivalent to leaking the account, and identifies both the user's
provider and the user.

Today, opening a profile's details page writes that entire block to the
application log at INFO level. Three separate egress paths follow from that
one line: a plaintext file on every desktop install, a "share app logs" menu
item users are explicitly asked to use when reporting bugs, and Sentry
breadcrumbs (analytics defaults to on).

This plan removes the log statement and adds a scrubbing layer so a future
re-introduction is contained rather than immediately dangerous.

## Current state

Files involved:

- `lib/features/profile/details/profile_details_notifier.dart` — builds the
  profile-details view state; contains the offending log call.
- `lib/core/logger/logger_controller.dart` — sets the effective log level and
  installs the file printer.
- `lib/core/analytics/analytics_logger.dart` — turns log records into Sentry
  breadcrumbs.
- `lib/core/analytics/analytics_filter.dart` — the existing Sentry scrubbing
  hook. This is where the new redaction belongs.
- `lib/core/analytics/analytics_controller.dart` — wires the hooks into
  `SentryFlutter.init`.

**The leak**, `profile_details_notifier.dart:47-62`. `profContent` is built
from the profile's generated sing-box config, filtered down to the real
outbounds, then logged verbatim:

```dart
      final endpoints = jsonObject['endpoints'] as List? ?? [];
      profContent = '{"outbounds": ${json.encode(outbounds)},"endpoints":${json.encode(endpoints)} }';
      loggy.info(profContent);
    } catch (e, st) {
      loggy.error('Error parsing profile-content JSON', e, st);
```

`profContent` is already returned to the caller inside `ProfileDetailsState`
(a few lines below, `configContent:`), so the log line is redundant — it looks
like leftover debugging.

**Why INFO reaches disk**, `logger_controller.dart:27-33`:

```dart
  static Future<void> postInit(bool debugMode) async {
    final logLevel = debugMode && false ? LogLevel.all : LogLevel.info;
    final logToFile = debugMode || (!Platform.isAndroid && !Platform.isIOS);

    if (!logToFile || kIsWeb) _instance.removePrinter("app");

    Loggy.initLoggy(logPrinter: _instance, logOptions: LogOptions(logLevel));
  }
```

`debugMode && false` is always false, so the level is always `LogLevel.info`.
`logToFile` is true on every desktop platform. So INFO records always land in
the on-disk app log on desktop.

**Why INFO reaches Sentry**, `analytics_logger.dart:6-12`:

```dart
class SentryLoggyIntegration extends LoggyPrinter implements Integration<SentryOptions> {
  SentryLoggyIntegration({LogLevel minBreadcrumbLevel = LogLevel.info, LogLevel minEventLevel = LogLevel.error})
    : _minBreadcrumbLevel = minBreadcrumbLevel,
      _minEventLevel = minEventLevel;
```

The breadcrumb threshold is INFO, so the record becomes a breadcrumb attached
to the next captured event.

**The existing scrub hook**, `analytics_filter.dart:8-13` — note it only
replaces the `user` object and never touches `breadcrumbs`:

```dart
FutureOr<SentryEvent?> sentryBeforeSend(SentryEvent event, Hint hint) async {
  if (!canSendEvent(event.throwable)) return null;
  return event.copyWith(
    user: SentryUser(email: "", username: "", ipAddress: "0.0.0.0"),
  );
}
```

**Where it is wired**, `analytics_controller.dart:42-56` (abridged):

```dart
      await SentryFlutter.init((options) {
        options.dsn = dsn;
        options.debug = kDebugMode;
        ...
        options.addIntegration(sentryLogger);
        options.beforeSend = sentryBeforeSend;
```

Repo conventions to match:
- This codebase uses `loggy` via mixins; log calls read `loggy.info(...)`,
  `loggy.warning(...)`, `loggy.error(msg, e, st)`.
- Top-level functions in `lib/core/analytics/` are plain functions, not class
  members (see `sentryBeforeSend`, `canSendEvent`). Follow that shape.
- Tests live under `test/` mirroring the `lib/` path, use
  `package:flutter_test/flutter_test.dart`, double-quoted strings, and
  `group("<functionName>", ...)` wrapping `test("Should ...", ...)`. See
  `test/features/profile/data/profile_parser_test.dart:1-13`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps | `flutter pub get` | exit 0 |
| Codegen | `make gen` | exit 0 |
| Tests | `flutter test` | all pass |
| Targeted test | `flutter test test/core/analytics/analytics_filter_test.dart` | all pass |

(If plan 001 has landed, `make test` also works and is preferred.)

## Scope

**In scope** (the only files you should modify):
- `lib/features/profile/details/profile_details_notifier.dart`
- `lib/core/analytics/analytics_filter.dart`
- `lib/core/analytics/analytics_controller.dart`
- `test/core/analytics/analytics_filter_test.dart` (create)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `lib/core/logger/logger_controller.dart` — the `debugMode && false` on line
  28 is obviously suspicious, but changing the global log level is a separate
  behavioral decision that affects every log site in the app. Note it in your
  report; do not change it here.
- `lib/core/analytics/analytics_logger.dart` — do not change the breadcrumb
  threshold. Scrubbing is the fix; lowering the volume is a different debate.
- `lib/utils/sentry_utils.dart` — it contains a second, divergent copy of
  `sentryBeforeSend`/`canSendEvent`. Consolidating the two is a real cleanup
  but it is not this plan's job; record it in your report.
- Any change to what `generateConfig` returns.

## Git workflow

- Branch: `advisor/002-stop-logging-credentials`
- Commit per step. Message style matches recent history, e.g.
  `Stop logging full proxy config content at INFO level`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Delete the log statement

In `lib/features/profile/details/profile_details_notifier.dart`, remove the
line:

```dart
      loggy.info(profContent);
```

Leave everything around it untouched — `profContent` is still assigned on the
line above and still consumed by `ProfileDetailsState` below.

**Verify**: `grep -n "loggy.info(profContent)" lib/features/profile/details/profile_details_notifier.dart`
returns nothing, and `grep -n "profContent" lib/features/profile/details/profile_details_notifier.dart`
still returns the assignment and the `configContent:` use.

### Step 2: Add a redaction helper

In `lib/core/analytics/analytics_filter.dart`, add a top-level function that
redacts credential-bearing content from an arbitrary string:

```dart
/// Keys whose values are credential-grade in a sing-box outbound: leaking one
/// identifies the user's provider and grants access to it. Also covers the
/// user-info portion of subscription URLs.
const _sensitiveJsonKeys = <String>[
  "password",
  "uuid",
  "private_key",
  "pre_shared_key",
  "psk",
  "auth",
  "auth_str",
  "token",
  "secret",
  "license_key",
];

/// Best-effort redaction for text that may embed proxy configuration or
/// subscription URLs. Applied to Sentry breadcrumbs and event messages so a
/// stray log call cannot ship credentials to telemetry.
String redactSensitive(String input) {
  var out = input;
  for (final key in _sensitiveJsonKeys) {
    // "key": "value"  ->  "key": "[redacted]"
    out = out.replaceAll(
      RegExp('"$key"\\s*:\\s*"[^"]*"', caseSensitive: false),
      '"$key": "[redacted]"',
    );
  }
  // scheme://user:pass@host  ->  scheme://[redacted]@host
  out = out.replaceAll(
    RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s@]+@'),
    r'$1[redacted]@',
  );
  return out;
}
```

**Verify**: `flutter analyze lib/core/analytics/analytics_filter.dart` reports
no errors (warnings about unused members are expected until Step 3).

### Step 3: Apply the redaction to breadcrumbs and event messages

Still in `analytics_filter.dart`, extend `sentryBeforeSend` and add a
`sentryBeforeBreadcrumb`:

```dart
FutureOr<SentryEvent?> sentryBeforeSend(SentryEvent event, Hint hint) async {
  if (!canSendEvent(event.throwable)) return null;
  final scrubbed = event.copyWith(
    user: SentryUser(email: "", username: "", ipAddress: "0.0.0.0"),
    breadcrumbs: event.breadcrumbs
        ?.map((b) => b.copyWith(message: b.message == null ? null : redactSensitive(b.message!)))
        .toList(),
  );
  final message = scrubbed.message;
  if (message == null) return scrubbed;
  return scrubbed.copyWith(
    message: SentryMessage(
      redactSensitive(message.formatted),
      template: message.template,
      params: message.params,
    ),
  );
}

Breadcrumb? sentryBeforeBreadcrumb(Breadcrumb? breadcrumb, Hint? hint) {
  if (breadcrumb == null) return null;
  final message = breadcrumb.message;
  if (message == null) return breadcrumb;
  return breadcrumb.copyWith(message: redactSensitive(message));
}
```

Then in `lib/core/analytics/analytics_controller.dart`, immediately after the
existing `options.beforeSend = sentryBeforeSend;` line (currently `:56`), add:

```dart
        options.beforeBreadcrumb = sentryBeforeBreadcrumb;
```

**Verify**: `grep -n "beforeBreadcrumb" lib/core/analytics/analytics_controller.dart`
returns one line; `flutter analyze lib/core/analytics/` reports no errors.

**If the Sentry SDK's `copyWith` on `SentryEvent`/`Breadcrumb` does not accept
these named parameters** (the installed version is `sentry_flutter ^8.14.0`),
adjust to whatever that version exposes — the requirement is "breadcrumb
messages and the event message pass through `redactSensitive`", not the exact
call shape. If you cannot achieve that in under 20 minutes, STOP and report.

### Step 4: Test the redaction

Create `test/core/analytics/analytics_filter_test.dart`, modelled on the
structure of `test/features/profile/data/profile_parser_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/analytics/analytics_filter.dart';

void main() {
  group("redactSensitive", () {
    test("Should redact a password field in outbound json", () {
      const input = '{"type":"trojan","server":"example.com","password":"s3cret"}';
      final out = redactSensitive(input);
      expect(out.contains("s3cret"), false);
      expect(out.contains("example.com"), true);
    });

    test("Should redact a uuid field", () {
      const input = '{"uuid":"8d1e4243-7ecf-4ffa-89ec-8b63eee75337"}';
      expect(redactSensitive(input).contains("8d1e4243"), false);
    });

    test("Should redact url user info", () {
      const input = "https://user:token123@example.com/sub";
      final out = redactSensitive(input);
      expect(out.contains("token123"), false);
      expect(out.contains("example.com"), true);
    });

    test("Should leave harmless text unchanged", () {
      const input = "connection established to example.com";
      expect(redactSensitive(input), input);
    });
  });
}
```

**Verify**: `flutter test test/core/analytics/analytics_filter_test.dart` →
4 tests pass.

### Step 5: Confirm nothing else regressed

**Verify**: `flutter test` → all tests pass.

## Test plan

- New file `test/core/analytics/analytics_filter_test.dart` covering
  `redactSensitive`: password field, uuid field, URL user-info, and a
  negative case proving harmless text is untouched.
- Structural pattern to follow: `test/features/profile/data/profile_parser_test.dart`
  (imports `package:flutter_test/flutter_test.dart`, `group` per function under
  test, `test("Should ...")` naming, double-quoted strings, no mocks).
- Verification: `flutter test` → all pass, including 4 new tests.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -rn "loggy.info(profContent)" lib/` returns no matches
- [ ] `grep -c "redactSensitive" lib/core/analytics/analytics_filter.dart` returns at least `3`
- [ ] `grep -c "beforeBreadcrumb" lib/core/analytics/analytics_controller.dart` returns `1`
- [ ] `flutter test test/core/analytics/analytics_filter_test.dart` exits 0 with 4 passing tests
- [ ] `flutter test` exits 0
- [ ] `flutter analyze lib/core/analytics/ lib/features/profile/details/profile_details_notifier.dart` reports no new errors
- [ ] `git status` shows changes ONLY to the four in-scope source files plus `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `profile_details_notifier.dart` no longer contains the `loggy.info(profContent)`
  line (someone already fixed it) — verify whether the Sentry scrubbing half is
  still needed and report.
- The `sentry_flutter` version installed does not expose `beforeBreadcrumb`, or
  `copyWith` does not accept `breadcrumbs`/`message` as described in Step 3.
- Removing the log line causes any test or analyzer error — it should be inert.
- You find additional log calls that emit profile content or subscription URLs
  (grep for `loggy.info` / `loggy.debug` near `config`, `profile`, `url`,
  `outbound`). Report them; do not fix them in this plan unless they are the
  same one-line shape, in which case list each one you removed.

## Maintenance notes

- `redactSensitive` is a defence-in-depth net, not a licence to log secrets.
  Reviewers should still reject any new log statement that emits profile
  content — the regex list will always lag the protocol list.
- Two known follow-ups deliberately left out of scope, both worth their own
  change: (1) `logger_controller.dart:28`'s `debugMode && false` makes
  `LogLevel.all` unreachable — either the `&& false` is vestigial or the
  intent changed, and someone should decide which; (2)
  `lib/utils/sentry_utils.dart` holds a second divergent copy of
  `sentryBeforeSend`/`canSendEvent` — only the `analytics_filter.dart` one is
  wired, so the other is dead or a trap.
- If a protocol with a new credential field name is added (see
  `lib/features/profile/details/json_editor.dart`'s schema tables for the
  current protocol list), add that field name to `_sensitiveJsonKeys`.
- What a reviewer should scrutinize: that Step 3's changes actually reach
  `SentryFlutter.init` — a scrub function that is defined but never assigned to
  `options` is the easy failure mode here.
