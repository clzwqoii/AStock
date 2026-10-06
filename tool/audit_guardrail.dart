/// 除权护栏体检：看它到底挡住了多少信号、以及被挡掉的那些表现如何。
///
/// ## 为什么需要这个工具
///
/// 2026 年 13 条规则整齐划一地跑输基准（PF 0.8~1.1），太整齐了，不像各自失效，
/// 更像口径问题。除权护栏（`isCleanSignalDay`）是回测里唯一会**大面积丢信号**
/// 的部件，所以先量它：挡了多少、挡掉的那些本来是赚是亏。
///
/// 三条口径必须和 `backtestRule` 一致，否则量出来的是另一回事：
/// - 同一套 [isCorporateActionGap] / [barsSinceCorporateAction]；
/// - 同样按 `IndicatorSnapshot.minBars` 起步；
/// - 同样用不复权价算 10 日前瞻收益。
///
/// 用法: dart run tool/audit_guardrail.dart [--db 路径] [--horizon 10]
library;

// ignore_for_file: avoid_print

import 'package:stock/config.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

void main(List<String> args) {
  var dbPath = AppConfig.load().dbPath;
  var horizon = 10;
  var onlyRule = 'rsi_oversold';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--db':
        dbPath = args[++i];
      case '--horizon':
        horizon = int.parse(args[++i]);
      case '--rule':
        onlyRule = args[++i];
      default:
        throw ArgumentError('未知参数 ${args[i]}');
    }
  }

  final repo = BarRepository(dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();
  final rule = ruleById(onlyRule);
  print('库=$dbPath  池=${stocks.length} 只  规则=${rule.id}（${rule.name}）'
      '  口径=$horizon日');
  print('');

  // 每只股票只算一次 barsSinceCorporateAction，整条 O(n)。
  // 分桶：keep = 护栏放行；blocked = 护栏挡掉；并按信号年份分开统计。
  final stats = <String, _Bucket>{};
  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < IndicatorSnapshot.minBars + horizon) continue;
    final series = IndicatorSeries.from(bars);
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    final last = bars.length - 1 - horizon;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      if (!rule.test(series.at(t))) continue;
      final ret = (bars[t + horizon].close / bars[t].close - 1) * 100;
      final clean = sinceGap[t] >= kCorporateActionLookbackBars;
      final year = bars[t].date.year.toString();
      stats.putIfAbsent('$year/keep', () => _Bucket()).add(ret);
      if (!clean) stats.putIfAbsent('$year/blocked', () => _Bucket()).add(ret);
    }
  }

  final years = {for (final k in stats.keys) k.split('/').first}.toList()..sort();
  print('${'年份'.padRight(6)}${'放行胜率'.padRight(10)}${'放行数'.padRight(10)}'
      '${'挡掉胜率'.padRight(10)}${'挡掉数'.padRight(10)}${'挡掉占比'.padRight(10)}'
      '${'挡掉的均收益'.padRight(12)}挡掉后整体胜率');
  print('-' * 88);
  var tk = 0, tw = 0, tb = 0, bw = 0;
  for (final y in years) {
    final k = stats['$y/keep'] ?? _Bucket();
    final b = stats['$y/blocked'] ?? _Bucket();
    tk += k.count;
    tw += k.wins;
    tb += b.count;
    bw += b.wins;
    final ratio = (k.count + b.count) == 0
        ? 0.0
        : b.count / (k.count + b.count) * 100;
    final after = (tw + bw) / (tk + tb) * 100;
    print('${y.padRight(6)}${'${k.winRate.toStringAsFixed(1)}%'.padRight(10)}'
        '${'${k.count}'.padRight(10)}${'${b.winRate.toStringAsFixed(1)}%'.padRight(10)}'
        '${'${b.count}'.padRight(10)}${'${ratio.toStringAsFixed(1)}%'.padRight(10)}'
        '${'${b.avg.toStringAsFixed(2)}%'.padRight(12)}'
        '${after.toStringAsFixed(1)}%');
  }
  print('-' * 88);
  print('');
  print('合计：放行 $tw/$tk（${(tw / tk * 100).toStringAsFixed(1)}%），'
      '挡掉 $bw/$tb（${(bw / tb * 100).toStringAsFixed(1)}%）');
  print('');
  print('读法：');
  print('  · 「挡掉占比」= 护栏拦下多少信号。超过 ~10% 说明它在大幅改变样本。');
  print('  · 「挡掉的均收益」为负 = 护栏拦的确实是坏信号，说明它在干活。');
  print('  · 若挡掉的均收益为正、且占比大 → 护栏在误杀，需要收窄回溯根数。');
}

class _Bucket {
  var count = 0;
  var wins = 0;
  var sum = 0.0;

  void add(double ret) {
    count++;
    if (ret > 0) wins++;
    sum += ret;
  }

  double get winRate => count == 0 ? 0 : wins / count * 100;
  double get avg => count == 0 ? 0 : sum / count;
}
