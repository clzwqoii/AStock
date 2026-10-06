/// 中枢突破「三类买点」参数扫描 —— 按视频口径实现。
///
/// 视频原话要点：
///   1. 识别中枢：**前期底部区间**构建震荡（如 W 底），中间小区间大震荡并
///      **伴随量能变化**（主力建仓）
///   2. 启动信号：**放量突破中枢** → **缩量洗盘** → **回踩不破前期中枢区间**
///      （三类买点 / 三类起爆结构）
///   3. 纪律：**等洗盘结束再进场**，**避免高位追涨**；没有一波到底的空间
///
/// 与我此前 20 日扁平箱体的差别：这里要求中枢处于**底部位阶**（突破不过度远离
/// 箱体上沿 = 不追高），且洗盘段必须**缩量**。
///
/// 扫 突破上限 × 最大箱体宽度 × 缩量比例 × 是否要求方向向上 = 32 组参数，
/// 按年切分检验，只列信号量足够的组合。
///
/// 用法: dart run tool/sweep_chan_sanbuy.dart
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:stock/config.dart';
import 'package:stock/core/indicators.dart' as ind;
import 'package:stock/data/bar_repository.dart';

/// 中枢箱体长度：覆盖视频里「前期底部区间」的量级。
const _boxN = 20;

/// 信号持有期。
const _horizon = 10;

/// 突破后洗盘窗口：视频要求「等洗盘结束」，洗盘最多这么几天。
const _washDays = 8;

/// 突破上限（%）：突破日收盘价最多比箱体上沿高这么多，超过即"高位追涨"排除。
const _gaps = [3.0, 6.0, 12.0, double.infinity];

/// 最大箱体宽度（%）。
const _wmaxs = [15.0, 25.0];

/// 缩量比例上限：洗盘段最大量 / 突破日量，超过即不是缩量洗盘。
const _shrinks = [0.6, 1.0];

/// 再启动日的量比下限。视频强调洗盘结束再进场，启动日应重新放量。
const _relaunches = [1.0, 1.5];

/// 是否要求中枢方向向上（后半段高低点均高于前半段）。
const _risings = [true, false];

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();

  final ncfg = _gaps.length * _wmaxs.length * _shrinks.length * _relaunches.length *
      _risings.length;

  // 计数器：idx = cc * (ny+1) + yi，yi == ny 表示全样本
  final baseCnt = <int, int>{};
  final baseWin = <int, int>{};
  var sig = List<int>.filled(ncfg * 32, 0);
  var win = List<int>.filled(ncfg * 32, 0);

  for (final stock in stocks) {
    final b = stock.bars;
    final n = b.length;
    if (n < _boxN + _washDays + _horizon + 1) continue;

    final close = List<double>.filled(n, 0);
    final low = List<double>.filled(n, 0);
    final vol = List<double>.filled(n, 0);
    final yr = List<int>.filled(n, 0);
    final fwd = List<double>.filled(n, 0);
    final up = List<double>.filled(n, 0);
    final wid = List<double>.filled(n, 0);
    final ris = List<bool>.filled(n, false);
    for (var t = 0; t < n; t++) {
      close[t] = b[t].close;
      low[t] = b[t].low;
      vol[t] = b[t].volume;
      yr[t] = b[t].date.year;
    }
    for (var t = _boxN; t + _horizon < n; t++) {
      fwd[t] = (b[t + _horizon].close / b[t].close - 1) * 100;
    }
    for (var t = _boxN; t + _horizon < n; t++) {
      final seg = b.sublist(0, t);
      up[t] = ind.highestHigh(seg, _boxN) ?? 0;
      wid[t] = ind.pivotWidthPct(seg, _boxN) ?? double.infinity;
      ris[t] = ind.pivotRising(seg, _boxN);
    }

    for (var t = _boxN; t + _horizon < n; t++) {
      baseCnt[yr[t]] = (baseCnt[yr[t]] ?? 0) + 1;
      if (fwd[t] > 0) baseWin[yr[t]] = (baseWin[yr[t]] ?? 0) + 1;
    }

    // 5 日均量（量比用）
    final vol5 = List<double>.filled(n, 0);
    for (var t = _boxN; t < n; t++) {
      var s5 = 0.0;
      for (var k = t - 5; k < t; k++) {
        s5 += vol[k];
      }
      vol5[t] = s5 / 5;
    }

    for (var t = _boxN + _washDays; t + _horizon < n; t++) {
      if (up[t] <= 0 || close[t] <= up[t]) continue;
      final vr = vol[t] / math.max(vol5[t], 1);
      final gap = (close[t] - up[t]) / up[t] * 100;

      // 往前找最近一次突破日 j（洗盘前的启动）
      var j = -1;
      for (var k = t - 1; k >= t - _washDays; k--) {
        if (k >= _boxN && up[k] > 0 && close[k] > up[k]) {
          j = k;
          break;
        }
      }
      if (j < 0) continue;
      final upper = up[j];
      // 回踩不破：洗盘段最低价不得跌回箱体上沿之下
      var broke = false;
      for (var k = j + 1; k <= t; k++) {
        if (low[k] < upper) {
          broke = true;
          break;
        }
      }
      if (broke) continue;
      // 缩量洗盘：只看洗盘段 (j, t-1]；信号日 t 是"洗盘结束再启动"，
      // 本身就该放量，不能算进缩量比较里（此前把 t 算进去是错的）。
      var mxv = 0.0;
      for (var k = j + 1; k < t; k++) {
        if (vol[k] > mxv) mxv = vol[k];
      }
      final shr = mxv / math.max(vol[j], 1);

      final yi = _yearIndex[yr[t]];
      if (yi == null) continue;
      for (var gi = 0; gi < _gaps.length; gi++) {
        if (gap > _gaps[gi]) continue;
        for (var wi = 0; wi < _wmaxs.length; wi++) {
          if (wid[j] > _wmaxs[wi]) continue;
          for (var si = 0; si < _shrinks.length; si++) {
            if (shr > _shrinks[si]) continue;
            for (var li = 0; li < _relaunches.length; li++) {
              if (vr < _relaunches[li]) continue;
              for (var ri = 0; ri < _risings.length; ri++) {
                if (_risings[ri] && !ris[j]) continue;
                final cc = ((gi * _wmaxs.length + wi) * _shrinks.length + si) *
                        _relaunches.length +
                    li;
                final idx = cc * _risings.length + ri;
                sig[idx * 32 + yi]++;
                if (fwd[t] > 0) win[idx * 32 + yi]++;
                sig[idx * 32 + 31]++;
                if (fwd[t] > 0) win[idx * 32 + 31]++;
              }
            }
          }
        }
      }
    }
  }

  _print(stocks.length, ncfg, baseCnt, baseWin, sig, win);
  exit(0);
}

