/// 跑一遍全规则 × 全持有期回测，把报告落盘成 JSON（页面读它）。
///
/// 用法:
///   dart run tool/report_all.dart [--db 路径] [--out 报告路径] [--archive]
/// `--archive` 会顺手把本次快照追加进同目录的 backtest-history.json，
/// 用于跨月对比胜率漂移（样本外跟踪）。
/// 用法: dart run tool/report_all.dart [db路径] [输出json路径]
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/report_store.dart';

Future<void> main(List<String> args) async {
  var archive = false;
  String? dbPath;
  String? out;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--archive') {
      archive = true;
    } else if (a.startsWith('--db=')) {
      dbPath = a.substring(5);
    } else if (a == '--db' && i + 1 < args.length) {
      dbPath = args[++i];
    } else if (a.startsWith('--out=')) {
      out = a.substring(6);
    }
  }
  dbPath ??= AppConfig.load().dbPath;
  // 必须与 app 读的路径一致（reportPathFor 由数据库路径推导），
  // 否则 UI 永远读不到 CLI 生成的报告。
  out ??= reportPathFor(dbPath);
  final sw = Stopwatch()..start();
  final repo = BarRepository(dbPath);
  final stocks = repo.loadAllStocks();
  final dataDate = repo.maxTradeDate() ?? '';
  repo.close();
  if (stocks.isEmpty) {
    print('数据库 $dbPath 为空（0 只股票），先跑 dart run bin/sync.dart 同步数据');
    return;
  }
  final bars = stocks.map((s) => s.bars.length).reduce((a, b) => a > b ? a : b);
  print('股票 ${stocks.length} 只 · 每只最多 $bars 根');
  final report = backtestAll(stocks, builtInRules,
      horizons: kDefaultHorizons,
      recentWindowTradingDays: kRecentWindowTradingDays);
  File(out).writeAsStringSync(jsonEncode(report.toJson()));
  print('耗时 ${sw.elapsed.inSeconds}s → $out');

  // 月度跟踪：把本次快照追加进台账（同一数据截止日只保留最新一条）
  if (archive) {
    final hp = historyPathFor(out);
    final prev = loadBacktestHistory(hp) ?? const BacktestHistory([]);
    final snap = BacktestSnapshot.of(report, dataDate);
    final merged = prev.upsert(snap);
    saveBacktestHistory(hp, merged); // 原子替换：App 侧读-改-写同一个文件
    print('月度台账 → $hp（${merged.snapshots.length} 期）');
  }
  _print(report);
}

void _print(BacktestReport r) {
  print('');
  print('══ 基准 ══');
  for (final h in r.horizons) {
    final b = r.baseline[h]!;
    print('  $h 日: 样本 ${b.count} · 胜率 ${(b.winRate * 100).toStringAsFixed(1)}% · '
        '平均 ${b.avgReturn.toStringAsFixed(2)}%');
  }
  print('');
  final rows = <(String, int, double, double)>[];
  for (final rule in builtInRules) {
    for (final h in r.horizons) {
      final x = r.result(rule.id, h)!;
      rows.add((rule.name, h, x.winRate, x.avgReturn));
    }
  }
  rows.sort((a, b) => b.$3.compareTo(a.$3));
  print('══ 按胜率排序（持有期 平均） ══');
  for (final (name, h, w, avg) in rows) {
    print('  ${name.padRight(20)} ${h.toString().padLeft(2)}日  '
        '胜率 ${(w * 100).toStringAsFixed(1).padLeft(5)}%  平均 ${avg.toStringAsFixed(2).padLeft(6)}%');
  }
}
