// Cycle 8d — config smoke test (pure Dart, no device). Loads the real
// config.v1.json asset and asserts it exposes exactly the 7-keyword grammar,
// consistent with keyword_config.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:fsd_app/capture/keyword_config.dart';
import 'package:fsd_app/config/app_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('test_config_loads_keywords', () async {
    final config = await AppConfig.load('assets/config/config.v1.json');

    expect(config.keywords, const <String>[
      'log it',
      'log scary',
      'mark level one',
      'mark level two',
      'mark level three',
      'mark level four',
      'mark level five',
    ]);
    // The config file and the code grammar must agree.
    expect(config.keywords, configuredKeywords);
  });
}
