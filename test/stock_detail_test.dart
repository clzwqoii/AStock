/// 个股详情页：均线图例（loadFn 注入假实现，widget 测试不碰真实库与 IO）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/ui/stock_detail_page.dart';

Bar _b(int day, double close) => Bar(
      date: DateTime(2026, 9, day),
      open: close,
      high: close,
      low: close,
      close: close,
      volume: 1000,
    );

Future<StockDetail?> _fakeLoad(String dbPath, String symbol) async {
  final bars = [for (var d = 1; d <= 30; d++) _b(d, 10 + d * 0.1)];
  return StockDetail(
    symbol: symbol,
    name: '测试股',
    bars: bars,
    snapshot: IndicatorSnapshot.fromStock(StockData(symbol: symbol, bars: bars)),
  );
}

void main() {
  testWidgets('图例展示 5 条均线：MA5/10/20/30/60', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: StockDetailPage(dbPath: '/tmp/x.db', symbol: 'T.SH', loadFn: _fakeLoad),
    ));
    await tester.pumpAndSettle();

    expect(find.text('MA5'), findsOneWidget);
    expect(find.text('MA10'), findsOneWidget);
    // MA20 在信息条与图例各出现一次
    expect(find.text('MA20'), findsNWidgets(2));
    expect(find.text('MA30'), findsOneWidget);
    expect(find.text('MA60'), findsOneWidget);
  });
}