final _yearIndex = <int, int>{2024: 0, 2025: 1, 2026: 2};

void _print(int nStocks, int ncfg, Map<int, int> baseCnt, Map<int, int> baseWin,
    List<int> sig, List<int> win) {
  final ys = baseCnt.keys.toList()..sort();
  print('══ 中枢突破「三类买点」参数扫描（视频口径，持有期 $_horizon 日）══');
  print('样本：$nStocks 只股票。基准胜率（全样本，非选股）：');
  for (final y in ys) {
    final b = baseCnt[y]!;
    final w = baseWin[y]!;
    print('   $y  样本数 $b  基准胜率 ${(w / b * 100).toStringAsFixed(1)}%');
  }
  print('');
  print('   ${'突破上限%'.padLeft(10)}${'最大宽%'.padLeft(8)}'
      '${'缩量比例'.padLeft(8)}${'启动量比'.padLeft(8)}${'向上'.padLeft(5)}'
      '${'信号数'.padLeft(9)}'
      '${'胜率'.padLeft(8)}${'超额'.padLeft(8)}  按年表现            判定');
  final rows = <String>[];
  var passed = 0;
  for (var cc = 0; cc < ncfg; cc++) {
    final iAll = cc * 32 + 31;
    final c = sig[iAll];
    if (c < 100) continue;
    final w = win[iAll];
    final yStr = <String>[];
    var ok = true;
    for (final y in ys) {
      final yi = _yearIndex[y]!;
      final i = cc * 32 + yi;
      final bc = baseCnt[y]!;
      final bw = baseWin[y]!;
      final wr = win[i] / sig[i];
      final bwR = bw / bc;
      if (wr <= bwR) ok = false;
      yStr.add('$y ${(wr * 100).toStringAsFixed(1)}'
          '(${((wr - bwR) * 100).toStringAsFixed(1)}pp)');
    }
    if (ok) passed++;
    rows.add('   ${_gaps[(cc ~/ 8) % _gaps.length] == double.infinity ? "不限" : _gaps[(cc ~/ 8) % _gaps.length].toStringAsFixed(0)}'
        '${''.padLeft(10 - 10)}'
        '${_wmaxs[(cc ~/ 4) % _wmaxs.length].toStringAsFixed(0).padLeft(8)}'
        '${_shrinks[(cc ~/ 2) % _shrinks.length].toStringAsFixed(1).padLeft(8)}'
        '${_relaunches[(cc ~/ 2) % _relaunches.length].toStringAsFixed(1).padLeft(8)}'
        '${(_risings[cc % 2] ? "是" : "否").padLeft(5)}'
        '${c.toString().padLeft(9)}'
        '${(w / c * 100).toStringAsFixed(1).padLeft(7)}%'
        '${"—".padLeft(8)}  ${yStr.join("  ")}  ${ok ? "✓ 通过" : "⚠ 不过关"}');
  }
  rows.sort((a, b) {
    final pa = a.contains("✓") ? 0 : 1;
    final pb = b.contains("✓") ? 0 : 1;
    return pa == pb ? b.compareTo(a) : pa - pb;
  });
  print(rows.take(36).join("\n"));
  print('');
  print('共 $passed / $ncfg 组参数在三年里每年都跑赢基准。');
}
