/// 结果表对齐与列宽：表头与数值列对齐、名称列弹性（成交额定宽，右对齐数字列
/// 拉宽会留大片空白）、命中规则列已移除
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
      signalDate: '2026-09-30',
      ret20: -18.19,
      matchedRules: ['测试规则甲'], // 引擎数据仍在，UI 不再展示
    );

Future<void> _pump(WidgetTester tester, {Size size = const Size(1400, 900)}) async {
  addTearDown(tester.view.resetPhysicalSize);
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ScreeningPage(
        dbPath: '/tmp/stock-test/stock.db',
        screenFn: (dbPath, rules) async => (
          total: 1,
          picked: [_row()],
          dataDate: '20260930',
          blockedStale: 0,
          blockedCorporateAction: 0, blockedSuspension: 0,
        ),
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
      '20日%': '-18.19%',
      '量比': '1.23',
      'MA20': '111.00',
    };
    pairs.forEach((header, value) {
      final h = tester.getRect(find.text(header)).right;
      final v = tester.getRect(find.text(value)).right;
      expect(h - v, closeTo(0, 2), reason: '$header 表头与值未对齐');
    });
  });

  testWidgets('宽布局：名称列定宽紧凑，评分/目标/止损/盈亏比紧跟名称', (tester) async {
    await _pump(tester);

    final nameHeader = tester.getRect(find.text('名称'));
    final nameValue = tester.getRect(find.text('名称很长很长的股票'));
    expect(nameHeader.left, closeTo(nameValue.left, 1)); // 表头与值左对齐
    // 名称定宽（约 6 个汉字），不再弹性吃掉宽窗口的剩余宽度
    expect(nameValue.width, lessThanOrEqualTo(80));
    // 表头从左到右：名称 → 评分 → 目标 → 止损 → 盈亏比 → 收盘
    final order = ['名称', '评分', '目标', '止损', '盈亏比', '收盘']
        .map((t) => tester.getRect(find.text(t)).left)
        .toList();
    expect(order, equals(List<double>.from(order)..sort()), reason: '重点字段未紧跟名称列');
    // 成交额定宽 84：右对齐数字列被拉宽会留大片空白
    expect(tester.getRect(find.text('45678')).width, lessThanOrEqualTo(84));
  });

  testWidgets('宽布局：20日% 列渲染且带正负号（让"抄了多深的底"可读）', (tester) async {
    await _pump(tester);
    expect(find.text('20日%'), findsOneWidget);
    expect(find.text('-18.19%'), findsOneWidget);
  });

  testWidgets('护栏挡掉假信号时状态栏显示计数', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScreeningPage(
          dbPath: '/tmp/stock-test/stock.db',
          screenFn: (dbPath, rules) async => (
            total: 1,
            picked: [_row()],
            dataDate: '20260930',
            blockedStale: 2,
            blockedCorporateAction: 1,
            blockedSuspension: 0,
          ),
        ),
      ),
    ));
    await tester.tap(find.text('收盘价站上MA20').last);
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();

    // _sbItem 用 Text.rich 拼 label+value，label 后面跟一个空格，
    // 所以按子串找而不是整串。
    expect(find.textContaining('过滤假信号'), findsOneWidget);
    // label 与计数在同一个 Text.rich 的两个 span 里，取整段明文一起断言
    final items = tester.widgetList<Text>(find.byWidgetPredicate((w) =>
        w is Text && (w.textSpan?.toPlainText().contains('过滤假信号') ?? false)));
    expect(items, isNotEmpty, reason: '状态栏没有渲染护栏计数');
    expect(items.single.textSpan!.toPlainText(), contains('3'),
        reason: '状态栏没有显示被挡掉的假信号数量');
  });

  testWidgets('窄布局：无「命中规则」列，名称列弹性吃剩余宽度', (tester) async {
    await _pump(tester, size: const Size(600, 900));

    expect(find.text('命中规则'), findsNothing);
    final nameWidth = tester.getRect(find.text('名称很长很长的股票')).width;
    expect(nameWidth, greaterThan(96)); // 弹性列（手机上名称宽一些可接受）
  });
}
