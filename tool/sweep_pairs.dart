/// 规则组合穷举：一遍扫描记录「每天哪些规则触发」+ 三个持有期的前瞻收益，
/// 之后任意规则组合（两两、三联）都只是对位掩码做子集判断，统计几乎免费。
///
/// 用法:
///   dart run tool/sweep_pairs.dart [--top 20] [--triples] [--split-at 20250101]
///                                   [--focus macd_golden_cross,kdj_golden_cross] [--db 路径]
///
/// - `--top N`          每个榜列前 N 条
/// - `--triples`        连三联一起穷举（16 条规则 = 560 个三联）
/// - `--split-at 日期`  按日历年切分做跨行情稳健性检验（YYYYMMDD）
/// - `--focus id,id`    单独看这些规则的所有组合及其跨行情表现
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

Future<void> main(List<String> args) async {
  var top = 20;
  var triples = false;
  var split = false;
  String? splitAt;
  final focus = <String>[];
  String? dbPath;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--top=')) {
      top = int.parse(a.substring(6));
    } else if (a == '--top' && i + 1 < args.length) {
      top = int.parse(args[++i]);
    } else if (a == '--triples') {
      triples = true;
    } else if (a == '--split') {
      split = true;
    } else if (a.startsWith('--split-at=')) {
      split = true;
      splitAt = a.substring(11);
    } else if (a == '--split-at' && i + 1 < args.length) {
      split = true;
      splitAt = args[++i];
    } else if (a.startsWith('--focus=')) {
      focus.addAll(a.substring(8).split(','));
    } else if (a == '--focus' && i + 1 < args.length) {
      focus.addAll(args[++i].split(','));
    } else if (a.startsWith('--db=')) {
      dbPath = a.substring(5);
    }
  }

  // 切分点：--split-at 指定则用它，否则样本中位日。只算一次。
  final int cut;
  if (split) {
    if (splitAt == null) {
      // 需要先知道天数，稍后填；这里先用极大值占位，扫描后再回填。
      cut = 1 << 30;
    } else {
      if (splitAt.length != 8 || int.tryParse(splitAt) == null) {
        stderr.writeln('--split-at 需要 YYYYMMDD 格式');
        exit(1);
      }
      final y = int.parse(splitAt.substring(0, 4));
      final m = int.parse(splitAt.substring(4, 6));
      final d = int.parse(splitAt.substring(6, 8));
      cut = DateTime(y, m, d).millisecondsSinceEpoch ~/ 86400000;
    }
  } else {
    cut = 1 << 30;
  }
  final useMedianCut = split && splitAt == null;

  final repo = BarRepository(dbPath ?? AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();
  if (stocks.isEmpty) {
    print('数据库为空（0 只股票），先跑 dart run bin/sync.dart 同步数据');
    return;
  }
  final bars = stocks.map((s) => s.bars.length).reduce((a, b) => a > b ? a : b);
  final rules = builtInRules;
  final n = rules.length;
  final maxH = kDefaultHorizons.reduce((a, b) => a > b ? a : b);

  final sw = Stopwatch()..start();
  // ── 一遍扫描：只在有规则触发的日子留下记录 ──
  final masks = <int>[];
  final days = <int>[];
  final r5 = <double>[], r10 = <double>[], r20 = <double>[];
  for (final stock in stocks) {
    final b = stock.bars;
    if (b.length < IndicatorSnapshot.minBars + maxH) continue;
    final series = IndicatorSeries.from(b);
    final lastEval = b.length - 1 - maxH;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      final snap = series.at(t);
      var mask = 0;
      for (var i = 0; i < n; i++) {
        if (rules[i].test(snap)) mask |= 1 << i;
      }
      if (mask == 0) continue; // 无规则触发的日子对组合统计没用
      masks.add(mask);
      days.add(b[t].date.millisecondsSinceEpoch ~/ 86400000);
      final from = b[t].close;
      r5.add((b[t + 5].close / from - 1) * 100);
      r10.add((b[t + 10].close / from - 1) * 100);
      r20.add((b[t + 20].close / from - 1) * 100);
    }
  }
  final realCut = useMedianCut ? ([...days]..sort())[days.length ~/ 2] : cut;

  print('股票 ${stocks.length} 只 · 每只最多 $bars 根');
  print('有规则触发的日子 ${masks.length} 个 · 扫描耗时 ${sw.elapsed.inSeconds}s');

  final b5 = _Stats.of(r5), b10 = _Stats.of(r10), b20 = _Stats.of(r20);
  print('无条件基准：5日 ${_pct(b5.winRate)} / ${_num(b5.avgReturn)}% ；'
      '10日 ${_pct(b10.winRate)} / ${_num(b10.avgReturn)}% ；'
      '20日 ${_pct(b20.winRate)} / ${_num(b20.avgReturn)}%');

  // ── 组合统计：对位掩码做子集判断 ──
  final all = <(String, int, _Tri)>[];
  void evalCombo(String label, int mask) {
    final a5 = <double>[], a10 = <double>[], a20 = <double>[];
    for (var i = 0; i < masks.length; i++) {
      if ((masks[i] & mask) != mask) continue;
      a5.add(r5[i]);
      a10.add(r10[i]);
      a20.add(r20[i]);
    }
    all.add((label, mask, _Tri(_Stats.of(a5), _Stats.of(a10), _Stats.of(a20))));
  }

  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      evalCombo('${rules[i].name} + ${rules[j].name}', (1 << i) | (1 << j));
    }
  }
  if (triples) {
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        for (var k = j + 1; k < n; k++) {
          evalCombo('${rules[i].name}+${rules[j].name}+${rules[k].name}',
              (1 << i) | (1 << j) | (1 << k));
        }
      }
    }
  }

  // 严选：三个持有期都跑赢基准 + 信号数够看
  final ok = all.where((c) {
    final s = c.$3;
    return s.a5.count >= 30 &&
        s.a5.winRate > b5.winRate &&
        s.a10.winRate > b10.winRate &&
        s.a20.winRate > b20.winRate;
  }).toList()
    ..sort((a, b) => (b.$3.a10.winRate - b10.winRate)
        .compareTo(a.$3.a10.winRate - b10.winRate));

  print('');
  print('══ 三个持有期都跑赢基准（按 10 日超额胜率排序，top $top）══');
  print('   共 ${ok.length}/${all.length} 个组合达标${triples ? '（含三联）' : '（仅两两）'}');
  print(_header());
  for (final c in ok.take(top)) {
    _row(c.$1, c.$3, b5, b10, b20);
  }
  if (ok.isEmpty) print('   （没有组合在三个持有期都跑赢基准）');

  // ── 指定规则的组合 ──
  for (final fid in focus) {
    final i = rules.indexWhere((r) => r.id == fid);
    if (i < 0) {
      print('');
      print('⚠ 未知规则 id: $fid');
      continue;
    }
    print('');
    print('══ ${rules[i].name}（$fid）的组合，按 10 日超额胜率排序 ══');
    print(_header());
    final mine = all.where((c) => c.$2 & (1 << i) != 0).toList()
      ..sort((a, b) => (b.$3.a10.winRate - b10.winRate)
          .compareTo(a.$3.a10.winRate - b10.winRate));
    var shown = 0;
    for (final c in mine) {
      if (c.$3.a10.count < 30) continue; // 样本太小的不占榜
      _row(c.$1, c.$3, b5, b10, b20);
      if (++shown >= top) break;
    }
    if (shown == 0) print('   （没有样本 >=30 的组合）');

    if (split) {
      print('   —— 按年切分（分界 $realCut）——');
      final be = _Stats.of([for (var k = 0; k < masks.length; k++)
        if (days[k] < realCut) r10[k]]);
      final bl = _Stats.of([for (var k = 0; k < masks.length; k++)
        if (days[k] >= realCut) r10[k]]);
      print('   基准：前段 ${be.count} 信号 ${_pct(be.winRate)} / '
          '后段 ${bl.count} 信号 ${_pct(bl.winRate)}');
      shown = 0;
      for (final c in mine) {
        if (c.$3.a10.count < 30) continue;
        final idx = <int>[];
        for (var k = 0; k < masks.length; k++) {
          if ((masks[k] & c.$2) == c.$2) idx.add(k);
        }
        final y1 = _Stats.of([for (final k in idx) if (days[k] < realCut) r10[k]]);
        final y2 = _Stats.of([for (final k in idx) if (days[k] >= realCut) r10[k]]);
        if (y1.count == 0 || y2.count == 0) continue;
        final okBoth = y1.winRate > be.winRate && y2.winRate > bl.winRate;
        print('   ${c.$1.padRight(40)}'
            ' 前段 ${y1.count.toString().padLeft(5)}信号 '
            '${_pct(y1.winRate).padLeft(6)}'
            ' / 后段 ${y2.count.toString().padLeft(5)}信号 '
            '${_pct(y2.winRate).padLeft(6)}'
            '   ${okBoth ? '两段都赢 ✓' : '⚠ 一段输'}');
        if (++shown >= top) break;
      }
    }
  }

  // ── 全部组合的跨行情裁决 ──
  if (split) {
    final be = _Stats.of([for (var k = 0; k < masks.length; k++)
      if (days[k] < realCut) r10[k]]);
    final bl = _Stats.of([for (var k = 0; k < masks.length; k++)
      if (days[k] >= realCut) r10[k]]);
    print('');
    print('══ 按年切分的最终裁决（分界 $realCut）══');
    print('   基准：前段 ${be.count} 信号 ${_pct(be.winRate)} / '
        '${_num(be.avgReturn)}% ；后段 ${bl.count} 信号 ${_pct(bl.winRate)} / '
        '${_num(bl.avgReturn)}%');
    print('   —— 先看 $n 条单规则 ——');
    for (var i = 0; i < n; i++) {
      final idx = <int>[];
      for (var k = 0; k < masks.length; k++) {
        if ((masks[k] & (1 << i)) != 0) idx.add(k);
      }
      final y1 = _Stats.of([for (final k in idx) if (days[k] < realCut) r10[k]]);
      final y2 = _Stats.of([for (final k in idx) if (days[k] >= realCut) r10[k]]);
      final okBoth = y1.winRate > be.winRate && y2.winRate > bl.winRate;
      print('   ${rules[i].name.padRight(24)}'
          '前段 ${y1.count.toString().padLeft(7)}信号 ${_pct(y1.winRate).padLeft(6)}'
          ' / ${y1.avgReturn.toStringAsFixed(2).padLeft(6)}%'
          '   后段 ${y2.count.toString().padLeft(7)}信号 ${_pct(y2.winRate).padLeft(6)}'
          ' / ${y2.avgReturn.toStringAsFixed(2).padLeft(6)}%'
          '   ${okBoth ? '两段都赢 ✓' : '⚠ 一段输'}');
    }
    print('   —— 再看达标的组合 ——');
    for (final c in ok) {
      final idx = <int>[];
      for (var k = 0; k < masks.length; k++) {
        if ((masks[k] & c.$2) == c.$2) idx.add(k);
      }
      final y1 = _Stats.of([for (final k in idx) if (days[k] < realCut) r10[k]]);
      final y2 = _Stats.of([for (final k in idx) if (days[k] >= realCut) r10[k]]);
      if (y1.count == 0 || y2.count == 0) continue;
      final okBoth = y1.winRate > be.winRate && y2.winRate > bl.winRate;
      print('   ${c.$1.padRight(42)}'
          '前段 ${y1.count.toString().padLeft(5)}信号 ${_pct(y1.winRate).padLeft(6)}'
          ' / ${y1.avgReturn.toStringAsFixed(2).padLeft(6)}%'
          '   后段 ${y2.count.toString().padLeft(5)}信号 ${_pct(y2.winRate).padLeft(6)}'
          ' / ${y2.avgReturn.toStringAsFixed(2).padLeft(6)}%'
          '   ${okBoth ? '两段都赢 ✓' : '⚠ 一段输'}');
    }
  }
  exit(0);
}

