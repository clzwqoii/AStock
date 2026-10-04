/// App 启动配置加载：
/// - 桌面（macOS/Windows/Linux）：沿用 ~/.stock，与命令行工具共享同一份数据/配置；
/// - 移动端（iOS/Android）：沙盒强制隔离，$HOME 不可靠，改用 path_provider 的应用支持目录。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'config.dart';

Future<AppConfig> loadAppConfig() async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return AppConfig.load();
  }
  final dir = await getApplicationSupportDirectory();
  return AppConfig.load(
    envFile: '${dir.path}/.env',
    dbPath: '${dir.path}/stock.db',
  );
}