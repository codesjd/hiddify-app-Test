# Plan 029: Add tests for the config-building translation layer (`v2/config/builder.go`)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. This plan is TEST-ONLY: it adds a new test
> file and does not change any production code. When done, update the
> status row for this plan in `plans/README.md` — unless a reviewer
> dispatched you and told you they maintain the index.
>
> **Drift check (run first)**: inside the `hiddify-core` submodule, run
> `git diff --stat 8653861f1c6b87f4833e4bc3182af4b32c53b711..HEAD -- v2/config/builder.go v2/config/dns.go v2/config/hiddify_option.go v2/config/config.go`.
> If any of these changed, re-read the live functions before proceeding; on
> a mismatch between this plan's excerpts and the live code, treat it as a
> STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW (test-only; no production code changes)
- **Depends on**: none
- **Category**: tests
- **Planned at**: `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, Dart repo commit `e38210d1`,
  2026-07-29

## Why this matters

`hiddify-core/v2/config/builder.go` (1226 lines) is the layer that turns
every user-facing setting (`HiddifyOptions` — TUN on/off, DNS servers, WARP
mode, routing rules, per-app inbound ports) into the actual sing-box
`option.Options` config the core runs. It has **zero tests**. The only test
file in the package, `v2/config/parser_test.go`, exclusively covers
`parser.go`'s raw-content-format detection/migration helpers
(`TestLooksLikeSingboxSchema`, `TestParseConfigContent_*`,
`TestParseConfig_HonorsUseXrayCoreWhenPossible`) — confirmed by reading that
file directly; none of it calls `BuildConfig`, `setDns`, `setInbound`, or any
other function in `builder.go`/`dns.go`. A regression here — the wrong DNS
server picked, TUN silently not added, a routing rule dropped — produces a
config that's syntactically valid and loads fine, so nothing else in the
test suite would catch it; the failure mode is a client that connects but
misbehaves (leaks DNS, routes wrong, etc.), the worst kind of regression for
a VPN client to ship silently.

This plan adds a `builder_test.go` covering `BuildConfig` end-to-end for a
handful of representative option combinations, plus one direct `setDns`
edge case. It intentionally does not attempt full coverage of
`setRoutingOptions` (the largest, most complex function in the file, 542
lines) — that is a larger effort; see Maintenance notes.

## Current state

Read directly from the live files (all in `hiddify-core/v2/config/`):

**`BuildConfig`** (`builder.go:64-97`) is the entry point this plan tests.
It takes a `*HiddifyOptions` and a `*ReadOptions`, and returns the built
`*option.Options`:

```go
func BuildConfig(ctx context.Context, hopts *HiddifyOptions, inputOpt *ReadOptions) (*option.Options, error) {
	input, err := ReadSingOptions(ctx, inputOpt)
	if err != nil {
		return nil, err
	}
	var options option.Options
	if hopts.EnableFullConfig {
		options.Inbounds = input.Inbounds
		options.DNS = input.DNS
		options.Route = input.Route
	}
	setExperimental(&options, hopts)
	setLog(&options, hopts)
	setInbound(&options, hopts)
	staticIPs := make(map[string][]string)
	if err := setOutbounds(&options, input, hopts, &staticIPs); err != nil {
		return nil, err
	}
	if err := setDns(&options, hopts, &staticIPs); err != nil {
		return nil, err
	}
	if err := setRoutingOptions(&options, hopts); err != nil {
		return nil, err
	}
	return &options, nil
}
```

**`ReadOptions`** (`config.go:10-27`) can bypass file/content reading
entirely by setting its `Options` field directly — `ReadSingOptions` returns
`opt.Options` unchanged if it's non-nil (`config.go:16-19`). This is exactly
what makes `BuildConfig` cheaply testable: pass
`&ReadOptions{Options: &option.Options{}}` as `inputOpt` and no file I/O or
JSON parsing happens.

**`DefaultHiddifyOptions()`** (`hiddify_option.go:108-169`) already
constructs a fully-populated, valid `*HiddifyOptions` (`EnableTun: false`,
`RemoteDnsAddress: "1.1.1.1"`, etc.) — use this as the base for every test
case, then override only the field(s) under test via a copy
(`opts := *config.DefaultHiddifyOptions(); opts.EnableTun = true`).

**TUN inbound behavior** (`builder.go:433-478`, `setInbound`) — verified
directly: when `hopt.EnableTun` is `true`, exactly one inbound with
`Type: C.TypeTun` and `Tag: InboundTUNTag` (`"tun-in"`) is appended to
`options.Inbounds` (`builder.go:476`); when `false`, no such inbound is
added (the whole block at `:441-478` is skipped). Regardless of
`EnableTun`, one or more `C.TypeMixed` inbounds are always added
(`:495-516`) — don't assert on `len(options.Inbounds)` directly, assert on
tag/type membership instead, since the mixed-inbound count depends on
`AllowConnectionFromLAN` and IPv6 support.

**FakeDNS server behavior** (`dns.go:120-130`) — verified directly: when
`opt.EnableFakeDNS` is `true`, `options.DNS.Servers` gets one additional
entry appended with `Tag: DNSFakeTag` (`"dns-fake"`) and
`Type: C.DNSTypeFakeIP`; when `false`, no such entry exists.

**Remote DNS server address transformation** (`dns.go:32-37,50,312-365`) —
verified directly: `getDnsAddress` prepends `"udp://"` to
`opt.RemoteDnsAddress` if it has no `"://"` already. For the default
`RemoteDnsAddress: "1.1.1.1"`, this produces `"udp://1.1.1.1"`, which
`getDNSServerOptions` parses to `serverType == "udp"` (`C.DNSTypeUDP`,
`dns.go:349`), setting `o.Type = C.DNSTypeUDP` and
`o.Options.(*option.RemoteDNSServerOptions).Server = "1.1.1.1"` (via
`M.ParseSocksaddr(dnsurl).AddrString()`, `dns.go:352-361`). The resulting
server has `Tag: DNSRemoteTag` (`"dns-remote"`, `dns.go:50`). This is a good
representative assertion for "the DNS address setting actually reaches the
built config."

Repo/package conventions: table-driven Go tests using the standard
`testing` package (no third-party assertion library is imported anywhere in
`hiddify-core/v2/` — confirmed by `grep -rn "testify\|assert\." v2/**/*_test.go`
returning nothing outside generated code), plain `if got != want { t.Errorf(...) }`
or `t.Fatalf` checks. Match this — do not introduce `testify` or any new
test dependency.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Run the new tests | `cd hiddify-core && go test ./v2/config/... -run TestBuildConfig -v` | all new tests pass |
| Run the whole config package's tests | `cd hiddify-core && go test ./v2/config/...` | all pass (existing `parser_test.go` tests + new ones) |
| Vet | `cd hiddify-core && go vet ./v2/config/...` | exit 0 |

Note: a prior audit pass found that `go build`/`go vet` from the
`hiddify-core` **root** (`./...`) can fail to resolve because nested
submodules under `hiddify-sing-box/replace/` aren't checked out in some
environments. Scoping every command to `./v2/config/...` specifically avoids
that — if even the scoped command fails to resolve, report the exact error
rather than trying to check out unrelated submodules to work around it.

## Scope

**In scope**:
- `hiddify-core/v2/config/builder_test.go` (create — this plan's only file)

**Out of scope**:
- Any change to `builder.go`, `dns.go`, `hiddify_option.go`, or any other
  production file in `v2/config/` — this is a test-only plan. If while
  writing these tests you find what looks like an actual bug (e.g. an
  assertion that should hold doesn't), do NOT fix it — report it in your
  final summary as a candidate finding instead, and write the test to
  characterize the *actual* current behavior (with a comment noting it looks
  suspicious) rather than the behavior you expected.
- `setRoutingOptions` (`builder.go:565-1107`, the 542-line routing-rules
  function) — out of scope for this pass; it's the largest, most complex
  function in the file and deserves its own dedicated test-writing effort
  given its size. Note this as a follow-up in your final report, don't
  expand this plan to cover it.
- `setOutbounds`, WARP-specific patching (`patchHiddifyWarpFromConfig`) —
  same reasoning; a follow-up, not this plan.
- `parser_test.go` — already has coverage; don't modify it.

## Git workflow

- Branch: `advisor/029-config-builder-tests`
- One commit.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `v2/config/builder_test.go` with the TUN inbound test

```go
package config

