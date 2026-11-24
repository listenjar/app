// The app with Flutter Driver's extension on, for driving it from the Dart
// MCP server (tap, type, screenshot): `flutter run -t test_driver/main.dart`.
// Not a test; the e2e suite lives in the monorepo's e2e/.
import 'package:desktop/main.dart' as app;
import 'package:flutter_driver/driver_extension.dart';

Future<void> main(List<String> arguments) async {
  enableFlutterDriverExtension(enableTextEntryEmulation: false);
  await app.main(arguments);
}
