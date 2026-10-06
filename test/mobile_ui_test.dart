import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
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
        dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0,
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
        dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0,
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
    expect(find.textContaining('· 60信号'), findsWidgets); // 初始统计行

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
    expect(find.textContaining('· 20信号'), findsWidgets);
    expect(find.textContaining('· 60信号'), findsNothing);
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
        dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0,
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
          blockedCorporateAction: 0,
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
