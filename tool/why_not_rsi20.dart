/// 回答"为什么不是 RSI<20 量比>1.5"：把每个参数组合的**分年信号数与胜率**拉出来。
///
/// 关键怀疑：RSI<20 在全样本上 86.4% 好看，但可能只是因为它的信号高度集中在某一年。
/// 如果它在近段已经几乎不触发，那全样本胜率就是那段行情的遗物。
///
/// 用法: dart run tool/why_not_rsi20.dart
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

const _combos = [
  (20.0, 1.5),
  (20.0, 2.0),
  (25.0, 1.5),
  (25.0, 2.0),
  (30.0, 1.5),
  (30.0, 2.0),
  (35.0, 1.5),
];

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  final bars = stocks.map((s) => s.bars.length).reduce((a, b) => a > b ? a : b);
  final dataDate = repo.maxTradeDate() ?? '';
  repo.close();
  final maxH = kDefaultHorizons.reduce((a, b) => a > b ? a : b);

  final rec = <({double rsi, double vol, int year, double r10})>[];
  final baseByYear = <int, List<double>>{};
  for (final stock in stocks) {
    final b = stock.bars;
    if (b.length < IndicatorSnapshot.minBars + maxH) continue;
    final series = IndicatorSeries.from(b);
    final last = b.length - 1 - maxH;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      final s = series.at(t);
      final r = (b[t + 10].close / b[t].close - 1) * 100;
      final y = b[t].date.year;
      rec.add((rsi: s.rsi14, vol: s.volumeRatio, year: y, r10: r));
      (baseByYear[y] ??= <double>[]).add(r);
    }
  }

  final years = baseByYear.keys.toList()..sort();
  print('股票 ${stocks.length} 只 · 每只最多 $bars 根 · 数据截至 $dataDate');
  print('可评估日 ${rec.length} 个');
  print('');
  print('各年基准（10 日）：');
  for (final y in years) {
    final b = baseByYear[y]!;
    print('  $y: ${b.length} 样本 / ${(b.where((x) => x > 0).length / b.length * 100).toStringAsFixed(1)}%');
  }

  print('');
  print('══ 每个参数组合：分年信号数与胜率 ══');
  final yearHeader = years.map((y) => '$y信号/'.padLeft(19)).join(' ');
  print('   参数                全年信号   全年胜率 | $yearHeader');
  for (final (rt, vt) in _combos) {
    List<double> pick(bool Function(({double rsi, double vol, int year, double r10})) f) =>
        [for (final r in rec) if (f(r)) r.r10];
    final all = pick((r) => r.rsi < rt && r.vol > vt);
    final cells = <String>[];
    for (final y in years) {
      final s = pick((r) => r.rsi < rt && r.vol > vt && r.year == y);
      final w = s.isEmpty ? 0.0 : s.where((x) => x > 0).length / s.length;
      cells.add('${s.length.toString().padLeft(5)}/${w == 0 ? '  —  ' : '${(w * 100).toStringAsFixed(1)}%'}'
          .padLeft(19));
    }
    final allW = all.isEmpty ? 0.0 : all.where((x) => x > 0).length / all.length;
    print('   RSI<${rt.toStringAsFixed(0)} 量比>${vt.toStringAsFixed(1)}   '
        '${all.length.toString().padLeft(7)}  ${(allW * 100).toStringAsFixed(1).padLeft(5)}% │ '
        '${cells.join(' ')}');
  }

  print('');
  print('══ 近段（${years.last}）与早段（${years.first}）的信号数之比 ══');
  for (final (rt, vt) in _combos) {
    List<double> pick(int y) => [
          for (final r in rec)
            if (r.rsi < rt && r.vol > vt && r.year == y) r.r10
        ];
    final e = pick(years.first).length;
    final l = pick(years.last).length;
    final ratio = e == 0 ? double.infinity : l / e;
    print('   RSI<${rt.toStringAsFixed(0)} 量比>${vt.toStringAsFixed(1)}：'
        '${years.first} $e → ${years.last} $l（近段/早段 = '
        '${ratio.isFinite ? ratio.toStringAsFixed(2) : '∞'}）');
  }
  exit(0);
}
