/// 市场环境诊断：无条件 10 日胜率到底由什么决定。
///
/// ## 要回答的问题
///
/// 三年无条件基准胜率是 47.7% / 55.5% / **44.2%**，2026 年最低。
/// 所有规则的超额都是"相对当年基准"算的，基准本身低了 11pp，
/// 会让 2026 年的超额看起来格外差。所以得先搞清楚：
/// **是 2026 年整体在跌，还是某几个月崩了，还是采样问题。**
///
/// 三个口径：
///
/// 1. **按月**：把信号日按 `YYYYMM` 分桶，看 10 日前向收益的胜率与均值。
///    "全年低"和"某个月砸的"是两回事——后者是事件，前者是 regime。
/// 2. **按年汇总**：与回测报告的 `yearlyBaseline` 对账，防止口径漂移。
/// 3. **横截面离散度**：同年内不同股票的收益方差。方差大说明是分化市。
///
/// 用法: dart run tool/market_regime.dart [dbPath]
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/report_store.dart';

/// 与回测报告同一持有期。
const _horizon = 10;

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  final dataDate = repo.maxTradeDate();
  repo.close();

  // 月度桶：'YYYYMM' -> [count, wins, sum, 收益列表(抽样算离散度用)]
  final byMonth = <String, _Bucket>{};
  final byYear = <int, _Bucket>{};

  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < IndicatorSnapshot.minBars + _horizon) continue;
    final last = bars.length - 1 - _horizon;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      final r = (bars[t + _horizon].close / bars[t].close - 1) * 100;
      final d = bars[t].date;
      final mk = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      (byMonth[mk] ??= _Bucket()).add(r);
      (byYear[d.year] ??= _Bucket()).add(r);
    }
  }

  final months = byMonth.keys.toList()..sort();
  final years = byYear.keys.toList()..sort();

  print('══ 市场环境：无条件 $_horizon 日前向收益（全市场、不做任何选股）══');
  print('数据截至 $dataDate；${stocks.length} 只股票。');
  print('');
  print('基准胜率 = 该桶内 10 日后上涨的 (股票,交易日) 占比。');
  print('');

  _tableHeader(byYear);
  for (final y in years) {
    final b = byYear[y]!;
    print('  $y  ${b.count.toString().padLeft(8)}  '
        '${(b.winRate * 100).toStringAsFixed(1).padLeft(6)}%  '
        '${b.avg.toStringAsFixed(2).padLeft(8)}%  '
        '${b.median.toStringAsFixed(2).padLeft(8)}%  '
        '${b.sd.toStringAsFixed(2).padLeft(7)}%');
  }

  print('');
  print('══ 逐月（看崩塌是全年均匀还是集中在某几月）══');
  print('  ${'月份'.padRight(9)}${'样本'.padLeft(9)}${'胜率'.padLeft(8)}'
      '${'平均%'.padLeft(9)}${'中位%'.padLeft(9)}');
  for (final m in months) {
    final b = byMonth[m]!;
    final bar = _bar(b.winRate);
    print('  ${m.padRight(9)}${b.count.toString().padLeft(9)}'
        '${(b.winRate * 100).toStringAsFixed(1).padLeft(7)}%'
        '${b.avg.toStringAsFixed(2).padLeft(8)}%'
        '${b.median.toStringAsFixed(2).padLeft(8)}%  $bar');
  }

  // 与报告对账
  final reportPath =
      '${File(args.isNotEmpty ? args[0] : AppConfig.load().dbPath).parent.path}'
      '/stock-backtest-report.json';
  print('');
  print('══ 与回测报告 yearlyBaseline 对账 ══');
  try {
    final r = ReportStore(reportPath).load();
    if (r == null) {
      print('  读不到报告：$reportPath');
    } else {
      for (final y in years) {
        final b = r.yearlyBaseline[y]?[_horizon];
        if (b == null) continue;
        final mine = byYear[y]!;
        final same = (mine.winRate - b.winRate).abs() < 1e-9 &&
            (mine.count - b.count).abs() < 1;
        print('  $y  我算 ${(mine.winRate * 100).toStringAsFixed(2)}% / '
            '${mine.count}  报告 ${(b.winRate * 100).toStringAsFixed(2)}% / '
            '${b.count}  ${same ? "✓ 一致" : "✗ 口径有差"}');
      }
    }
  } on Object catch (e) {
    print('  对账失败：$e');
  }
  exit(0);
}

void _tableHeader(Map<int, _Bucket> byYear) {
  print('══ 按年 ══');
  print('  ${'年'.padRight(6)}${'样本'.padLeft(8)}${'胜率'.padLeft(8)}'
      '${'平均%'.padLeft(9)}${'中位%'.padLeft(9)}${'标准差'.padLeft(8)}');
}

String _bar(double winRate) {
  // 50% 为中轴，向右变强
  final n = ((winRate - 0.35) / 0.30 * 20).round().clamp(0, 20);
  return '${'█' * n}${'·' * (20 - n)}';
}

class _Bucket {
  int count = 0;
  int wins = 0;
  double sum = 0;
  double sumSq = 0;
  final values = <double>[];

  void add(double v) {
    count++;
    sum += v;
    sumSq += v * v;
    if (v > 0) wins++;
    if (values.length < 200000) values.add(v);
  }

  double get winRate => count == 0 ? 0 : wins / count;
  double get avg => count == 0 ? 0 : sum / count;

  double get median {
    if (values.isEmpty) return 0;
    final s = [...values]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  double get sd {
    if (count < 2) return 0;
    final mean = sum / count;
    // 用 sumSq 算，避免再存一遍
    final v = (sumSq - count * mean * mean) / (count - 1);
    return v <= 0 ? 0 : math.sqrt(v);
  }
}
