/// 中枢突破（缠论）参数扫描。
///
/// 目的是区分两种情况：
///   (a) 中枢突破这套逻辑本身无效
///   (b) 只是我用的「N 日固定箱体」这个代理太粗糙，换参数就能用
/// 扫 箱体长度 × 最大宽度 × 是否要求方向向上 三个维度，按年切分检验。
///
/// 用法: dart run tool/sweep_pivot.dart
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/indicators.dart' as ind;
import 'package:stock/data/bar_repository.dart';

const _lookbacks = [20, 40, 60];
const _widths = [15.0, 25.0, 40.0];
const _risingOpts = [true, false];

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();
  final maxH = 20;

  final results = <(int, double, bool, _S, _S, _S, bool)>[];
  var globalBaseWin = 0.0;

  for (final lb in _lookbacks) {
    // 每天记录：收盘价、中枢上沿、宽度、方向、量比、年、前瞻收益
    final rec = <({double close, double up, double w, bool ris, double vr,
                   int y, double r10})>[];
    final baseByYear = <int, List<double>>{};
    for (final stock in stocks) {
      final b = stock.bars;
      if (b.length < lb + maxH + 1) continue;
      for (var t = lb; t <= b.length - 1 - maxH; t++) {
        final seg = b.sublist(0, t);
        final up = ind.highestHigh(seg, lb) ?? 0;
        if (up <= 0) continue;
        final w = ind.pivotWidthPct(seg, lb) ?? double.infinity;
        final ris = ind.pivotRising(seg, lb);
        var sum = 0.0;
        for (var k = t - 5; k < t; k++) {
          sum += b[k].volume;
        }
        final vr = b[t].volume / (sum / 5);
        final y = b[t].date.year;
        final r = (b[t + 10].close / b[t].close - 1) * 100;
        rec.add((close: b[t].close, up: up, w: w, ris: ris, vr: vr, y: y, r10: r));
        (baseByYear[y] ??= <double>[]).add(r);
      }
    }
    final n0 = rec.isEmpty ? 1 : rec.length;
    globalBaseWin = rec.where((r) => r.r10 > 0).length / n0;

    for (final wmax in _widths) {
      for (final risReq in _risingOpts) {
        List<double> pick(int? y) => [
              for (final r in rec)
                if (r.close > r.up && r.w <= wmax && (!risReq || r.ris) &&
                    r.vr >= 1.5 && (y == null || r.y == y))
                  r.r10
            ];
        final sAll = _S.of(pick(null));
        final ys = baseByYear.keys.toList()..sort();
        final sE = _S.of(pick(ys.first));
        final sL = _S.of(pick(ys.last));
        final bE = _S.of(baseByYear[ys.first]!);
        final bL = _S.of(baseByYear[ys.last]!);
        final ok = sE.count >= 30 && sL.count >= 30 &&
            sE.winRate > bE.winRate && sL.winRate > bL.winRate;
        results.add((lb, wmax, risReq, sAll, sE, sL, ok));
      }
    }
    print('已完成 箱体=$lb 日（${rec.length} 个可评估日）');
  }

  print('');
  print('══ 中枢突破参数扫描（10 日持有期）══');
  print('全样本基准约 ${(globalBaseWin * 100).toStringAsFixed(1)}%'
      '（注意：各箱体长度的可评估日集合不同，基准略有差异）');
  print('   ${'箱体'.padLeft(5)}${'最大宽%'.padLeft(8)}${'要求向上'.padLeft(9)}'
      '${'信号数'.padLeft(9)}${'胜率'.padLeft(8)}${'平均%'.padLeft(9)}'
      '${'盈亏比'.padLeft(8)}${'超额'.padLeft(8)}  跨行情');
  for (final r in results) {
    final (lb, w, risReq, sAll, sE, sL, ok) = r;
    print('   ${lb.toString().padLeft(5)}${w.toStringAsFixed(0).padLeft(8)}'
        '${(risReq ? '是' : '否').padLeft(9)}'
        '${sAll.count.toString().padLeft(8)}'
        '${(sAll.winRate * 100).toStringAsFixed(1).padLeft(7)}%'
        '${sAll.avg.toStringAsFixed(2).padLeft(8)}%'
        '${sAll.pf.toStringAsFixed(2).padLeft(8)}'
        '${((sAll.winRate - globalBaseWin) * 100).toStringAsFixed(1).padLeft(7)}pp'
        '   ${ok ? '两段都赢 ✓' : '⚠ 不过关'}');
  }
  exit(0);
}

class _S {
  const _S(this.count, this.winRate, this.avg, this.pf);
  final int count;
  final double winRate;
  final double avg;
  final double pf;

  factory _S.of(List<double> xs) {
    if (xs.isEmpty) return const _S(0, 0, 0, 0);
    var g = 0.0, l = 0.0;
    for (final x in xs) {
      if (x > 0) {
        g += x;
      } else if (x < 0) {
        l += -x;
      }
    }
    return _S(xs.length, xs.where((x) => x > 0).length / xs.length,
        xs.reduce((a, b) => a + b) / xs.length, (g == 0 || l == 0) ? 0 : g / l);
  }
}
