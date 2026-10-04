/// 应用配置：环境变量优先，其次项目根目录 .env（KEY=VALUE 格式）。
/// Flutter 没有原生 .env 支持，这里用纯 Dart 解析，CLI 与 App 四端通用。
library;

import 'dart:io';

class AppConfig {
  const AppConfig({
    required this.tushareToken,
    required this.dbPath,
    this.themeAccent = 'red',
    this.configPath = '',
  });

  final String tushareToken;
  final String dbPath;

  /// 主题强调色名（red/charcoal/blue/green），解析在 UI 层做。
  final String themeAccent;

  /// 设置页保存配置的目标文件；空字符串表示由 StockApp 退回 ~/.stock/.env。
  /// 移动端由 path_provider 解析（沙盒内路径），桌面保持与 CLI 共享 ~/.stock。
  final String configPath;

  AppConfig copyWith({String? tushareToken, String? dbPath, String? themeAccent, String? configPath}) =>
      AppConfig(
        tushareToken: tushareToken ?? this.tushareToken,
        dbPath: dbPath ?? this.dbPath,
        themeAccent: themeAccent ?? this.themeAccent,
        configPath: configPath ?? this.configPath,
      );

  /// 解析 .env 文本：跳过注释/空行/无等号行，去首尾空白与成对引号。
  static Map<String, String> parseDotEnv(String content) {
    final vars = <String, String>{};
    for (final raw in content.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final i = line.indexOf('=');
      if (i <= 0) continue;
      var value = line.substring(i + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      vars[line.substring(0, i).trim()] = value;
    }
    return vars;
  }

  /// 依序合并多个 .env 文件（后者覆盖前者），缺失文件跳过。
  static Map<String, String> loadDotEnv(List<String> paths) {
    final merged = <String, String>{};
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      merged.addAll(parseDotEnv(file.readAsStringSync()));
    }
    return merged;
  }

  /// 读取顺序：进程环境变量 → ~/.stock/.env（App 设置页写入处）→ 当前目录 .env（CLI 开发用）。
  /// [dbPath] 显式指定时覆盖文件/默认值（移动端沙盒路径用）。
  static AppConfig load({String? envFile, String? dbPath}) {
    final home = Platform.environment['HOME'] ?? '.';
    final defaultHome = '$home/.stock';
    final files = envFile != null ? [envFile] : ['$defaultHome/.env', '.env'];
    final fileVars = loadDotEnv(files);
    String pick(String key) => Platform.environment[key] ?? fileVars[key] ?? '';
    final fileDb = pick('STOCK_DB_PATH');
    return AppConfig(
      tushareToken: pick('TUSHARE_TOKEN'),
      dbPath: dbPath ?? (fileDb == '' ? '$defaultHome/stock.db' : fileDb),
      themeAccent: pick('THEME_ACCENT') == '' ? 'red' : pick('THEME_ACCENT'),
      configPath: envFile ?? files.first,
    );
  }

  /// 合并写入配置文件（保留已有键），父目录不存在时自动创建。
  static Future<void> updateFile(String path, Map<String, String> updates) async {
    final file = File(path);
    final vars = file.existsSync() ? parseDotEnv(file.readAsStringSync()) : <String, String>{};
    vars.addAll(updates);
    await file.parent.create(recursive: true);
    await file.writeAsString('${[for (final e in vars.entries) '${e.key}=${e.value}'].join('\n')}\n');
  }
}
