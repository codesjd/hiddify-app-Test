# Plan 018: Require an authenticated secret on the core's gRPC control channel (all 3 platforms)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. This plan spans Dart, Go, Kotlin, and Swift —
> if your environment cannot build/verify one of those toolchains, complete
> the phases you can verify and STOP before the final "make it mandatory"
> step (Step 6) rather than guessing the others are fine. When done, update
> the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat e38210d1..HEAD -- lib/hiddifycore/hiddify_core_service.dart lib/hiddifycore/core_interface/ android/app/src/main/kotlin/com/hiddify/hiddify/MethodHandler.kt ios/Runner/Handlers/MethodHandler.swift`
> and, inside the `hiddify-core` submodule, `git diff --stat 8653861f1c..HEAD -- v2/hcore/grpc_server.go v2/hcore/hcore.proto`.
> If any changed, re-read the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P0
- **Effort**: L
- **Risk**: MED-HIGH — touches the control channel every platform uses to
  start/stop the VPN; a mistake here can brick the app on one platform
- **Depends on**: none
- **Category**: security
- **Planned at**: Dart commit `e38210d1`, `hiddify-core` submodule commit
  `8653861f1c6b87f4833e4bc3182af4b32c53b711`, 2026-07-29

## Why this matters

The core's gRPC control server (`CoreService`/`HelloService`/`EzytelService` —
start/stop the VPN, change every setting, select outbounds) has **no
authentication on any platform today**, not just desktop as an earlier pass
of this audit assumed. Verified directly, end to end:

- **Go server never checks any secret.** `hiddify-core/v2/hcore/hcore.proto:70`
  defines `string secret = 6;` on `SetupRequest`, but
  `grpc_server.go:41-132` (`Setup`) and `:179-269`
  (`StartGrpcServerByMode`) never read `params.Secret` anywhere — confirmed
  by `grep -n "Secret" v2/hcore/grpc_server.go` returning nothing. There is
  no `grpc.UnaryInterceptor`/`StreamInterceptor` registered for either the
  insecure or the mTLS server branch.
- **All 3 platforms launch the insecure gRPC mode with an empty secret.**
  `SetupMode` (`hcore.proto:52-58`) has 4 values: `OLD=0`, `GRPC_NORMAL=1`,
  `GRPC_BACKGROUND=2` (both mTLS — see `grpc_server.go:199-242`),
  `GRPC_NORMAL_INSECURE=3`, `GRPC_BACKGROUND_INSECURE=4` (no transport
  security at all — `grpc_server.go:199-200`). The single shared Dart call
  site, `lib/hiddifycore/hiddify_core_service.dart:94`, hardcodes
  `core.setup(directories, debug, 3)` — mode `3`, insecure, for **every**
  platform. Each platform's native setup handler then hardcodes an **empty**
  secret regardless: `lib/hiddifycore/core_interface/core_interface_desktop.dart:66,95`
  generates a 100-char random secret but only passes it into the FFI
  `_box.setup(...)` call — it is never sent as gRPC metadata on the
  `HelloClient`/`CoreClient` it constructs three lines later
  (`:74,112` both use `ChannelCredentials.insecure()` with no secret
  attached). `android/app/src/main/kotlin/com/hiddify/hiddify/MethodHandler.kt:96`
  hardcodes `it.secret=""`. `ios/Runner/Handlers/MethodHandler.swift:85`
  hardcodes `opts.secret = ""`, and line 87 even hardcodes
  `opts.mode = 4` (ignoring whatever mode Dart passed).
- **The mTLS path (`GRPC_NORMAL`/`GRPC_BACKGROUND`, modes 1/2) is real on the
  Go side but incompletely wired on the client side.**
  `grpc_server.go:202-241` genuinely generates/stores a certificate pair and
  enforces `tls.RequireAndVerifyClientCert` when a non-insecure mode is used
  — this is not fake. But `lib/hiddifycore/core_interface/core_interface_mobile.dart:28,40-42,73-79`
  shows the intended flow (fetch the server's public key via
  `get_grpc_server_public_key`, register the client's key via
  `add_grpc_client_public_key`, then use `MTLSChannelCredentials`) with the
  actual key-exchange calls **commented out** — so `serverPublicKey`
  (a `late Uint8List`, line 28) is never assigned. Since mode is hardcoded to
  `3`/`4` everywhere anyway (see above), this branch is currently dead code
  on every platform, not just broken — it never executes. **This plan does
  not attempt to finish the mTLS wiring** (see Scope); it closes the hole
  through the `secret` field, which is simpler and already threaded most of
  the way through on every platform.

Net effect today: any local process on the same machine — desktop, or any
app with local IPC/debugging access on Android/iOS — can connect to the
core's gRPC port and call any RPC: start/stop the VPN, rewrite every
setting, select outbounds, read logs. This plan makes the secret real:
generate one, send it, check it, and reject calls that don't have it.

## Current state

Files this plan touches, and their role today:

- `hiddify-core/v2/hcore/grpc_server.go` — builds the gRPC server; add the
  auth interceptor here.
- `hiddify-core/v2/hcore/hcore.proto:64-70` — `SetupRequest.secret` already
  exists; no proto change needed.
- `lib/hiddifycore/core_interface/core_interface_desktop.dart` — desktop
  already generates a secret (`:66`) and passes it into `_box.setup()`
  (`:95`); needs to also attach it as call metadata on both gRPC clients
  it constructs (`:74-81`, `:107-119`).
- `android/app/src/main/kotlin/com/hiddify/hiddify/MethodHandler.kt:76-111`
  (`Trigger.Setup` handler) — needs to accept a secret from the Dart method
  channel call instead of hardcoding `it.secret=""` (`:96`).
- `ios/Runner/Handlers/MethodHandler.swift` (the analogous Setup handler,
  around line 85) — same fix as Android, plus stop hardcoding
  `opts.mode = 4` independent of what Dart sends (a separate, smaller bug —
  fix it while you're there since it's one line, but don't expand this
  plan's scope beyond the secret).
- `lib/hiddifycore/core_interface/core_interface_mobile.dart:39-101`
  (`setup`) — needs to generate a secret (matching the desktop pattern) and
  pass it through the `methodChannel.invokeMethod("setup", {...})` call
  (`:61-68`) so Android/iOS native code can forward it, then attach it as
  metadata on `fgClient`/`bgClient` (`:84-98`).

Go's `StartGrpcServerByMode` today (`grpc_server.go:179-200`, relevant part):

```go
	if mode == SetupMode_GRPC_BACKGROUND_INSECURE || mode == SetupMode_GRPC_NORMAL_INSECURE {
		grpcServer[mode] = grpc.NewServer()
	} else {
		// ... mTLS setup, unchanged by this plan ...
	}
