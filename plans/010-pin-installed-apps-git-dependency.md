# Plan 010: Pin the `installed_apps` git dependency to a commit instead of `HEAD`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- pubspec.yaml pubspec.lock`
> If either file changed since this plan was written, re-check the current
> `installed_apps` entry in both files against the excerpts below before
> proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

`pubspec.yaml` depends on `installed_apps` (the package that drives the
per-app-proxy feature — deciding which apps get tunneled) directly from a
third-party GitHub repository, with no `ref:` pin:

```yaml
  installed_apps: # ^1.5.2
    git: https://github.com/VB10/installed_apps
```

`pubspec.lock` confirms this resolves to `ref: HEAD`, currently pinned by the
lockfile to `resolved-ref: 395d51876f9b5b4bc620d8549b05755c6f1966ba`. As long
as nobody runs `flutter pub upgrade` (or deletes the lockfile), the committed
lock protects normal builds. But the *manifest* itself declares "track
whatever this external maintainer's default branch points to right now",
which is one `pub upgrade` away from pulling in unreviewed code from a
repository this project doesn't control — for a package that has direct
filesystem/package-enumeration access on the user's device. Pinning the
manifest to the exact commit already in the lockfile removes that ambiguity
without changing what actually gets built today (the resolved commit doesn't
change).

## Current state

- `pubspec.yaml:109-110` — the dependency declaration to change.
- `pubspec.lock:913-921` — already pinned to a specific commit; used here
  only as the source of truth for which commit to pin the manifest to.

`pubspec.yaml:109-110` today:

```yaml
  installed_apps: # ^1.5.2
    git: https://github.com/VB10/installed_apps
```

`pubspec.lock:913-921` today:

```yaml
  installed_apps:
    dependency: "direct main"
    description:
      path: "."
      ref: HEAD
      resolved-ref: "395d51876f9b5b4bc620d8549b05755c6f1966ba"
      url: "https://github.com/VB10/installed_apps"
    source: git
    version: "1.5.2"
```

For reference, this repo has precedent for forking a third-party git
dependency it depends on more heavily
(`circle_flags`, `pubspec.yaml:89-91`, forked under `hiddify-com`) — that is a
larger step than this plan takes. This plan only pins the existing upstream
reference; forking is out of scope (see Scope below).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Fetch deps | `flutter pub get` | exit 0, `pubspec.lock` unchanged in its `resolved-ref` for this package |
| Tests | `make test` | all pass |

## Scope

**In scope**:
- `pubspec.yaml` (the `installed_apps` entry only)

**Out of scope**:
- `pubspec.lock` by hand — let `flutter pub get` regenerate it after the
  manifest change; do not hand-edit the lockfile.
- Forking `installed_apps` under the `hiddify-com` org the way `circle_flags`
  was forked — that is a larger, maintainer-owned decision (who hosts the
  fork, who reviews future updates to it) and out of scope for this plan.
- Any other unpinned git dependency — this plan only addresses
  `installed_apps`, the one flagged in this audit pass. If you notice another
  unpinned `git:` dependency while making this change, note it in your final
  report rather than fixing it here (out-of-scope scope creep).

## Git workflow

- Branch: `advisor/010-pin-installed-apps`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Pin installed_apps git dependency to the commit already in the lockfile`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Pin the manifest to the commit already resolved in the lockfile

Change `pubspec.yaml:109-110` to:

```yaml
  installed_apps: # ^1.5.2
    git:
      url: https://github.com/VB10/installed_apps
      ref: 395d51876f9b5b4bc620d8549b05755c6f1966ba
```

**Verify**: `grep -A2 "installed_apps:" pubspec.yaml` shows the `ref:` line
with the commit hash above.

### Step 2: Confirm the lockfile doesn't change the resolved commit

**Verify**: `flutter pub get` → exit 0. Then
`grep -A5 "^  installed_apps:" pubspec.lock` shows
`resolved-ref: "395d51876f9b5b4bc620d8549b05755c6f1966ba"` (unchanged) and
`ref: "395d51876f9b5b4bc620d8549b05755c6f1966ba"` (no longer `HEAD`).

**If the resolved commit changes**: that would mean the hash above is wrong
or the upstream repo rewrote history at that ref. STOP and report — do not
pin to whatever new commit resolves instead without confirming it's expected.

### Step 3: Confirm the app still builds/tests correctly

**Verify**: `make test` → all pass (this dependency isn't exercised directly
by the Dart test suite, so this step confirms nothing else broke, not that
per-app-proxy specifically works — see Maintenance notes).

## Test plan

No new automated test — this is a manifest-only change with no behavior
difference (the resolved commit is identical before and after). Verification
is entirely the lockfile diff in Step 2.

## Done criteria

- [ ] `grep -A2 "installed_apps:" pubspec.yaml` shows a `ref:` key with the commit hash
- [ ] `pubspec.lock`'s `installed_apps` entry shows `ref: "395d51876f9b5b4bc620d8549b05755c6f1966ba"` (matching `resolved-ref`, unchanged)
- [ ] `make test` exits 0
- [ ] `git status` shows changes only to `pubspec.yaml`, `pubspec.lock`, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- `pubspec.lock`'s `resolved-ref` for `installed_apps` changes after
  `flutter pub get` — the commit this plan assumes is current may have
  changed or the hash may be wrong. Report the actual resolved ref rather
  than accepting a different commit silently.
- `flutter pub get` fails after the manifest change — report the exact error.

## Maintenance notes

- This does not eliminate the maintenance burden of depending on an
  unreviewed third-party git repo — it only stops silent drift on
  `pub upgrade`. Bumping this pin in the future should be a deliberate,
  reviewed step (diff the upstream commits between the old and new ref)
  rather than something that happens automatically.
- Per-app-proxy is a feature best smoke-tested manually on a real
  Android device (enumerate installed apps, verify tunneling selection still
  works) since it has no automated coverage — this plan does not add that
  coverage; it was out of scope (see Scope).