String _header() => '   组合'.padRight(44) +
    '信号(10日)'.padLeft(11) +
    '5日胜率'.padLeft(9) +
    '10日胜率'.padLeft(9) +
    '20日胜率'.padLeft(9) +
    '10日均收'.padLeft(10) +
    '10日PF'.padLeft(8) +
    '超额(10日)'.padLeft(11);

void _row(String name, _Tri s, _Stats b5, _Stats b10, _Stats b20) {
  final ex = (s.a10.winRate - b10.winRate) * 100;
  print('   ${name.padRight(42)}'
      '${s.a10.count.toString().padLeft(10)}'
      '${_pct(s.a5.winRate).padLeft(8)}'
      '${_pct(s.a10.winRate).padLeft(8)}'
      '${_pct(s.a20.winRate).padLeft(8)}'
      '${s.a10.avgReturn.toStringAsFixed(2).padLeft(9)}%'
      '${s.a10.profitFactor.toStringAsFixed(2).padLeft(8)}'
      '${ex.toStringAsFixed(1).padLeft(10)}pp');
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
String _num(double v) => v.toStringAsFixed(2);

class _Tri {
  _Tri(this.a5, this.a10, this.a20);
  final _Stats a5, a10, a20;
}

class _Stats {
  const _Stats(this.count, this.winRate, this.avgReturn, this.profitFactor);

  factory _Stats.of(List<double> xs) {
    if (xs.isEmpty) return const _Stats(0, 0, 0, 0);
    var g = 0.0, l = 0.0;
    for (final x in xs) {
      if (x > 0) {
        g += x;
      } else if (x < 0) {
        l += -x;
      }
    }
    return _Stats(
      xs.length,
      xs.where((x) => x > 0).length / xs.length,
      xs.reduce((a, b) => a + b) / xs.length,
      (g == 0 || l == 0) ? 0 : g / l,
    );
  }

  final int count;
  final double winRate;
  final double avgReturn;
  final double profitFactor;
}
