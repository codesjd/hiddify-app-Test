// ignore_for_file: avoid_dynamic_calls
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/model/optional_range.dart';
import 'package:hiddify/features/log/model/log_level.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';

/// Flattens a nested json map into dotted paths, e.g. {"a": {"b": 1}} -> {"a.b"}.
Set<String> flattenKeys(Map<String, dynamic> json, [String prefix = ""]) {
  final keys = <String>{};
  json.forEach((key, value) {
    final path = prefix.isEmpty ? key : "$prefix.$key";
    if (value is Map<String, dynamic>) {
      keys.addAll(flattenKeys(value, path));
    } else {
      keys.add(path);
    }
  });
  return keys;
}

/// A SingboxConfigOption built from real field values (any valid placeholder
/// works, only the resulting JSON *keys* matter here) - its .toJson() is the
/// actual, live wire-model key shape, not a hand-maintained copy of it, so
/// this test tracks the real model automatically as it changes.
SingboxConfigOption _placeholderConfigOption() {
  return SingboxConfigOption(
    region: "",
    balancerStrategy: BalancerStrategy.values.first,
    useXrayCoreWhenPossible: false,
    executeConfigAsIs: false,
    logLevel: LogLevel.values.first,
    resolveDestination: false,
    ipv6Mode: IPv6Mode.values.first,
    remoteDnsAddress: "",
    remoteDnsDomainStrategy: DomainStrategy.values.first,
    directDnsAddress: "",
    directDnsDomainStrategy: DomainStrategy.values.first,
    mixedPort: 0,
    tproxyPort: 0,
    directPort: 0,
    redirectPort: 0,
    enableMixedPort: false,
    enableTproxyPort: false,
    enableDirectPort: false,
    enableRedirectPort: false,
    tunImplementation: TunImplementation.values.first,
    mtu: 0,
    strictRoute: false,
    connectionTestUrl: "",
    urlTestInterval: Duration.zero,
    enableClashApi: false,
    clashApiPort: 0,
    enableTun: false,
    setSystemProxy: false,
    allowConnectionFromLan: false,
    lanSharingPassword: "",
    enableFakeDns: false,
    independentDnsCache: false,
    routeRule: const {},
    tlsTricks: const SingboxTlsTricks(
      enableFragment: false,
      fragmentSize: OptionalRange(),
      fragmentSleep: OptionalRange(),
      mixedSniCase: false,
      enablePadding: false,
      paddingSize: OptionalRange(),
    ),
    chainStatus: ChainStatus.values.first,
    extraSecurity: SingboxExtraSecurityOption(
      mode: ChainMode.values.first,
      warp: const SingboxExtraSecurityWarpOption(licenseKey: ""),
      psiphon: SingboxExtraSecurityPsiphonOption(region: PsiphonRegion.values.first, conduitPairingId: ""),
      profile: const SingboxExtraSecurityProfileOption(id: null),
    ),
    unblocker: SingboxUnblockerOption(
      mode: ChainMode.values.first,
      warp: const SingboxUnblockerWarpOption(
        licenseKey: "",
        cleanIp: "",
        cleanPort: 0,
        noise: OptionalRange(),
        noiseSize: OptionalRange(),
        noiseDelay: OptionalRange(),
        noiseMode: "",
      ),
      psiphon: SingboxUnblockerPsiphonOption(region: PsiphonRegion.values.first, conduitPairingId: ""),
      profile: const SingboxUnblockerProfileOption(id: null),
    ),
  );
}

/// Keys in ConfigOptions.preferences that are intentionally NOT in the wire
/// model (they are app-layer only, not sent to the core).
const _appOnlyKeys = <String>{
  // service-mode is an app setting, not a singbox wire field
  "service-mode",
};

void main() {
  group("ConfigOptions.preferences", () {
    test("Should only contain keys that exist in the wire model (or are app-only)", () {
      final modelKeys = flattenKeys(_placeholderConfigOption().toJson());
      final registered = ConfigOptions.preferences.keys.toSet();

      final orphaned = registered.difference(modelKeys).difference(_appOnlyKeys);
      expect(
        orphaned,
        isEmpty,
        reason:
            "these preference paths have no field in SingboxConfigOption (real .toJson() output): $orphaned. "
            "Either the preference key is wrong/stale, or it needs adding to _appOnlyKeys with a reason.",
      );
    });
  });
}
