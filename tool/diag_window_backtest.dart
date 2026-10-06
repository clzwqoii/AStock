/// 诊断脚本：把 mac 库截断到最近 N 个交易日重跑回测，
/// 对比安卓端的信号数，判断安卓差异来自「历史长度」还是「股票数」。
/// 只读库，不写任何文件。
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : '${Platform.environment['HOME']}/.stock/stock.db';
  final repo = BarRepository(dbPath);
  try {
    final all = repo.loadAllStocks();
    print('全库：${all.length} 只股票');
    // 每根数分布（抽样 500 只估中位数）
    final lens = [for (final s in all) s.bars.length]..sort();
    print('K线根数 中位数=${lens[lens.length ~/ 2]} p10=${lens[lens.length ~/ 10]}');

    // 截断到全局最近 N 个交易日（按库内最大日期往前数 N 个不同的交易日）
    final allDates = <String>{
      for (final s in all) for (final b in s.bars) _fmt(b.date)
    }.toList()..sort();
    final ids = [
      'rsi_oversold_volume_loose',
      'ma60_breakout_pullback',
      'ma60_breakout_bull',
      'ma60_breakout',
      'ma5_golden_ma10',
      'macd_golden_cross',
      'close_above_ma60',
      'pct_change_up',
      'close_above_ma20',
      'kdj_golden_cross',
      'rsi_oversold_volume',
      'near_ma250',
      'rsi_oversold',
    ];
    String row(BacktestReport r) =>
        ids.map((id) => '${r.results[id]?[5]?.count ?? 0}').join(' ');
    print('列序: ${ids.join(' ')}');
    for (final n in [250, 150, 120, 100, 90, 80, 60]) {
      if (n >= allDates.length) continue;
      final cutoff = allDates[allDates.length - n];
      final truncated = <StockData>[
        for (final s in all)
          StockData(
              symbol: s.symbol,
              bars: [for (final b in s.bars) if (_fmt(b.date).compareTo(cutoff) >= 0) b]),
      ];
      final kept = truncated.where((s) => s.bars.isNotEmpty).length;
      final report = backtestAll(truncated, builtInRules, horizons: [5]);
      print('窗口$n(自$cutoff,$kept只) 基准=${report.baseline[5]!.count} ${row(report)}');
    }
    // 全窗口基线
    final full = backtestAll(all, builtInRules, horizons: [5]);
    print('全窗口(${allDates.first}起) 基准=${full.baseline[5]!.count} ${row(full)}');
  } finally {
    repo.close();
  }
}

String _fmt(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
