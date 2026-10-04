/// 数据同步 CLI：拉取全市场日线到本地 SQLite。
/// 用法: dart run bin/sync.dart [回填交易日数=120] [数据库路径=~/.stock/stock.db]
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/data/tushare_client.dart';

Future<void> main(List<String> args) async {
  final config = AppConfig.load();
  if (config.tushareToken.isEmpty) {
    stderr.writeln('缺少 TUSHARE_TOKEN：请在项目根目录 .env 配置（参考 .env.example）');
    exitCode = 1;
    return;
  }
  final dbPath = args.length > 1 ? args[1] : config.dbPath;
  final days = args.isNotEmpty ? int.tryParse(args[0]) ?? 120 : 120;

  Directory(File(dbPath).parent.path).createSync(recursive: true);
  final repo = BarRepository(dbPath);
  final syncedBefore = repo.maxTradeDate();
  final sw = Stopwatch()..start();
  try {
    final r = await SyncService(TushareClient(token: config.tushareToken), repo)
        .sync(backfillDays: days);
    print('数据库: $dbPath');
    print('上次同步至: ${syncedBefore ?? '（空库）'}');
    print('本次拉取: ${r.dates} 个交易日, ${r.rows} 行, 耗时 ${sw.elapsed}');
  } on TushareException catch (e) {
    stderr.writeln('tushare 接口错误: $e');
    exitCode = 1;
  } finally {
    repo.close();
  }
}
