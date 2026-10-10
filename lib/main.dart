import 'package:flutter/material.dart';

import 'app_paths.dart';
import 'ui/stock_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await loadAppConfig();
  runApp(StockApp(config: config));
}
