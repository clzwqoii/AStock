/// 日K蜡烛图（CustomPainter 自绘）：蜡烛 + 成交量 + MA5/10/20 均线，无第三方图表依赖。
/// 十字光标：桌面鼠标悬停、移动端按住拖动均激活，读数浮层跟随。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/indicators.dart';
import '../core/models.dart';
import 'candle_chart_math.dart';
import 'colors.dart';

class CandleChart extends StatefulWidget {
  const CandleChart({super.key, required this.bars, this.maxBars = 120});

  final List<Bar> bars;
  final int maxBars;

  @override
  State<CandleChart> createState() => _CandleChartState();
}

class _CandleChartState extends State<CandleChart> {
  /// 可见 K 线（超长时取末尾 maxBars 根）与均线、MACD、KDJ。
  late List<Bar> _visible;
  late List<List<double?>> _maSeries;
  ({List<double> dif, List<double> dea, List<double> hist})? _macd;
  ({List<double?> k, List<double?> d, List<double?> j})? _kdj;
  late double _lo;
  late double _hi;

  /// 十字光标指向的可见索引；null 未激活。
  int? _active;
  /// 指针位置（画横线）；桌面移出后置空。
  Offset? _pointer;

  @override
  void initState() {
    super.initState();
    _recompute(widget.bars);
  }

  @override
  void didUpdateWidget(covariant CandleChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.bars, widget.bars)) {
      _recompute(widget.bars);
      setState(() {
        _active = null;
        _pointer = null;
      });
    }
  }

  void _recompute(List<Bar> bars) {
    final visible = bars.length > widget.maxBars ? bars.sublist(bars.length - widget.maxBars) : bars;
    final closes = [for (final b in visible) b.close];
    _visible = visible;
    _maSeries = [for (final n in maPeriods) smaSeries(closes, n)];
    _macd = closes.isEmpty ? null : macd(closes);
    _kdj = visible.length >= 9 ? kdj(visible) : null;
    final range = priceRange(visible, _maSeries);
    _lo = range.lo;
    _hi = range.hi;
  }

  ChartGeometry _geometryFor(Size size) =>
      ChartGeometry(size: size, count: _visible.length, lo: _lo, hi: _hi);

  void _update(Offset local, Size size) {
    if (_visible.isEmpty) return;
    final geo = _geometryFor(size);
    final idx = geo.indexForX(local.dx);
    if (idx < 0 || idx >= _visible.length) return;
    setState(() {
      _active = idx;
      _pointer = Offset(local.dx, local.dy.clamp(geo.priceRect.top, geo.priceRect.bottom));
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (size.isEmpty) return const SizedBox.expand();
        final geo = _geometryFor(size);
        return MouseRegion(
          onHover: (e) => _update(e.localPosition, size),
          onExit: (_) => setState(() {
            _active = null;
            _pointer = null;
          }),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: (d) => _update(d.localPosition, size),
            onPanStart: (d) => _update(d.localPosition, size),
            onPanUpdate: (d) => _update(d.localPosition, size),
            child: SizedBox.expand(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _CandlePainter(
                      geo: geo,
                      bars: _visible,
                      maSeries: _maSeries,
                      macdData: _macd,
                      kdjData: _kdj,
                      activeIndex: _active,
                      pointerY: _pointer?.dy,
                    ),
                  ),
                  if (_active != null) _readout(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 读数浮层：左上角，一行一字段排布，宽度受图表约束（右侧留给价格刻度）。
  Widget _readout() {
    final i = _active!;
    final r = CandleReadout.of(_visible[i], previous: i > 0 ? _visible[i - 1] : null);
    final pctColor = switch (r.rising) {
      null => AppColors.dim,
      true => AppColors.red,
      false => AppColors.down,
    };
    return Positioned(
      left: 4,
      top: 2,
      child: IgnorePointer(
        child: Container(
          key: const ValueKey('crosshair-readout'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            border: Border.all(color: AppColors.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(r.date,
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.text)),
                  const SizedBox(width: 8),
                  Text(r.pct, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: pctColor)),
                  const SizedBox(width: 6),
                  Text(r.volume, style: const TextStyle(fontSize: 10, color: AppColors.dim)),
                ],
              ),
              const SizedBox(height: 2),
              _pair('开', r.open, '高', r.high),
              _pair('低', r.low, '收', r.close),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pair(String l1, String v1, String l2, String v2) => Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l1, style: const TextStyle(fontSize: 10, color: AppColors.dim)),
            const SizedBox(width: 2),
            Text(v1, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.text)),
            const SizedBox(width: 12),
            Text(l2, style: const TextStyle(fontSize: 10, color: AppColors.dim)),
            const SizedBox(width: 2),
            Text(v2, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.text)),
          ],
        ),
      );
}

