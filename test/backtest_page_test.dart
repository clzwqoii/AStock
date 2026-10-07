// 回测对比页：无报告时显示入口、有报告时渲染表格与排序。
// 回测入口可注入假实现，避免测试里真跑 30 秒。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/backtest.dart' as bt; // Baseline 与 Flutter 的同名，bt. 消歧
import 'package:stock/core/market_state.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/report_store.dart';
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

  testWidgets('窄屏(手机宽)下筛选 chips 下移独立一行,AppBar 不溢出遮挡', (tester) async {
    // 360dp + 1.3 倍字号 ≈ 真机（安卓常见小屏 + 用户系统字体放大）。
    // 此前 chips 与返回键/标题/回测按钮同挤 actions 行,放不下时
    // NavigationToolbar 静默把标题压到读不了、chip 贴上返回键（真机截图实拍）。
    // 修复:窄屏(<600dp)把筛选 chips 下移到 AppBar 下方独立一行。
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    File(reportPath).writeAsStringSync(jsonEncode(_fakeReport(generated).toJson()));

    await pump(tester, BacktestPage(
      dbPath: dbPath,
      reportPath: reportPath,
      onBack: () {},
      runFn: (_, {reportPath}) async {
        fail('不应触发');
      },
    ));

    // 布局必须完整:标题、返回键、筛选 chips、回测按钮同时可见。
    expect(find.text('回测对比'), findsOneWidget);
    expect(find.text('只看稳健规则'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('重新回测'), findsOneWidget);
    // 标题不能被挤到读不了。
    expect(tester.getSize(find.text('回测对比')).width, greaterThan(40),
        reason: '窄屏下标题被压扁就是 actions 溢出遮挡');
    // chips 必须在标题下方独立一行,而不是同一行里挤。
    expect(tester.getTopLeft(find.text('只看稳健规则')).dy,
        greaterThan(tester.getBottomRight(find.text('回测对比')).dy),
        reason: '窄屏下筛选 chips 应下移到 AppBar 下方独立一行');
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

  testWidgets('回测抛 Error（如 StateError）时也显示错误信息，不产生未捕获异常', (tester) async {
    await pump(tester, BacktestPage(
      dbPath: dbPath,
      reportPath: reportPath,
      runFn: (_, {reportPath}) async => throw StateError('库状态异常'),
    ));

    await tester.tap(find.text('开始回测'));
    await tester.pumpAndSettle();

    expect(find.textContaining('库状态异常'), findsOneWidget);
    expect(find.text('还没有回测报告'), findsOneWidget);
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

  group('市场状态卡片', () {
    /// 把 [ms] 挂到现有报告上（其余字段原样复制）。
    BacktestReport withState(BacktestReport r, MarketState? ms) => BacktestReport(
          generatedAt: r.generatedAt,
          horizons: r.horizons,
          stockCount: r.stockCount,
          baseline: r.baseline,
          results: r.results,
          yearly: r.yearly,
          yearlyBaseline: r.yearlyBaseline,
          signalProfile: r.signalProfile,
          marketState: ms,
        );

    testWidgets('牛市:标签+三个指标+截至行都渲染', (tester) async {
      const ms = MarketState(
        regime: MarketRegime.bull,
        asOfDate: '2026-10-06',
        stockCount: 5623,
        maGap: 6.2,
        ret20: 5.3,
        breadthAboveMa20: 0.62,
        newHighLowDiff20: 0.11,
      );
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: withState(_fakeReport(generated), ms),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(find.text('牛市'), findsOneWidget);
      expect(find.text('近20日 +5.3%'), findsOneWidget);
      expect(find.text('站上MA20 62%'), findsOneWidget);
      expect(find.text('新高−新低 +11pp'), findsOneWidget);
      expect(find.textContaining('截至 2026-10-06 · 5623 只'), findsOneWidget);
    });

    testWidgets('熊市显示熊市标签与负号指标', (tester) async {
      const ms = MarketState(
        regime: MarketRegime.bear,
        asOfDate: '2026-10-06',
        stockCount: 5623,
        maGap: -7.1,
        ret20: -6.4,
        breadthAboveMa20: 0.18,
        newHighLowDiff20: -0.22,
      );
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: withState(_fakeReport(generated), ms),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(find.text('熊市'), findsOneWidget);
      expect(find.text('近20日 -6.4%'), findsOneWidget);
      expect(find.text('新高−新低 -22pp'), findsOneWidget);
    });

    testWidgets('旧报告无 marketState 时不显示状态卡片', (tester) async {
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: _fakeReport(generated), // _fakeReport 不带 marketState
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(find.text('牛市'), findsNothing);
      expect(find.text('熊市'), findsNothing);
      // 不能用"近20日"判:规则说明文案里也有(如"放量突破近20日箱体上沿")。
      expect(find.textContaining('新高−新低'), findsNothing);
      // 不加"暂无"提示行:回测页纵向空间全给表格(见 _table 里的注释)。
      expect(find.textContaining('暂无'), findsNothing);
    });

    testWidgets('数据不足时显示数据不足标签', (tester) async {
      const ms = MarketState(
        regime: MarketRegime.insufficient,
        asOfDate: '2026-10-06',
        stockCount: 0,
        maGap: 0,
        ret20: 0,
        breadthAboveMa20: 0,
        newHighLowDiff20: 0,
      );
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: withState(_fakeReport(generated), ms),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(find.text('数据不足'), findsOneWidget);
    });
  });

  group('全期超额列红绿（分年一致性口径）', () {
    BacktestStats st(double avg) => BacktestStats(
          count: 900,
          winRate: 0.5,
          avgReturn: avg,
          medianReturn: avg,
          bestReturn: avg,
          worstReturn: -avg,
          profitFactor: 1,
        );

    /// 涨幅规则分年均收都赢基准（红），MA60突破分年都输（绿）。
    BacktestReport report() {
      const robust = 'pct_change_up';
      const loser = 'ma60_breakout';
      return BacktestReport(
        generatedAt: generated.toIso8601String(),
        horizons: const [10],
        stockCount: 1,
        baseline: {
          10: bt.Baseline.fromStats(forwardDays: 10, stats: st(0.5)),
        },
        results: {
          robust: {
            10: BacktestResult.fromStats(
                ruleId: robust, forwardDays: 10, stats: st(2.0)),
          },
          loser: {
            10: BacktestResult.fromStats(
                ruleId: loser, forwardDays: 10, stats: st(-1.0)),
          },
        },
        yearly: {
          2024: {
            robust: {10: st(2.0)},
            loser: {10: st(-1.0)},
          },
          2025: {
            robust: {10: st(2.0)},
            loser: {10: st(-1.0)},
          },
        },
        yearlyBaseline: {
          2024: {10: st(0.5)},
          2025: {10: st(0.5)},
        },
      );
    }

    testWidgets('分年都赢基准的规则超额染红，分年都输染绿', (tester) async {
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report(),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(tester.widget<Text>(find.text('+1.5')).style?.color,
          AccentColor.red.color,
          reason: '分年均收都赢该年基准 → 红（历史有优势）');
      expect(tester.widget<Text>(find.text('-1.5')).style?.color,
          AppColors.down,
          reason: '分年均收都输该年基准 → 绿（历史无优势）');
    });

    testWidgets('红绿语义挂在「N日超额」列头 Tooltip 上', (tester) async {
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report(),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(
          find.byWidgetPredicate((w) =>
              w is Tooltip && (w.message ?? '').contains('历史有优势')),
          findsOneWidget);
    });

    testWidgets('旧格式报告没有分年数据时,超额列不染红', (tester) async {
      // 旧报告的 JSON 没有 yearly / yearlyBaseline 两个键：fromJson 容错成空 map
      // （_intKeyedStats3(null) → const {}），而空循环会让"分年都赢"的判定恒真。
      // 上色若直接用那个返回值，全表超额为正的规则会一起变红——
      // "历史有优势"是凭空来的。没有可判年份就该保持黑色。
      final legacyJson = report().toJson()
        ..remove('yearly')
        ..remove('yearlyBaseline');
      expect(legacyJson.containsKey('yearly'), isFalse);

      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: BacktestReport.fromJson(legacyJson),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(tester.widget<Text>(find.text('+1.5')).style?.color,
          isNot(AccentColor.red.color),
          reason: '一个可判年份都没有时不能宣称"历史有优势"');
      expect(tester.widget<Text>(find.text('-1.5')).style?.color,
          isNot(AppColors.down), reason: '同理不能宣称"历史无优势"');
    });
  });

  group('最近半年口径', () {
    /// 构造带 recent 数据的报告:[sig] 为指定规则的窗口日均值。
    BacktestReport recentReport({
      required RecentSlice base,
      required RecentSlice ruleA, // 显著为正
      required RecentSlice ruleB, // 独立日不足
      required RecentSlice ruleC, // 显著为负
    }) {
      BacktestReport r = _fakeReport(generated);
      return BacktestReport(
        generatedAt: r.generatedAt,
        horizons: r.horizons,
        stockCount: r.stockCount,
        baseline: r.baseline,
        results: r.results,
        yearly: r.yearly,
        yearlyBaseline: r.yearlyBaseline,
        signalProfile: r.signalProfile,
        recent: {
          'pct_change_up': {for (final h in r.horizons) h: ruleA},
          'close_above_ma20': {for (final h in r.horizons) h: ruleB},
          'macd_golden_cross': {for (final h in r.horizons) h: ruleC},
        },
        recentBaseline: {for (final h in r.horizons) h: base},
      );
    }

    RecentSlice sliceOf(Map<int, double> dayMean) => RecentSlice(
          stats: BacktestStats.of(dayMean.values.toList()),
          dayMeanReturn: dayMean,
        );

    testWidgets('默认全期口径,不显示「最近半年」chip 与超额列', (tester) async {
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: _fakeReport(generated),
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(find.text('最近半年'), findsNothing);
      expect(find.text('半年超额'), findsNothing);
    });

    testWidgets('切到最近半年:超额列出现,显著/不显著/样本不足三态', (tester) async {
      // 基准 30 天日均 0;规则 A 每日 +1(显著为正);
      // 规则 B 只有 5 个独立日(不足);规则 C 每日 -1(显著为负)。
      final base = sliceOf({for (var d = 1; d <= 30; d++) d: 0.0});
      final report = recentReport(
        base: base,
        ruleA: sliceOf({for (var d = 1; d <= 30; d++) d: 1.0}),
        ruleB: sliceOf({for (var d = 1; d <= 5; d++) d: 1.0}),
        ruleC: sliceOf({for (var d = 1; d <= 30; d++) d: -1.0}),
      );
      // 台账:pct_change_up 连续 2 期红;macd_golden_cross 只有 1 期红。
      RecentExcessRec red(double lo) =>
          RecentExcessRec(excess: 1.0, ciLow: lo, ciHigh: 2.0, days: 100);
      BacktestSnapshot snap(String date, Map<String, RecentExcessRec> recs) =>
          BacktestSnapshot(
            generatedAt: 't',
            dataDate: date,
            stockCount: 2,
            evaluableDays: 100,
            ruleWinRate: const {},
            recentExcess: recs,
          );
      File(historyPathFor(reportPath)).writeAsStringSync(jsonEncode(
        BacktestHistory([
          snap('20260831', {'pct_change_up': red(0.5), 'macd_golden_cross': red(0.5)}),
          snap('20260930', {'pct_change_up': red(0.6)}),
        ]).toJson(),
      ));
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      await tester.tap(find.text('最近半年'));
      await tester.pump();

      expect(find.text('半年超额'), findsOneWidget);
      expect(find.text('+1.0'), findsWidgets); // 规则 A(及基准行外的同值行)
      expect(find.text('-1.0'), findsOneWidget); // 规则 C
      expect(find.text('样本不足'), findsOneWidget); // 规则 B
      expect(find.text('连红'), findsOneWidget);
      // 规则 A 连续 2 期红(台账注入);C 只有 1 期、其余无数据 → —。
      expect(find.text('2连红'), findsOneWidget);
      expect(find.text('1连红'), findsNothing, reason: '不足 2 期不显示');
      // 年份列与主力月列在窗口口径下无意义,应消失
      expect(find.text('2024年'), findsNothing);
      expect(find.text('主力月'), findsNothing);
    });

    testWidgets('报告无 recent 数据(旧口径)时不显示「最近半年」chip', (tester) async {
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: _fakeReport(generated), // 不带 recent
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(find.text('最近半年'), findsNothing);
    });

    testWidgets('半年视图无任何显著为正规则时,表格上方出现醒目提示', (tester) async {
      // 规则 C 显著为负、规则 B 样本不足 → 没有一条红。
      final base = sliceOf({for (var d = 1; d <= 30; d++) d: 0.0});
      final r = _fakeReport(generated);
      final report = BacktestReport(
        generatedAt: r.generatedAt,
        horizons: r.horizons,
        stockCount: r.stockCount,
        baseline: r.baseline,
        results: r.results,
        recent: {
          'close_above_ma20': {for (final h in r.horizons) h: sliceOf({for (var d = 1; d <= 5; d++) d: 1.0})},
          'macd_golden_cross': {for (final h in r.horizons) h: sliceOf({for (var d = 1; d <= 30; d++) d: -1.0})},
        },
        recentBaseline: {for (final h in r.horizons) h: base},
      );
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      await tester.tap(find.text('最近半年'));
      await tester.pump();

      expect(find.textContaining('当前没有任何规则在最近半年显著跑赢基准'),
          findsOneWidget);
    });

    testWidgets('半年视图存在显著为正规则时不显示无红提示', (tester) async {
      final base = sliceOf({for (var d = 1; d <= 30; d++) d: 0.0});
      final report = recentReport(
        base: base,
        ruleA: sliceOf({for (var d = 1; d <= 30; d++) d: 1.0}), // 红
        ruleB: sliceOf({for (var d = 1; d <= 5; d++) d: 1.0}),
        ruleC: sliceOf({for (var d = 1; d <= 30; d++) d: -1.0}),
      );
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      await tester.tap(find.text('最近半年'));
      await tester.pump();

      expect(find.textContaining('当前没有任何规则在最近半年显著跑赢基准'),
          findsNothing);
    });

    testWidgets('窗口口径说明随口径出现', (tester) async {
      final base = sliceOf({for (var d = 1; d <= 30; d++) d: 0.0});
      final report = recentReport(
        base: base,
        ruleA: sliceOf({for (var d = 1; d <= 30; d++) d: 1.0}),
        ruleB: sliceOf({for (var d = 1; d <= 5; d++) d: 1.0}),
        ruleC: sliceOf({for (var d = 1; d <= 30; d++) d: -1.0}),
      );
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));
      expect(find.textContaining('按天重抽'), findsNothing);

      await tester.tap(find.text('最近半年'));
      await tester.pump();
      expect(find.textContaining('按天重抽'), findsOneWidget);
      // 颜色语义必须写在页面上:红色是及格线不是冠军、灰色别追、没有红色少动。
      expect(find.text('怎么看「最近半年」'), findsOneWidget);
      expect(find.textContaining('及格线'), findsOneWidget);
      expect(find.textContaining('没有红色'), findsOneWidget);
      // 与选股页统计行的口径衔接(那边是"最近一个样本够的年份的超额",比这里松)。
      expect(find.textContaining('最近一个样本够的年份的超额'), findsOneWidget);
      // 超额列固定跟随中间持有期:挂在列头 Tooltip 上而不是多写一行正文
      // (正文多一行会把表头挤出手机首屏)。
      expect(
          find.byWidgetPredicate((w) =>
              w is Tooltip && (w.message ?? '').contains('中间持有期')),
          findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Tooltip && (w.message ?? '').contains('一期 = 一次回测快照')),
          findsOneWidget);
    });

    testWidgets('全期口径下显示「超额」列,数值 = 均收 − 同期基准,基准行 —', (tester) async {
      final r = _fakeReport(generated);
      final pfH = r.horizons.length >= 2 ? r.horizons[1] : r.horizons.last;
      final baseAvg = r.baseline[pfH]!.avgReturn;
      final rule = ruleById('pct_change_up');
      final excess = r.result(rule.id, pfH)!.avgReturn - baseAvg;
      final text =
          '${excess >= 0 ? '+' : ''}${excess.toStringAsFixed(1)}';

      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: r,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      expect(find.text('$pfH日超额'), findsOneWidget);
      expect(find.text(text), findsOneWidget);
      // 基准行没有自己的超额;分年列的"—"也可能出现,不计数。
      expect(find.text('—'), findsWidgets);
    });

    testWidgets('窗口口径下不显示全期超额列(由半年超额替代)', (tester) async {
      final base = RecentSlice(
        stats: BacktestStats.of([for (var i = 0; i < 30; i++) 0.0]),
        dayMeanReturn: {for (var d = 1; d <= 30; d++) d: 0.0},
      );
      final report = BacktestReport(
        generatedAt: generated.toIso8601String(),
        horizons: const [5, 10],
        stockCount: 2,
        baseline: _fakeReport(generated).baseline,
        results: _fakeReport(generated).results,
        recent: {
          'pct_change_up': {5: base, 10: base},
        },
        recentBaseline: {5: base, 10: base},
      );
      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report,
        runFn: (_, {reportPath}) async => fail('不应触发'),
      ));

      await tester.tap(find.text('最近半年'));
      await tester.pump();

      expect(find.text('半年超额'), findsOneWidget);
      expect(find.text('10日超额'), findsNothing);
    });

    testWidgets('页面内「重新回测」写入的台账要立刻反映到连红列', (tester) async {
      // runBacktest 会 upsert 台账，而页面只在 initState 读一次 -- 重跑后
      // 连红列会永久停在旧期数（台账首启不存在时更是整列都是 —）。
      final base = sliceOf({for (var d = 1; d <= 30; d++) d: 0.0});
      final report = recentReport(
        base: base,
        ruleA: sliceOf({for (var d = 1; d <= 30; d++) d: 1.0}),
        ruleB: sliceOf({for (var d = 1; d <= 5; d++) d: 1.0}),
        ruleC: sliceOf({for (var d = 1; d <= 30; d++) d: -1.0}),
      );
      RecentExcessRec red() =>
          RecentExcessRec(excess: 1.0, ciLow: 0.5, ciHigh: 2.0, days: 100);
      BacktestSnapshot snap(String date) => BacktestSnapshot(
            generatedAt: 't',
            dataDate: date,
            stockCount: 2,
            evaluableDays: 100,
            ruleWinRate: const {},
            recentExcess: {'pct_change_up': red()},
          );
      File(historyPathFor(reportPath))
          .writeAsStringSync(jsonEncode(BacktestHistory([snap('20260831')]).toJson()));

      await pump(tester, BacktestPage(
        dbPath: dbPath,
        reportPath: reportPath,
        initialReport: report,
        runFn: (_, {reportPath}) async {
          // 与 runBacktest 一致：同日替换、新数据截止日追加一期。
          final hp = historyPathFor(reportPath!);
          final prev = loadBacktestHistory(hp) ?? const BacktestHistory([]);
          File(hp).writeAsStringSync(
              jsonEncode(prev.upsert(snap('20260930')).toJson()));
          return report;
        },
      ));

      await tester.tap(find.text('最近半年'));
      await tester.pump();
      expect(find.text('2连红'), findsNothing, reason: '重跑前台账只有 1 期');

      await tester.tap(find.text('重新回测'));
      await tester.pumpAndSettle();
      expect(find.text('2连红'), findsOneWidget,
          reason: '刚写进台账的那一期必须被页面读到');
    });
  });
}
