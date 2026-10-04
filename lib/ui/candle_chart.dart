/// 日K蜡烛图（CustomPainter 自绘）：蜡烛 + 成交量 + MA5/10/20 均线，无第三方图表依赖。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/indicators.dart';
import '../core/models.dart';
import 'colors.dart';

class CandleChart extends StatelessWidget {
  const CandleChart({super.key, required this.bars, this.maxBars = 120});

  final List<Bar> bars;
  final int maxBars;

  @override
  Widget build(BuildContext context) {
    final visible =
        bars.length > maxBars ? bars.sublist(bars.length - maxBars) : bars;
    return CustomPaint(painter: _CandlePainter(visible), child: const SizedBox.expand());
  }
}

class _CandlePainter extends CustomPainter {
  _CandlePainter(this.bars);

  final List<Bar> bars;

  static const _up = AppColors.red;
  static const _down = AppColors.down;
  static const _maColors = [Color(0xFFF59E0B), Color(0xFF3B82F6), Color(0xFF8B5CF6)];
  static const _dim = AppColors.dim;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    final closes = [for (final b in bars) b.close];
    final maSets = [smaSeries(closes, 5), smaSeries(closes, 10), smaSeries(closes, 20)];

    final labelW = 46.0;
    final priceRect = Rect.fromLTWH(0, 10, size.width - labelW, size.height * 0.62);
    final volTop = priceRect.bottom + 18;
    final volRect = Rect.fromLTWH(0, volTop, size.width - labelW, size.height - volTop - 22);

    var lo = bars.first.low;
    var hi = bars.first.high;
    for (final b in bars) {
      lo = math.min(lo, b.low);
      hi = math.max(hi, b.high);
    }
    for (final set in maSets) {
      for (final v in set) {
        if (v != null) {
          lo = math.min(lo, v);
          hi = math.max(hi, v);
        }
      }
    }
    final pad = (hi - lo) * 0.06;
    lo -= pad;
    hi += pad;

    double yPos(double p) =>
        priceRect.bottom - (p - lo) / (hi - lo) * priceRect.height;

    // 网格与右侧价格标签
    final grid = Paint()..color = const Color(0xFFEEF0F4)..strokeWidth = 1;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i <= 2; i++) {
      final p = lo + (hi - lo) * i / 2;
      final y = yPos(p);
      canvas.drawLine(Offset(0, y), Offset(priceRect.right, y), grid);
      _text(canvas, tp, p.toStringAsFixed(2), Offset(priceRect.right + 4, y - 6));
    }

    final slot = priceRect.width / bars.length;
    final bodyW = (slot * 0.62).clamp(1.5, 18.0);
    var maxVol = 0.0;
    for (final b in bars) {
      maxVol = math.max(maxVol, b.volume);
    }
    double xPos(int i) => slot * i + slot / 2;

    // 成交量柱
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final h = maxVol == 0 ? 0.0 : b.volume / maxVol * volRect.height;
      final color = (b.close >= b.open ? _up : _down).withValues(alpha: 0.55);
      canvas.drawRect(
          Rect.fromLTWH(xPos(i) - bodyW / 2, volRect.bottom - h, bodyW, h), Paint()..color = color);
    }

    // 蜡烛：涨收红、跌收绿（A股惯例，按开收判断阴阳）
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final paint = Paint()..color = b.close >= b.open ? _up : _down;
      final cx = xPos(i);
      canvas.drawLine(
          Offset(cx, yPos(b.high)), Offset(cx, yPos(b.low)), paint..strokeWidth = 1.4);
      final top = yPos(math.max(b.open, b.close));
      final bh = math.max(1.5, (yPos(math.min(b.open, b.close)) - top).abs());
      canvas.drawRect(Rect.fromLTWH(cx - bodyW / 2, top, bodyW, bh), paint);
    }

    // MA 均线
    for (var m = 0; m < maSets.length; m++) {
      final path = Path();
      var started = false;
      final series = maSets[m];
      for (var i = 0; i < series.length; i++) {
        final v = series[i];
        if (v == null) continue;
        final pt = Offset(xPos(i), yPos(v));
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

    // 底部日期标签
    if (bars.length > 1) {
      _bottomDate(canvas, tp, bars.first.date, 2, size);
      _bottomDate(canvas, tp, bars[bars.length ~/ 2].date, size.width / 2 - 20, size);
      _bottomDate(canvas, tp, bars.last.date, size.width - 60, size);
    }
  }

  void _bottomDate(Canvas canvas, TextPainter tp, DateTime date, double x, Size size) {
    _text(canvas, tp, '${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
        Offset(x, size.height - 16));
  }

  void _text(Canvas canvas, TextPainter tp, String text, Offset offset) {
    tp.text = TextSpan(text: text, style: const TextStyle(fontSize: 10, color: _dim));
    tp.layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(_CandlePainter oldDelegate) => oldDelegate.bars != bars;
}
