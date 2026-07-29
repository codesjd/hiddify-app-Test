import 'dart:async';

import 'package:fpdart/fpdart.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:rxdart/rxdart.dart';

mixin ExceptionHandler implements LoggerMixin {
  TaskEither<F, R> exceptionHandler<F, R>(
    Future<Either<F, R>> Function() run,
    F Function(Object error, StackTrace stackTrace) onError,
  ) {
    return TaskEither(() async {
      try {
        return await run();
      } catch (error, stackTrace) {
        return Left(onError(error, stackTrace));
      }
    });
  }
}

extension StreamExceptionHandler<R extends Object?> on Stream<R> {
  /// Emits [Left(onError(...))] on error then re-subscribes to the source with
  /// exponential backoff (1s → 2s → 4s … capped at [maxDelay]).
  /// The stream terminates only when the source terminates normally.
  Stream<Either<F, R>> handleExceptions<F>(
    F Function(Object error, StackTrace stackTrace) onError, {
    Duration initialDelay = const Duration(seconds: 1),
    Duration maxDelay = const Duration(seconds: 30),
  }) {
    // ponytail: simple controller-based resume; upgrade to RetryWhenStream
    // if we ever need cancellation tokens or structured concurrency.
    final controller = StreamController<Either<F, R>>.broadcast();
    Duration delay = initialDelay;

    void subscribe() {
      map(right<F, R>).listen(
        (event) {
          delay = initialDelay; // reset backoff on success
          controller.add(event);
        },
        onError: (Object error, StackTrace stackTrace) {
          controller.add(Left(onError(error, stackTrace)));
          if (!controller.isClosed) {
            Future.delayed(delay, () {
              if (!controller.isClosed) {
                delay = delay * 2 > maxDelay ? maxDelay : delay * 2;
                subscribe();
              }
            });
          }
        },
        onDone: () => controller.close(),
        cancelOnError: true,
      );
    }

    subscribe();
    return controller.stream;
  }
}

extension TaskEitherExceptionHandler<F, R> on TaskEither<F, R> {
  TaskEither<F, R> handleExceptions(F Function(Object error, StackTrace stackTrace) onError) {
    return TaskEither(() async {
      try {
        return await run();
      } catch (error, stackTrace) {
        return Left(onError(error, stackTrace));
      }
    });
  }
}
