# Plan 036: Investigate consolidating the duplicated sing-box/xray-core protocol builders

> **Executor instructions**: This is an INVESTIGATE plan, not a build plan.
> The deliverable is a written recommendation document — do not write or
> modify any Go production code as part of this plan. Follow the steps,
> produce the document, and STOP — the actual refactor (if the maintainer
> greenlights it after reading the doc) is a separate, future plan. When
> done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: inside `hiddify-core/ray2sing/ray2sing/`, run
> `wc -l vless.go xrayvless.go vmess.go xrayvmess.go trojan.go xraytrojan.go direct.go xraydirect.go`.
> If any of these files are missing or wildly different in size from what's
> quoted below, re-read them fresh before proceeding — the duplication
> pattern may have already been partially addressed.

## Status

- **Priority**: P3
- **Effort**: S–M (the investigation itself; the hypothetical refactor this
  might recommend is separately estimated as L)
- **Risk**: LOW (read-only investigation, no code changes)
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`hiddify-core/ray2sing/ray2sing/` converts share-links (vless://, vmess://,
trojan://, etc.) into outbound configs for **two** different proxy engines:
sing-box and an embedded xray-core. For at least 4 protocols, this is done by
two entirely separate builder files that each independently re-parse the
same URL-decoded parameter map:

- `vless.go` (49 lines, sing-box) vs. `xrayvless.go` (102 lines, xray;
  roughly half of it is commented-out dead code from an earlier
  implementation using `conf.OutboundDetourConfig` — not this plan's
  concern, but visible while reading it)
- `vmess.go` (85 lines) vs. `xrayvmess.go` (108 lines)
- `trojan.go` (31 lines) vs. `xraytrojan.go` (101 lines)
- `direct.go` (22 lines) vs. `xraydirect.go` (92 lines)

Each pair reads through two parallel low-level helper families:
`common.go`'s `getTLSOptions`/`getMuxOptions`/`getTransportOptions` (used by
the sing-box builders) vs. `xray_common.go`'s `getTLSOptionsXray`/
`getMuxOptionsXray`/`getStreamSettingsXray` (used by the xray builders).
Verified directly in this pass: these two families have **already silently
drifted** — `common.go:52-54` defaults the uTLS fingerprint (`fp`) to
`"chrome"` when a `reality` link omits it; `xray_common.go:271-273` has the
identical default **commented out** (`// fp = "chrome"`), so the same
malformed/incomplete reality link produces different anti-detection
behavior depending on which backend parses it. That's not a hypothetical
risk this plan is worried about — it's a concrete instance already found
(tracked as its own fix in this pass, see plan 035 if it exists by the time
you read this — check `plans/` for a "fingerprint drift" or "DEBT-01"-titled
plan). It is direct evidence that "the two backends will silently diverge
over time" is not speculative.

Consolidating the two builder families into one parse-once,
adapt-per-backend structure would prevent future instances of this same
class of bug. But it touches the config-generation hot path for every user
config import across ~4 protocols with dual-backend support, and a bad
refactor breaks proxy connectivity broadly — that is exactly the kind of
change that should be scoped and reviewed *before* being attempted, not
discovered mid-refactor. This plan produces that scoping document.

## Current state

Files to read before writing the recommendation (read them all yourself —
do not rely on this plan's line-count table as a substitute):

- `ray2sing/ray2sing/vless.go` / `xrayvless.go` — smallest, cleanest pair;
  read this one first to build a mental model of the pattern.
- `ray2sing/ray2sing/vmess.go` / `xrayvmess.go`
- `ray2sing/ray2sing/trojan.go` / `xraytrojan.go`
- `ray2sing/ray2sing/direct.go` / `xraydirect.go`
- `ray2sing/ray2sing/common.go` (helpers: `getTLSOptions`, `getMuxOptions`,
  `getTransportOptions`, `getDialerOptions`, and the reality/fingerprint
  logic at `:52-54`)
- `ray2sing/ray2sing/xray_common.go` (helpers: `getTLSOptionsXray`,
  `getMuxOptionsXray`, `getStreamSettingsXray`, and the commented-out
  fingerprint default at `:271-273`, `:326-327`)
- `ray2sing/ray2sing/url_schema.go` (`ParseUrl`, the shared param-map decoder
  both backends start from — confirm this part is already shared, so the
  duplication starts *after* parsing, not at parsing itself)
- `ray2sing/ray2sing/convert.go` (the dispatcher that picks which backend's
  builder to call per protocol — read this to understand exactly which
  protocols currently need dual-backend support vs. sing-box-only; the
  earlier audit estimated "~4 protocols" but verify the actual count and
  list here)

Repo convention: sing-box builders return a `*T.Outbound` (sing-box's
`option` package types, strongly typed); xray builders return a
`map[string]any` shaped into xray-core's JSON config format (loosely typed,
built via string-keyed maps). Any consolidation proposal has to reconcile
this — a shared intermediate representation needs to be adaptable to both a
strongly-typed and a loosely-typed output, which is itself worth flagging as
a design question in the recommendation doc, not glossed over.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Confirm file sizes | `wc -l ray2sing/ray2sing/{vless,xrayvless,vmess,xrayvmess,trojan,xraytrojan,direct,xraydirect}.go` (run from `hiddify-core/`) | matches or explains any drift from "Current state" |
| Confirm existing tests | `ls ray2sing/ray2sing_test/*vless* ray2sing/ray2sing_test/*vmess* ray2sing/ray2sing_test/*trojan*` | lists the existing per-protocol tests you'd need to keep passing if a refactor is later attempted |
| Go build (sanity, no code changes expected) | `cd hiddify-core && go build ./ray2sing/...` | exit 0 — confirms your read-only investigation didn't accidentally touch anything |