class _CandlePainter extends CustomPainter {
  _CandlePainter({
    required this.geo,
    required this.bars,
    required this.maSeries,
    this.macdData,
    this.kdjData,
    this.activeIndex,
    this.pointerY,
  });

  final ChartGeometry geo;
  final List<Bar> bars;
  final List<List<double?>> maSeries;

  /// 可见窗口的 MACD 数据；null（无数据）不画面板内容。
  final ({List<double> dif, List<double> dea, List<double> hist})? macdData;

  /// 可见窗口的 KDJ 数据；null（不足 9 根）不画面板内容。
  final ({List<double?> k, List<double?> d, List<double?> j})? kdjData;

  /// 十字光标指向的索引，null 不画。
  final int? activeIndex;
  /// 指针 y（横线位置），null 不画。
  final double? pointerY;

  static const _up = AppColors.red;
  static const _down = AppColors.down;
  static const _maColors = maColors;
  static const _difColor = AppColors.text; // DIF 深色实线
  static const _deaColor = Color(0xFFF59E0B); // DEA 琥珀（与 MA5 同色系）
  static const _kColor = AppColors.text; // K 深色
  static const _dColor = Color(0xFFF59E0B); // D 琥珀
  static const _jColor = Color(0xFF8B5CF6); // J 紫（与 MA20 同色系）
  static const _dim = AppColors.dim;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    final priceRect = geo.priceRect;
    final volRect = geo.volRect;

