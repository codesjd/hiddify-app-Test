# Plan 011: Characterization tests for ProfileParser's untrusted-content parsers

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- lib/features/profile/data/profile_parser.dart test/features/profile/data/profile_parser_test.dart`
> If either file changed since this plan was written, re-read the current
> function bodies referenced below before proceeding; on a functional
> mismatch (not just line-number shift), treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: 001 (needs `make test` to mean something); should land
  before or alongside 008 (both touch `profile_parser_test.dart` — see
  Maintenance notes on merge order)
- **Category**: tests
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

`lib/features/profile/data/profile_parser.dart` sits on two trust boundaries:
it parses content from untrusted subscription URLs, and it builds the
override blob handed straight to the Go core. It is also the 3rd-highest-churn
non-generated file in the repo (frequent bug fixes land here — see plans 004
and 008). Despite that, five pure, dependency-free functions in this file have
zero test coverage:

- `_parseHeadersFromContent` (parses `#key: value` / `// key: value` header
  lines out of the profile's own content — not the HTTP response headers)
- `_parseSubscriptionInfo` (parses the `subscription-userinfo` header value)
- `protocol` (detects proxy type from raw profile content, used for local
  profile naming)
- `profileOverride` / `applyProfileOverride` + `_mergeJson` (build and apply
  the override JSON sent to the core)

The existing test file (`test/features/profile/data/profile_parser_test.dart`)
only ever calls `ProfileParser.parse`/`populateHeaders` with `content: ''`
(see the four existing tests, e.g. `profile_parser_test.dart:13-22`,
`:39-48`) — meaning the content-parsing path
(`_parseHeadersFromContent`) has **never executed under test**, only the
remote-headers path has. This plan closes that gap without changing any
production code — it is pure characterization: assert what the code
currently does, so a future change to this file has a regression net.

## Current state

Functions this plan adds tests for, and their current behavior (read
`lib/features/profile/data/profile_parser.dart` directly for full context —
excerpts here are the parts each test needs):

**`_parseHeadersFromContent`** (`profile_parser.dart:275-291`), reached via
the public `populateHeaders`:

```dart
  static Map<String, dynamic> _parseHeadersFromContent(String content) {
    final headers = <String, dynamic>{};
    final content_ = safeDecodeBase64(content);
    final lines = content_.split("\n");
    final linesToProcess = lines.length < 10 ? lines.length : 10;
    for (int i = 0; i < linesToProcess; i++) {
      final line = lines[i];
      if (line.startsWith("#") || line.startsWith("//")) {
        final index = line.indexOf(':');
        if (index == -1) continue;
        final key = line.substring(0, index).replaceFirst(RegExp("^#|//"), "").trim().toLowerCase();
        final value = line.substring(index + 1).trim();
        headers[key] = value;
      }
    }
    return headers;
  }
```

Only the first 10 lines are scanned; only `allowedProfileHeaders`
(`profile_parser.dart:46-56`) survive `_mergeAndValidateHeaders`
(`profile_parser.dart:257-273`) into the final map — an unrecognized header
key in content is silently dropped, not an error.

**`protocol`** (`profile_parser.dart:383-413`) — detects proxy type from raw
content; returns `ProxyType.unknown.label` if nothing matches, and a
`[Interface]` substring anywhere short-circuits to `wireguard` before any
line-by-line URI parsing.

**`profileOverride`** (`profile_parser.dart:430-456`) and
**`applyProfileOverride`/`_mergeJson`** (`profile_parser.dart:458-481`) — build
and then deep-merge the override JSON; only keys in `allowedOverrideConfigs`
(`profile_parser.dart:38-45`) survive `removeWhere`.

Repo convention: this test file uses plain `test()`/`group()` blocks (no
`setUp`), constructs `ProfileEntity.remote(...)` directly for `parse()`
inputs, and asserts on the `Either` result via `.match((l) {}, (r) { ... })`
or `isRight()`/`.value`. Match that style — see the existing
`group("parse", ...)` block for the pattern.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Tests | `flutter test test/features/profile/data/profile_parser_test.dart` | all pass |
| Full suite | `make test` | all pass |

## Scope

**In scope**:
- `test/features/profile/data/profile_parser_test.dart` (extend only —
  add new `group`s, do not modify existing tests)

