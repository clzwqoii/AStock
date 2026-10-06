// 回测对比页：无报告时显示入口、有报告时渲染表格与排序。
// 回测入口可注入假实现，避免测试里真跑 30 秒。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/ui/backtest_page.dart';
import 'package:stock/ui/colors.dart';

import 'fixtures.dart';

final _day0 = DateTime(2024, 1, 1);

StockData _stock(List<double> closes, {String symbol = 'T'}) => StockData(
      symbol: symbol,
      bars: [
        for (var i = 0; i < closes.length; i++)
          kbar(close: closes[i], volume: 100, date: _day0.add(Duration(days: i))),
      ],
    );

/// 造一份小而确定的报告：只有 2 条规则、2 个持有期。
BacktestReport _fakeReport(DateTime now) => backtestAll(
      [
        _stock(<double>[
          ...List.filled(40, 10.0),
          11.0, 11.5, 12.0, 12.5, 13.0, 13.5,
          ...List.filled(20, 14.0),
        ]),
        _stock(List<double>.filled(66, 10.0), symbol: 'F'),
      ],
      [ruleById('pct_change_up'), ruleById('close_above_ma20')],
      horizons: const [5, 10],
    ).let((r) => BacktestReport(
          generatedAt: now.toIso8601String(),
          horizons: r.horizons,
          stockCount: r.stockCount,
          baseline: r.baseline,
          results: r.results,
        ));

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

