import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/analytics/analytics_filter.dart';

void main() {
  group("redactSensitive", () {
    test("Should redact a password field in outbound json", () {
      const input = '{"type":"trojan","server":"example.com","password":"s3cret"}';
      final out = redactSensitive(input);
      expect(out.contains("s3cret"), false);
      expect(out.contains("example.com"), true);
    });

    test("Should redact a uuid field", () {
      const input = '{"uuid":"8d1e4243-7ecf-4ffa-89ec-8b63eee75337"}';
      expect(redactSensitive(input).contains("8d1e4243"), false);
    });

    test("Should redact url user info", () {
      const input = "https://user:token123@example.com/sub";
      final out = redactSensitive(input);
      expect(out.contains("token123"), false);
      expect(out.contains("example.com"), true);
    });

    test("Should leave harmless text unchanged", () {
      const input = "connection established to example.com";
      expect(redactSensitive(input), input);
    });
  });
}
