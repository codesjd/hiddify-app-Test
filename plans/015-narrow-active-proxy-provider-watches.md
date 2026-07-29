# Plan 015: Stop 3 widgets rebuilding at core tick rate by narrowing their `activeProxyNotifierProvider` watch

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- lib/features/home/widget/connection_button.dart lib/features/proxy/active/active_proxy_delay_indicator.dart lib/features/stats/widget/connection_stats_card.dart lib/hiddifycore/generated/v2/hcore/hcore.pb.dart`
> If any of these changed since this plan was written, re-read the live
> widget bodies and the live `OutboundInfo` field list before proceeding; on
> a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

`activeProxyNotifierProvider` (`lib/features/proxy/active/active_proxy_notifier.dart:76-88`)
is an `AsyncValue<OutboundInfo>` fed by a stream of the currently-active
proxy's live info. `OutboundInfo` is a generated protobuf message
(`lib/hiddifycore/generated/v2/hcore/hcore.pb.dart:623+`) whose fields
include `upload`/`download` byte counters that change on essentially every
emission, and whose equality (`protobuf` package's `GeneratedMessage.==`,
field-by-field structural comparison) therefore almost never returns `true`
between two consecutive emissions. Three widgets call plain
`ref.watch(activeProxyNotifierProvider)` and only ever read one or two small
fields off the result:

- `connection_button.dart:30-31` — only reads `.urlTestDelay`
- `active_proxy_delay_indicator.dart:16` — only reads `.urlTestDelay` (plus
  whether data is available at all)
- `connection_stats_card.dart:17` — reads `.tagDisplay` **and** `.ipinfo`
  (both, not just `tagDisplay` — see Current state for why this one needs a
  slightly wider selector than the other two)

Because none of these three narrow their watch, all three rebuild on every
proxy-info tick (traffic byte updates included) even though the values they
actually render — a delay number, a tag name, an IP — change far less often.
On the home screen, `connection_button.dart` backs the animated connect/
disconnect button, so this is a continuously-visible widget rebuilding at
stream tick rate for no visual reason.

`active_proxy_card.dart:22` already does this correctly for its own purposes
(`ref.watch(activeProxyNotifierProvider.select((value) => value.valueOrNull))`)
— use `.select()` the same way, but note that widget selects the *entire*
`OutboundInfo`, which is appropriate there only because that card also
displays live traffic; **do not copy that exact selector into these three
widgets**, since it would not fix anything (the whole-object selector still
changes every tick for the same byte-counter reason). Select only the
specific field(s) each widget actually reads.

## Current state

**`lib/features/home/widget/connection_button.dart:30-31`** today:

```dart
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final delay = activeProxy.valueOrNull?.urlTestDelay ?? 0;
```

`activeProxy` is not used anywhere else in this file (confirmed by reading
the whole file) — only `delay` is used downstream.

**`lib/features/proxy/active/active_proxy_delay_indicator.dart:16,19-24`**
today:

```dart
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    final theme = Theme.of(context);

    if (activeProxy is! AsyncData) {
      return const SizedBox(); // Avoid building widget if data is not available
    }

    final proxy = activeProxy.value!;
    final delay = proxy.urlTestDelay;
```

Only `urlTestDelay` is read; the `is! AsyncData` check exists purely to
short-circuit when there's no data yet.

**`lib/features/stats/widget/connection_stats_card.dart:17,23-54`** today —
this one reads **two** fields, not one (`proxy.tagDisplay` at line 26 and
`proxy.ipinfo.ip`/`proxy.ipinfo.countryCode` at lines 32-41):

```dart
    final activeProxy = ref.watch(activeProxyNotifierProvider);
    // ...
        switch (activeProxy) {
          AsyncData(value: final proxy) => (
            label: const Icon(FluentIcons.arrow_routing_20_regular),
            data: Text(proxy.tagDisplay),
            semanticLabel: null,
          ),
          _ => (label: const Icon(FluentIcons.arrow_routing_20_regular), data: const Text("..."), semanticLabel: null),
        },
        switch (activeProxy) {
          AsyncData(value: final proxy) when proxy.ipinfo.ip.isNotEmpty => (
            label: Row(
              children: [
                IPCountryFlag(countryCode: proxy.ipinfo.countryCode, size: 16),
              ],
            ),
            data: IPText(
              ip: proxy.ipinfo.ip,
              onLongPress: () async {
                ref.read(ipInfoNotifierProvider.notifier).refresh();
              },
              constrained: true,
            ),
            semanticLabel: null,
          ),
          _ => (
            label: const Icon(FluentIcons.question_circle_20_regular),
            data: const ShimmerSkeleton(widthFactor: .85, height: 14),
            semanticLabel: null,
          ),
        },