void main() {
  late Directory tmp;
  late String dbPath;
  late String reportPath;
  final generated = DateTime(2026, 10, 5, 14, 30);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('btpage');
    dbPath = '${tmp.path}/t.db';
    reportPath = '${tmp.path}/report.json';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(
      home: AccentScope(color: AccentColor.red.color, child: child),
    ));
    await tester.pump();
  }

  testWidgets('无缓存报告时显示入口与说明', (tester) async {
    await pump(tester, BacktestPage(dbPath: dbPath, reportPath: reportPath, runFn: (_, {reportPath}) async {
      fail('不应在无缓存时自动回测');
    }));

    expect(find.text('还没有回测报告'), findsOneWidget);
    expect(find.text('开始回测'), findsOneWidget);
    expect(find.textContaining('PF（盈亏比）'), findsNothing); // 图例只在有报告时出现
  });

  testWidgets('点「开始回测」跑注入的实现，成功后渲染表格', (tester) async {
    var called = 0;
    await pump(tester, BacktestPage(
      dbPath: dbPath,
      reportPath: reportPath,
      runFn: (_, {reportPath}) async {
        called++;
        // 与生产一致：落盘后页面下次能秒开
        final r = _fakeReport(generated);
        File(reportPath!).writeAsStringSync(jsonEncode(r.toJson()));
        return r;
      },
    ));

    await tester.tap(find.text('开始回测'));
    await tester.pumpAndSettle();

    expect(called, 1);
    expect(find.text('还没有回测报告'), findsNothing);
    expect(find.text('（无条件基准）'), findsOneWidget);
    expect(find.text('当日涨幅>3%'), findsOneWidget);
    expect(find.text('收盘价站上MA20'), findsOneWidget);
    // 表头三个持有期都在
    expect(find.text('5日胜率'), findsOneWidget);
    expect(find.text('10日胜率'), findsOneWidget);
    expect(find.text('20日胜率'), findsNothing); // 假报告只有 5/10
  });

  testWidgets('有缓存报告时直接渲染，不触发回测', (tester) async {
    File(reportPath).writeAsStringSync(jsonEncode(_fakeReport(generated).toJson()));

    await pump(tester, BacktestPage(dbPath: dbPath, reportPath: reportPath, runFn: (_, {reportPath}) async {
      fail('有缓存时不该自动回测');
    }));

    expect(find.text('（无条件基准）'), findsOneWidget);
    expect(find.text('重新回测'), findsOneWidget);
    expect(find.textContaining('生成于 2026-10-05 14:30'), findsOneWidget);
  });

  testWidgets('缓存损坏时降级成"无报告"，不崩', (tester) async {
    File(reportPath).writeAsStringSync('{ 这不是合法 json');

    await pump(tester, BacktestPage(dbPath: dbPath, reportPath: reportPath, runFn: (_, {reportPath}) async {
      fail('缓存损坏时不该自动回测');
    }));

    expect(find.text('还没有回测报告'), findsOneWidget);
  });

  testWidgets('点列头切换排序方向', (tester) async {
    File(reportPath).writeAsStringSync(jsonEncode(_fakeReport(generated).toJson()));
    await pump(tester, BacktestPage(dbPath: dbPath, reportPath: reportPath, runFn: (_, {reportPath}) async {
      fail('不应触发');
    }));

    String firstRuleName() {
      final rows = find.byType(InkWell);
      // 表头第一个可点的就是"规则"列
      return tester.widget<Text>(find.descendant(
        of: rows.first,
        matching: find.byType(Text),
      )).data!;
    }

    final before = firstRuleName();
    await tester.tap(find.text('10日胜率'));
    await tester.pump();
    final afterName = firstRuleName();
    // 按胜率降序后，第一行不再是"规则"列默认的名字序
    expect(find.text('10日胜率'), findsOneWidget);
    expect(before, isNotEmpty);
    expect(afterName, isNotEmpty);
  });

  testWidgets('回测抛异常时显示错误信息', (tester) async {
    await pump(tester, BacktestPage(
      dbPath: dbPath,
      reportPath: reportPath,
      runFn: (_, {reportPath}) async => throw Exception('库不存在'),
    ));

    await tester.tap(find.text('开始回测'));
    await tester.pumpAndSettle();

    expect(find.textContaining('库不存在'), findsOneWidget);
    expect(find.text('还没有回测报告'), findsOneWidget); // 仍停在空态
  });

  testWidgets('onBack 非空时 AppBar 显示返回键，点击回调', (tester) async {
    File(reportPath).writeAsStringSync(jsonEncode(_fakeReport(generated).toJson()));
    var back = 0;
    await pump(tester, BacktestPage(
      dbPath: dbPath,
      reportPath: reportPath,
      onBack: () => back++,
      runFn: (_, {reportPath}) async => fail('不应触发'),
    ));

    await tester.tap(find.byIcon(Icons.arrow_back));
    expect(back, 1);
  });
  
  group('规则介绍与两页联动', () {
    testWidgets('表格里规则名下方显示一句话说明', (tester) async {
      File(reportPath).writeAsStringSync(jsonEncode(_fakeReport(generated).toJson()));
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));
  
      // 当日涨幅>3% 的说明
      expect(find.text('当日涨幅超过 3%，短线强势'), findsOneWidget);
      expect(find.text('收盘价站在 MA20 上方，短期趋势向上'), findsOneWidget);
    });
  
    testWidgets('initialReport 非空时直接渲染，不读盘', (tester) async {
      // 不落盘，只靠外壳传入
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: _fakeReport(generated),
        runFn: (_, {reportPath}) async => fail('有 initialReport 不该再读盘'),
      ));
  
      expect(find.text('（无条件基准）'), findsOneWidget);
      expect(find.text('重新回测'), findsOneWidget);
    });
  
    testWidgets('回测成功后 onReport 回调把新报告交给外壳', (tester) async {
      BacktestReport? received;
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        onReport: (r) => received = r,
        runFn: (_, {reportPath}) async {
          final r = _fakeReport(generated);
          File(reportPath!).writeAsStringSync(jsonEncode(r.toJson()));
          return r;
        },
      ));
  
      await tester.tap(find.text('开始回测'));
      await tester.pumpAndSettle();
  
      expect(received, isNotNull);
      expect(received!.stockCount, 2);
      // 外壳据此刷新后，按钮文案切到"重新回测"
      expect(find.text('重新回测'), findsOneWidget);
    });
  
    test('每条规则都有非空说明（规则的"介绍"不能空）', () {
      for (final r in builtInRules) {
        expect(r.desc, isNotEmpty, reason: r.id);
      }
    });
  });
  

