import 'dart:io';

import 'package:dio/dio.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Keys whose values are credential-grade in a sing-box outbound: leaking one
/// identifies the user's provider and grants access to it. Also covers the
/// user-info portion of subscription URLs.
const _sensitiveJsonKeys = <String>[
  "password",
  "uuid",
  "private_key",
  "pre_shared_key",
  "psk",
  "auth",
  "auth_str",
  "token",
  "secret",
  "license_key",
];

/// Best-effort redaction for text that may embed proxy configuration or
/// subscription URLs. Applied to Sentry breadcrumbs and event messages so a
/// stray log call cannot ship credentials to telemetry.
String redactSensitive(String input) {
  var out = input;
  for (final key in _sensitiveJsonKeys) {
    // "key": "value"  ->  "key": "[redacted]"
    out = out.replaceAll(
      RegExp('"$key"\\s*:\\s*"[^"]*"', caseSensitive: false),
      '"$key": "[redacted]"',
    );
  }
  // scheme://user:pass@host  ->  scheme://[redacted]@host
  out = out.replaceAll(
    RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s@]+@'),
    r'$1[redacted]@',
  );
  return out;
}

FutureOr<SentryEvent?> sentryBeforeSend(SentryEvent event, Hint hint) async {
  if (!canSendEvent(event.throwable)) return null;
  final scrubbed = event.copyWith(
    user: SentryUser(email: "", username: "", ipAddress: "0.0.0.0"),
    breadcrumbs: event.breadcrumbs
        ?.map((b) => b.copyWith(message: b.message == null ? null : redactSensitive(b.message!)))
        .toList(),
  );
  final message = scrubbed.message;
  if (message == null) return scrubbed;
  return scrubbed.copyWith(
    message: SentryMessage(
      redactSensitive(message.formatted),
      template: message.template,
      params: message.params,
    ),
  );
}

Breadcrumb? sentryBeforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  if (breadcrumb == null) return null;
  final message = breadcrumb.message;
  if (message == null) return breadcrumb;
  return breadcrumb.copyWith(message: redactSensitive(message));
}

bool canSendEvent(dynamic throwable) {
  return switch (throwable) {
    UnexpectedFailure(:final error) => canSendEvent(error),
    DioException _ => false,
    SocketException _ => false,
    HttpException _ => false,
    HandshakeException _ => false,
    ExpectedFailure _ => false,
    ExpectedMeasuredFailure _ => false,
    _ => true,
  };
}

bool canLogEvent(dynamic throwable) => switch (throwable) {
  ExpectedMeasuredFailure _ => true,
  _ => canSendEvent(throwable),
};