## Scope

**In scope**:
- Reading the files listed in "Current state".
- Writing one new file: `hiddify-core/docs/protocol-builder-consolidation-spike.md`
  (the `hiddify-core/docs/` directory already exists — e.g.
  `docs/hiddifyrpc.md` — follow its general documentation style/tone).

**Out of scope**:
- Any change to `ray2sing/ray2sing/*.go` — this plan produces a
  recommendation, not a refactor. If, while investigating, an unrelated bug
  or the fingerprint-drift fix mentioned above hasn't been applied yet, do
  NOT fix it here — note it in the recommendation doc as supporting evidence
  instead.
- Protocols not currently built by both backends — scope the investigation
  to whatever `convert.go` shows actually needs dual-backend support today;
  don't speculate about protocols that might need it in the future.
- Any change to `hiddify-core/v2/config/` or the Dart client — this is
  scoped to `ray2sing` only.

## Git workflow

- Branch: `advisor/036-protocol-builder-consolidation-spike`
- One commit (the new doc file).
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Inventory the duplication precisely

For each of the 4 protocol pairs, read both files and record: which fields
each backend's builder reads from the decoded param map, which fields each
writes to its output shape, and where the two diverge (a field the sing-box
side handles that the xray side doesn't, or vice versa — the fingerprint
default is one confirmed example; look for others, e.g. in the mux/transport
handling).

### Step 2: Confirm the fingerprint divergence and check for siblings

Re-verify the `common.go:52-54` vs. `xray_common.go:271-273` divergence
directly (`grep -n "fp\b\|chrome" ray2sing/ray2sing/common.go
ray2sing/ray2sing/xray_common.go`). Check whether any *other* option (mux
settings, transport/XHTTP options, packet encoding) has a similar
present-on-one-side-only default by comparing `getMuxOptions`/
`getMuxOptionsXray` and `getTransportOptions`/`getStreamSettingsXray` the
same way.

### Step 3: Sketch a shared intermediate-representation design

Sketch (in the doc, not in code) a proposed shared parsed-options struct per
protocol — e.g. a `parsedVlessOptions` struct capturing every field either
backend needs, populated once from the decoded param map, with two thin
adapter functions (`toSingboxOutbound(parsedVlessOptions) *T.Outbound` and
`toXrayJSON(parsedVlessOptions) map[string]any`) replacing the current
from-scratch reparse in each of `vless.go`/`xrayvless.go`. Do this for at
least the vless pair in enough detail to be concrete (field names, types);
sketch the other 3 more briefly, noting where they'd need the same shape.

### Step 4: Write the recommendation document

Create `hiddify-core/docs/protocol-builder-consolidation-spike.md`
containing:

1. The inventory from Step 1 (a table or list per protocol pair: fields read,
   fields written, confirmed divergences).
2. The fingerprint-divergence finding from Step 2 as concrete motivating
   evidence (cite exact file:line).
3. The sketched design from Step 3.
4. An explicit **"Open questions for the maintainer"** section, at minimum
   covering: (a) is the risk (config-generation hot path, breaks proxy
   connectivity if done wrong) worth the benefit given only ~N protocols
   need dual-backend support (use the real count from `convert.go`, not the
   ~4 estimate) — is that number growing or stable? (b) should the migration
   be done protocol-by-protocol (lower risk per step, longer total timeline)
   or all at once? (c) what test coverage should exist *before* attempting
   this (cross-reference the existing `ray2sing_test/` per-protocol tests —
   are they sufficient to catch a regression during a refactor, or does this
   need characterization tests first)?
5. A one-line recommendation of your own (do it now / do it protocol-by-
   protocol / don't do it / do it only when a 3rd divergence bug is found) —
   framed as a recommendation for the maintainer to weigh, not a decision
   you're making on their behalf.

**Verify**: `test -f hiddify-core/docs/protocol-builder-consolidation-spike.md && echo exists`
→ prints `exists`. The doc contains all 5 numbered sections above (spot-check
by grepping for section headers).

## Test plan

Not applicable — no code changes. The "test" of this plan's success is
whether the document lets a maintainer make an informed go/no-go decision
without re-reading all 8 files themselves.

## Done criteria

- [ ] `hiddify-core/docs/protocol-builder-consolidation-spike.md` exists
- [ ] It documents the per-protocol field inventory, the confirmed fingerprint divergence (with file:line), the sketched shared-struct design, an explicit open-questions section, and a one-line recommendation
- [ ] `cd hiddify-core && go build ./ray2sing/...` still exits 0 (confirms no accidental code changes)
- [ ] `git status` shows changes only to the new doc file
- [ ] `plans/README.md` status row updated

## STOP conditions

- You find yourself editing any `.go` file — stop, this is a documentation-
  only plan. Revert the change and note what you wanted to fix in the
  recommendation doc's open-questions section instead.
- `convert.go`'s actual dual-backend protocol count differs significantly
  from "~4" — use the real number in the doc, and flag the discrepancy in
  your final report.
- You cannot confirm the fingerprint divergence still exists (e.g. it was
  already fixed by another plan) — note that it's resolved, and look for a
  different concrete divergence example instead of citing a fixed one as
  live evidence.

## Maintenance notes

- This doc is a decision input, not a commitment — if the maintainer reads
  it and decides not to consolidate, that's a valid outcome; don't treat
  "the doc got written" as implying the refactor should happen.
- If the maintainer does greenlight consolidation later, that follow-up plan
  should be scoped protocol-by-protocol (per this doc's own open question)
  rather than as one giant L-effort plan touching all 4 pairs at once, unless
  the maintainer explicitly prefers the bigger-bang approach after reading
  the trade-offs here.
