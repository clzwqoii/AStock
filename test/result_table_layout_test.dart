/// 结果表对齐与列宽：表头与数值列对齐、名称列定宽（宽屏）、命中规则列已移除
/// （AND 组合下每行命中 = 勾选全集，纯复读；引擎 matchedRules 字段保留给未来 OR 模式）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/ui/screening_page.dart';

/// 数值全部取互不相同的小数，避免 find.text 撞到别列。
ScreenRow _row() => ScreenRow(
      symbol: '600000.SH',
      name: '名称很长很长的股票',
      close: 123.45,
      change: 0.45,
      changePct: 4.56,
      volumeRatio: 1.23,
      amountWan: 45678,
      ma20: 111.0,
      matchedRules: ['测试规则甲'], // 引擎数据仍在，UI 不再展示
    );

Future<void> _pump(WidgetTester tester, {Size size = const Size(1400, 900)}) async {
  addTearDown(tester.view.resetPhysicalSize);
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ScreeningPage(
        dbPath: '/tmp/stock-test/stock.db',
        screenFn: (dbPath, rules) async => (total: 1, picked: [_row()], dataDate: '20260930'),
      ),
    ),
  ));
  await tester.tap(find.text('收盘价站上MA20').last); // 未选规则时按钮禁用
  await tester.pump();
  await tester.tap(find.text('开始选股'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('宽布局：无「命中规则」列，数值列表头与值右缘对齐', (tester) async {
    await _pump(tester);

    expect(find.text('命中规则'), findsNothing); // AND 组合下纯复读，已移除
    const pairs = {
      '收盘': '123.45',
      '涨跌': '+0.45',
      '涨跌幅': '+4.56%',
      '量比': '1.23',
      'MA20': '111.00',
    };
    pairs.forEach((header, value) {
      final h = tester.getRect(find.text(header)).right;
      final v = tester.getRect(find.text(value)).right;
      expect(h - v, closeTo(0, 2), reason: '$header 表头与值未对齐');
    });
  });

  testWidgets('宽布局：名称列定宽，成交额列吃剩余宽度', (tester) async {
    await _pump(tester);

    final nameHeader = tester.getRect(find.text('名称'));
    final nameValue = tester.getRect(find.text('名称很长很长的股票'));
    expect(nameHeader.left, closeTo(nameValue.left, 1)); // 表头与值左对齐
    expect(nameValue.width, lessThanOrEqualTo(96)); // 定宽
    // 成交额成为唯一弹性列：数值单元格满宽（表头文本是收缩盒量不了列宽）
    expect(tester.getRect(find.text('45678')).width, greaterThan(120));
  });

  testWidgets('窄布局：无「命中规则」列，名称列弹性吃剩余宽度', (tester) async {
    await _pump(tester, size: const Size(600, 900));

    expect(find.text('命中规则'), findsNothing);
    final nameWidth = tester.getRect(find.text('名称很长很长的股票')).width;
    expect(nameWidth, greaterThan(96)); // 弹性列（手机上名称宽一些可接受）
  });
}
