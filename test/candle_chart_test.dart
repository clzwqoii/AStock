/// 蜡烛图十字光标：几何换算、读数格式化、指针交互（拖动/悬停）。
/// 几何与格式化是纯函数，先测它们；绘制行为只验读数是否出现。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/models.dart';
import 'package:stock/ui/candle_chart.dart';
import 'package:stock/ui/candle_chart_math.dart';

Bar _b(
  int day, {
  double open = 10,
  double high = 10,
  double low = 10,
  double close = 10,
  double volume = 1000,
}) =>
    Bar(
      date: DateTime(2026, 9, day),
      open: open,
      high: high,
      low: low,
      close: close,
      volume: volume,
    );

/// 读数容器 key，测试用它定位浮层（K线刻度标签也含 MM-DD，不能直接全局找）。
const _readoutKey = ValueKey('crosshair-readout');

void main() {
  group('ChartGeometry', () {
    test('索引：按 x 落在哪一格，越界钳到首/末根', () {
      final geo = ChartGeometry(size: const Size(300, 200), count: 4, lo: 0, hi: 100);
      expect(geo.slot, closeTo(63.5, 1e-9)); // 右侧留 46 给价格标签：(300-46)/4
      expect(geo.centerX(0), closeTo(31.75, 1e-9));
      expect(geo.indexForX(0), 0);
      expect(geo.indexForX(63.4), 0);
      expect(geo.indexForX(63.5), 1);
      expect(geo.indexForX(254), 3);
      expect(geo.indexForX(-20), 0);
      expect(geo.indexForX(9999), 3);
    });

    test('无数据返回 -1，slot 为 0 不除零', () {
      const geo = ChartGeometry(size: Size(300, 200), count: 0, lo: 0, hi: 0);
      expect(geo.indexForX(10), -1);
      expect(geo.slot, 0);
    });

    test('价格与 y 坐标可往返换算，高价在上', () {
      final geo = ChartGeometry(size: const Size(300, 200), count: 10, lo: 10, hi: 20);
      for (final p in [10.0, 13.0, 20.0]) {
        expect(geo.priceForY(geo.yForPrice(p)), closeTo(p, 1e-9));
      }
      expect(geo.yForPrice(20), lessThan(geo.yForPrice(10)));
    });

    test('成交量区在价格区下方，不越界', () {
      final geo = ChartGeometry(size: const Size(300, 200), count: 10, lo: 10, hi: 20);
      expect(geo.volRect.top, greaterThan(geo.priceRect.bottom));
      expect(geo.volRect.bottom, lessThanOrEqualTo(200));
    });

    test('MACD 面板在成交量区下方，高度非负且不与日期标签重叠', () {
      final geo = ChartGeometry(size: const Size(300, 400), count: 10, lo: 10, hi: 20);
      expect(geo.macdRect.top, greaterThanOrEqualTo(geo.volRect.bottom));
      expect(geo.macdRect.bottom, lessThanOrEqualTo(400));
      expect(geo.macdRect.height, greaterThan(0));
    });

    test('KDJ 面板在 MACD 面板下方，高度非负且不与日期标签重叠', () {
      final geo = ChartGeometry(size: const Size(300, 400), count: 10, lo: 10, hi: 20);
      expect(geo.kdjRect.top, greaterThanOrEqualTo(geo.macdRect.bottom));
      expect(geo.kdjRect.bottom, lessThanOrEqualTo(400));
      expect(geo.kdjRect.height, greaterThan(0));
    });

    test('极矮画布：各面板高度夹为非负', () {
      final geo = ChartGeometry(size: const Size(300, 120), count: 10, lo: 10, hi: 20);
      expect(geo.volRect.height, greaterThanOrEqualTo(0));
      expect(geo.macdRect.height, greaterThanOrEqualTo(0));
      expect(geo.kdjRect.height, greaterThanOrEqualTo(0));
    });
  });

  group('priceRange', () {
    test('覆盖 K 线高低与均线值，两侧各留 6% 边距', () {
      final bars = [_b(1, high: 12, low: 8), _b(2, high: 11, low: 9)];
      final r = priceRange(bars, [
        [8.5, null]
      ]);
      expect(r.lo, closeTo(7.76, 1e-9));
      expect(r.hi, closeTo(12.24, 1e-9));
    });

    test('高低相等（一字板）时撑开成非零区间，避免除零', () {
      final r = priceRange([_b(1, high: 10, low: 10)], const []);
      expect(r.lo, 9);
      expect(r.hi, 11);
    });
  });

  group('读数格式化', () {
    test('含日期、涨跌幅、量（相对前收）', () {
      final r = CandleReadout.of(
          _b(30, open: 18.2, high: 18.6, low: 18.0, close: 18.5, volume: 120000),
          previous: _b(29, close: 17.95));
      expect(r.date, '2026-09-30');
      expect(r.pct, '+3.06%');
      expect(r.rising, true);
      expect(r.volume, '12.00万手');
      expect(r.open, '18.20');
      expect(r.high, '18.60');
      expect(r.low, '18.00');
      expect(r.close, '18.50');
    });

    test('首根没有前收时涨跌幅为 --、方向未知', () {
      final r = CandleReadout.of(_b(1, open: 8, high: 9, low: 7, close: 8.5, volume: 999));
      expect(r.pct, '--');
      expect(r.rising, isNull);
      expect(r.volume, '999手');
      expect(r.date, '2026-09-01');
    });

    test('前收为 0 时不显示涨跌幅，避免除零', () {
      final r = CandleReadout.of(_b(2, close: 10), previous: _b(1, close: 0));
      expect(r.pct, '--');
      expect(r.rising, isNull);
      expect(r.close, '10.00');
    });

    test('下跌时涨跌幅带负号且方向为 false', () {
      final r = CandleReadout.of(_b(3, close: 9), previous: _b(2, close: 10));
      expect(r.pct, '-10.00%');
      expect(r.rising, false);
    });
  });

  group('十字光标交互', () {
    testWidgets('拖动指针出现读数；拖动到别处读数跟随', (tester) async {
      final bars = [for (var d = 1; d <= 30; d++) _b(d, close: 10 + d * 0.1)];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, height: 240, child: CandleChart(bars: bars))),
      ));
      await tester.pump();
      expect(find.byKey(_readoutKey), findsNothing);

      await tester.drag(find.byType(CandleChart), const Offset(60, 0));
      await tester.pump();
      final first = _readoutDate(tester);
      expect(first, isNotEmpty);

      await tester.drag(find.byType(CandleChart), const Offset(-120, 0));
      await tester.pump();
      expect(_readoutDate(tester), isNotEmpty);
      expect(_readoutDate(tester), isNot(first));
    });

    testWidgets('松开后保留最后一根（移动端不要求长按）', (tester) async {
      final bars = [for (var d = 1; d <= 20; d++) _b(d)];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, height: 200, child: CandleChart(bars: bars))),
      ));
      await tester.pump();
      await tester.drag(find.byType(CandleChart), const Offset(40, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_readoutKey), findsOneWidget);
    });

    testWidgets('读数浮层在图表内且不压右侧价格刻度', (tester) async {
      final bars = [for (var d = 1; d <= 30; d++) _b(d, close: 10 + d * 0.1)];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, height: 240, child: CandleChart(bars: bars))),
      ));
      await tester.pump();
      await tester.drag(find.byType(CandleChart), const Offset(60, 0));
      await tester.pump();

      final chart = tester.getRect(find.byType(CandleChart));
      final card = tester.getRect(find.byKey(_readoutKey));
      expect(card.left, greaterThanOrEqualTo(chart.left));
      expect(card.top, greaterThanOrEqualTo(chart.top));
      // 右侧 labelW 留给价格刻度，浮层不得越界（早期版本单行读数会把图表撑破）
      expect(card.right, lessThanOrEqualTo(chart.right - ChartGeometry.labelW));
      expect(card.bottom, lessThanOrEqualTo(chart.bottom));
    });

    testWidgets('鼠标悬停（桌面）即出现读数，移出后清除', (tester) async {
      final bars = [for (var d = 1; d <= 20; d++) _b(d, close: 10 + d * 0.2)];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(width: 320, height: 200, child: CandleChart(bars: bars))),
      ));
      await tester.pump();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(160, 100));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(find.byKey(_readoutKey), findsOneWidget);

      await gesture.moveBy(const Offset(-500, 400)); // 移出图表区域
      await tester.pump();
      expect(find.byKey(_readoutKey), findsNothing);
    });
  });
}

/// 读数里第一行（日期）的文本。
String _readoutDate(WidgetTester tester) =>
    tester.widgetList<Text>(find.descendant(of: find.byKey(_readoutKey), matching: find.byType(Text))).first.data ?? '';
