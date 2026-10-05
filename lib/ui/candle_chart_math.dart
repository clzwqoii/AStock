/// 蜡烛图纯计算层：坐标几何、价格区间、十字光标读数文本。
/// 不依赖绘制，供 [CandleChart] 的 painter 与单测共用；改刻度先改这里。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models.dart';

/// K 线图画布几何：像素坐标 ↔ K线索引/价格 的双向换算。
/// 画布右侧固定留 [labelW] 给价格标签，下方留 [bottomPad] 给日期标签。
@immutable
class ChartGeometry {
  const ChartGeometry({
    required this.size,
    required this.count,
    required this.lo,
    required this.hi,
  });

  final Size size;
  final int count;
  final double lo;
  final double hi;

  static const labelW = 46.0;
  static const priceTop = 10.0;
  // 纵向四段：价格 / 成交量 / MACD / KDJ。价格区要显著大于副面板之和（真机反馈：
  // KDJ 吃剩余高度会把 K 线压扁），三个副面板按份额定高，空间不足时靠下的先被夹为 0。
  static const priceHeightRatio = 0.46;
  static const volGap = 12.0;
  static const volHeightRatio = 0.12;
  static const macdGap = 12.0;
  static const macdHeightRatio = 0.14;
  static const kdjGap = 12.0;
  static const kdjHeightRatio = 0.14;
  static const bottomPad = 22.0;

  /// 价格轴区域（蜡烛 + 均线）。
  Rect get priceRect =>
      Rect.fromLTWH(0, priceTop, size.width - labelW, size.height * priceHeightRatio);

  /// 成交量柱区域，夹在价格轴与 MACD 面板之间。
  Rect get volRect => Rect.fromLTWH(
        0,
        priceRect.bottom + volGap,
        priceRect.width,
        math.max(0.0, size.height * volHeightRatio),
      );

  /// MACD 面板（DIF/DEA + 红绿柱）。
  Rect get macdRect => Rect.fromLTWH(
        0,
        volRect.bottom + macdGap,
        priceRect.width,
        math.max(0.0, size.height * macdHeightRatio),
      );

  /// KDJ 面板（K/D/J 三线），高度定份额不再吃剩余空间。
  Rect get kdjRect => Rect.fromLTWH(
        0,
        macdRect.bottom + kdjGap,
        priceRect.width,
        math.max(0.0, size.height * kdjHeightRatio),
      );

  double get slot => count <= 0 ? 0.0 : priceRect.width / count;

  /// 第 i 根的水平中心 x。
  double centerX(int i) => slot * (i + 0.5);

  double yForPrice(double p) =>
      hi <= lo ? priceRect.center.dy : priceRect.bottom - (p - lo) / (hi - lo) * priceRect.height;

  double priceForY(double y) => lo + (priceRect.bottom - y) / priceRect.height * (hi - lo);

  /// x 像素落在哪一根上；无数据返回 -1；越界钳到首/末根（贴着边缘拖动时读数不丢）。
  int indexForX(double x) {
    if (count <= 0 || slot <= 0) return -1;
    return (x / slot).floor().clamp(0, count - 1);
  }
}

/// 价格轴上下界：覆盖 K 线高低与均线可见值，两侧各留 [padRatio] 边距。
/// 高低相等（一字板）时撑开成非零区间，避免 yForPrice 除零。
({double lo, double hi}) priceRange(
  List<Bar> bars,
  List<List<double?>> maSeries, {
  double padRatio = 0.06,
}) {
  var lo = bars.first.low;
  var hi = bars.first.high;
  for (final b in bars) {
    lo = math.min(lo, b.low);
    hi = math.max(hi, b.high);
  }
  for (final set in maSeries) {
    for (final v in set) {
      if (v != null) {
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
  }
  if (hi <= lo) {
    final mid = (hi + lo) / 2;
    return (lo: mid - 1, hi: mid + 1);
  }
  final pad = (hi - lo) * padRatio;
  return (lo: lo - pad, hi: hi + pad);
}

/// 日期标签：`MM-DD`，横轴刻度与读数共用。
String dateLabel(DateTime date) =>
    '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// 十字光标读数：一个字段一个 getter，由浮层按行排布（拼成一行会超出图表宽度）。
class CandleReadout {
  const CandleReadout(this.bar, this.previous);

  factory CandleReadout.of(Bar bar, {Bar? previous}) => CandleReadout(bar, previous);

  final Bar bar;

  /// 前一根，用于算涨跌幅；null = 首根。
  final Bar? previous;

  /// `YYYY-MM-DD`。
  String get date => '${bar.date.year}-${dateLabel(bar.date)}';

  /// 涨跌幅文本；无前收（或前收为 0）时 `--`。
  String get pct {
    final p = pctChange;
    if (p == null) return '--';
    return '${p >= 0 ? '+' : '-'}${p.abs().toStringAsFixed(2)}%';
  }

  /// 涨跌方向，用于上色；null 表示未知。
  bool? get rising {
    final p = pctChange;
    return p == null ? null : p >= 0;
  }

  double? get pctChange => pctChangeOf(bar, previous: previous);

  String get volume => formatVolume(bar.volume);

  String get open => _n(bar.open);
  String get high => _n(bar.high);
  String get low => _n(bar.low);
  String get close => _n(bar.close);
}

/// K 线涨跌幅（%）；无前收或前收为 0 时返回 null。
double? pctChangeOf(Bar bar, {Bar? previous}) {
  final prevClose = previous?.close ?? 0;
  if (prevClose <= 0) return null;
  return (bar.close - prevClose) / prevClose * 100;
}

/// 成交量文本：库内口径为**手**，过万按万手显示（读数与详情页一致）。
String formatVolume(double hands) => hands >= 10000
    ? '${(hands / 10000).toStringAsFixed(2)}万手'
    : '${hands.toStringAsFixed(0)}手';

String _n(double v) => v.toStringAsFixed(2);
