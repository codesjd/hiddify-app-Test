import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('write(null) removes the key instead of throwing', () async {
    SharedPreferences.setMockInitialValues({'my-key': 'existing-value'});
    final prefs = await SharedPreferences.getInstance();
    final entry = PreferencesEntry<String?, String?>(preferences: prefs, key: 'my-key', defaultValue: null);

    expect(prefs.containsKey('my-key'), isTrue);

    final result = await entry.write(null);

    expect(result, isTrue);
    expect(prefs.containsKey('my-key'), isFalse);
    expect(entry.read(), isNull);
  });

  test('write(non-null) still round-trips normally', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final entry = PreferencesEntry<String?, String?>(preferences: prefs, key: 'my-key', defaultValue: null);

    expect(await entry.write('value'), isTrue);
    expect(entry.read(), equals('value'));
  });
}
