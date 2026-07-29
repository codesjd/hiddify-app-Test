# Plan 037: Investigate whether `v2/hcore` needs an abstraction boundary in front of sing-box internals

> **Executor instructions**: This is an INVESTIGATE plan, not a build plan.
> The deliverable is a written recommendation document — do not write or
> modify any Go production code as part of this plan. Follow the steps,
> produce the document, and STOP. When done, update the status row for this
> plan in `plans/README.md`.
>
> **Drift check (run first)**: inside `hiddify-core/`, run
> `grep -rl "sagernet/sing-box" v2/hcore/*.go | wc -l`. If the result is
> wildly different from `11` (the count found while writing this plan), the
> import surface has changed — re-run the discovery grep in Step 1 fresh
> before trusting this plan's inventory.

## Status

- **Priority**: P3
- **Effort**: S–M (the investigation itself; the hypothetical adapter-layer
  refactor this might recommend is separately estimated as L)
- **Risk**: LOW (read-only investigation, no code changes)
- **Depends on**: none (complements plan 030's control-plane test work — a
  finished adapter layer would make `v2/hcore` easier to unit test without a
  real sing-box instance, which is exactly the gap plan 030 works around
  today; check whether plan 030 exists and read its approach before writing
  Step 4 of this plan)
- **Category**: tech-debt
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`v2/hcore` is the gRPC-facing layer of this project — everything the Flutter
client calls goes through it. Verified directly in this pass:
`grep -rl "sagernet/sing-box" v2/hcore/*.go` matches **11 files**, importing
at least these internal sing-box packages directly: `adapter`,
`common/monitoring`, `protocol/group`, `protocol/group/balancer`,
`common/urltest`, `daemon`, `experimental/clashapi`,
`experimental/clashapi/trafficontrol`, `experimental/libbox`, `option`,
`constant`, `log`, plus the top-level `sagernet/sing-box` package itself
(aliased `box` in `service.go`). `proxy_info.go:9-83`
(`GetProxyInfo`/`GetAllProxiesInfo`) is a concrete example of the depth of
this coupling: it type-asserts directly against `adapter.OutboundGroup`,
`*balancer.Balancer`, and calls `monitoring.RealTag`/`monitoring.Get(ctx)`
from inside what is otherwise proto-response-shaping code — there is no
boundary layer translating "what sing-box's internal object model looks
like" into "what the gRPC API returns."

This has a real cost: every sing-box internal API change (a renamed method
on `adapter.OutboundGroup`, a new balancer type) is a breaking change to
`hcore` itself, and it makes `hcore`'s business logic impossible to unit test
without constructing a real sing-box instance — which is exactly why an
earlier pass of this audit found `v2/hcore` has almost no test coverage
outside 2 files (see plan 030, if it exists by the time you read this).

But this is also defensibly **intentional** for a project with exactly one
consumer of `hcore` (this app) and exactly one backend it will ever talk to
(sing-box) — a thin adapter layer for a 1:1 relationship that will never have
a second implementation is exactly the kind of premature abstraction this
project's own engineering culture pushes back on elsewhere (see the "no
unrequested abstractions" ponytail convention evident in this repo's
comments, e.g. `lib/core/utils/exception_handler.dart`'s
`// ponytail: simple controller-based resume` note on the Dart side). Whether
the testability and change-isolation benefit is worth the abstraction cost
here is a genuine judgment call, not a clear-cut fix — hence an investigate
plan rather than a build plan.

## Current state

Files to read before writing the recommendation:

- `v2/hcore/proxy_info.go` (the clearest, most-cited example — read this
  first: `GetProxyInfo` at the top of the file, `GetAllProxiesInfo` below it)
- `v2/hcore/commands.go` (imports `adapter`, `monitoring`, `protocol/group`)
- `v2/hcore/service.go` (imports the most sing-box internals of any file:
  `adapter`, `common/urltest`, `daemon`, `experimental/clashapi`,
  `experimental/clashapi/trafficontrol`, `experimental/libbox`, `option`,
  and the top-level `sagernet/sing-box` package itself — this is likely the
  file with the deepest coupling; read it in full)
- `v2/hcore/buildconfighelper.go`, `independent_instance.go`,
  `log_interface.go`, `logproto.go`, `pause.go`, `platform_interface.go`,
  `restart.go`, `grpc_server.go` — the remaining 8 of the 11 files with a
  sing-box import; skim each for what it imports and why, don't necessarily
  read them line-by-line the way you should for `proxy_info.go`/`service.go`.

