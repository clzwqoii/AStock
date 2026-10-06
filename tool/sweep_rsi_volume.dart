/// RSI超卖·放量 的参数邻域扫描。
///
/// 现役规则是 `RSI14<30 且 量比>2`，两个阈值都是从既有规则里拿的，从没扫过。
/// 这里扫 RSI 阈值 × 量比阈值的全部组合，并对每个组合做**按年切分**检验——
/// 全样本更漂亮但跨年塌掉的例子已经出现过三次，所以跨年不过关的一律标注。
///
/// 只报告，不修改 `builtInRules`。
///
/// 用法:
///   dart run tool/sweep_rsi_volume.dart [--db 路径] [--split-at 20250101]
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

const _rsiThresholds = [20.0, 25.0, 30.0, 35.0, 40.0];
const _volThresholds = [1.5, 2.0, 3.0, 5.0];

Future<void> main(List<String> args) async {
  String? dbPath;
  String? splitAt;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--db=')) {
      dbPath = a.substring(5);
    } else if (a == '--db' && i + 1 < args.length) {
      dbPath = args[++i];
    } else if (a.startsWith('--split-at=')) {
      splitAt = a.substring(11);
    } else if (a == '--split-at' && i + 1 < args.length) {
      splitAt = args[++i];
    }
  }

  final repo = BarRepository(dbPath ?? AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  final bars = stocks.map((s) => s.bars.length).reduce((a, b) => a > b ? a : b);
  repo.close();
  final maxH = kDefaultHorizons.reduce((a, b) => a > b ? a : b);

  final sw = Stopwatch()..start();
  // ── 一遍扫描：只留 RSI/量比/日期序数/三个持有期的前瞻收益 ──
  final rec = <({double rsi, double vol, int day, double r10})>[];
  for (final stock in stocks) {
    final b = stock.bars;
    if (b.length < IndicatorSnapshot.minBars + maxH) continue;
    final series = IndicatorSeries.from(b);
    final lastEval = b.length - 1 - maxH;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      final s = series.at(t);
      rec.add((
        rsi: s.rsi14,
        vol: s.volumeRatio,
        day: b[t].date.millisecondsSinceEpoch ~/ 86400000,
        r10: (b[t + 10].close / b[t].close - 1) * 100,
      ));
    }
  }
  print('股票 ${stocks.length} 只 · 每只最多 $bars 根');
  print('可评估日 ${rec.length} 个 · 扫描耗时 ${sw.elapsed.inSeconds}s');

  final sd = [for (final r in rec) r.day]..sort();
  final cut = splitAt == null
      ? sd[sd.length ~/ 2]
      : DateTime(
          int.parse(splitAt.substring(0, 4)),
          int.parse(splitAt.substring(4, 6)),
          int.parse(splitAt.substring(6, 8)),
        ).millisecondsSinceEpoch ~/ 86400000;

  final base = _st([for (final r in rec) r.r10]);
  final baseE = _st([for (final r in rec) if (r.day < cut) r.r10]);
  final baseL = _st([for (final r in rec) if (r.day >= cut) r.r10]);
  print('切分点：${splitAt ?? '样本中位日'} = $cut');
  print('无条件基准 10日：${base.count} 样本 / ${_p(base.winRate)} / ${_n(base.avg)}%');
  print('   前段 ${baseE.count} 样本 ${_p(baseE.winRate)} ；'
      '后段 ${baseL.count} 样本 ${_p(baseL.winRate)}');

  final rows = <(double, double, _Stat, _Stat, _Stat, bool)>[];
  for (final rt in _rsiThresholds) {
    for (final vt in _volThresholds) {
      List<double> sel(bool Function(({double rsi, double vol, int day, double r10})) f) =>
          [for (final r in rec) if (f(r)) r.r10];
      final all = sel((r) => r.rsi < rt && r.vol > vt);
      final e = sel((r) => r.rsi < rt && r.vol > vt && r.day < cut);
      final l = sel((r) => r.rsi < rt && r.vol > vt && r.day >= cut);
      final sAll = _st(all), sE = _st(e), sL = _st(l);
      final okBoth = sE.count >= 30 && sL.count >= 30 &&
          sE.winRate > baseE.winRate && sL.winRate > baseL.winRate;
      rows.add((rt, vt, sAll, sE, sL, okBoth));
    }
  }
  rows.sort((a, b) =>
      (b.$3.winRate - base.winRate).compareTo(a.$3.winRate - base.winRate));

  print('');
  print('══ 全部 ${rows.length} 组参数，按 10 日超额胜率排序 ══');
  print('   RSI<   量比>   信号(10日)   胜率    平均%     PF    超额    跨行情');
  for (final r in rows) {
    final (rt, vt, s, _, _, ok) = (r.$1, r.$2, r.$3, r.$4, r.$5, r.$6);
    final cur = rt == 30.0 && vt == 2.0 ? ' ← 现役' : '';
    print('   ${rt.toStringAsFixed(0).padLeft(5)}  ${vt.toStringAsFixed(1).padLeft(5)}'
        '${s.count.toString().padLeft(11)}'
        '${_p(s.winRate).padLeft(8)}'
        '${s.avg.toStringAsFixed(2).padLeft(8)}%'
        '${s.pf.toStringAsFixed(2).padLeft(7)}'
        '${((s.winRate - base.winRate) * 100).toStringAsFixed(1).padLeft(7)}pp'
        '   ${ok ? '两段都赢 ✓' : '⚠ 不过关'}$cur');
  }

  print('');
  print('══ 只列跨行情两段都赢的 ══');
  final good = rows.where((r) => r.$6).toList();
  if (good.isEmpty) {
    print('   （没有参数组合通过跨行情检验）');
  } else {
    for (final r in good) {
      final (rt, vt, s, e, l, _) = (r.$1, r.$2, r.$3, r.$4, r.$5, r.$6);
      print('   RSI<$rt 量比>$vt ：全样本 ${s.count} 信号 ${_p(s.winRate)}'
          ' / 前段 ${e.count} 信号 ${_p(e.winRate)}'
          ' / 后段 ${l.count} 信号 ${_p(l.winRate)}'
          ' / PF ${s.pf.toStringAsFixed(2)}'
          ' / 超额 ${((s.winRate - base.winRate) * 100).toStringAsFixed(1)}pp'
          '（前段超额 ${((e.winRate - baseE.winRate) * 100).toStringAsFixed(1)}pp'
          '、后段超额 ${((l.winRate - baseL.winRate) * 100).toStringAsFixed(1)}pp）');
    }
  }
  exit(0);
}

class _Stat {
  const _Stat(this.count, this.winRate, this.avg, this.pf);
  final int count;
  final double winRate;
  final double avg;
  final double pf;
}

_Stat _st(List<double> xs) {
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

String _p(double v) => '${(v * 100).toStringAsFixed(1)}%';
String _n(double v) => v.toStringAsFixed(2);
