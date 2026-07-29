# Plan 014: Fix CONTRIBUTING.md's onboarding-blocking inaccuracies

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e38210d1..HEAD -- CONTRIBUTING.md pubspec.yaml Makefile`
> If any of these changed since this plan was written, re-verify the specific
> facts below (Flutter version constraint, Makefile targets) against the live
> files before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (independent of 013, though both touch onboarding docs)
- **Category**: dx
- **Planned at**: commit `e38210d1`, 2026-07-29

## Why this matters

`CONTRIBUTING.md` is the first doc a new contributor reads, and four things
in it are actively wrong rather than just stale — each one either breaks a
step the contributor tries to follow, or points at content that doesn't
exist. A contributor copying the example `flutter --version` output verbatim
would falsely believe an ancient Flutter satisfies the constraint; one
following the `make prepare` step gets a list of *other* commands to run
instead of anything actually happening; one clicking the Go-core link gets a
404; and nobody following this doc learns that `git submodule update --init
--recursive` is required before `make android-prepare` (the doc's own first
suggested command) can work at all.

## Current state

`CONTRIBUTING.md` in full is short (123 lines) — read it directly before
editing. The four specific problems, each with the fix this plan makes:

1. **Wrong Flutter/Dart version example** (`CONTRIBUTING.md:37-45`):

   ```
   $ flutter --version

   # example response
   Flutter 3.13.4 • channel stable • https://github.com/flutter/flutter.git
   Framework • revision 367f9ea16b (4 weeks ago) • 2023-09-12 23:27:53 -0500
   Engine • revision 9064459a8b
   Tools • Dart 3.1.2 • DevTools 2.25.0
   ```

   `pubspec.yaml:12` requires `flutter: ^3.38.5` — a contributor with the
   Flutter version shown above fails `flutter pub get` before writing a line.

2. **404 link to the Go core's contributing doc** (`CONTRIBUTING.md:32`):

   ```
   Please follow our [Go Core Development repository](https://github.com/hiddify/hiddify-next-core/main/CONTRIBUTING.m).
   ```

   Two separate errors: `.m` is not a valid file extension (should be `.md`),
   and the URL path is missing `/blob/` before the branch name (a raw GitHub
   web URL needs `https://github.com/<org>/<repo>/blob/<branch>/<path>`, not
   `<org>/<repo>/<branch>/<path>`). The Go core's actual module path
   (`hiddify-core/go.mod:1`) is `github.com/hiddify/hiddify-core`, confirming
   the correct org/repo name to link to.

3. **Wrong packaging tool name** (`CONTRIBUTING.md:96`):

   ```
   We use [flutter_distributor](https://github.com/leanflutter/flutter_distributor) for packaging.
   ```

   The `Makefile` doesn't use `flutter_distributor` anywhere — every packaging
   target (`Makefile:166,188,192,246,277,287,297,...`) calls `fastforge`
   (`dart pub global activate fastforge`, `fastforge package ...`).
   `fastforge` is the actively maintained successor to the archived
   `flutter_distributor`.

4. **`make prepare` doesn't do what the doc implies** (`CONTRIBUTING.md:64`
   references "After setting up the environment" but the doc's own earlier
   list of `make <platform>-prepare` commands at lines 56-60 is the real
   setup step). The literal `Makefile:98-103` target:

   ```make
   prepare:
   	@echo use the following commands to prepare the library for each platform:
   	@echo    make android-prepare
   	@echo    make windows-prepare
   	@echo    make linux-prepare 
   	@echo    make macos-prepare
   	@echo    make ios-prepare
   ```

   `make prepare` on its own only prints that list — it does not run any of
   them. The doc's existing per-platform list (`windows-prepare`,
   `linux-prepare`, etc.) is already correct; the fix is making sure nothing
   implies a bare `make prepare` does the actual work.

5. **No mention of `git submodule update --init --recursive` anywhere** —
   `make android-prepare` (and every other `<platform>-prepare` target) chains
   to `common-prepare` → `get gen translate`, none of which touch git
   submodules, but the Go core lives in the `hiddify-core/` submodule and
   `windows-libs`/`android-libs`/etc. (invoked by the platform-prepare
   targets) expect it to be present if building from source. A fresh
   `git clone` without `--recurse-submodules` leaves `hiddify-core/` empty.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm Flutter constraint | `grep "flutter:" pubspec.yaml` | shows `^3.38.5` |
| Confirm fastforge usage | `grep -c fastforge Makefile` | non-zero |
| Confirm prepare target behavior | `grep -A5 "^prepare:" Makefile` | shows only `@echo` lines |

This is a documentation-only plan; there is no test or analyze command that
verifies prose accuracy — verification is manual cross-referencing against
the files above.

## Scope

**In scope**:
- `CONTRIBUTING.md`

**Out of scope**:
- `CLAUDE.md` — that's plan 013, a separate agent-facing doc; don't merge
  their content or duplicate the submodule/codegen explanation verbatim,
  cross-reference instead if useful.
