import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/singbox/model/singbox_proxy_type.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// Fake client: cancels the shared token on the first download attempt.
class _CancelOnDownloadClient extends DioHttpClient {
  _CancelOnDownloadClient() : super(timeout: const Duration(seconds: 1), userAgent: 'test', debug: false);

  @override
  Future<Response> download(
    String url,
    String path, {
    CancelToken? cancelToken,
    String? userAgent,
    ({String username, String password})? credentials,
    bool proxyOnly = false,
  }) async {
    cancelToken?.cancel();
    throw DioException(requestOptions: RequestOptions(path: url), type: DioExceptionType.cancel);
  }
}

void main() {
  const validBaseUrl = "https://example.com/configurations/user1/filename.yaml";
  const validExtendedUrl = "https://example.com/configurations/user1/filename.yaml?test#b";
  const validSupportUrl = "https://example.com/support";

  group("parse", () {
    test("Should use filename in url with no headers and fragment", () {
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validBaseUrl,
          lastUpdate: DateTime.now(),
        ),
      );
      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        expect(r is RemoteProfileEntity, true);
        r.map(
          remote: (rp) {
            expect(rp.name, equals("filename"));
            expect(rp.url, equals(validBaseUrl));
            expect(rp.options, isNull);
            expect(rp.subInfo, isNull);
          },
          local: (lp) {},
        );
      });
    });

    test("Should use fragment in url with no headers", () {
      final profile = ProfileParser.parse(
        tempFilePath: '',
        profile: ProfileEntity.remote(
          id: const Uuid().v4(),
          active: true,
          name: '',
          url: validExtendedUrl,
          lastUpdate: DateTime.now(),
        ),
      );
      expect(profile.isRight(), true);
      profile.match((l) {}, (r) {
        expect(r is RemoteProfileEntity, true);
        r.map(
          remote: (rp) {
            expect(rp.name, equals("b"));
            expect(rp.url, equals(validExtendedUrl));
            expect(rp.options, isNull);
            expect(rp.subInfo, isNull);
          },
          local: (lp) {},
        );
      });
    });

    test("Should use base64 title in headers", () {
      final headers = <String, List<String>>{
        "profile-title": ["base64:ZXhhbXBsZVRpdGxl"],
        "profile-update-interval": ["1"],
        "connection-test-url": [validBaseUrl],
        "remote-dns-address": [validBaseUrl],
        "subscription-userinfo": ["upload=0;download=1024;total=10240.5;expire=1704054600.55"],
        "profile-web-page-url": [validBaseUrl],
        "support-url": [validSupportUrl],
      };
      // This fix occurs in the _downloadProfile method within ProfileParser, and the fixed headers are passed to populateHeaders
      final fixedHeaders = headers.map((key, value) {
        if (value.length == 1) return MapEntry(key, value.first);
        return MapEntry(key, value);
      });
      final allHeaders = ProfileParser.populateHeaders(content: '', remoteHeaders: fixedHeaders);
      expect(allHeaders.isRight(), true);
      allHeaders.match((l) {}, (r) {
        final profile = ProfileParser.parse(
          tempFilePath: '',
          profile: ProfileEntity.remote(
            id: const Uuid().v4(),
            active: true,
            name: '',
            url: validExtendedUrl,
            lastUpdate: DateTime.now(),
            populatedHeaders: r,
          ),
        );
        expect(profile.isRight(), true);
        profile.match((l) {}, (r) {
          expect(r is RemoteProfileEntity, true);
          r.map(
            remote: (rp) {
              expect(rp.name, equals("exampleTitle"));
              expect(rp.url, equals(validExtendedUrl));
              expect(rp.options, equals(const ProfileOptions(updateInterval: Duration(hours: 1))));
              expect(
                rp.subInfo,
                equals(
                  SubscriptionInfo(
                    upload: 0,
                    download: 1024,
                    total: 10240,
                    expire: DateTime.fromMillisecondsSinceEpoch(1704054600 * 1000),
                    webPageUrl: validBaseUrl,
                    supportUrl: validSupportUrl,
                  ),
                ),
              );
            },
            local: (lp) {},
          );
        });
      });
    });

    test("Should use infinite when given 0 for subscription properties", () {
      final headers = <String, List<String>>{
        "profile-title": ["title"],
        "profile-update-interval": ["1"],
        "subscription-userinfo": ["upload=0;download=1024;total=0;expire=0"],
        "profile-web-page-url": [validBaseUrl],
        "support-url": [validSupportUrl],
      };
      // This fix occurs in the _downloadProfile method within ProfileParser, and the fixed headers are passed to populateHeaders
      final fixedHeaders = headers.map((key, value) {
        if (value.length == 1) return MapEntry(key, value.first);
        return MapEntry(key, value);
      });
      final allHeaders = ProfileParser.populateHeaders(content: '', remoteHeaders: fixedHeaders);
      expect(allHeaders.isRight(), true);
      allHeaders.match((l) {}, (r) {
        final profile = ProfileParser.parse(
          tempFilePath: '',
          profile: RemoteProfileEntity(
            id: const Uuid().v4(),
            active: true,
            name: '',
            url: validBaseUrl,
            lastUpdate: DateTime.now(),
            populatedHeaders: r,
          ),
        );
        expect(profile.isRight(), true);
        profile.match((l) {}, (r) {
          expect(r is RemoteProfileEntity, true);
          r.map(
            remote: (rp) {
              expect(rp.subInfo, isNotNull);
              expect(rp.subInfo!.total, equals(ProfileParser.infiniteTrafficThreshold + 1));
              expect(
                rp.subInfo!.expire,
                equals(DateTime.fromMillisecondsSinceEpoch(ProfileParser.infiniteTimeThreshold * 1000)),
              );
            },
            local: (lp) {},
          );
        });
      });
    });
  });

  // Plan 008: expandRemoteLinesInParallel must not write "null" on partial cancellation
  group("expandRemoteLinesInParallel", () {
    test("does not write literal 'null' when cancelled mid-expansion", () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final refProvider = Provider<Ref>((ref) => ref);
      final ref = container.read(refProvider);
      await container.read(sharedPreferencesProvider.future);

      final tempFile = await File(
        '${Directory.systemTemp.path}/expand_test_${DateTime.now().microsecondsSinceEpoch}.txt',
      ).create();
      addTearDown(() {
        if (tempFile.existsSync()) tempFile.deleteSync();
      });
      await tempFile.writeAsString('line-a\nhttp://example.invalid/x\nline-b');

      final parser = ProfileParser(ref: ref, httpClient: _CancelOnDownloadClient());
      final cancelToken = CancelToken();

      await parser.expandRemoteLinesInParallel(
        tempFilePath: tempFile.path,
        httpClient: _CancelOnDownloadClient(),
        cancelToken: cancelToken,
        ref: ref,
        parallelism: 1,
      );

      final finalContent = await tempFile.readAsString();
      expect(finalContent, equals('line-a\nhttp://example.invalid/x\nline-b'));
      expect(finalContent.contains('null'), isFalse);
    });
  });

  // Plan 011: characterization tests for ProfileParser static methods
  group("populateHeaders parses headers from content", () {
    test("extracts # and // prefixed headers from content, ignores unknown keys", () {
      const content = "#profile-title: My Config\n"
          "// support-url: https://example.com/support\n"
          "#unknown-key: should be dropped\n"
          "vless://actual-config-line-not-a-header";
      final result = ProfileParser.populateHeaders(content: content);
      expect(result.isRight(), true);
      result.match((l) {}, (r) {
        expect(r["profile-title"], equals("My Config"));
        expect(r["support-url"], equals("https://example.com/support"));
        expect(r.containsKey("unknown-key"), isFalse);
      });
    });

    test("only scans the first 10 lines of content", () {
      final lines = List.generate(15, (i) => "line $i");
      lines[12] = "#profile-title: too late";
      final content = lines.join("\n");
      final result = ProfileParser.populateHeaders(content: content);
      expect(result.isRight(), true);
      result.match((l) {}, (r) {
        expect(r.containsKey("profile-title"), isFalse);
      });
    });

    test("content headers are overridden by remote headers with the same key", () {
      const content = "#profile-title: From Content";
      final result = ProfileParser.populateHeaders(
        content: content,
        remoteHeaders: {"profile-title": "From Remote"},
      );
      expect(result.isRight(), true);
      result.match((l) {}, (r) {
        expect(r["profile-title"], equals("From Remote"));
      });
    });
  });

  group("protocol", () {
    test("detects wireguard from [Interface] marker regardless of other lines", () {
      const content = "some preamble\n[Interface]\nPrivateKey = abc";
      expect(ProfileParser.protocol(content), equals(ProxyType.wireguard.label));
    });

    test("detects vless from a vless:// uri line", () {
      const content = "vless://uuid@host:443?type=tcp#My%20Server";
      expect(ProfileParser.protocol(content), equals("My Server"));
    });

    test("falls back to the scheme label when the uri has no fragment", () {
      const content = "trojan://password@host:443";
      expect(ProfileParser.protocol(content), equals(ProxyType.trojan.label));
    });

    test("returns unknown label when nothing matches", () {
      const content = "not a uri at all\njust some text";
      expect(ProfileParser.protocol(content), equals(ProxyType.unknown.label));
    });
  });

  group("profileOverride", () {
    test("enable-warp header sets chain-status and extra-security", () {
      final result = ProfileParser.profileOverride(
        populatedHeaders: {"enable-warp": "true"},
        userOverride: null,
      );
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded["chain-status"], equals("extra_security"));
      expect(decoded["extra-security"], equals({"mode": "warp"}));
    });

    test("keys not in allowedOverrideConfigs are dropped", () {
      final result = ProfileParser.profileOverride(
        populatedHeaders: {"not-an-allowed-key": "value", "connection-test-url": "https://example.com"},
        userOverride: null,
      );
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded.containsKey("not-an-allowed-key"), isFalse);
      expect(decoded["connection-test-url"], equals("https://example.com"));
    });

    test("userOverride.enableFragment sets tls-tricks even without a header", () {
      final result = ProfileParser.profileOverride(
        populatedHeaders: null,
        userOverride: const UserOverride(enableFragment: true),
      );
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded["tls-tricks"], equals({"enable-fragment": true}));
    });
  });

  group("applyProfileOverride", () {
    test("returns main unchanged when override is null", () {
      final main = {"a": 1};
      expect(ProfileParser.applyProfileOverride(main, null), equals({"a": 1}));
    });

    test("deep-merges nested maps instead of replacing them", () {
      final main = {
        "outer": {"a": 1, "b": 2},
      };
      final override = jsonEncode({
        "outer": {"b": 99, "c": 3},
      });
      final result = ProfileParser.applyProfileOverride(main, override);
      expect(
        result,
        equals({
          "outer": {"a": 1, "b": 99, "c": 3},
        }),
      );
    });

    test("non-map override string (no '{') leaves main unchanged", () {
      final main = {"a": 1};
      expect(ProfileParser.applyProfileOverride(main, "not-json"), equals({"a": 1}));
    });
  });
}