```

Desktop's secret generation and (unused) client construction
(`core_interface_desktop.dart:59-119`, relevant parts):

```dart
  final port = 17078;
  static String generateRandomPassword(int length) { /* ... */ }
  static final String secret = generateRandomPassword(100);

  @override
  Future<String> setup(Directories directories, bool debug, int mode) async {
    const channelOption = ChannelCredentials.insecure();
    final helloClient = HelloClient(
      ClientChannel('127.0.0.1', port: port, options: const ChannelOptions(credentials: channelOption)),
    );
    // ...
    final errPtr = _box.setup(
      directories.baseDir.path.toNativeUtf8().cast(),
      directories.workingDir.path.toNativeUtf8().cast(),
      directories.tempDir.path.toNativeUtf8().cast(),
      SetupMode.GRPC_NORMAL_INSECURE.value,
      "127.0.0.1:$port".toNativeUtf8().cast(),
      secret.toNativeUtf8().cast(),
      0,
      debug ? 1 : 0,
    );
    // ...
    bgClient = fgClient = CoreClient(
      ClientChannel('localhost', port: port, options: const ChannelOptions(credentials: ChannelCredentials.insecure())),
    );
```

Android's setup handler (`MethodHandler.kt:76-98`, relevant part):

```kotlin
            Trigger.Setup.method -> {
                GlobalScope.launch {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        // ...
                        val mode = args["mode"] as Int
                        val grpcPort = args["grpcPort"] as Int
                        runCatching {
                            Mobile.setup(
                                SetupOptions().also {
                                    it.basePath = Settings.baseDir
                                    it.workingDir = Settings.workingDir
                                    it.tempDir = Settings.tempDir
                                    it.fixAndroidStack = Bugs.fixAndroidStack
                                    it.mode = mode.toLong()
                                    it.listen = "127.0.0.1:" + grpcPort
                                    it.secret = ""
                                    it.debug = Settings.debugMode
                                }, null)
                            success("")
                        }.onFailure { error(it) }
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Go build/vet | `cd hiddify-core && go build ./v2/... && go vet ./v2/...` | exit 0 (note: per a prior audit pass, this may fail to resolve standalone if nested submodules under `hiddify-sing-box/replace/` aren't checked out — if so, note it and verify with `gofmt -l` / manual read instead) |
| Go tests | `cd hiddify-core && go test ./v2/hcore/...` | all pass |
| Dart analyze | `make analyze` (from repo root) | no new findings vs. plan-001 baseline |
| Dart tests | `make test` | all pass |
| Android build | `./gradlew :app:compileDebugKotlin` (from `android/`, if an Android SDK is available in this environment) | exit 0 — SKIP and report if no SDK is available |
| iOS build | `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner build` (if a macOS/Xcode toolchain is available) | exit 0 — SKIP and report if unavailable |

## Scope

**In scope**:
- `hiddify-core/v2/hcore/grpc_server.go` (add the interceptor)
- `lib/hiddifycore/core_interface/core_interface_desktop.dart`
- `lib/hiddifycore/core_interface/core_interface_mobile.dart`
- `android/app/src/main/kotlin/com/hiddify/hiddify/MethodHandler.kt`
- `ios/Runner/Handlers/MethodHandler.swift`
- `lib/hiddifycore/hiddify_core_service.dart` (only if a secret needs to be
  threaded through the shared `core.setup(directories, debug, 3)` call site
  — check whether `CoreInterface.setup`'s abstract signature needs a
  parameter added, or whether each platform generating its own secret
  internally, as desktop already does, is sufficient. Prefer the latter — it
  requires no interface signature change — unless you find a reason it
  can't work.)

**Out of scope**:
- Finishing the mTLS (`GRPC_NORMAL`/`GRPC_BACKGROUND`, modes 1/2) wiring —
  the commented-out `add_grpc_client_public_key`/`get_grpc_server_public_key`
  exchange in `core_interface_mobile.dart:73-79`. That is a larger, separate
  effort (real certificate exchange, not just a shared string) and is not
  required to close this hole. Do not uncomment or attempt to fix that code.
- `hiddify-core/v2/hcore/tunnelservice/` and `icmpservice/` — separate
  elevated services with their own unauthenticated-loopback finding, planned
  separately (see plans 019, 020). Do not touch them here.
- Any change to `SetupMode` enum values or the proto schema.
- Android's `AddGrpcClientPublicKey`/`GetGrpcServerPublicKey` method channel
  handlers (`MethodHandler.kt:35-36,55-74`) — unrelated to the secret-based
  fix, part of the out-of-scope mTLS path.

## Git workflow

- Branch: `advisor/018-grpc-secret-auth`
- Commit per phase (Go interceptor; desktop; Android; iOS; mobile Dart
  shim + final enforcement flip) — six commits, matching the six steps
  below.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a secret-checking gRPC interceptor on the Go side (soft mode first)

In `hiddify-core/v2/hcore/grpc_server.go`, add a unary + stream interceptor
that:

- Reads a `secret` value from a package-level variable set during `Setup`
  from `params.Secret` (currently discarded — capture it into a new
  `var configuredSecret string` alongside the existing `grpcServer`/`mu`
  package vars).
- On each RPC, reads a `secret` key from the incoming gRPC metadata
  (`metadata.FromIncomingContext(ctx)`).
- **Soft mode for this step**: if `configuredSecret` is empty, allow the call
  through unconditionally (this is the current, pre-fix state for any
  platform not yet updated by this plan). If `configuredSecret` is
  non-empty, reject with `codes.Unauthenticated` when the metadata secret
  doesn't match (constant-time compare — use `subtle.ConstantTimeCompare`
  from `crypto/subtle`).
- Wire both interceptors into **both** branches of `StartGrpcServerByMode`
  (the insecure `grpc.NewServer()` call at `:200` and the mTLS
  `grpc.NewServer(grpc.Creds(creds))` call at `:241`) via
  `grpc.ChainUnaryInterceptor(...)`/`grpc.ChainStreamInterceptor(...)` —
  don't special-case one branch, both should honor a configured secret.

Capture `params.Secret` into `configuredSecret` at the top of `Setup`
(`grpc_server.go:41`), before `StartGrpcServerByMode` is called at `:109`.

**Verify**: `cd hiddify-core && go build ./v2/hcore/...` → exit 0.
`grep -n "configuredSecret" v2/hcore/grpc_server.go` shows it read in `Setup`
and checked in the new interceptor.

### Step 2: Desktop — send the secret as call metadata

In `core_interface_desktop.dart`, attach `secret` (already generated at
`:66`) as metadata on both gRPC clients. `package:grpc`'s `ClientChannel`
accepts per-call metadata via `CallOptions`; the simplest approach for a
client used for every call is a `CallOptions(metadata: {'secret': secret})`
passed when constructing `HelloClient`/`CoreClient` (check the `grpc` package
version in `pubspec.lock` for the exact constructor parameter name — recent
`grpc` package versions accept an `options:` named parameter on the generated
client constructors, e.g. `HelloClient(channel, options: CallOptions(metadata: {'secret': secret}))`).

**Verify**: `grep -n "'secret': secret" lib/hiddifycore/core_interface/core_interface_desktop.dart`
returns at least 2 matches (one per client). `make analyze` → no new
findings.

### Step 3: Android — forward the secret from Dart through the method channel into the FFI setup call

In `MethodHandler.kt:76-98`, change `it.secret=""` to read a `secret` string
from the method call's `args` map instead:

```kotlin
                        val secret = args["secret"] as String? ?: ""
                        // ...
                                    it.secret = secret
```

**Verify**: `grep -n "it.secret = secret" android/app/src/main/kotlin/com/hiddify/hiddify/MethodHandler.kt`
returns 1 match, and `grep -c "it.secret=\"\"" android/app/src/main/kotlin/com/hiddify/hiddify/MethodHandler.kt`
returns `0`.

### Step 4: iOS — same fix, plus stop hardcoding `mode`

In the iOS `MethodHandler.swift`'s Setup handler (around line 85), change
`opts.secret = ""` to read from the method call's arguments the same way,
and change `opts.mode = 4` (line 87) to use the `mode` value already
destructured at line 70 instead of a hardcoded constant:

```swift
                    opts.secret = (args["secret"] as? String) ?? ""
                    opts.mode = Int64(mode)
```

Adjust the exact Swift syntax to match this file's existing style — read the
surrounding function first.

**Verify**: `grep -n "opts.secret = " ios/Runner/Handlers/MethodHandler.swift`
shows the new line, and `grep -c "opts.secret = \"\"" ios/Runner/Handlers/MethodHandler.swift`
returns `0`.

### Step 5: Mobile Dart shim — generate a secret and thread it through

In `core_interface_mobile.dart`, add a generated secret (mirror desktop's
`generateRandomPassword` — consider moving that helper to a shared location
both `core_interface_desktop.dart` and `core_interface_mobile.dart` can
import, rather than duplicating it, if that's a small change; otherwise
duplicating a ~4-line static method is acceptable rather than a bigger
refactor). Add `"secret": secret` to the `methodChannel.invokeMethod("setup", {...})`
call's argument map (`:61-68`), and attach the same secret as metadata on
`fgClient`/`bgClient` (`:84-98`) the same way Step 2 did for desktop.

**Verify**: `grep -n "\"secret\": secret" lib/hiddifycore/core_interface/core_interface_mobile.dart`
returns 1 match, and `grep -n "'secret': secret" lib/hiddifycore/core_interface/core_interface_mobile.dart`
returns at least 2 matches (client metadata).

### Step 6: Flip the Go interceptor to mandatory — ONLY if all platforms are verified

This step removes the "soft mode" from Step 1 (empty `configuredSecret`
should now be treated as a misconfiguration, not a bypass) so the fix
actually closes the hole rather than remaining opt-in.

**Before making this change**, confirm Steps 2-5 all landed and, for each
platform you were able to build/test in this environment (see the Commands
table — Android/iOS builds may not be available here), confirm the RPC calls
succeed with the secret attached. If you could not verify Android and/or iOS
in this environment (no SDK/Xcode available), **do NOT flip this to
mandatory** — leave Step 1's soft-mode behavior in place, and report exactly
which platforms you verified vs. couldn't, so this final step becomes a
clearly-scoped follow-up once someone can build/test the unverified
platform(s).

If proceeding: change the interceptor so a request with a missing/wrong
`secret` metadata value is always rejected with `codes.Unauthenticated`,
regardless of whether `configuredSecret` happens to be empty (an empty
configured secret at this point would itself be a bug in one of Steps 2-5,
not a valid state to allow through).

**Verify**: `cd hiddify-core && go test ./v2/hcore/...` → all pass, including
a new test (see Test plan) that a call without the correct secret metadata
is rejected.

## Test plan

- **Go**: add a test in `hiddify-core/v2/hcore/` (new file, e.g.
  `grpc_server_test.go`) that starts a `GRPC_NORMAL_INSECURE` server with a
  configured secret, then asserts a `HelloClient`-equivalent call (or a raw
  gRPC call) without the `secret` metadata is rejected with
  `codes.Unauthenticated`, and the same call **with** the correct secret
  metadata succeeds. Model the harness after the existing
  `v2/hcore/start_test.go` or `log_interface_test.go` for this repo's Go
  test conventions.
- **Dart**: no new automated test — attaching metadata to a `CallOptions` is
  a thin wrapper around a well-tested library API; the meaningful
  verification is the Go-side test above plus a manual end-to-end run (see
  below) confirming the app still connects.
- Manual verification (if you can run the app): start the app on each
  buildable platform, confirm VPN connect/disconnect and settings screens
  still work exactly as before (the fix should be invisible to a working
  user — it only rejects callers that don't send the secret).

## Done criteria

- [ ] `cd hiddify-core && go build ./v2/hcore/...` exits 0
- [ ] `cd hiddify-core && go test ./v2/hcore/...` passes, including the new secret-rejection test
- [ ] `make analyze` (Dart) reports no new findings vs. plan-001 baseline
- [ ] `make test` (Dart) exits 0
- [ ] Every platform's Setup handler (`MethodHandler.kt`, `MethodHandler.swift`, `core_interface_desktop.dart`) sends a non-empty secret — confirmed by the greps in each step
- [ ] Step 6 (mandatory enforcement) is applied ONLY if all reachable-in-this-environment platforms were verified; your final report states explicitly which platforms were verified and which were not
- [ ] `git status` shows changes only to the files in Scope, plus `plans/README.md`
- [ ] `plans/README.md` status row updated, explicitly noting whether Step 6 was applied or deferred and why

## STOP conditions

- Any file's current content doesn't match the excerpts in "Current state"
  (drift since this plan was written) — re-read the live code before
  proceeding; these platform-native files are exactly the kind that could
  have been touched by unrelated work since.
- `go build`/`go vet` on `hiddify-core` fails for a reason unrelated to this
  change (e.g. the nested-submodule checkout issue a prior audit pass
  reported) — note it and verify by reading the diff carefully instead of
  forcing a build fix; don't check out unrelated submodules to work around it.
- You cannot find the iOS or Android build toolchain in this environment —
  make the code changes (Steps 3/4) since they're simple and low-risk to
  write blind, but do NOT proceed to Step 6 (mandatory enforcement) without
  being able to verify at least one of them, per Step 6's own instructions.
- The `grpc` Dart package version in this repo doesn't support per-call
  metadata the way Step 2 assumes — check `pubspec.lock`'s `grpc:` entry and
  read that package's actual `CallOptions`/client-constructor API rather
  than guessing; report if the API differs meaningfully from what's assumed
  here.
- Any existing test (Dart or Go) starts failing after these changes in a way
  not explained by "a call now correctly requires the secret" — investigate
  before assuming it's unrelated.

## Maintenance notes

- This plan intentionally does not fix the mTLS path
  (`GRPC_NORMAL`/`GRPC_BACKGROUND`) — it is currently dead code on every
  platform (mode is hardcoded to the insecure variants everywhere). If a
  future effort wants real transport-level mutual TLS instead of a shared
  secret over an otherwise-plaintext-to-localhost channel, that effort needs
  to actually finish the commented-out key exchange in
  `core_interface_mobile.dart:73-79` and its Android/iOS counterparts — this
  plan does not block that, but doesn't attempt it either.
- The secret is transmitted over loopback-only TCP (127.0.0.1) without TLS
  even after this plan — it protects against a *different* local process
  connecting, not against traffic interception on the loopback interface
  itself (which requires kernel-level access already implying compromise).
  That's an accepted, standard trade-off for loopback-only control channels;
  don't treat it as a gap this plan needs to also close.
- If Step 6 was deferred (soft-mode interceptor left in place because not
  all platforms could be verified), the very next thing whoever picks this
  up should do is verify the remaining platform(s) and then apply Step 6 —
  don't let the soft-mode state linger indefinitely, since it means the
  interceptor is currently a no-op for any caller that (by bug or
  regression) stops sending a secret.
