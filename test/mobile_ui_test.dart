import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/score.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/ui/candle_chart.dart';
import 'package:stock/ui/colors.dart';
import 'package:stock/ui/mobile_home.dart';
import 'package:stock/ui/stock_app.dart';

import 'fixtures.dart';


void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532); // 390×844 @3x
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mobile');
    dbPath = '${tmp.path}/t.db';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Widget stockApp({Future<void> Function(String)? persistAccent}) => StockApp(
        config: AppConfig(tushareToken: '', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: persistAccent,
      );

  testWidgets('窄屏显示底部导航与移动选股页（20 个规则开关，无侧栏）', (tester) async {
    _phone(tester);
    await tester.pumpWidget(stockApp());
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(20));
    expect(find.text('开始选股'), findsOneWidget);
    expect(find.textContaining('全市场'), findsOneWidget);
  });

  testWidgets('系统内存压力通知可正常分发（选股页注册了 WidgetsBindingObserver）', (tester) async {
    _phone(tester);
    await tester.pumpWidget(stockApp());
    await tester.pump();

    // 不抛即视为通过：释放池子后页面状态不受影响，仍能正常出结果。
    tester.binding.handleMemoryPressure();
    await tester.pump();
    expect(find.text('开始选股'), findsOneWidget);
  });

  testWidgets('移动端选股：开规则出结果卡片', (tester) async {
    _phone(tester);
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: dbPath),
      showOnboarding: false,
      screenFn: (dbPath, rules) async => (
        total: 2,
        picked: [
          ScreenRow(
              symbol: '000581.SZ',
              name: '威孚高科',
              close: 18.21, change: 0.41, changePct: 2.31,
              volumeRatio: 1.8, amountWan: 8452, ma20: 18.10),
        ],
        dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('收盘价站上MA20').last);
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();

    // 结果区在首屏折叠线以下（sliver 懒构建），滚动到可见再断言
    await tester.scrollUntilVisible(
      find.textContaining('只 · 点击查看详情'),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('只 · 点击查看详情'), findsOneWidget);
    // 结果卡片为懒构建，先滚动进视口再断言
    await tester.scrollUntilVisible(
      find.text('威孚高科'),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('威孚高科'), findsOneWidget);
  });

  testWidgets('结果卡片数值带标签：信号日/近20日/10日胜率/目标价/止损价，不再裸数字', (tester) async {
    _phone(tester);
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: dbPath),
      showOnboarding: false,
      screenFn: (dbPath, rules) async => (
        total: 2,
        picked: [
          ScreenRow(
            symbol: '300601.SZ',
            name: '康泰生物',
            close: 13.58, change: 0.79, changePct: 6.18,
            volumeRatio: 1.8, amountWan: 8452, ma20: 13.10,
            signalDate: '2026-09-30', ret20: 5.0,
            score: const StockScore(
              score: 50, rawWinRate: 0.5, baselineWinRate: 0.5,
              sampleCount: 0, hitRuleIds: [], source: 'planA',
              lowConfidence: true, reason: '未命中任何已回测规则'),
            forecast: const PriceForecast(
              entry: 13.58, target: 13.23, stop: 12.77,
              optimistic: null, riskReward: -0.43,
              lowConfidence: true, reason: '历史平均收益为负，目标价低于买入价'),
          ),
        ],
        dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('收盘价站上MA20').last);
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('康泰生物'),
      80,
      scrollable: find.byType(Scrollable).first,
    );

    // 信号信息带词：信号日 + 近20日涨跌
    expect(find.textContaining('信号 09-30'), findsOneWidget);
    expect(find.textContaining('近20日 +5.0%'), findsOneWidget);
    // 卡片三个带标签的指标：胜率 / 目标价 / 止损价
    expect(find.text('10日胜率'), findsOneWidget);
    expect(find.textContaining('50%'), findsOneWidget);
    expect(find.text('目标价'), findsOneWidget);
    expect(find.textContaining('13.23'), findsOneWidget);
    expect(find.textContaining('-2.6%'), findsOneWidget);
    expect(find.text('止损价'), findsOneWidget);
    expect(find.textContaining('12.77'), findsOneWidget);
    // 旧裸数字写法退役：目标/止损不再用斜杠拼接，负盈亏比不再出现
    expect(find.textContaining('盈亏比'), findsNothing);
    expect(find.textContaining('13.23/12.77'), findsNothing);
  });

  testWidgets('移动端点击结果卡片进入个股详情（K线图 + 指标）', (tester) async {
    _phone(tester);
    seedStocks(dbPath);
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: dbPath),
      showOnboarding: false,
      screenFn: (dbPath, rules) async => (
        total: 2,
        picked: [
          ScreenRow(
              symbol: 'S1.SH',
              name: '测试股票',
              close: 10.5, change: 0.5, changePct: 5.0,
              volumeRatio: 3.0, amountWan: 0.1, ma20: 10.025),
        ],
        dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('收盘价站上MA20').last);
    await tester.pump();
    // 收起规则面板，减少页面长度
    await tester.tap(find.text('选股规则'));
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();

    // 滚动到结果卡片并点击
    await tester.scrollUntilVisible(
      find.text('测试股票'),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('测试股票'));
    await tester.pumpAndSettle();

    expect(find.byType(CandleChart), findsOneWidget);
    expect(find.textContaining('RSI14'), findsWidgets);
    expect(find.textContaining('不复权'), findsOneWidget);
  });

  testWidgets('底部导航切到设置页可切换主题色并持久化', (tester) async {
    _phone(tester);
    String? persisted;
    await tester.pumpWidget(stockApp(persistAccent: (name) async => persisted = name));
    await tester.pump();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('accent-blue')));
    await tester.pump();

    expect(persisted, 'blue');
  });

  testWidgets('移动端重新回测后 onReport 回传，选股页统计行同步刷新', (tester) async {
    _phone(tester);
    // 单调上涨序列：close_above_ma20 从第 20 根起每天都命中，
    // 90 根 → 10 日持有期 60 个信号；50 根 → 20 个信号。统计行只差在信号数。
    BacktestReport rising(int n) => backtestAll(
          [
            StockData(
              symbol: 'X',
              bars: [
                for (var i = 0; i < n; i++)
                  kbar(
                    close: 10.0 + 0.1 * i,
                    volume: 100,
                    date: DateTime(2024, 1, 1).add(Duration(days: i)),
                  ),
              ],
            ),
          ],
          [ruleById('close_above_ma20')],
          horizons: const [5, 10],
        );

    var current = rising(90);
    final updated = rising(50);
    BacktestReport? reported;

    Future<void> pumpHome() => tester.pumpWidget(MaterialApp(
          home: AccentScope(
            color: AccentColor.red.color,
            child: MobileHome(
              dbPath: dbPath,
              syncing: false,
              syncMsg: null,
              syncedDate: null,
              accent: AccentColor.red,
              onAccentChanged: (_) {},
              onSyncPressed: () {},
              configPath: '${tmp.path}/.env',
              initialToken: '',
              backtestReport: current,
              backtestRunFn: (_, {reportPath}) async => updated,
              onReport: (r) => reported = r,
            ),
          ),
        ));

    await pumpHome();
    await tester.pump();
    // 统计行显示「最近一年 均收益 · 超额 · 胜率 · PF · 基准 · 信号数」：
    // 90 根时 2024 年均收益 6.78%。年份只写后两位（24年）。
    expect(find.textContaining('24年 6.78%'), findsWidgets); // 初始统计行
    expect(find.textContaining('24年 7.74%'), findsNothing);

    await tester.tap(find.text('回测'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新回测'));
    await tester.pumpAndSettle();

    // 回测页把新报告交回外壳（与桌面端 onReport 同一条链路）
    expect(reported, same(updated));
    // 外壳收到后换新报告重建（StockApp: setState(() => _report = r)）
    current = updated;
    await pumpHome();
    await tester.pump();
    await tester.tap(find.text('选股'));
    await tester.pumpAndSettle();
    expect(find.textContaining('24年 7.74%'), findsWidgets);
    expect(find.textContaining('24年 6.78%'), findsNothing);
  });

  testWidgets('移动端长按统计行弹出字段说明（与桌面共用 RuleStatLine.helpText）', (tester) async {
    _phone(tester);
    // 安卓/iOS 规则面板与桌面侧栏共用排序 helper 与统计行——这里锁住
    // Tooltip 在触屏上的触发路径（长按），防止以后重构把移动端说明弄丢。
    final report = backtestAll(
      [
        StockData(
          symbol: 'X',
          bars: [
            for (var i = 0; i < 90; i++)
              kbar(
                close: 10.0 + 0.1 * i,
                volume: 100,
                date: DateTime(2024, 1, 1).add(Duration(days: i)),
              ),
          ],
        ),
      ],
      [ruleById('close_above_ma20')],
      horizons: const [5, 10],
    );
    await tester.pumpWidget(MaterialApp(
      home: AccentScope(
        color: AccentColor.red.color,
        child: MobileHome(
          dbPath: dbPath,
          syncing: false,
          syncMsg: null,
          syncedDate: null,
          accent: AccentColor.red,
          onAccentChanged: (_) {},
          onSyncPressed: () {},
          configPath: '${tmp.path}/.env',
          initialToken: '',
          backtestReport: report,
          backtestRunFn: (_, {reportPath}) async => report,
          onReport: (_) {},
        ),
      ),
    ));
    await tester.pump();

    final statLine = find.textContaining('24年 6.78%');
    await tester.scrollUntilVisible(statLine, 80,
        scrollable: find.byType(Scrollable).first);

    // 主力规则名后挂「主力」徽标（不钉首位，位置由超额排序决定）
    expect(find.text('主力'), findsOneWidget);

    await tester.longPress(statLine.last);
    await tester.pumpAndSettle();
    expect(find.textContaining('胜率高不等于赚钱'), findsOneWidget,
        reason: '长按统计行应弹出字段说明');
  });

  testWidgets('选股完成后规则面板自动收起，结果列表不再被面板遮住', (tester) async {
    _phone(tester);
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: dbPath),
      showOnboarding: false,
      screenFn: (dbPath, rules) async => (
        total: 2,
        picked: [
          ScreenRow(
              symbol: '000581.SZ',
              name: '威孚高科',
              close: 18.21, change: 0.41, changePct: 2.31,
              volumeRatio: 1.8, amountWan: 8452, ma20: 18.10),
        ],
        dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
      ),
    ));
    await tester.pump();
    expect(find.byType(Switch), findsNWidgets(20)); // 面板展开中

    await tester.tap(find.text('收盘价站上MA20').last);
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();

    expect(find.byType(Switch), findsNothing, reason: '选股完成应收起规则面板');
    expect(find.textContaining('只 · 点击查看详情'), findsOneWidget);
  });

  testWidgets('头部渐变随主题色（绿主题不再是红头部）', (tester) async {
    _phone(tester);
    // IndexedStack 只构建当前页签，直接以绿主题启动断言头部渐变
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: dbPath, themeAccent: 'green'),
      showOnboarding: false,
      persistAccent: (_) async {},
    ));
    await tester.pump();

    final gradContainers = find
        .ancestor(of: find.text('A股选股'), matching: find.byType(Container))
        .evaluate()
        .map((e) => e.widget as Container)
        .where((c) => (c.decoration as BoxDecoration?)?.gradient is LinearGradient)
        .toList();
    expect(gradContainers, isNotEmpty); // 头部渐变容器存在
    final grad =
        (gradContainers.first.decoration! as BoxDecoration).gradient! as LinearGradient;
    expect(grad.colors.first, AccentColor.green.color);
    expect(grad.colors.last, isNot(AccentColor.green.color)); // 深端压暗
  });

  testWidgets('点开始选股出现模态加载框，完成后消失', (tester) async {    _phone(tester);
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: dbPath),
      showOnboarding: false,
      screenFn: (dbPath, rules) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return (
          total: 1,
          picked: const <ScreenRow>[],
          dataDate: '20260930',
          blockedStale: 0,
          blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
        );
      },
    ));
    await tester.pump();
    await tester.tap(find.text('收盘价站上MA20').last);
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pump(); // 弹框出现（screenFn 还没返回）
    expect(find.textContaining('正在选股'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.textContaining('正在选股'), findsNothing);
  });

  testWidgets('同步完成后头部徽标显示库里最新交易日，不再停留「未同步」', (tester) async {
    _phone(tester);
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
      showOnboarding: false,
      runSyncFn: ({required dbPath, required token, onProgress}) async =>
          const SyncResult(dates: 0, rows: 0, latestDate: '20261006'),
      // 报告缺失会触发自动补算回测；注入假实现避免真跑 30~50 秒
      runBacktestFn: (_, {reportPath}) async => BacktestReport(
        generatedAt: DateTime(2026, 10, 5).toIso8601String(),
        horizons: const [10],
        stockCount: 0,
        baseline: const {},
        results: const {},
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('同步完成'), findsOneWidget);
    expect(find.textContaining('未同步'), findsNothing);
    expect(find.text('已同步 10-06'), findsOneWidget);
  });
}