- The `Makefile` itself — not being changed, only documented accurately.
- Any other doc (`README.md`, `SLANG.md`) — out of scope for this pass.

## Git workflow

- Branch: `advisor/014-fix-contributing-md`
- One commit. Message style matches recent history (see `git log`), e.g.
  `Fix CONTRIBUTING.md: Flutter version, core link, fastforge, submodule init`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix the Flutter/Dart version example

Replace the example block at `CONTRIBUTING.md:37-45` with output consistent
with the actual constraint (`pubspec.yaml:12`, `flutter: ^3.38.5`). Don't
fabricate a fake exact revision hash; instead phrase it as a minimum version
requirement:

```markdown
Hiddify uses [Flutter](https://flutter.dev), make sure that you have at least
the version required by `pubspec.yaml` installed before starting development
(check the `environment:`/`flutter:` constraint there for the exact minimum).
You can check your installed version with:

```shell
$ flutter --version
```
```

**Verify**: `grep -c "3.13.4" CONTRIBUTING.md` returns `0`.

### Step 2: Fix the Go core contributing link

Replace `CONTRIBUTING.md:32`:

```
Please follow our [Go Core Development repository](https://github.com/hiddify/hiddify-next-core/main/CONTRIBUTING.m).
```

with:

```
Please follow our [Go Core Development repository](https://github.com/hiddify/hiddify-core/blob/main/CONTRIBUTING.md).
```

**Verify**: `grep -c "hiddify-next-core" CONTRIBUTING.md` returns `0`, and
`grep -c "hiddify-core/blob/main/CONTRIBUTING.md" CONTRIBUTING.md` returns `1`.

**If this link still 404s when you check it** (e.g. that repo's
`CONTRIBUTING.md` doesn't exist at `main`): don't guess further — link to the
repository root instead (`https://github.com/hiddify/hiddify-core`) and note
in your final report that the specific file wasn't found.

### Step 3: Fix the packaging tool reference

Replace `CONTRIBUTING.md:96`:

```
We use [flutter_distributor](https://github.com/leanflutter/flutter_distributor) for packaging.
```

with:

```
We use [fastforge](https://github.com/leanflutter/fastforge) (the actively
maintained successor to flutter_distributor) for packaging.
```

**Verify**: `grep -c "flutter_distributor" CONTRIBUTING.md` returns `0`, and
`grep -c "fastforge" CONTRIBUTING.md` returns at least `1`.

### Step 4: Clarify `make prepare` and add the submodule step

Near `CONTRIBUTING.md:50-60` (the "Setting up the Environment" section), make
two changes:

- Add a sentence before the per-platform command list clarifying that these
  are the actual setup commands, and that the bare `make prepare` on its own
  only prints this same list rather than running anything:

  ```markdown
  Before building, initialize the `hiddify-core` git submodule (only needed
  once, or after switching branches that reference a different submodule
  commit):

      git submodule update --init --recursive

  Then run the following make command for your target platform (running
  `make prepare` on its own only prints this list — it does not build
  anything itself):
  ```

- Keep the existing per-platform list (`make windows-prepare`, etc.) as-is
  immediately after — it's already correct.

**Verify**: `grep -c "git submodule update --init --recursive" CONTRIBUTING.md`
returns at least `1`, and `grep -c "does not build anything itself" CONTRIBUTING.md`
returns `1`.

## Test plan

No automated test applies to a documentation file. Verification is the
`grep` checks in each step above, cross-referenced against the source-of-truth
files (`pubspec.yaml`, `Makefile`, `hiddify-core/go.mod`) cited in "Current
state".

## Done criteria

- [ ] `grep -c "3.13.4" CONTRIBUTING.md` returns `0`
- [ ] `grep -c "hiddify-next-core" CONTRIBUTING.md` returns `0`
- [ ] `grep -c "flutter_distributor" CONTRIBUTING.md` returns `0`
- [ ] `grep -c "git submodule update --init --recursive" CONTRIBUTING.md` returns at least `1`
- [ ] `git status` shows changes only to `CONTRIBUTING.md`, `plans/README.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- `pubspec.yaml`'s Flutter constraint is no longer `^3.38.5` (drift since this
  plan was written) — use whatever the live constraint says instead of the
  value in this plan.
- The corrected Go-core link still returns a 404 after Step 2 — apply the
  fallback in Step 2 (link to the repo root) and note it rather than leaving
  a guessed-but-still-broken URL.

## Maintenance notes

- This doc will drift again the same way it did before — there's no
  automated link-checker or version-constraint-sync in CI. If plan 013's
  `CLAUDE.md` lands, consider (as a future, separate decision) whether
  `CONTRIBUTING.md`'s environment-setup section should simply point to
  `CLAUDE.md` instead of maintaining two descriptions of the same
  codegen/submodule steps — not part of this plan, just worth flagging for
  whoever next edits either file.