    // 网格与右侧价格标签
    final grid = Paint()..color = const Color(0xFFEEF0F4)..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= 2; i++) {
      final p = geo.lo + (geo.hi - geo.lo) * i / 2;
      final y = geo.yForPrice(p);
      canvas.drawLine(Offset(0, y), Offset(priceRect.right, y), grid);
      _text(canvas, tp, p.toStringAsFixed(2), Offset(priceRect.right + 4, y - 6));
    }

    final slot = geo.slot;
    final bodyW = (slot * 0.62).clamp(1.5, 18.0);
    var maxVol = 0.0;
    for (final b in bars) {
      maxVol = math.max(maxVol, b.volume);
    }

    // 成交量柱
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final h = maxVol == 0 ? 0.0 : b.volume / maxVol * volRect.height;
      final color = (b.close >= b.open ? _up : _down).withValues(alpha: 0.55);
      canvas.drawRect(
          Rect.fromLTWH(geo.centerX(i) - bodyW / 2, volRect.bottom - h, bodyW, h), Paint()..color = color);
    }
    if (volRect.height > 8) {
      _panelHeader(canvas, tp, volRect, '成交量',
          [(formatVolume(bars[_displayIndex].volume), _dim)]);
    }

    // 十字光标：选中列高亮 → 竖线 → 横线（画在蜡烛下面，避免盖住当日走势）
    final active = activeIndex;
    if (active != null && active >= 0 && active < bars.length) {
      final cx = geo.centerX(active);
      canvas.drawRect(
        Rect.fromLTWH(cx - slot / 2, priceRect.top - 4, slot, volRect.bottom - priceRect.top + 4),
        Paint()..color = AppColors.text.withValues(alpha: 0.05),
      );
    }
    final hair = Paint()
      ..color = _dim.withValues(alpha: 0.85)
      ..strokeWidth = 1;
    if (active != null && active >= 0 && active < bars.length) {
      _dashed(canvas, Offset(geo.centerX(active), priceRect.top - 4),
          Offset(geo.centerX(active), volRect.bottom), hair);
    }
    if (pointerY != null) {
      _dashed(canvas, Offset(0, pointerY!), Offset(priceRect.right, pointerY!), hair);
      _priceTag(canvas, tp, geo.priceForY(pointerY!), pointerY!, size);
    }

    // 蜡烛：涨收红、跌收绿（A股惯例，按开收判断阴阳）
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final paint = Paint()..color = b.close >= b.open ? _up : _down;
      final cx = geo.centerX(i);
      canvas.drawLine(Offset(cx, geo.yForPrice(b.high)), Offset(cx, geo.yForPrice(b.low)),
          paint..strokeWidth = 1.4);
      final top = geo.yForPrice(math.max(b.open, b.close));
      final bh = math.max(1.5, (geo.yForPrice(math.min(b.open, b.close)) - top).abs());
      canvas.drawRect(Rect.fromLTWH(cx - bodyW / 2, top, bodyW, bh), paint);
    }

    // MA 均线
    for (var m = 0; m < maSeries.length; m++) {
      final path = Path();
      var started = false;
      final series = maSeries[m];
      for (var i = 0; i < series.length; i++) {
        final v = series[i];
        if (v == null) continue;
        final pt = Offset(geo.centerX(i), geo.yForPrice(v));
        if (started) {
          path.lineTo(pt.dx, pt.dy);
        } else {
          path.moveTo(pt.dx, pt.dy);
          started = true;
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = _maColors[m]
            ..strokeWidth = 1.6
            ..style = PaintingStyle.stroke);
    }

    _paintMacd(canvas, tp, grid);
    _paintKdj(canvas, tp);

    // 底部日期标签
    if (bars.length > 1) {
      _bottomDate(canvas, tp, bars.first.date, 2, size);
      _bottomDate(canvas, tp, bars[bars.length ~/ 2].date, size.width / 2 - 20, size);
      _bottomDate(canvas, tp, bars.last.date, size.width - 60, size);
    }
  }

  /// MACD 副面板：零轴线 + 红绿柱（国内惯例红正绿负）+ DIF/DEA 线。
  void _paintMacd(Canvas canvas, TextPainter tp, Paint grid) {
    final m = macdData;
    final rect = geo.macdRect;
    if (m == null || rect.height < 8) return;
    var maxAbs = 0.0;
    for (var i = 0; i < bars.length; i++) {
      maxAbs = math.max(maxAbs, m.dif[i].abs());
      maxAbs = math.max(maxAbs, m.dea[i].abs());
      maxAbs = math.max(maxAbs, m.hist[i].abs());
    }
    if (maxAbs <= 0) return;
    final mid = rect.center.dy;
    final half = rect.height / 2 * 0.9;
    double yFor(double v) => mid - v / maxAbs * half;
    canvas.drawLine(Offset(0, mid), Offset(rect.right, mid), grid);

    final barW = math.min(geo.slot * 0.45, 6.0);
    final histPaint = Paint();
    for (var i = 0; i < bars.length; i++) {
      final v = m.hist[i];
      final h = math.max(0.5, v.abs() / maxAbs * half);
      histPaint.color = (v >= 0 ? _up : _down).withValues(alpha: 0.7);
      canvas.drawRect(Rect.fromLTWH(geo.centerX(i) - barW / 2, v >= 0 ? mid - h : mid, barW, h), histPaint);
    }
    for (final (color, series) in [(_difColor, m.dif), (_deaColor, m.dea)]) {
      _strokeSeries(canvas, series, (i) => yFor(series[i]), color, 1.2);
    }
    final di = _displayIndex;
    _panelHeader(canvas, tp, rect, 'MACD', [
      ('DIF ${m.dif[di].toStringAsFixed(2)}', _difColor),
      ('DEA ${m.dea[di].toStringAsFixed(2)}', _deaColor),
      ('MACD ${m.hist[di].toStringAsFixed(2)}', _dim),
    ]);
  }

  /// 逐日折线：跳过 null（KDJ 前 n−1 根无值），与 MA 均线同款画法。
  void _strokeSeries(
      Canvas canvas, List<double?> series, double Function(int i) yAt, Color color, double width) {
    final path = Path();
    var started = false;
    for (var i = 0; i < series.length; i++) {
      if (series[i] == null) continue;
      if (started) {
        path.lineTo(geo.centerX(i), yAt(i));
      } else {
        path.moveTo(geo.centerX(i), yAt(i));
        started = true;
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..style = PaintingStyle.stroke);
  }

  /// KDJ 副面板：K/D/J 三线（纵轴按可见数据动态伸缩）。
  void _paintKdj(Canvas canvas, TextPainter tp) {
    final k = kdjData;
    final rect = geo.kdjRect;
    if (k == null || rect.height < 8) return;
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final s in [k.k, k.d, k.j]) {
      for (final v in s) {
        if (v == null) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (hi <= lo) {
      lo -= 5;
      hi += 5;
    }
    final pad = (hi - lo) * 0.1;
    lo -= pad;
    hi += pad;
    double yAt(List<double?> s, int i) => rect.bottom - (s[i]! - lo) / (hi - lo) * rect.height;
    _strokeSeries(canvas, k.k, (i) => yAt(k.k, i), _kColor, 1.2);
    _strokeSeries(canvas, k.d, (i) => yAt(k.d, i), _dColor, 1.2);
    _strokeSeries(canvas, k.j, (i) => yAt(k.j, i), _jColor, 1.1);
    final di = _displayIndex;
    final kv = k.k[di], dv = k.d[di], jv = k.j[di];
    _panelHeader(canvas, tp, rect, 'KDJ', [
      if (kv != null) ('K ${kv.toStringAsFixed(1)}', _kColor),
      if (dv != null) ('D ${dv.toStringAsFixed(1)}', _dColor),
      if (jv != null) ('J ${jv.toStringAsFixed(1)}', _jColor),
    ]);
  }

  /// 数值行所指的 K 线：十字光标激活时跟随光标，否则显示最后一根。
  int get _displayIndex {
    final a = activeIndex;
    return (a != null && a >= 0 && a < bars.length) ? a : bars.length - 1;
  }

  /// 面板顶部行：左侧标题 + 右侧数值段（从右往左排，各段独立着色，与系列同色）。
  void _panelHeader(
      Canvas canvas, TextPainter tp, Rect rect, String title, List<(String, Color)> values) {
    _text(canvas, tp, title, Offset(4, rect.top + 2));
    var x = rect.right - 4;
    for (final (text, color) in values.reversed) {
      tp.text = TextSpan(text: text, style: TextStyle(fontSize: 10, color: color));
      tp.layout();
      x -= tp.width;
      tp.paint(canvas, Offset(x, rect.top + 2));
      x -= 10;
    }
  }

  /// 横线右侧的价格标签（白底，压在价格刻度左侧）。
  void _priceTag(Canvas canvas, TextPainter tp, double price, double y, Size size) {
    final t = TextPainter(
      text: TextSpan(
        text: price.toStringAsFixed(2),
        style: const TextStyle(fontSize: 10, color: AppColors.text),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final left = geo.priceRect.right + 4;
    final top = (y - t.height / 2).clamp(0.0, size.height - t.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, ChartGeometry.labelW - 8, t.height + 2), const Radius.circular(3)),
      Paint()..color = Colors.white,
    );
    t.paint(canvas, Offset(left + 3, top + 1));
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint,
      {double dash = 5, double gap = 4}) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final ux = dx / len;
    final uy = dy / len;
    var d = 0.0;
    while (d < len) {
      final e = math.min(d + dash, len);
      canvas.drawLine(Offset(a.dx + ux * d, a.dy + uy * d), Offset(a.dx + ux * e, a.dy + uy * e), paint);
      d = e + gap;
    }
  }

  void _bottomDate(Canvas canvas, TextPainter tp, DateTime date, double x, Size size) {
    _text(canvas, tp, dateLabel(date), Offset(x, size.height - 16));
  }

  void _text(Canvas canvas, TextPainter tp, String text, Offset offset, {Color? color}) {
    tp.text = TextSpan(text: text, style: TextStyle(fontSize: 10, color: color ?? _dim));
    tp.layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(_CandlePainter oldDelegate) =>
      oldDelegate.bars != bars ||
      oldDelegate.activeIndex != activeIndex ||
      oldDelegate.pointerY != pointerY ||
      oldDelegate.macdData != macdData ||
      oldDelegate.kdjData != kdjData ||
      oldDelegate.geo.lo != geo.lo ||
      oldDelegate.geo.hi != geo.hi ||
      oldDelegate.geo.size != geo.size;
}