For each, note: which sing-box types/functions are used, and whether the
usage is (a) a thin pass-through (e.g. just calling a sing-box function and
returning its result, which an interface could wrap trivially) or (b) genuine
business logic interleaved with sing-box-specific type assertions (harder to
abstract cleanly, as `proxy_info.go`'s `GetProxyInfo` is).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Re-confirm import surface | `grep -rl "sagernet/sing-box" v2/hcore/*.go \| wc -l` (from `hiddify-core/`) | `11` (or note the drift) |
| List exact imported packages | `grep -rh "sagernet/sing-box" v2/hcore/*.go \| sort -u` | the ~13-package list in "Why this matters" |
| Go build (sanity, no code changes expected) | `cd hiddify-core && go build ./v2/hcore/...` | exit 0 |

## Scope

**In scope**:
- Reading the files listed in "Current state".
- Writing one new file: `hiddify-core/docs/hcore-abstraction-boundary-spike.md`
  (the `hiddify-core/docs/` directory already exists — e.g.
  `docs/hiddifyrpc.md` — follow its general documentation style/tone).

**Out of scope**:
- Any change to `v2/hcore/*.go` or any sing-box package — this plan produces
  a recommendation, not a refactor.
- Evaluating sing-box's own internal architecture — this plan only looks at
  the boundary from `hcore`'s side.
- Writing any new tests — that's plan 030's scope (or a follow-up once/if
  this spike's recommendation is acted on); this plan only documents the
  *testability* argument as one factor in the recommendation, it doesn't add
  test coverage itself.

## Git workflow

- Branch: `advisor/037-hcore-abstraction-boundary-spike`
- One commit (the new doc file).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Re-confirm the import surface

Run the two grep commands in "Commands you will need". Confirm the file
count and package list match (or note drift).

### Step 2: Classify each of the 11 files' sing-box usage

For each file, note whether its sing-box usage is a thin pass-through or
business logic interleaved with sing-box-specific types (see "Current
state" for the a/b distinction). `proxy_info.go`'s `GetProxyInfo` is a
confirmed example of (b) — its type assertions against
`adapter.OutboundGroup`/`*balancer.Balancer` are direct, load-bearing logic,
not a thin wrapper.

### Step 3: Sketch what a boundary would look like

Sketch (in the doc, not in code) what a thin `sing-box adapter` package
might expose — e.g. an `hcore`-owned interface like
`ProxyInspector.GetGroupInfo(tag string) (GroupInfo, bool)` that
`proxy_info.go` would call instead of type-asserting against
`adapter.OutboundGroup` directly, with one concrete implementation backed by
the real sing-box types. Do this in enough detail for the file(s) classified
as (b) in Step 2 to be concrete; for files classified as (a), a lighter
sketch (or "no boundary needed, already a thin call-through") is enough.

### Step 4: Write the recommendation document

Create `hiddify-core/docs/hcore-abstraction-boundary-spike.md` containing:

1. The file-by-file classification from Step 2.
2. The sketched adapter design from Step 3 for the (b)-classified files.
3. The concrete list of call sites that would need to move behind an
   interface if this were pursued (file:line references).
4. The testability argument, made concrete: name which specific `hcore`
   functions currently cannot be unit-tested without a real sing-box
   instance, and would become testable with mocks/fakes if this boundary
   existed. Cross-reference plan 030's approach if it exists — does its
   test harness already work around this gap in a way that makes the
   abstraction less urgent, or does it hit the same wall this spike is
   about?
5. An explicit **"Open questions for the maintainer"** section, at minimum
   covering: (a) does `hcore` realistically need to support a second backend
   ever (if genuinely never, that's strong evidence against the abstraction —
   name what would have to change about this project's architecture for a
   second backend to become plausible); (b) is a *partial* abstraction (only
   the (b)-classified files/functions) an acceptable middle ground, or does a
   half-migrated state read as worse than the current uniform-but-leaky
   pattern; (c) how much of the testability benefit could be captured more
   cheaply by narrower techniques (e.g. extracting pure functions out of the
   type-assertion-heavy code, without a full interface boundary)?
6. A one-line recommendation of your own, framed as input to the
   maintainer's decision, not a decision you're making for them.

**Verify**: `test -f hiddify-core/docs/hcore-abstraction-boundary-spike.md && echo exists`
→ prints `exists`. The doc contains all 6 numbered sections above.

## Test plan

Not applicable — no code changes. The "test" of this plan's success is
whether the document lets a maintainer make an informed go/no-go decision
without re-reading all 11 files themselves.

## Done criteria

- [ ] `hiddify-core/docs/hcore-abstraction-boundary-spike.md` exists
- [ ] It documents the file-by-file classification, the sketched adapter design, the concrete call-site list, the testability argument (with cross-reference to plan 030 if present), an explicit open-questions section, and a one-line recommendation
- [ ] `cd hiddify-core && go build ./v2/hcore/...` still exits 0 (confirms no accidental code changes)
- [ ] `git status` shows changes only to the new doc file
- [ ] `plans/README.md` status row updated

## STOP conditions

- You find yourself editing any `.go` file — stop, this is a documentation-
  only plan.
- The import count/package list differs significantly from what's recorded
  here — use the real numbers, and flag the discrepancy in your final report.
- Plan 030 (or whatever plan added `v2/hcore` test coverage) turns out to
  already address the testability problem this spike is partly motivated by
  — say so plainly in the doc rather than overstating the remaining need.

## Maintenance notes

- This doc is a decision input, not a commitment — a legitimate outcome is
  "accepted trade-off, document it as intentional and move on," which is
  itself worth recording explicitly in the doc if that's the conclusion, so
  a future audit doesn't re-raise the same question from scratch.
- If the maintainer does greenlight an abstraction layer later, prioritize
  the (b)-classified files/functions (business logic interleaved with
  sing-box types) over the (a)-classified thin pass-throughs, which gain
  little from being wrapped.
