import 'package:dio/dio.dart';

void main() {
  final c = CancelToken();
  c.cancel();
  // ignore: avoid_print
  print("isCancelled: ${c.isCancelled}");
}
