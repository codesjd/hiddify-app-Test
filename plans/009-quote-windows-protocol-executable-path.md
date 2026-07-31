# Plan 009: Quote the executable path in Windows URL-protocol registration

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- lib/core/router/deep_linking/url_protocol/windows_protocol.dart`
> If this file changed since this plan was written, compare the "Current
> state" excerpt below against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

`WindowsProtocolHandler.register` builds the Windows registry command line
that runs whenever the app's custom URL scheme (deep link) is invoked, and
writes it under `HKEY_CURRENT_USER\SOFTWARE\Classes\<scheme>\shell\open\command`
on every app launch. The arguments are quoted via the existing `_sanitize`
helper, but the executable path itself is not:

```dart
final cmd = '${executable ?? Platform.resolvedExecutable} ${args.join(' ')}';
```

If `Platform.resolvedExecutable` (or a future caller-supplied `executable`)
contains a space — the default Windows install path pattern
(`C:\Program Files\Hiddify\...`) is exactly this shape — an unquoted command
string is ambiguous about where the executable name ends and the first
argument begins. This is the classic unquoted-path resolution-order issue:
Windows tries each space-delimited prefix as a candidate executable
(`C:\Program.exe`, then `C:\Program Files\Hiddify.exe`, etc.) before the
intended one, so anything writable earlier in that path search order gets
launched instead when the registered scheme is invoked. The fix is one call
to the sanitizer that's already used for the arguments.

## Current state

- `lib/core/router/deep_linking/url_protocol/windows_protocol.dart` — the
  only file to change.

The file in full as it exists today:

```dart
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/core/router/deep_linking/url_protocol/protocol.dart';
import 'package:win32/win32.dart';

const _hive = HKEY_CURRENT_USER;

class WindowsProtocolHandler extends ProtocolHandler {
  @override
  void register(String scheme, {String? executable, List<String>? arguments}) {
    if (defaultTargetPlatform != TargetPlatform.windows) return;

    final prefix = _regPrefix(scheme);
    final capitalized = scheme[0].toUpperCase() + scheme.substring(1);
    final args = getArguments(arguments).map((a) => _sanitize(a));
    final cmd = '${executable ?? Platform.resolvedExecutable} ${args.join(' ')}';

    _regCreateStringKey(_hive, prefix, '', 'URL:$capitalized');
    _regCreateStringKey(_hive, prefix, 'URL Protocol', '');
    _regCreateStringKey(_hive, '$prefix\\shell\\open\\command', '', cmd);
  }

  @override
  void unregister(String scheme) {
    if (defaultTargetPlatform != TargetPlatform.windows) return;

    final txtKey = TEXT(_regPrefix(scheme));
    try {
      RegDeleteTree(HKEY_CURRENT_USER, txtKey);
    } finally {
      free(txtKey);
    }
  }

  String _regPrefix(String scheme) => 'SOFTWARE\\Classes\\$scheme';

  int _regCreateStringKey(int hKey, String key, String valueName, String data) {
    final txtKey = TEXT(key);
    final txtValue = TEXT(valueName);
    final txtData = TEXT(data);
    try {
      return RegSetKeyValue(hKey, txtKey, txtValue, REG_SZ, txtData, txtData.length * 2 + 2);
    } finally {
      free(txtKey);
      free(txtValue);
      free(txtData);
    }
  }

  String _sanitize(String value) {
    value = value.replaceAll(r'%s', '%1').replaceAll(r'"', '\\"');
    return '"$value"';
  }
}
```

`_sanitize` already produces exactly what's needed here: it escapes embedded
`"` and wraps the result in quotes. Applying it to the executable path is
consistent with how the arguments are already handled two lines above.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Analyze | `make analyze` | no new findings vs. the plan-001 baseline |
| Tests | `make test` | all pass (this file has no existing test; see Scope) |

## Scope

**In scope**:
- `lib/core/router/deep_linking/url_protocol/windows_protocol.dart`

**Out of scope**:
- `lib/core/router/deep_linking/url_protocol/protocol.dart` and any other
  platform's protocol handler (`linux_protocol.dart`, etc., if present) —
  this bug is specific to how Windows builds a single shell command-line
  string; other platforms use different mechanisms and are unaffected.
- Adding a unit test — `RegSetKeyValue`/`win32` registry calls require a real
  Windows registry and are not something this repo's test suite exercises
  (no existing test touches this file); verification here is a manual smoke
  check instead (Step 2).

## Git workflow

- Branch: `advisor/009-windows-protocol-quote-executable`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Quote the executable path in Windows URL-protocol registration`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Sanitize the executable path the same way arguments already are

Change the `cmd` construction to:

```dart
    final exe = _sanitize(executable ?? Platform.resolvedExecutable);
    final cmd = '$exe ${args.join(' ')}';
```

**Verify**: `grep -n "_sanitize(executable ?? Platform.resolvedExecutable)" lib/core/router/deep_linking/url_protocol/windows_protocol.dart`
returns 1 match.

### Step 2: Manual smoke check (if a Windows machine is available in this environment)

This cannot be verified by an automated test (see Scope). If you have access
to run the app on Windows:

1. Run the app once so `register` executes (it is normally called on app
   startup — check `lib/core/router/deep_linking/` for the call site if you
   need to trigger it directly).
2. Inspect the registry value at
   `HKEY_CURRENT_USER\SOFTWARE\Classes\<scheme>\shell\open\command` (e.g. via
   `reg query "HKCU\Software\Classes\hiddify\shell\open\command"` for
   whatever scheme this app registers) and confirm the executable portion is
   now wrapped in quotes.
3. Trigger a deep link (e.g. `start hiddify://test`) and confirm the app
   still opens normally.

If no Windows machine is available in this environment, skip this step and
say so explicitly in your final report — do not claim it was verified.

## Test plan

No automated test is added (see Scope — this needs a real Windows registry).
Verification is the `grep` in Step 1 plus, where possible, the manual check
in Step 2.

## Done criteria

- [ ] `grep -n "_sanitize(executable ?? Platform.resolvedExecutable)" lib/core/router/deep_linking/url_protocol/windows_protocol.dart` returns 1 match
- [ ] `make analyze` reports no new findings compared to the plan-001 baseline count
- [ ] `git status` shows changes only to `lib/core/router/deep_linking/url_protocol/windows_protocol.dart`, `plans/README.md`
- [ ] `plans/README.md` status row updated, noting whether the Step 2 manual check was performed or skipped

## STOP conditions

- The code at `windows_protocol.dart:12-23` doesn't match the excerpt above
  (drift since this plan was written) — re-read the live `register` method
  before proceeding.
- `_sanitize`'s behavior has changed (e.g. it no longer wraps in quotes) —
  re-read it and confirm it still produces a quoted, escaped string before
  reusing it here.

## Maintenance notes

- If a future change introduces a second place that builds a Windows shell
  command line from `Platform.resolvedExecutable` or a caller-supplied path,
  it should go through `_sanitize` (or a shared helper) the same way, rather
  than reintroducing an unquoted string.
- This plan does not add registry-level test coverage. If this class is ever
  refactored to accept an injectable registry-write function (for testing),
  a regression test for "no unquoted paths in the generated command string"
  would be cheap to add then.