**Out of scope**:
- Any change to `lib/features/profile/data/profile_parser.dart` — this is a
  test-only plan. If a test reveals what looks like a bug, do NOT fix it here:
  record it in your final report and let it become a separate finding (plan
  008 already covers the one known bug in this file's cancellation path —
  check whether a newly-discovered issue overlaps with that plan before
  assuming it's new).
- `expandRemoteLinesInParallel` — covered by plan 008, not this plan.

## Git workflow

- Branch: `advisor/011-profile-parser-characterization-tests`
- One commit per new `group` (4 commits), or one commit for the whole file —
  either is fine; match whichever granularity plan 008 used if it landed
  first (see Maintenance notes on ordering).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Test `_parseHeadersFromContent` via `populateHeaders`

Add a new group to `profile_parser_test.dart`:

```dart
  group("populateHeaders parses headers from content", () {
    test("extracts # and // prefixed headers from content, ignores unknown keys", () {
      const content = "#profile-title: My Config\n"
          "// support-url: https://example.com/support\n"
          "#unknown-key: should be dropped\n"
          "vless://actual-config-line-not-a-header";
      final result = ProfileParser.populateHeaders(content: content);
      expect(result.isRight(), true);
      result.match((l) {}, (r) {
        expect(r["profile-title"], equals("My Config"));
        expect(r["support-url"], equals("https://example.com/support"));
        expect(r.containsKey("unknown-key"), isFalse);
      });
    });

    test("only scans the first 10 lines of content", () {
      final lines = List.generate(15, (i) => "line $i");
      lines[12] = "#profile-title: too late";
      final content = lines.join("\n");
      final result = ProfileParser.populateHeaders(content: content);
      expect(result.isRight(), true);
      result.match((l) {}, (r) {
        expect(r.containsKey("profile-title"), isFalse);
      });
    });

    test("content headers are overridden by remote headers with the same key", () {
      const content = "#profile-title: From Content";
      final result = ProfileParser.populateHeaders(
        content: content,
        remoteHeaders: {"profile-title": "From Remote"},
      );
      expect(result.isRight(), true);
      result.match((l) {}, (r) {
        expect(r["profile-title"], equals("From Remote"));
      });
    });
  });
```

**Verify**: `flutter test test/features/profile/data/profile_parser_test.dart --plain-name "populateHeaders parses headers from content"`
→ all 3 pass.

### Step 2: Test `protocol`

```dart
  group("protocol", () {
    test("detects wireguard from [Interface] marker regardless of other lines", () {
      const content = "some preamble\n[Interface]\nPrivateKey = abc";
      expect(ProfileParser.protocol(content), equals(ProxyType.wireguard.label));
    });

    test("detects vless from a vless:// uri line", () {
      const content = "vless://uuid@host:443?type=tcp#My%20Server";
      expect(ProfileParser.protocol(content), equals("My Server"));
    });

    test("falls back to the scheme label when the uri has no fragment", () {
      const content = "trojan://password@host:443";
      expect(ProfileParser.protocol(content), equals(ProxyType.trojan.label));
    });

    test("returns unknown label when nothing matches", () {
      const content = "not a uri at all\njust some text";
      expect(ProfileParser.protocol(content), equals(ProxyType.unknown.label));
    });
  });
```

Check the exact import path for `ProxyType` at the top of the test file
(`profile_parser.dart` imports it from
`package:hiddify/singbox/model/singbox_proxy_type.dart`) — add that import if
not already present.

**Verify**: `flutter test test/features/profile/data/profile_parser_test.dart --plain-name protocol`
→ all 4 pass.

### Step 3: Test `profileOverride`

```dart
  group("profileOverride", () {
    test("enable-warp header sets chain-status and extra-security", () {
      final result = ProfileParser.profileOverride(
        populatedHeaders: {"enable-warp": "true"},
        userOverride: null,
      );
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded["chain-status"], equals("extra_security"));
      expect(decoded["extra-security"], equals({"mode": "warp"}));
    });

    test("keys not in allowedOverrideConfigs are dropped", () {
      final result = ProfileParser.profileOverride(
        populatedHeaders: {"not-an-allowed-key": "value", "connection-test-url": "https://example.com"},
        userOverride: null,
      );
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded.containsKey("not-an-allowed-key"), isFalse);
      expect(decoded["connection-test-url"], equals("https://example.com"));
    });

    test("userOverride.enableFragment sets tls-tricks even without a header", () {
      final result = ProfileParser.profileOverride(
        populatedHeaders: null,
        userOverride: UserOverride(enableFragment: true),
      );
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded["tls-tricks"], equals({"enable-fragment": true}));
    });
  });
```

Check `UserOverride`'s actual constructor (it may be a freezed class requiring
`const` or additional required-named parameters with defaults) — read
`lib/features/profile/model/profile_entity.dart` (or wherever `UserOverride`
is defined) and adjust the constructor call to match; the test's intent
(only `enableFragment: true` set, everything else default) is what matters,
not the exact syntax above.

