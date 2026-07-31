import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/utils/exception_handler.dart';

void main() {
  group("handleExceptions", () {
    test("Should resume after error and not complete the stream (real single-subscription source)", () async {
      var calls = 0;
      // Every call must return a genuinely fresh, single-subscription stream - the
      // same shape as the async* methods this extension actually wraps in production
      // (watchGroup(), watchActiveGroups(), watchStats(), etc). First call: emits 1
      // then errors. Second call: emits 2 then closes.
      Stream<int> source() async* {
        calls++;
        if (calls == 1) {
          yield 1;
          throw Exception("transient");
        } else {
          yield 2;
        }
      }

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
      Stream<int> source() => Stream<int>.fromIterable([1, 2]);
      final results = <Either<String, int>>[];

      await source.handleExceptions<String>((e, _) => "error").forEach(results.add);

      expect(results, [const Right<String, int>(1), const Right<String, int>(2)]);
    });

    test("Should not complete after repeated errors", () async {
      var emissions = 0;
      Stream<int> source() async* {
        throw Exception("down");
      }

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

    test("sanity check: a single-subscription stream cannot be listened to twice - "
        "this is why handleExceptions must take a factory, not an already-materialized stream", () {
      Stream<int> single() async* {
        yield 1;
      }

      final s = single();
      s.listen((_) {});
      expect(() => s.listen((_) {}), throwsStateError);
    });
  });
}
