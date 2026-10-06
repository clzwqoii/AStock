/// 头对头比较两组 RSI超卖·放量 参数，附显著性检验。
///
/// 回答"要不要把 RSI<20 换成了 RSI<25"：两组在不同指标上各有胜负，
/// 所以这里同时给出胜率/平均收益/盈亏比/信号数/分年超额，并对关键差异做 z 检验，
/// 避免把噪声当结论。
///
/// 用法: dart run tool/compare_rsi_variants.dart
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

const _candidates = [
  ('RSI<20 量比>1.5（现役）', 20.0, 1.5),
  ('RSI<25 量比>1.5', 25.0, 1.5),
  ('RSI<30 量比>2.0（原现役）', 30.0, 2.0),
];

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
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

  _Stat stat(List<double> xs) => _Stat.of(xs);

  print('各年基准（10 日）：');
  for (final y in years) {
    final b = baseByYear[y]!;
    print('  $y: ${b.length} 样本 / ${(b.where((x) => x > 0).length / b.length * 100).toStringAsFixed(1)}%');
  }
  print('');

  final out = <String, Map<String, dynamic>>{};
  for (final (label, rt, vt) in _candidates) {
    List<double> pick(int? y) => [
          for (final r in rec)
            if (r.rsi < rt && r.vol > vt && (y == null || r.year == y)) r.r10
        ];
    final all = stat(pick(null));
    final byYear = {for (final y in years) y: stat(pick(y))};
    final baseByYearStat = {for (final y in years) y: stat(baseByYear[y]!)};
    out[label] = {
      'all': all,
      'byYear': byYear,
      'excess': {
        for (final y in years)
          y: (byYear[y]!.winRate - baseByYearStat[y]!.winRate) * 100
      },
      'winners': all.count * all.winRate,
    };
  }

  print('══ 全样本对比 ══');
  print('   ${'参数'.padRight(26)}${'信号数'.padLeft(9)}${'胜率'.padLeft(8)}'
      '${'平均%'.padLeft(9)}${'盈亏比'.padLeft(8)}${'赢家总数'.padLeft(10)}');
  for (final e in out.entries) {
    final s = e.value['all'] as _Stat;
    print('   ${e.key.padRight(24)}${s.count.toString().padLeft(8)}'
        '${(s.winRate * 100).toStringAsFixed(1).padLeft(7)}%'
        '${s.avg.toStringAsFixed(2).padLeft(8)}%'
        '${s.pf.toStringAsFixed(2).padLeft(8)}'
        '${(e.value['winners'] as double).toStringAsFixed(0).padLeft(10)}');
  }

  print('');
  print('══ 分年胜率与超额（对当年基准）══');
  for (final e in out.entries) {
    final by = e.value['byYear'] as Map<int, _Stat>;
    final ex = e.value['excess'] as Map<int, double>;
    final cells = [
      for (final y in years)
        '$y ${by[y]!.count}信号 ${(by[y]!.winRate * 100).toStringAsFixed(1)}%'
            '（${ex[y]! >= 0 ? '+' : ''}${ex[y]!.toStringAsFixed(1)}pp）'
    ];
    print('   ${e.key}');
    for (final c in cells) {
      print('      $c');
    }
  }

  // 显著性检验：逐项比
  print('');
  print('══ 显著性检验（z 检验，|z|>2 才算真实差异）══');
  final keys = out.keys.toList();
  for (var i = 0; i < keys.length; i++) {
    for (var j = i + 1; j < keys.length; j++) {
      final a = out[keys[i]]!['all'] as _Stat;
      final b = out[keys[j]]!['all'] as _Stat;
      final z = _z(a, b);
      print('   ${keys[i]} vs ${keys[j]}：胜率差 '
          '${((a.winRate - b.winRate) * 100).toStringAsFixed(1)}pp，z=${z.toStringAsFixed(1)}'
          ' → ${z.abs() > 2 ? '差异真实' : '噪声范围内'}');
      // 分年
      for (final y in years) {
        final ya = (out[keys[i]]!['byYear'] as Map<int, _Stat>)[y]!;
        final yb = (out[keys[j]]!['byYear'] as Map<int, _Stat>)[y]!;
        if (ya.count < 30 || yb.count < 30) continue;
        final zy = _z(ya, yb);
        print('      $y：${((ya.winRate - yb.winRate) * 100).toStringAsFixed(1)}pp，'
            'z=${zy.toStringAsFixed(1)} → ${zy.abs() > 2 ? '差异真实' : '噪声'}');
      }
    }
  }

  // 多准则裁决
  print('');
  print('══ 多准则裁决 ══');
  for (final crit in ['胜率最高', '平均收益最高', '盈亏比最高', '信号数最多',
      '赢家总数最多', '最差年份超额最高', '三年超额之和最高']) {
    String? best;
    var bestV = -double.infinity;
    for (final e in out.entries) {
      final v = switch (crit) {
        '胜率最高' => (e.value['all'] as _Stat).winRate,
        '平均收益最高' => (e.value['all'] as _Stat).avg,
        '盈亏比最高' => (e.value['all'] as _Stat).pf,
        '信号数最多' => (e.value['all'] as _Stat).count.toDouble(),
        '赢家总数最多' => e.value['winners'] as double,
        '最差年份超额最高' => (e.value['excess'] as Map<int, double>)
            .values
            .reduce(math.min),
        _ => (e.value['excess'] as Map<int, double>).values.reduce((a, b) => a + b),
      };
      if (v > bestV) {
        bestV = v;
        best = e.key;
      }
    }
    print('   ${crit.padRight(12)} → $best');
  }
  exit(0);
}

/// 两比例差异的 z 统计量（合并标准误）。
double _z(_Stat a, _Stat b) {
  if (a.count == 0 || b.count == 0) return 0;
  final se = math.sqrt(a.winRate * (1 - a.winRate) / a.count +
      b.winRate * (1 - b.winRate) / b.count);
  if (se == 0) return 0;
  return (a.winRate - b.winRate) / se;
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