```

Selecting only `tagDisplay` here (as one might assume from the widget's name)
would silently break the IP-info block, which reads `proxy.ipinfo` — a
separate field. This widget needs a selector that returns both.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps + codegen | `make verify-prepare` | exit 0 |
| Analyze | `make analyze` | no new findings vs. the plan-001 baseline |
| Tests | `make test` | all pass |

## Scope

**In scope**:
- `lib/features/home/widget/connection_button.dart`
- `lib/features/proxy/active/active_proxy_delay_indicator.dart`
- `lib/features/stats/widget/connection_stats_card.dart`

**Out of scope**:
- `lib/features/proxy/active/active_proxy_card.dart` — already correct for
  its own needs; do not change it.
- `lib/features/proxy/active/active_proxy_notifier.dart` — the provider
  itself is not being changed, only how these three widgets watch it.
- `lib/features/platform_specific/android_quick_settings_tile.dart` and
  `lib/features/system_tray/notifier/system_tray_notifier.dart` — both have
  the same watch pattern but currently commented out
  (`ref.watch(activeProxyNotifierProvider)` is inside a `//` comment in both);
  since the code isn't live, changing it isn't necessary here — note in your
  final report if you'd like a follow-up to cover them if/when uncommented.
- `lib/features/stats/widget/connection_stats_card.dart`'s commented-out
  `ipInfo`-based third `switch` block (lines 55-103) — dead code, unrelated
  to this fix, do not touch it.

## Git workflow

- Branch: `advisor/015-narrow-active-proxy-watches`
- One commit per file (3 commits), or one commit for all three — either is
  fine.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `connection_button.dart`

Replace lines 30-31:

```dart
    final delay = ref.watch(activeProxyNotifierProvider.select((value) => value.valueOrNull?.urlTestDelay)) ?? 0;
```

(This replaces both the old `activeProxy` and `delay` lines with one.)

**Verify**: `grep -n "activeProxyNotifierProvider.select" lib/features/home/widget/connection_button.dart`
returns 1 match, and `grep -c "ref.watch(activeProxyNotifierProvider)" lib/features/home/widget/connection_button.dart`
returns `0`.

### Step 2: `active_proxy_delay_indicator.dart`

Replace lines 16, 19-24:

```dart
    final delay = ref.watch(activeProxyNotifierProvider.select((value) => value.valueOrNull?.urlTestDelay));
    final theme = Theme.of(context);

    if (delay == null) {
      return const SizedBox(); // Avoid building widget if data is not available
    }
```

Remove the now-unused `final proxy = activeProxy.value!;` and
`final delay = proxy.urlTestDelay;` lines that followed (the selector above
already produces `delay` directly).

**Verify**: `grep -n "activeProxyNotifierProvider.select" lib/features/proxy/active/active_proxy_delay_indicator.dart`
returns 1 match, `grep -c "ref.watch(activeProxyNotifierProvider)" lib/features/proxy/active/active_proxy_delay_indicator.dart`
returns `0`, and `grep -c "activeProxy.value!" lib/features/proxy/active/active_proxy_delay_indicator.dart`
returns `0`.

### Step 3: `connection_stats_card.dart`

Replace line 17 with a selector returning a record of both fields this
widget actually uses:

```dart
    final activeProxy = ref.watch(
      activeProxyNotifierProvider.select((value) => (tagDisplay: value.valueOrNull?.tagDisplay, ipinfo: value.valueOrNull?.ipinfo)),
    );
```

Then update both `switch` blocks to match on the record instead of the old
`AsyncValue`:

