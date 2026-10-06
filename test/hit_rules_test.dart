/// 引擎命中链路：screenWithHits/CSV 行数据仍带 matchedRules（未来 OR 模式复用）；
/// UI 的「命中规则」列已在 AND 组合语义下移除（每行命中 = 勾选全集，纯复读）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/ui/colors.dart';
import 'package:stock/ui/screening_page.dart';

import 'fixtures.dart';

void main() {
  late String dbPath;

  setUp(() {
    dbPath = '/tmp/stock-hit-${DateTime.now().microsecondsSinceEpoch}.db';
    seedStocks(dbPath);
  });

  tearDown(() {
    try {
      BarRepository(dbPath).close();
    } catch (_) {}
    File(dbPath).deleteSync();
  });

  testWidgets('组合选股导出 CSV：行数据仍带引擎回填的 matchedRules', (tester) async {
    List<ScreenRow>? exported;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.binding.setSurfaceSize(const Size(1400, 900)); // 默认 800x600 会把后几条规则挤到滚动区外
    await tester.pumpWidget(MaterialApp(
      home: AccentScope(
        color: AccentColor.red.color,
        child: Scaffold(
          body: ScreeningPage(
            dbPath: dbPath,
            screenFn: (_, rules) async => (
              total: 2,
              dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0, blockedSuspension: 0,
              picked: [
                ScreenRow(
                  symbol: 'S1.SH',
                  name: '测试一',
                  close: 10.5,
                  change: 0.5,
                  changePct: 5.0,
                  volumeRatio: 3.0,
                  amountWan: 0.1,
                  ma20: 10.025,
                  matchedRules: [for (final r in rules) r.name],
                ),
                const ScreenRow(
                  symbol: 'S2.SZ',
                  name: '测试二',
                  close: 10.5,
                  change: 0.5,
                  changePct: 5.0,
                  volumeRatio: 1.0,
                  amountWan: 0.1,
                  ma20: 10.025,
                  matchedRules: ['收盘价站上MA20'],
                ),
              ],
            ),
            exportCsv: (rows, {dataDate, combo}) async {
              exported = rows;
              return '/tmp/x.csv';
            },
          ),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('收盘价站上MA20').last);
    await tester.pump();
    // 新增的规则落到滚动区外，需滚动到可见再点。
    await tester.scrollUntilVisible(
      find.text('当日涨幅>3%').last,
      60,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('当日涨幅>3%').last);
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();

    // UI 不再展示命中规则（AND 语义下纯复读），但导出的行数据仍带引擎回填
    expect(find.text('收盘价站上MA20＋当日涨幅>3%'), findsNothing);

    await tester.tap(find.byTooltip('导出 CSV'));
    await tester.pumpAndSettle();
    expect(exported!.first.matchedRules, ['收盘价站上MA20', '当日涨幅>3%']);
    expect(exported!.last.matchedRules, ['收盘价站上MA20']);
  });

  testWidgets('宽屏侧栏填满窗口高度，底部设置块不被规则列表挤出', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(MaterialApp(
      home: AccentScope(
        color: AccentColor.red.color,
        child: const Scaffold(body: ScreeningPage(dbPath: '/tmp/x.db')),
      ),
    ));
    await tester.pump();
    expect(tester.getRect(find.byType(Container).first).height, 900);
    expect(tester.getRect(find.textContaining('数据源')).bottom, lessThanOrEqualTo(900));
    for (final name in ['收盘价站上MA20', 'MA5上穿MA10', 'MACD金叉', '量比>2', '当日涨幅>3%']) {
      expect(find.text(name), findsOneWidget, reason: '$name 应在可视区内，无需滚动');
    }
  });

  test('runScreening 用真实库回填命中规则（S1 同时命中量比与涨幅）', () async {
    final r = await runScreening(dbPath, [ruleById('volume_surge'), ruleById('pct_change_up')]);
    final s1 = r.picked.firstWhere((row) => row.symbol == 'S1.SH');
    expect(s1.matchedRules, ['量比>2', '当日涨幅>3%']);

    final single = await runScreening(dbPath, [ruleById('pct_change_up')]);
    expect(single.picked.every((row) => row.matchedRules.length == 1), isTrue);
  });
}
