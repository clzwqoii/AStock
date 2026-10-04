/// 选股工作台：表头排序 + CSV 导出的交互测试（注入假 engine / 假导出，不碰真实库与文件）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/ui/colors.dart';
import 'package:stock/ui/screening_page.dart';

/// 假选股结果：顺序故意与各种排序结果都不同，便于断言排序真的生效。
List<ScreenRow> _rows() => [
      ScreenRow(
          symbol: 'A.SH',
          name: '股票A',
          close: 10,
          change: 0.1,
          changePct: 1,
          volumeRatio: 2,
          amountWan: 500,
          ma20: 9),
      ScreenRow(
          symbol: 'B.SH',
          name: '股票B',
          close: 30,
          change: -0.5,
          changePct: -5,
          volumeRatio: 5,
          amountWan: 100,
          ma20: 28),
      ScreenRow(
          symbol: 'C.SH',
          name: '股票C',
          close: 20,
          change: 0.6,
          changePct: 3,
          volumeRatio: 1,
          amountWan: 900,
          ma20: 19),
    ];

Future<void> _pump(WidgetTester tester, {ExportCsvFn? exportCsv}) async {
  addTearDown(tester.view.resetPhysicalSize);
  await tester.binding.setSurfaceSize(const Size(1400, 900)); // 窄窗口下表头会横向滚出视口
  await tester.pumpWidget(MaterialApp(
    home: AccentScope(
      color: AccentColor.red.color,
      child: Scaffold(
        body: ScreeningPage(
          dbPath: '/tmp/stock-test/stock.db',
          screenFn: (dbPath, rules) async =>
              (total: 100, picked: _rows(), dataDate: '20260930'),
          exportCsv: exportCsv,
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.tap(find.text('收盘价站上MA20').last); // 未选规则时按钮禁用
  await tester.pump();
  await tester.tap(find.text('开始选股'));
  await tester.pumpAndSettle();
}

/// 结果行的代码列顺序（按 y 坐标排序读 symbol）。
List<String> _symbolOrder(WidgetTester tester) {
  final items = <(String, double)>[];
  for (final s in ['A.SH', 'B.SH', 'C.SH']) {
    items.add((s, tester.getTopLeft(find.widgetWithText(SizedBox, s).first).dy));
  }
  items.sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final i in items) i.$1];
}

void main() {
  testWidgets('默认按引擎顺序；点涨跌幅表头降序，再点升序', (tester) async {
    await _pump(tester);
    expect(_symbolOrder(tester), ['A.SH', 'B.SH', 'C.SH']);

    await tester.tap(find.text('涨跌幅'));
    await tester.pump();
    expect(_symbolOrder(tester), ['C.SH', 'A.SH', 'B.SH']);

    await tester.tap(find.text('涨跌幅'));
    await tester.pump();
    expect(_symbolOrder(tester), ['B.SH', 'A.SH', 'C.SH']);
  });

  testWidgets('换列默认降序（量比、收盘各自排序）', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('量比'));
    await tester.pump();
    expect(_symbolOrder(tester), ['B.SH', 'A.SH', 'C.SH']); // 5 > 2 > 1

    await tester.tap(find.text('收盘'));
    await tester.pump();
    expect(_symbolOrder(tester), ['B.SH', 'C.SH', 'A.SH']); // 30 > 20 > 10
  });

  testWidgets('排序后重新选股仍保留当前排序列', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('收盘'));
    await tester.pump();
    expect(_symbolOrder(tester), ['B.SH', 'C.SH', 'A.SH']);

    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();
    expect(_symbolOrder(tester), ['B.SH', 'C.SH', 'A.SH']);
  });

  testWidgets('导出 CSV：按当前排序写盘并提示路径', (tester) async {
    List<ScreenRow>? exported;
    String? exportedCombo;
    String? exportedDate;
    await _pump(tester, exportCsv: (rows, {dataDate, combo}) async {
      exported = rows;
      exportedCombo = combo;
      exportedDate = dataDate;
      return '/tmp/stock-test/选股结果-20261004-120000.csv';
    });

    await tester.tap(find.text('涨跌幅'));
    await tester.pump();
    await tester.tap(find.byTooltip('导出 CSV'));
    await tester.pumpAndSettle();

    expect(exported!.map((r) => r.symbol).toList(), ['C.SH', 'A.SH', 'B.SH']);
    expect(exportedDate, '20260930');
    expect(exportedCombo, '收盘价站上MA20');
    expect(find.textContaining('/tmp/stock-test/选股结果-'), findsOneWidget);
  });

  testWidgets('空结果时导出按钮不出现', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AccentScope(
        color: AccentColor.red.color,
        child: Scaffold(
          body: ScreeningPage(
            dbPath: '/tmp/stock-test/stock.db',
            screenFn: (dbPath, rules) async =>
                (total: 0, picked: <ScreenRow>[], dataDate: null),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.tap(find.text('收盘价站上MA20').last);
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('导出 CSV'), findsNothing);
  });
}