**Verify**: `flutter test test/features/profile/data/profile_parser_test.dart --plain-name profileOverride`
→ all 3 pass.

### Step 4: Test `applyProfileOverride` / `_mergeJson`

```dart
  group("applyProfileOverride", () {
    test("returns main unchanged when override is null", () {
      final main = {"a": 1};
      expect(ProfileParser.applyProfileOverride(main, null), equals({"a": 1}));
    });

    test("deep-merges nested maps instead of replacing them", () {
      final main = {
        "outer": {"a": 1, "b": 2},
      };
      final override = jsonEncode({
        "outer": {"b": 99, "c": 3},
      });
      final result = ProfileParser.applyProfileOverride(main, override);
      expect(
        result,
        equals({
          "outer": {"a": 1, "b": 99, "c": 3},
        }),
      );
    });

    test("non-map override string (no '{') leaves main unchanged", () {
      final main = {"a": 1};
      expect(ProfileParser.applyProfileOverride(main, "not-json"), equals({"a": 1}));
    });
  });
```

**Verify**: `flutter test test/features/profile/data/profile_parser_test.dart --plain-name applyProfileOverride`
→ all 3 pass.

### Step 5: Confirm the full suite still passes

**Verify**: `make test` → all pass.

## Test plan

This entire plan *is* the test plan — 13 new characterization tests across 4
groups (`populateHeaders parses headers from content`, `protocol`,
`profileOverride`, `applyProfileOverride`), added to
`test/features/profile/data/profile_parser_test.dart`. Pattern: model each
new group after the existing `group("parse", ...)` block's style (plain
`test()`, direct static-method calls, `Either.match` where the return type is
an `Either`).

Verification: `flutter test test/features/profile/data/profile_parser_test.dart`
→ all pass, including the 13 new tests (4 + 4 + 3 + 3, minus any this plan's
Step 3 needed to adjust for `UserOverride`'s real constructor).

## Done criteria

- [ ] `make test` exits 0
- [ ] `flutter test test/features/profile/data/profile_parser_test.dart` shows at least 17 passing tests total (4 existing + 13 new)
- [ ] `git status` shows changes only to `test/features/profile/data/profile_parser_test.dart`, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- Any of the functions under test have a different signature or behavior than
  the excerpts above describe (drift since this plan was written) — re-read
  the live function and adapt the test to what it *actually* does; if the
  live behavior looks like a bug rather than an intentional change, STOP and
  report it instead of writing a test that encodes the bug as "correct".
- A test you write fails unexpectedly and the fix isn't obvious from reading
  the function once more carefully — report the failure and the function's
  actual behavior rather than modifying `profile_parser.dart` to make the
  test pass (this plan is test-only, see Scope).
- `UserOverride`'s constructor doesn't support constructing with only
  `enableFragment` set (e.g. it requires other fields with no defaults) —
  adapt Step 3's test to whatever construction pattern the existing
  `addLocal`/`addRemote` call sites use, rather than guessing.

## Maintenance notes

- This plan and plan 008 both touch `test/features/profile/data/profile_parser_test.dart`.
  If both are executed, whichever lands second should re-read the file after
  the first plan's changes and add its group(s) without reverting the
  other's — they touch different, non-overlapping `group()` blocks, so a
  straightforward merge (both sets of tests present) is expected; if a merge
  conflict appears, resolve by keeping both groups, not by dropping either.
- These are characterization tests, not a specification — if a future change
  to `profile_parser.dart` intentionally changes one of these behaviors
  (e.g. scanning more than 10 lines, or a different header-key
  normalization), update the corresponding test rather than treating a
  failure here as automatically wrong.
