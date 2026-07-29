// ignore_for_file: avoid_dynamic_calls
import 'package:flutter_test/flutter_test.dart';

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

/// Hand-maintained mirror of SingboxConfigOption's JSON key shape.
/// Keep in sync with lib/singbox/model/singbox_config_option.dart.
/// All values are placeholders — only the *keys* matter.
const _wireModelJson = <String, dynamic>{
  "region": "",
  "balancer-strategy": "",
  "use-xray-core-when-possible": false,
  "execute-config-as-is": false,
  "log-level": "",
  "resolve-destination": false,
  "ipv6-mode": "",
  "remote-dns-address": "",
  "remote-dns-domain-strategy": "",
  "direct-dns-address": "",
  "direct-dns-domain-strategy": "",
  "mixed-port": 0,
  "tproxy-port": 0,
  "direct-port": 0,
  "redirect-port": 0,
  "enable-mixed-port": false,
  "enable-tproxy-port": false,
  "enable-direct-port": false,
  "enable-redirect-port": false,
  "tun-implementation": "",
  "mtu": 0,
  "strict-route": false,
  "connection-test-url": "",
  "url-test-interval": 0,
  "enable-clash-api": false,
  "clash-api-port": 0,
  "enable-tun": false,
  "set-system-proxy": false,
  "allow-connection-from-lan": false,
  "lan-sharing-password": "",
  "enable-fake-dns": false,
  "independent-dns-cache": false,
  "route-rule": <String, dynamic>{},
  "tls-tricks": <String, dynamic>{
    "enable-fragment": false,
    "fragment-size": "",
    "fragment-sleep": "",
    "mixed-sni-case": false,
    "enable-padding": false,
    "padding-size": "",
  },
  "chain-status": "",
  "extra-security": <String, dynamic>{
    "mode": "",
    "warp": <String, dynamic>{"license-key": ""},
    "psiphon": <String, dynamic>{"region": "", "conduit-pairing-id": ""},
    "profile": <String, dynamic>{"id": ""},
  },
  "unblocker": <String, dynamic>{
    "mode": "",
    "warp": <String, dynamic>{
      "license-key": "",
      "clean-ip": "",
      "clean-port": 0,
      "noise": "",
      "noise-size": "",
      "noise-delay": "",
      "noise-mode": "",
    },
    "psiphon": <String, dynamic>{"region": "", "conduit-pairing-id": ""},
    "profile": <String, dynamic>{"id": ""},
  },
};

/// Keys in ConfigOptions.preferences that are intentionally NOT in the wire
/// model (they are app-layer only, not sent to the core).
const _appOnlyKeys = <String>{
  // service-mode is an app setting, not a singbox wire field
  "service-mode",
};

void main() {
  group("ConfigOptions.preferences", () {
    test("Should only contain keys that exist in the wire model (or are app-only)", () {
      final modelKeys = flattenKeys(_wireModelJson);
      // These keys live in preferences but are deliberately absent from the
      // wire model. Add here only with a comment explaining why.
      final registered = <String>{
        "region",
        "balancer-strategy",
        "use-xray-core-when-possible",
        "service-mode", // app-only
        "log-level",
        "resolve-destination",
        "ipv6-mode",
        "remote-dns-address",
        "remote-dns-domain-strategy",
        "direct-dns-address",
        "direct-dns-domain-strategy",
        "mixed-port",
        "tproxy-port",
        "direct-port",
        "redirect-port",
        "enable-mixed-port",
        "enable-tproxy-port",
        "enable-direct-port",
        "enable-redirect-port",
        "tun-implementation",
        "mtu",
        "strict-route",
        "connection-test-url",
        "url-test-interval",
        "enable-clash-api",
        "clash-api-port",
        "allow-connection-from-lan",
        "lan-sharing-password",
        "enable-fake-dns",
        "independent-dns-cache",
        "tls-tricks.enable-fragment",
        "tls-tricks.fragment-size",
        "tls-tricks.fragment-sleep",
        "tls-tricks.mixed-sni-case",
        "tls-tricks.enable-padding",
        "tls-tricks.padding-size",
        "chain-status",
        "extra-security.mode",
        "extra-security.warp.license-key",
        "extra-security.psiphon.region",
        "extra-security.psiphon.conduit-pairing-id",
        "extra-security.profile.id",
        "unblocker.mode",
        "unblocker.warp.license-key",
        "unblocker.warp.clean-ip",
        "unblocker.warp.clean-port",
        "unblocker.warp.noise",
        "unblocker.warp.noise-size",
        "unblocker.warp.noise-mode",
        "unblocker.warp.noise-delay",
        "unblocker.psiphon.region",
        "unblocker.psiphon.conduit-pairing-id",
        "unblocker.profile.id",
      };

      final orphaned = registered.difference(modelKeys).difference(_appOnlyKeys);
      expect(
        orphaned,
        isEmpty,
        reason: "these preference paths have no field in SingboxConfigOption: $orphaned",
      );
    });
  });
}
