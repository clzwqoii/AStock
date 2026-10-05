/// 结果表对齐与列宽：表头与数值列对齐、名称列定宽、命中规则列吃剩余宽度。
/// 几何断言直接量 RenderBox 坐标，回归的是 2026-10-05 真机反馈的错位问题。
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
      matchedRules: ['测试规则甲'],
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
  testWidgets('宽布局：表头含「命中规则」，数值列表头与值右缘对齐', (tester) async {
    await _pump(tester);

    expect(find.text('命中规则'), findsOneWidget);
    // 宽布局表头行此前漏了命中规则一格， Expanded 的名称列把差额吃掉，
    // 导致收盘往右所有表头整体右移一列宽（132px）。
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

  testWidgets('宽布局：名称列定宽，不再 Expanded 吃满剩余空间', (tester) async {
    await _pump(tester);

    final nameHeader = tester.getRect(find.text('名称'));
    final nameValue = tester.getRect(find.text('名称很长很长的股票'));
    expect(nameHeader.left, closeTo(nameValue.left, 1)); // 表头与值左对齐
    expect(nameValue.width, lessThanOrEqualTo(96)); // 定宽（Expanded 时约 700+）
  });

  testWidgets('窄布局：命中规则表头与值左对齐，名称列同样定宽', (tester) async {
    await _pump(tester, size: const Size(600, 900));

    expect(find.text('命中规则'), findsOneWidget);
    final hitHeader = tester.getRect(find.text('命中规则')).left;
    final hitValue = tester.getRect(find.text('测试规则甲')).left;
    expect(hitHeader, closeTo(hitValue, 1));
    expect(tester.getRect(find.text('名称很长很长的股票')).width, lessThanOrEqualTo(96));
  });
}