```dart
        switch (activeProxy) {
          (tagDisplay: final String tagDisplay, ipinfo: _) => (
            label: const Icon(FluentIcons.arrow_routing_20_regular),
            data: Text(tagDisplay),
            semanticLabel: null,
          ),
          _ => (label: const Icon(FluentIcons.arrow_routing_20_regular), data: const Text("..."), semanticLabel: null),
        },
        switch (activeProxy) {
          (tagDisplay: _, ipinfo: final ipinfo?) when ipinfo.ip.isNotEmpty => (
            label: Row(
              children: [
                IPCountryFlag(countryCode: ipinfo.countryCode, size: 16),
              ],
            ),
            data: IPText(
              ip: ipinfo.ip,
              onLongPress: () async {
                ref.read(ipInfoNotifierProvider.notifier).refresh();
              },
              constrained: true,
            ),
            semanticLabel: null,
          ),
          _ => (
            label: const Icon(FluentIcons.question_circle_20_regular),
            data: const ShimmerSkeleton(widthFactor: .85, height: 14),
            semanticLabel: null,
          ),
        },
```

Check the exact record-pattern syntax compiles as written (Dart record
patterns with named fields) — if `dart format`/`flutter analyze` flags the
pattern syntax, adjust the pattern matching syntax while preserving the same
two cases (tag present vs not; ipinfo present-and-non-empty-ip vs not), do
not fall back to re-watching the whole `AsyncValue`.

**Verify**: `grep -n "activeProxyNotifierProvider.select" lib/features/stats/widget/connection_stats_card.dart`
returns 1 match, and `grep -c "ref.watch(activeProxyNotifierProvider)" lib/features/stats/widget/connection_stats_card.dart`
(without `.select`) returns `0`.

### Step 4: Confirm everything still analyzes and builds

**Verify**: `make analyze` → no new findings compared to the plan-001
baseline count. `make test` → all pass (none of these three widgets have
existing widget tests, so this confirms nothing else broke, not behavior
of these specific widgets — see Maintenance notes).

## Test plan

No existing automated test covers these three widgets (no widget-test
harness exists in this repo yet — see `test/` directory listing). This plan
does not add one; it is a narrow, mechanical perf fix with a clear manual
verification path (Step 5 below) rather than new test infrastructure, which
would be disproportionate to an S-effort plan. Verification is the `grep`
checks per step plus `make analyze`/`make test` passing.

### Step 5: Manual smoke check (if a running device/emulator is available)

If you can run the app: connect to a proxy, confirm the connection button,
delay indicator, and stats card all still show the correct delay/tag/IP
values and update when the active proxy or its delay actually changes (e.g.
after a URL test). If no device is available in this environment, skip this
step and say so explicitly in your final report — do not claim it was
verified.

## Done criteria

- [ ] `make analyze` reports no new findings vs. the plan-001 baseline
- [ ] `make test` exits 0
- [ ] All three `grep -c "ref.watch(activeProxyNotifierProvider)"` checks (without `.select`) in Steps 1-3 return `0`
- [ ] All three `.select` greps in Steps 1-3 return `1`
- [ ] `git status` shows changes only to the 3 in-scope files, `plans/README.md`
- [ ] `plans/README.md` status row updated, noting whether Step 5's manual check was performed or skipped

## STOP conditions

- Any of the three widget files don't match the excerpts above (drift since
  this plan was written) — re-read the live file and identify every field it
  actually reads off `activeProxy`/`proxy` before selecting a narrower shape;
  do not assume the field list in this plan is still complete.
- The record-pattern syntax in Step 3 doesn't compile against this repo's
  Dart SDK version — report the exact analyzer/compiler error; do not
  silently fall back to watching the whole `AsyncValue` (that would
  reintroduce the bug this plan fixes).
- You find a fourth widget with the same whole-provider-watch pattern that
  this plan didn't account for — note it in your final report as a
  candidate for a follow-up, do not expand this plan's scope to fix it too.

## Maintenance notes

- If a future field is added to `OutboundInfo` that one of these widgets
  needs, extend that widget's selector tuple/record rather than reverting to
  a whole-object watch.
- `connection_stats_card.dart`'s commented-out third stats block (lines
  55-103, `ipInfo`-based) was left untouched — if it's ever uncommented, it
  will need its own narrowed selector on whatever provider it ends up
  watching, following the same pattern established here.
- No widget-test harness exists yet for these three files; if one is added
  later (a reasonable follow-up), a good first test would be "widget renders
  the delay/tag/IP text present in a fake `AsyncData<OutboundInfo>`" using
  `ProviderScope(overrides: [...])`.
