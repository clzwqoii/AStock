/// 三规则头对头对比：RSI超卖·放量 vs +KDJ金叉 vs +KDJ金叉+MACD金叉。
///
/// 回答：MACD/KDJ 金叉叠加在「RSI超卖·放量」之上，是增强还是稀释？
/// 关键风险是**信号数塌缩**——三个条件取交集，数量可能掉到不足以支撑结论。
/// 所以这里除胜率/盈亏比/分年超额外，还逐项做 z 检验，并单独报告信号衰减率。
///
/// 用法: dart run tool/compare_oversold_combo.dart
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

const _horizon = 10;

/// 三个级别：A 单独、B 加 KDJ金叉、C 再加 MACD金叉。
const _levels = [
  ('A 单独 RSI超卖·放量', ['rsi_oversold_volume']),
  ('B ＋KDJ金叉', ['rsi_oversold_volume', 'kdj_golden_cross']),
  ('C ＋KDJ金叉＋MACD金叉', ['rsi_oversold_volume', 'kdj_golden_cross', 'macd_golden_cross']),
];

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();

  // 预取规则
  final rov = ruleById('rsi_oversold_volume');
  final kdj = ruleById('kdj_golden_cross');
  final macd = ruleById('macd_golden_cross');

  final baseByYear = <int, List<double>>{};
  // 一次性记录：每天的三条规则判定 + 年 + 收益
  final rec = <({int year, double r10, bool rov, bool kdj, bool macd})>[];
  for (final stock in stocks) {
    final b = stock.bars;
    if (b.length < IndicatorSnapshot.minBars + _horizon) continue;
    final series = IndicatorSeries.from(b);
    final last = b.length - 1 - _horizon;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      final s = series.at(t);
      final r = (b[t + _horizon].close / b[t].close - 1) * 100;
      final y = b[t].date.year;
      (baseByYear[y] ??= <double>[]).add(r);
      rec.add((
        year: y,
        r10: r,
        rov: rov.test(s),
        kdj: kdj.test(s),
        macd: macd.test(s),
      ));
    }
  }
  final years = baseByYear.keys.toList()..sort();

  print('══ 三规则对比 · 持有期 $_horizon 日 · ${(rec.length / 10000).toStringAsFixed(0)} 万个可评估样本 ══');
  print('');
  print('基准胜率（10 日）：');
  for (final y in years) {
    final b = baseByYear[y]!;
    print('   $y  ${(b.where((x) => x > 0).length / b.length * 100).toStringAsFixed(1)}%');
  }

  final baseStat = {for (final y in years) y: _Stat.of(baseByYear[y]!)};

  final out = <String, Map<String, dynamic>>{};
  print('');
  print('══ 全样本 ══');
  print('   ${'组合'.padRight(24)}${'信号数'.padLeft(9)}${'衰减'.padLeft(7)}'
      '${'胜率'.padLeft(8)}${'平均%'.padLeft(9)}${'盈亏比'.padLeft(8)}');
  final counts = <String, int>{};
  for (final (label, ids) in _levels) {
    List<double> pick(int? y) => [
          for (final r in rec)
            if ((!ids.contains('rsi_oversold_volume') || r.rov) &&
                  (!ids.contains('kdj_golden_cross') || r.kdj) &&
                  (!ids.contains('macd_golden_cross') || r.macd) &&
                  (y == null || r.year == y))
                r.r10
        ];
    final all = _Stat.of(pick(null));
    counts[label] = all.count;
    out[label] = {
      'all': all,
      'byYear': {for (final y in years) y: _Stat.of(pick(y))},
    };
    print('   ${label.padRight(24)}${all.count.toString().padLeft(8)}'
        '${(all.count / counts[_levels[0].$1]! * 100).toStringAsFixed(0).padLeft(6)}%'
        '${(all.winRate * 100).toStringAsFixed(1).padLeft(7)}%'
        '${all.avg.toStringAsFixed(2).padLeft(8)}%'
        '${all.pf.toStringAsFixed(2).padLeft(8)}');
  }

  print('');
  print('══ 分年胜率与超额（对当年基准）══');
  for (final (label, _) in _levels) {
    final by = out[label]!['byYear'] as Map<int, _Stat>;
    final cells = [
      for (final y in years)
        '$y ${by[y]!.count}信号 ${(by[y]!.winRate * 100).toStringAsFixed(1)}%'
            '（${(by[y]!.winRate - baseStat[y]!.winRate) * 100 >= 0 ? '+' : ''}'
            '${((by[y]!.winRate - baseStat[y]!.winRate) * 100).toStringAsFixed(1)}pp）'
    ];
    print('   $label');
    for (final c in cells) {
      print('      $c');
    }
  }

  print('');
  print('══ 显著性检验（z 检验，|z|>2 才算真实差异）══');
  final keys = out.keys.toList();
  for (var i = 0; i < keys.length; i++) {
    for (var j = i + 1; j < keys.length; j++) {
      final a = out[keys[i]]!['all'] as _Stat;
      final b = out[keys[j]]!['all'] as _Stat;
      if (a.count < 2 || b.count < 2) continue;
      // 同一批总体上的两个子集，用合并胜率算标准误
      final pool = (a.winRate * a.count + b.winRate * b.count) / (a.count + b.count);
      final se = math.sqrt(pool * (1 - pool) * (1 / a.count + 1 / b.count));
      final z = (a.winRate - b.winRate) / se;
      final verdict = z.abs() > 2
          ? (z > 0 ? '${keys[i]} 显著更强' : '${keys[j]} 显著更强')
          : '差异不显著（可能是噪声）';
      print('   ${keys[i]} vs ${keys[j]}：胜率差 '
          '${((a.winRate - b.winRate) * 100).toStringAsFixed(1)}pp，z=${z.toStringAsFixed(2)}'
          '（se=${(se * 100).toStringAsFixed(2)}pp）→ $verdict');
    }
  }

  print('');
  print('══ 信号衰减 ══');
  for (var i = 1; i < _levels.length; i++) {
    final prev = counts[_levels[i - 1].$1]!;
    final cur = counts[_levels[i].$1]!;
    print('   ${_levels[i].$1}：$prev → $cur（保留 '
        '${(cur / prev * 100).toStringAsFixed(1)}%）');
  }
  exit(0);
}

class _Stat {
  const _Stat(this.count, this.winRate, this.avg, this.pf);
  final int count;
  final double winRate;
  final double avg;
  final double pf;

  factory _Stat.of(List<double> xs) {
    if (xs.isEmpty) return const _Stat(0, 0, 0, 0);
    var g = 0.0, l = 0.0;
    for (final x in xs) {
      if (x > 0) {
        g += x;
      } else if (x < 0) {
        l += -x;
      }
    }
    return _Stat(xs.length, xs.where((x) => x > 0).length / xs.length,
        xs.reduce((a, b) => a + b) / xs.length, (g == 0 || l == 0) ? 0 : g / l);
  }
}
