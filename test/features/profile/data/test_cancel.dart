import 'package:dio/dio.dart';
void main() {
  final c = CancelToken();
  c.cancel();
  print("isCancelled: ${c.isCancelled}");
}
