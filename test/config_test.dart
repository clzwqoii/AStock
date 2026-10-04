import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/config.dart';

void main() {
  group('parseDotEnv', () {
    test('解析 KEY=VALUE，跳过注释与空行', () {
      final m = AppConfig.parseDotEnv('''
# 注释行
TUSHARE_TOKEN=abc123

STOCK_DB_PATH=/tmp/stock.db
''');
      expect(m['TUSHARE_TOKEN'], 'abc123');
      expect(m['STOCK_DB_PATH'], '/tmp/stock.db');
    });

    test('去掉首尾空白与成对引号，保留值中的等号', () {
      final m = AppConfig.parseDotEnv('A= x = y \nB="q"\nC=\'1\'\nbroken line');
      expect(m['A'], 'x = y');
      expect(m['B'], 'q');
      expect(m['C'], '1');
      expect(m.containsKey('broken line'), isFalse);
    });
  });

  group('loadDotEnv 多文件合并', () {
    test('后面的文件覆盖前面的，缺失文件跳过', () async {
      final tmp = await Directory.systemTemp.createTemp('envtest');
      File('${tmp.path}/a.env').writeAsStringSync('TUSHARE_TOKEN=from-home\nONLY_A=1');
      File('${tmp.path}/b.env').writeAsStringSync('TUSHARE_TOKEN=from-cwd');
      final m = AppConfig.loadDotEnv(['${tmp.path}/a.env', '${tmp.path}/b.env', '${tmp.path}/missing.env']);
      expect(m['TUSHARE_TOKEN'], 'from-cwd');
      expect(m['ONLY_A'], '1');
      tmp.deleteSync(recursive: true);
    });
  });

  group('AppConfig 路径解析', () {
    test('load 支持显式 dbPath 覆盖，记录 configPath', () async {
      final tmp = await Directory.systemTemp.createTemp('envtest');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final cfg = AppConfig.load(envFile: '${tmp.path}/.env', dbPath: '/custom/x.db');
      expect(cfg.dbPath, '/custom/x.db', reason: '显式 dbPath 优先');
      expect(cfg.configPath, '${tmp.path}/.env', reason: 'configPath 记录实际使用的配置文件');
    });

    test('copyWith 合并单字段', () {
      const c = AppConfig(tushareToken: 'old', dbPath: '/a.db', themeAccent: 'green');
      final c2 = c.copyWith(tushareToken: 'new');
      expect(c2.tushareToken, 'new');
      expect(c2.dbPath, '/a.db');
      expect(c2.themeAccent, 'green');
    });

    test('configPath 缺省时落在 ~/.stock/.env', () {
      final cfg = AppConfig.load();
      expect(cfg.configPath, endsWith('.stock/.env'));
      expect(cfg.dbPath, endsWith('.stock/stock.db'));
    });
  });

  group('主题色配置', () {
    test('THEME_ACCENT 缺省为 red，可读自定义值', () {
      final tmp = Directory.systemTemp.createTempSync('envtest');
      File('${tmp.path}/.env').writeAsStringSync('THEME_ACCENT=blue');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final cfg = AppConfig.load(envFile: '${tmp.path}/.env');
      expect(cfg.themeAccent, 'blue');
      expect(AppConfig(tushareToken: '', dbPath: '').themeAccent, 'red');
    });

    test('updateFile 合并写入，保留其他键', () async {
      final tmp = Directory.systemTemp.createTempSync('envtest');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/sub/.env';
      Directory('${tmp.path}/sub').createSync(recursive: true);
      File(path).writeAsStringSync('TUSHARE_TOKEN=tok\nONLY_A=1');
      await AppConfig.updateFile(path, {'THEME_ACCENT': 'green'});
      final m = AppConfig.parseDotEnv(File(path).readAsStringSync());
      expect(m['TUSHARE_TOKEN'], 'tok');
      expect(m['ONLY_A'], '1');
      expect(m['THEME_ACCENT'], 'green');
    });
  });
}