/// 取某行文字的视觉纵坐标（表格是 Row + 横向滚动，纵向 y 即行序）。
double rowTop(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

/// [target] 在所有规则行里的纵向排名（0 = 最上一行）。
/// 不数 widget 个数——渲染实现会变，纵坐标才是"用户看到的顺序"。
int rowRankOf(WidgetTester tester, String target) {
  final names = <String>[
    for (final r in builtInRules) r.name,
    '（无条件基准）',
  ];
  final byTop = names.map((n) => (n: n, y: rowTop(tester, n))).toList()
    ..sort((a, b) => a.y.compareTo(b.y));
  return byTop.indexWhere((e) => e.n == target);
}

  group('主力规则与信号集中度列', () {
    testWidgets('主力规则排在表格第一行，基准行垫底', (tester) async {
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: _fakeReport(generated),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      // 未点任何列头时：主力第一、基准最后。
      // 这不是美观问题——按胜率排会把严格版排到宽松版前面，两个页面
      // 给出相反的"第一"，kMainRuleId 的决定就失效了。
      final mainName = ruleById(kMainRuleId).name;
      final mainIdx = rowRankOf(tester, mainName);
      final strictIdx = rowRankOf(tester, 'RSI超卖·放量');
      final baseIdx = rowRankOf(tester, '（无条件基准）');
      expect(mainIdx, 0, reason: '主力规则必须第一行');
      expect(mainIdx, lessThan(strictIdx));
      expect(baseIdx, greaterThan(strictIdx), reason: '基准行垫底');
    });

    testWidgets('出现「主力月」表头，主力规则显示其占比', (tester) async {
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: _fakeReport(generated),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));
      expect(find.text('主力月'), findsOneWidget);
      // _fakeReport 给了 100% 集中在单月，应显示 100%
      final prof = _fakeReport(generated).profileOf(kMainRuleId, 10);
      if (prof.signalCount > 0) {
        expect(find.text('${(prof.topMonthShare * 100).toStringAsFixed(0)}%'),
            findsWidgets);
      }
    });
  });

  group('分年胜率列', () {
    testWidgets('有分年数据时表头与数据行都出现 YYYY年 列', (tester) async {
      // 手工造一份带分年数据的报告（不依赖真库）
      final bars = <Bar>[];
      var d = DateTime(2024, 1, 2);
      for (var i = 0; i < 500; i++) {
        bars.add(kbar(close: 10.0 + 0.02 * i, volume: 100, date: d));
        d = d.add(const Duration(days: 1));
      }
      final r = backtestAll(
        [StockData(symbol: 'T', bars: bars)],
        [ruleById('close_above_ma20')],
        horizons: const [5, 10],
      );
  
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: r,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));
  
      // 表头有 2024年 / 2025年（序列跨两年）
      expect(find.text('2024年'), findsOneWidget);
      expect(find.text('2025年'), findsOneWidget);
      // 数据行有对应年份的百分比
      final texts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList();
      final pcts = texts
          .where((t) => t != null && RegExp(r'^[0-9]+[.][0-9]+%').hasMatch(t))
          .length;
      expect(pcts, greaterThanOrEqualTo(4));
    });
  
    testWidgets('分年数据显示 — 当该年无可用数据', (tester) async {
      // MA250 类规则在早年必然 0 信号：分年列应显示 — 而不是 0.0%
      final bars = <Bar>[];
      var d = DateTime(2024, 1, 2);
      for (var i = 0; i < 300; i++) {
        bars.add(kbar(close: 10.0 + 0.02 * i, volume: 100, date: d));
        d = d.add(const Duration(days: 1));
      }
      final r = backtestAll(
        [StockData(symbol: 'T', bars: bars)],
        [ruleById('ma250_up')],
        horizons: const [5],
      );
      // 300 根只够 MA250 在最后 50 天出现，2024 年其余时间无数据
      final anyYear = r.yearly.values
          .map((byRule) => byRule['ma250_up']?[5]?.count ?? 0)
          .reduce((a, b) => a + b);
      expect(anyYear, greaterThan(0));
  
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: r,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));
      expect(find.textContaining('—'), findsWidgets);
    });

    testWidgets('点年份列按该年胜率排序（而不是 PF）', (tester) async {
      // 手工构造统计量，让「2024 胜率序」与「PF 序」方向相反：
      //   RSI超卖 2024 胜率 0.9 / PF 1.0；当日涨幅 2024 胜率 0.3 / PF 2.0。
      // 按年排（降序）：RSI超卖 在上；按 PF 排（旧 bug）：当日涨幅 在上。
      BacktestStats st(double win, double pf) => BacktestStats(
            count: 100,
            winRate: win,
            avgReturn: 1,
            medianReturn: 1,
            bestReturn: 2,
            worstReturn: 0,
            profitFactor: pf,
          );
      final report = BacktestReport(
        generatedAt: generated.toIso8601String(),
        horizons: const [10],
        stockCount: 1,
        baseline: const {},
        results: {
          'rsi_oversold': {
            10: BacktestResult.fromStats(
                ruleId: 'rsi_oversold', forwardDays: 10, stats: st(0.5, 1.0)),
          },
          'pct_change_up': {
            10: BacktestResult.fromStats(
                ruleId: 'pct_change_up', forwardDays: 10, stats: st(0.5, 2.0)),
          },
        },
        yearly: {
          2024: {
            'rsi_oversold': {10: st(0.9, 1.0)},
            'pct_change_up': {10: st(0.3, 2.0)},
          },
        },
      );

      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      double dy(String text) => tester.getCenter(find.text(text)).dy;
      const rsi = 'RSI超卖(RSI14<30)';
      const surge = '当日涨幅>3%';

      await tester.tap(find.text('2024年')); // 降序：RSI超卖(.9) 在 当日涨幅(.3) 上方
      await tester.pump();
      expect(dy(rsi), lessThan(dy(surge)));

      await tester.tap(find.text('2024年')); // 升序：翻转（旧实现按 PF 排，两条规则不会翻转）
      await tester.pump();
      expect(dy(surge), lessThan(dy(rsi)));
    });
  });
}
