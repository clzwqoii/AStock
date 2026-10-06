/// 数据同步 CLI：拉取全市场日线到本地 SQLite。
///
/// 用法:
///   dart run bin/sync.dart                       # 增量（只拉已同步最大交易日之后的）
///   dart run bin/sync.dart 250                   # 首次回填 250 个交易日
///   dart run bin/sync.dart --from 20250901       # 补拉 2025-09-01 至今（含）的已收盘交易日
///   dart run bin/sync.dart --from 20250901 --to 20260101
///   dart run bin/sync.dart --db /path/to/stock.db
///
/// 水位线增量补不了「已入库最大交易日」之前的历史；要把库扩到更长区间必须用 --from。
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/eastmoney_client.dart';
import 'package:stock/data/sina_client.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/data/tushare_client.dart';

Future<void> main(List<String> args) async {
  final config = AppConfig.load();
  if (config.tushareToken.isEmpty) {
    stderr.writeln('缺少 TUSHARE_TOKEN：请在项目根目录 .env 配置（参考 .env.example）');
    exitCode = 1;
    return;
  }

  var backfillDays = 250;
  String? dbPath;
  String? fromDate;
  String? toDate;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--help' || a == '-h') {
      _usage();
      return;
    } else if (a == '--from' && i + 1 < args.length) {
      fromDate = args[++i];
    } else if (a.startsWith('--from=')) {
      fromDate = a.substring('--from='.length);
    } else if (a == '--to' && i + 1 < args.length) {
      toDate = args[++i];
    } else if (a.startsWith('--to=')) {
      toDate = a.substring('--to='.length);
    } else if (a == '--db' && i + 1 < args.length) {
      dbPath = args[++i];
    } else if (a.startsWith('--db=')) {
      dbPath = a.substring('--db='.length);
    } else if (int.tryParse(a) case final n?) {
      if (n <= 0) {
        stderr.writeln('回填交易日数必须为正整数，实际 $n');
        exitCode = 1;
        return;
      }
      backfillDays = n;
    } else {
      stderr.writeln('无法识别的参数: $a');
      _usage();
      exitCode = 1;
      return;
    }
  }

  dbPath ??= config.dbPath;
  Directory(File(dbPath).parent.path).createSync(recursive: true);
  final repo = BarRepository(dbPath);
  final syncedBefore = repo.maxTradeDate();
  final barsBefore = repo.barCount();
  final sw = Stopwatch()..start();
  try {
    final r = await SyncService(TushareClient(token: config.tushareToken), repo,
            sina: SinaClient(), eastmoney: EastmoneyClient())
        .sync(backfillDays: backfillDays, fromDate: fromDate, toDate: toDate);
    print('数据库: $dbPath');
    print('上次同步至: ${syncedBefore ?? '（空库）'}（$barsBefore 行）');
    print('本次拉取: ${r.dates} 个交易日, ${r.rows} 行, 耗时 ${sw.elapsed}');
    print('现在同步至: ${repo.maxTradeDate()}（${repo.barCount()} 行）');
  } on ArgumentError catch (e) {
    stderr.writeln('参数错误: ${e.message}');
    exitCode = 1;
  } on TushareException catch (e) {
    stderr.writeln('tushare 接口错误: $e');
    exitCode = 1;
  } finally {
    repo.close();
  }
}

void _usage() {
  print('''用法: dart run bin/sync.dart [回填交易日数=250] [--from YYYYMMDD] [--to YYYYMMDD] [--db 路径]

  （无参数）              增量同步，只拉已同步最大交易日之后的已收盘交易日
  <N>                    首次回填最近 N 个交易日（默认 250）
  --from YYYYMMDD        从此日起补拉（绕过水位线，可补更早的历史）
  --to YYYYMMDD          补拉到此日止（闭区间，默认到今天）
  --db 路径              指定数据库（默认 ~/.stock/stock.db）

  例：库已入库 120 个交易日，想扩到 250 个：
    dart run bin/sync.dart --from 20250901
''');
}
