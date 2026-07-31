# Plan 038: Document the `hiddify-sing-box` fork's upstream basis

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: inside the `hiddify-core/hiddify-sing-box`
> nested submodule, run `git log --oneline -5`. If the current `HEAD` is not
> `ed121a89` ("fix(xray): don't let a losing startup race permanently disable
> tun-exclusion"), the submodule has moved since this plan was written —
> re-run the discovery commands in Step 1 to find the current merge point and
> commit count before writing anything, rather than trusting the numbers
> below.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, nested `hiddify-sing-box`
  submodule commit `ed121a891` (its own detached-HEAD position at that time),
  Dart repo commit `e38210d1`, 2026-07-29

## Why this matters

`hiddify-core/hiddify-sing-box` is a heavily modified fork of
`sagernet/sing-box`, vendored as a nested git submodule
(`hiddify-core/.gitmodules` / the parent's submodule config points it at
`https://github.com/codesjd/hiddify-sing-box`, currently checked out
detached at `ed121a89`). Nothing in the repo records **which upstream
release this fork is based on** or **how much local work sits on top of it**.
A prior audit pass guessed "~15 hand-written commits" from a truncated
`git log -15` — this plan's own verification (Step 1) found the real number
is **92 commits** since the fork's last explicit upstream sync, because that
truncated log never reached the actual merge boundary. Without a recorded
anchor point, every future security/dependency audit of this fork has to
re-discover this same boundary by hand, and every future "should we pull in
upstream's latest sing-box release" decision has no concrete base to diff
against.

## Current state

Verified directly in this pass (re-run these yourself — see STOP conditions
if the results differ):

- `cd hiddify-core/hiddify-sing-box && git remote -v` → `origin
  https://github.com/codesjd/hiddify-sing-box` (fetch/push). `git branch
  --show-current` → empty (detached HEAD at `ed121a89`).
- `git log --oneline -100` shows the most recent explicit upstream sync is:
  `eac533ab Merge upstream sing-box v1.14.0-alpha.14 into extended` — i.e.
  this fork's `extended` branch was last brought up to date with
  **`sagernet/sing-box` v1.14.0-alpha.14** at that commit.
- `git log --oneline eac533ab..HEAD | wc -l` → **92** commits on top of that
  merge, not the ~15 a prior, truncated pass estimated. Themes visible in
  that range (for your own reference while writing the doc — don't just
  copy this list verbatim, see Step 2): embedded xray-core outbound
  implementation and hardening (`845ac5d1`, `7b60ad03`, several `fix(xray)`
  commits), certificate pinning (`15e35a00`, `5f2ff66e`, `b36acf84`), a
  `dnstt`/multi-resolver DNS pool feature line (`0a02b772` onward), a
  `gooserelay` protocol addition (`2d8f97b3` onward), a `smart_dns_pool`
  service (`3e748699`), an elevated-ICMP-helper integration seam (`2c4628bc`,
  `872bc23a`), and a block of ~20 `Revert "..."` commits near the tail of the
  range (oldest end, right after `eac533ab`) whose purpose isn't obvious from
  the log alone — note them as-is, don't guess why they're there.
- `hiddify-core/hiddify-sing-box/README.md` (40 lines) documents the fork's
  **feature list** (Amnezia 1.5, WARP, Tunneling, Mieru, XHTTP, SDNS,
  extended WireGuard options, unified delay) but has no section recording the
  upstream version/commit basis. This is the natural place to add that
  section — there is no existing `FORK.md` or similar file to prefer instead
  (confirmed: `ls hiddify-core/hiddify-sing-box/FORK.md` → no such file).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm current HEAD | `cd hiddify-core/hiddify-sing-box && git log --oneline -1` | shows `ed121a89 fix(xray): ...` (or report the drift if not) |
| Confirm merge boundary | `git log --oneline --all --grep="Merge upstream sing-box" | head -5` | shows `eac533ab Merge upstream sing-box v1.14.0-alpha.14 into extended` as the most recent match |
| Count commits since | `git log --oneline eac533ab..HEAD | wc -l` | `92` |

This is a documentation-only plan; there is no build/test command that
verifies prose accuracy — verification is re-running the commands above and
confirming the doc matches their actual output.

## Scope

**In scope**:
- `hiddify-core/hiddify-sing-box/README.md` (add one new section)

**Out of scope**:
- Any other file in `hiddify-sing-box` or `hiddify-core` — this plan adds
  documentation only, no code change.
- Actually syncing with upstream sing-box, or evaluating whether the ~20
  `Revert` commits near `eac533ab` need investigation — both are follow-ups
  this doc makes *possible* to scope accurately, not something this plan
  does itself.
- The Dart repo's own `plans/README.md`'s "Go core findings" section — the
  coordinating session updates that after all findings-derived plans are
  written; don't edit it as part of this plan.

## Git workflow

- This is a nested submodule (`hiddify-core/hiddify-sing-box`) inside a
  submodule (`hiddify-core`) inside the main Dart repo. Commit the README
  change **inside the `hiddify-sing-box` checkout itself** first
  (`cd hiddify-core/hiddify-sing-box && git add README.md && git commit`),
  then, if this environment's workflow expects it, update the parent
  `hiddify-core` submodule's recorded commit pointer and the Dart repo's own
  submodule pointer to match — check whether this repo's normal contribution
  flow does that (e.g. look at recent commits touching `hiddify-core` as a
  gitlink) before assuming; if unsure, stop after the nested commit and
  report the new commit hash rather than guessing how the outer pointers
  should move.
- Branch (inside `hiddify-sing-box`): `advisor/038-document-fork-basis`.
- Commit message style: this fork's own log uses short imperative subjects,
  often prefixed `fix(scope):`/`feat(scope):`/`docs(scope):` — use
  `docs: record upstream sing-box fork basis in README` (no scope prefix
  needed for a whole-repo doc addition, matching the plainer messages also
  present in the log, e.g. `b36acf84 Document PinnedPeerCertificateSha256's
  hostname-bypass semantics`).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Re-verify the merge boundary and commit count

Run the three commands in "Commands you will need" yourself before writing
anything. If the current `HEAD` is not `ed121a89`, or if
`git log --oneline --all --grep="Merge upstream sing-box"` finds a *more
recent* merge than `eac533ab` (meaning the fork has been re-synced with
upstream since this plan was written), use the new merge commit and re-count
commits on top of it instead of the numbers in this plan.

**Verify**: you can state the exact merge commit hash, the upstream version
string from its commit message, and the exact commit count on top of it.

### Step 2: Add a "Fork basis" section to `hiddify-sing-box/README.md`

Append a new section after the existing "## Features" list (before
"## Examples"):

```markdown
## Fork basis

This is a fork of [sagernet/sing-box](https://github.com/sagernet/sing-box),
tracked via the `extended` branch on
[codesjd/hiddify-sing-box](https://github.com/codesjd/hiddify-sing-box).

- **Last synced with upstream**: `v1.14.0-alpha.14`, at commit `eac533ab`
  ("Merge upstream sing-box v1.14.0-alpha.14 into extended").
- **Local work on top of that sync**: 92 commits as of `ed121a89` (this
  count will grow — don't rely on it staying accurate; regenerate with the
  command below). Broad themes as of this writing: embedded xray-core
  outbound support and hardening, TLS certificate pinning, a `dnstt`/
  multi-resolver DNS pool, the `gooserelay` outbound protocol, a
  `smart_dns_pool` service, and elevated-ICMP-helper integration — plus a
  block of upstream commit reverts shortly after the `eac533ab` sync whose
  rationale isn't recorded and may be worth investigating separately.
- **To see the current local-work list**: from this directory, run
  `git log --oneline eac533ab..HEAD` (or replace `eac533ab` with whatever
  commit the next sync lands on — update this doc's "Last synced" line when
  that happens).
- **To find the next sync point**: `git log --oneline --all --grep="Merge
  upstream sing-box"` shows every past sync merge; the most recent one is
  the current basis.
```

Adjust wording only if Step 1 found different numbers/commits than what's
written here — this section must reflect what you actually verified, not
what this plan assumed.

**Verify**: `grep -c "^## Fork basis" hiddify-core/hiddify-sing-box/README.md`
returns `1`.

## Test plan

No automated test applies to a documentation file. Verification is Step 1's
command outputs matching what the new README section states.

## Done criteria

- [ ] `hiddify-core/hiddify-sing-box/README.md` contains a "Fork basis" section
- [ ] The section's merge-commit hash, upstream version string, and commit count all match what Step 1 actually found (not necessarily the numbers in this plan, if drift occurred)
- [ ] `git status` inside `hiddify-core/hiddify-sing-box` shows changes only to `README.md`
- [ ] `plans/README.md` (in the main Dart repo) status row for plan 038 updated

## STOP conditions

- The current `HEAD` of `hiddify-sing-box` is not `ed121a89` and a *newer*
  upstream-sync merge exists — use the new merge point and re-derive the
  commit count; do not silently keep this plan's stale numbers.
- You're unsure how commit pointers should propagate from the nested
  `hiddify-sing-box` submodule up through `hiddify-core` and into the Dart
  repo's own submodule reference — stop after committing inside
  `hiddify-sing-box` and report the new commit hash, rather than guessing at
  the outer repos' submodule-pointer update process.
- `hiddify-sing-box/README.md`'s current content doesn't match the excerpt
  in "Current state" (e.g. the Features list or file length changed) — the
  section can still be appended, but note the drift in your final report.

## Maintenance notes

- This doc will go stale the moment new local commits land without updating
  the commit count — that's expected and fine, since the doc tells the
  reader how to regenerate the count/list themselves (the `git log
  eac533ab..HEAD` command) rather than requiring the count to be kept
  perfectly in sync. What *does* need updating promptly is the "Last synced"
  line, whenever someone performs a new upstream merge — that's the one
  fact this doc exists to anchor, and letting it go stale defeats the whole
  purpose.
- The ~20 `Revert` commits noted near the `eac533ab` boundary were observed
  but not investigated — a natural, separate follow-up would be figuring out
  why they're there (reverting bad upstream commits that got pulled in
  during the merge? Deliberately dropping upstream behavior the fork
  doesn't want?) and recording that too.