import (
	"context"
	"testing"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

func buildWithOverride(t *testing.T, override func(*HiddifyOptions)) *option.Options {
	t.Helper()
	opts := *DefaultHiddifyOptions()
	if override != nil {
		override(&opts)
	}
	built, err := BuildConfig(context.Background(), &opts, &ReadOptions{Options: &option.Options{}})
	if err != nil {
		t.Fatalf("BuildConfig() returned error: %v", err)
	}
	return built
}

func hasInboundTag(options *option.Options, tag string) bool {
	for _, in := range options.Inbounds {
		if in.Tag == tag {
			return true
		}
	}
	return false
}

func TestBuildConfig_TunInbound(t *testing.T) {
	t.Run("EnableTun true adds the tun-in inbound", func(t *testing.T) {
		built := buildWithOverride(t, func(o *HiddifyOptions) { o.EnableTun = true })
		if !hasInboundTag(built, InboundTUNTag) {
			t.Errorf("expected an inbound tagged %q when EnableTun is true, got tags: %v", InboundTUNTag, inboundTags(built))
		}
		for _, in := range built.Inbounds {
			if in.Tag == InboundTUNTag && in.Type != C.TypeTun {
				t.Errorf("inbound %q has Type %q, want %q", InboundTUNTag, in.Type, C.TypeTun)
			}
		}
	})

	t.Run("EnableTun false adds no tun-in inbound", func(t *testing.T) {
		built := buildWithOverride(t, func(o *HiddifyOptions) { o.EnableTun = false })
		if hasInboundTag(built, InboundTUNTag) {
			t.Errorf("did not expect an inbound tagged %q when EnableTun is false", InboundTUNTag)
		}
	})
}

func inboundTags(options *option.Options) []string {
	tags := make([]string, 0, len(options.Inbounds))
	for _, in := range options.Inbounds {
		tags = append(tags, in.Tag)
	}
	return tags
}
```

**Verify**: `cd hiddify-core && go test ./v2/config/... -run TestBuildConfig_TunInbound -v` →
both subtests pass.

### Step 2: Add the FakeDNS server test

Append to the same file:

```go
func hasDnsServerTag(options *option.Options, tag string) bool {
	if options.DNS == nil {
		return false
	}
	for _, s := range options.DNS.Servers {
		if s.Tag == tag {
			return true
		}
	}
	return false
}

func TestBuildConfig_FakeDns(t *testing.T) {
	t.Run("EnableFakeDNS true adds the dns-fake server", func(t *testing.T) {
		built := buildWithOverride(t, func(o *HiddifyOptions) { o.EnableFakeDNS = true })
		if !hasDnsServerTag(built, DNSFakeTag) {
			t.Errorf("expected a DNS server tagged %q when EnableFakeDNS is true", DNSFakeTag)
		}
	})

	t.Run("EnableFakeDNS false adds no dns-fake server", func(t *testing.T) {
		built := buildWithOverride(t, func(o *HiddifyOptions) { o.EnableFakeDNS = false })
		if hasDnsServerTag(built, DNSFakeTag) {
			t.Errorf("did not expect a DNS server tagged %q when EnableFakeDNS is false", DNSFakeTag)
		}
	})
}
```

**Verify**: `cd hiddify-core && go test ./v2/config/... -run TestBuildConfig_FakeDns -v` →
both subtests pass.

### Step 3: Add the custom remote-DNS-address test

Append to the same file:

```go
func TestBuildConfig_RemoteDnsAddress(t *testing.T) {
	built := buildWithOverride(t, func(o *HiddifyOptions) { o.RemoteDnsAddress = "9.9.9.9" })
	if built.DNS == nil {
		t.Fatal("expected DNS options to be set")
	}
	var found *option.DNSServerOptions
	for i := range built.DNS.Servers {
		if built.DNS.Servers[i].Tag == DNSRemoteTag {
			found = &built.DNS.Servers[i]
			break
		}
	}
	if found == nil {
		t.Fatalf("expected a DNS server tagged %q", DNSRemoteTag)
	}
	if found.Type != C.DNSTypeUDP {
		t.Errorf("remote DNS server Type = %q, want %q (RemoteDnsAddress %q has no scheme, should default to udp://)", found.Type, C.DNSTypeUDP, "9.9.9.9")
	}
	remoteOpts, ok := found.Options.(*option.RemoteDNSServerOptions)
	if !ok {
		t.Fatalf("remote DNS server Options is %T, want *option.RemoteDNSServerOptions", found.Options)
	}
	if remoteOpts.Server != "9.9.9.9" {
		t.Errorf("remote DNS server address = %q, want %q", remoteOpts.Server, "9.9.9.9")
	}
}
```

**Verify**: `cd hiddify-core && go test ./v2/config/... -run TestBuildConfig_RemoteDnsAddress -v` → passes.

### Step 4: Run the full package test suite

**Verify**: `cd hiddify-core && go test ./v2/config/...` → all pass (existing
`parser_test.go` tests plus the 3 new test functions / 5 new subtests added
here).

## Test plan

This plan's entire content is the test addition — see Steps 1-3 for the
exact 3 test functions / 5 subtests added to
`hiddify-core/v2/config/builder_test.go`:

- `TestBuildConfig_TunInbound` (2 subtests: TUN on adds `tun-in`, TUN off
  doesn't)
- `TestBuildConfig_FakeDns` (2 subtests: FakeDNS on adds `dns-fake` server,
  off doesn't)
- `TestBuildConfig_RemoteDnsAddress` (1 test: a custom `RemoteDnsAddress`
  reaches the built DNS server's address field, with the correct
  scheme-defaulting behavior)

Verification: `cd hiddify-core && go test ./v2/config/...` → all pass.

## Done criteria

- [ ] `hiddify-core/v2/config/builder_test.go` exists with the 3 test functions above
- [ ] `cd hiddify-core && go test ./v2/config/...` exits 0, all tests pass
- [ ] `cd hiddify-core && go vet ./v2/config/...` exits 0
- [ ] `git status` (in the `hiddify-core` submodule) shows changes only to `v2/config/builder_test.go`
- [ ] `plans/README.md` status row updated (in the parent Dart repo)

## STOP conditions

- Any function cited in "Current state" doesn't match its excerpt (drift
  since this plan was written) — re-read the live function and adjust the
  test to match actual current behavior; if the live behavior looks like a
  bug rather than an intentional change, write the test to characterize
  what's actually there (with a comment flagging the suspicion) and report
  it, per Scope — do not fix production code in this plan.
- `BuildConfig(ctx, opts, &ReadOptions{Options: &option.Options{}})` panics
  or errors in a way not explained by this plan's assumptions (e.g. it
  requires a non-empty base `option.Options` for some field this plan didn't
  account for) — report the exact panic/error rather than working around it
  with production-code changes.
- A test's assertion fails and you cannot determine whether that's because
  the test's expectation is wrong or because the code has an actual bug —
  report both possibilities rather than picking one and "fixing" either side
  to make it pass.

## Maintenance notes

- This plan deliberately does not cover `setRoutingOptions` (542 lines, the
  largest function in `builder.go`) or `setOutbounds`/WARP patching — both
  are substantial follow-up test-writing efforts in their own right, not
  attempted here to keep this plan's verification story clean (every
  assertion here traces to a function this plan's author read in full).
- If `BuildConfig`'s signature or `HiddifyOptions`'s field set changes in the
  future, `DefaultHiddifyOptions()` (the fixture base every test in this
  file uses) should be updated in the same change — these tests will fail
  loudly if it drifts, which is the intended safety net.
- The helper functions `buildWithOverride`, `hasInboundTag`,
  `hasDnsServerTag`, `inboundTags` are written to be reusable by whoever
  extends this file to cover `setRoutingOptions`/`setOutbounds` next — keep
  them in `builder_test.go` rather than duplicating similar helpers in a
  new file.
