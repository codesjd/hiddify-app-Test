import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/utils/exception_handler.dart';

/// Helper: build a stream from a factory that is called on each subscription.
Stream<int> _factoryStream(Stream<int> Function() factory) {
  return Stream<int>.multi((controller) {
    factory().listen(controller.add, onError: controller.addError, onDone: controller.close);
  });
}

void main() {
  group("handleExceptions", () {
    test("Should resume after error and not complete the stream", () async {
      var calls = 0;
      // First subscription: emits 1 then errors. Second: emits 2 then closes.
      final source = _factoryStream(() {
        calls++;
        if (calls == 1) {
          return Stream<int>.multi((c) {
            c.add(1);
            c.addError(Exception("transient"));
          });
        } else {
          return Stream<int>.fromIterable([2]);
        }
      });

      final results = <Either<String, int>>[];
      final wrapped = source.handleExceptions<String>(
        (e, _) => "error",
        initialDelay: const Duration(milliseconds: 10),
      );

      final sub = wrapped.listen(results.add);

      // Wait long enough for re-subscribe and second emission
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      expect(results, [const Right<String, int>(1), const Left<String, int>("error"), const Right<String, int>(2)]);
    });

    test("Should complete normally when source completes", () async {
      final source = Stream<int>.fromIterable([1, 2]);
      final results = <Either<String, int>>[];

      await source.handleExceptions<String>((e, _) => "error").forEach(results.add);

      expect(results, [const Right<String, int>(1), const Right<String, int>(2)]);
    });

    test("Should not complete after repeated errors", () async {
      var emissions = 0;
      final source = _factoryStream(
        () => Stream<int>.multi((c) {
          c.addError(Exception("down"));
        }),
      );

      final wrapped = source.handleExceptions<String>(
        (e, _) => "error",
        initialDelay: const Duration(milliseconds: 10),
        maxDelay: const Duration(milliseconds: 20),
      );

      final sub = wrapped.listen((_) => emissions++);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // Stream is still alive — not completed
      expect(sub.isPaused, false);
      await sub.cancel();
      // Multiple Left emissions received (backoff kept re-subscribing)
      expect(emissions, greaterThan(1));
    });
  });
}
