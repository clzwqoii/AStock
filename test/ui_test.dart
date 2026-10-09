import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/score.dart';
import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/report_store.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/ui/colors.dart';
import 'fixtures.dart';
import 'package:stock/ui/screening_page.dart';
import 'package:stock/ui/settings_page.dart';
import 'package:stock/ui/stock_app.dart';

ScreenRow fakeRow(String symbol, {String? name}) => ScreenRow(
      symbol: symbol,
      name: name,
      close: 10.5,
      change: 0.5,
      changePct: 5.0,
      volumeRatio: 3.0,
      amountWan: 120.0,
      ma20: 10.025,
    );

/// `YYYYMMDD`（与 trade_date 同格式）。
///
/// 覆盖判定的用例要用当天推算日期，不能写死：`isYearsCovered` 带 45 天断更
/// 护栏，写死的 maxDate 过一阵子就会因为"库变旧"而失败。
String stamp(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

void main() {
  late Directory tmp;
  late String dbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ui');
    dbPath = '${tmp.path}/t.db';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

/// 侧栏在 600px 测试视口里需要滚动，点击前先滚到可见。
Future<void> scrollTo(WidgetTester tester, Finder finder) =>
    tester.scrollUntilVisible(finder, 60, scrollable: find.byType(Scrollable).first);

  group('StockApp 启动自动同步', () {
    testWidgets('检测到上次更新过：启动即提示「已更新到新版本」', (tester) async {
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: '', dbPath: dbPath),
        showOnboarding: false,
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 0, rows: 0),
        updateNoticeCheck: () async => true,
      ));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('已更新到新版本'), findsOneWidget);
    });

    testWidgets('没有更新过（首次/普通启动）：不弹提示', (tester) async {
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: '', dbPath: dbPath),
        showOnboarding: false,
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 0, rows: 0),
        updateNoticeCheck: () async => false,
      ));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('已更新到新版本'), findsNothing);
    });

    testWidgets('更新检测抛异常：不影响启动（不崩溃、不提示）', (tester) async {
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: '', dbPath: dbPath),
        showOnboarding: false,
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 0, rows: 0),
        updateNoticeCheck: () async => throw StateError('读配置失败'),
      ));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('已更新到新版本'), findsNothing);
    });

    testWidgets('有 token 时启动即自动同步一次，状态显示在选股页', (tester) async {
      var calls = 0;
      String? usedToken;
      String? usedDb;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
        showOnboarding: false,
        runSyncFn: ({required dbPath, required token, onProgress}) async {
          calls++;
          usedToken = token;
          usedDb = dbPath;
          return const SyncResult(dates: 0, rows: 0);
        },
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

      expect(calls, 1);
      expect(usedToken, 'tok');
      expect(usedDb, dbPath);
      expect(find.textContaining('同步完成'), findsOneWidget);
    });

    testWidgets('无 token 时不触发同步', (tester) async {
      var calls = 0;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: '', dbPath: dbPath),
        showOnboarding: false,
        runSyncFn: ({required dbPath, required token, onProgress}) async {
          calls++;
          return const SyncResult(dates: 0, rows: 0);
        },
      ));
      await tester.pump();
      expect(calls, 0);
    });
  });

  group('工作台选股页（方案C）', () {
  Future<void> pumpWith(WidgetTester tester, ScreenFn screenFn) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScreeningPage(dbPath: dbPath, screenFn: screenFn)),
    ));
    await tester.pump();
  }

  testWidgets('侧栏 20 个规则开关按分组展示，单选结果传给引擎', (tester) async {
    List<Rule>? passedRules;
    await pumpWith(tester, (dbPath, rules) async {
      passedRules = rules;
      return (
        total: 2,
        picked: [fakeRow('S1.SH', name: '威孚高科')],
        dataDate: '20260930',
        blockedStale: 0,
        blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
      );
    });

    expect(find.byType(Switch), findsNWidgets(20));
    expect(find.text('趋势'), findsOneWidget);
    expect(find.text('超买超卖'), findsOneWidget);

    await scrollTo(tester, find.text('量比>2'));
    await tester.tap(find.text('量比>2'));
    await tester.pump();
    await tester.tap(find.text('开始选股'));
    await tester.pumpAndSettle();

    expect(passedRules?.map((r) => r.id), ['volume_surge']);
    expect(find.textContaining('S1.SH'), findsOneWidget);
    expect(find.textContaining('威孚高科'), findsOneWidget);
    expect(find.textContaining('入选'), findsOneWidget);
  });


    testWidgets('结果表头含评分/目标/止损/盈亏比，点评分可按评分排序', (tester) async {
      await pumpWith(tester, (dbPath, rules) async {
        return (
          total: 1,
          picked: [
            ScreenRow(
              symbol: '600000.SH',
              name: '浦发银行',
              close: 10.0,
              change: 0.2,
              changePct: 2.0,
              volumeRatio: 3.0,
              amountWan: 120.0,
              ma20: 9.8,
              score: StockScore(
                score: 90.4,
                source: 'planA',
                rawWinRate: 0.904,
                baselineWinRate: 0.50,
                sampleCount: 7496,
                hitRuleIds: const ['rsi_oversold_volume'],
                lowConfidence: false,
                reason: '',
              ),
              forecast: PriceForecast(
                entry: 10.0,
                target: 11.9,
                stop: 9.73,
                optimistic: 13.0,
                riskReward: 7.01,
                lowConfidence: false,
                reason: '',
              ),
            ),
          ],
          dataDate: '20260930', blockedStale: 0, blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
        );
      });
      await scrollTo(tester, find.text('量比>2'));
      await tester.tap(find.text('量比>2'));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pumpAndSettle();

      // 四个新表头
      for (final h in const ['评分', '目标', '止损', '盈亏比']) {
        expect(find.text(h), findsOneWidget, reason: '表头缺 $h');
      }
      // 评分按档位显示「90·高」，价位与盈亏比取两位小数
      expect(find.text('90·高'), findsOneWidget);
      expect(find.text('11.90'), findsOneWidget);
      expect(find.text('9.73'), findsOneWidget);
      expect(find.text('7.01'), findsOneWidget);

      // 点评分表头切换排序，不应崩
      await scrollTo(tester, find.text('评分'));
      await tester.tap(find.text('评分'));
      await tester.pumpAndSettle();
      expect(find.text('评分'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('无回测数据时新列留空，不显示 0 分或 0.00 价位', (tester) async {
      await pumpWith(tester, (dbPath, rules) async {
        return (
          total: 1,
          picked: [fakeRow('600000.SH')],
          dataDate: '20260930',
          blockedStale: 0,
          blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
        );
      });
      await scrollTo(tester, find.text('量比>2'));
      await tester.tap(find.text('量比>2'));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pumpAndSettle();
      // fakeRow 不带 score/forecast：评分与四个价位列都必须为空。
      // 写成 0 会被读成「0 分/目标价 0 元」，比留空危险得多。
      for (final bad in const ['0·低', '0.00']) {
        expect(find.text(bad), findsNothing, reason: '无数据时不该出现 $bad');
      }
      expect(find.text('—'), findsOneWidget, reason: '只剩名称缺失那一处占位符');
    });

    testWidgets('多选两条规则=组合选股，副标题展示组合条件', (tester) async {
      List<Rule>? passedRules;
      await pumpWith(tester, (dbPath, rules) async {
        passedRules = rules;
        return (
          total: 2,
          picked: [fakeRow('S1.SH')],
          dataDate: '20260930',
          blockedStale: 0,
          blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
        );
      });

      // 按规则名点，不按 Switch 下标：侧栏顺序由 ruleIdsSortedByExcess 决定，
      // 会随 backtestReport 有无 / 主力规则的钉住位置变化，用下标写死等于
      // 每次调顺序都要改测试（已经因此红过两次）。
      await scrollTo(tester, find.text('量比>2'));
      await tester.tap(find.text('量比>2'));
      await tester.pump();
      await scrollTo(tester, find.text('当日涨幅>3%'));
      await tester.tap(find.text('当日涨幅>3%'));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pumpAndSettle();

      expect(passedRules!.length, 2);
      expect(passedRules!.map((r) => r.id).toSet(), {'volume_surge', 'pct_change_up'});
      expect(find.textContaining('组合：'), findsOneWidget);
    });

    testWidgets('引擎返回空库时提示先同步', (tester) async {
      await pumpWith(tester, (a, b) async => (
            total: 0,
            picked: const <ScreenRow>[],
            dataDate: null,
            blockedStale: 0,
            blockedCorporateAction: 0,
            blockedSuspension: 0, timings: null,
          ));
      await scrollTo(tester, find.text('量比>2'));
      await tester.tap(find.text('量比>2'));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pumpAndSettle();

      expect(find.textContaining('暂无数据'), findsOneWidget);
    });

    testWidgets('开始选股期间显示模态加载框，完成后消失', (tester) async {
      await pumpWith(tester, (dbPath, rules) async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return (
          total: 1,
          picked: [fakeRow('S1.SH', name: '威孚高科')],
          dataDate: '20260930',
          blockedStale: 0,
          blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
        );
      });
      await tester.tap(find.text('收盘价站上MA20'));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pump(); // 弹框出现（screenFn 还没返回）
      expect(find.textContaining('正在选股'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.textContaining('正在选股'), findsNothing);
    });

    testWidgets('名称缺失时降级显示占位符', (tester) async {
      await pumpWith(tester, (a, b) async => (
            total: 1,
            picked: [fakeRow('600000.SH')],
            dataDate: '20260930',
            blockedStale: 0,
            blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
          ));
      await tester.tap(find.text('收盘价站上MA20'));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pumpAndSettle();

      expect(find.text('—'), findsOneWidget);
    });
  });

  group('主题色应用', () {
    testWidgets('设置页切换主题色：外壳持久化并立即重建主题', (tester) async {
      String? persisted;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: '', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: (name) async => persisted = name,
      ));
      await tester.pump();
      await scrollTo(tester, find.text('设置'));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('accent-blue')));
      await tester.pump();

      expect(persisted, 'blue');
      // 外壳用 AccentScope 把当前主题色传给整棵树（含主题与页面）。
      expect(tester.widget<AccentScope>(find.byType(AccentScope)).color, AccentColor.blue.color);
    });

    testWidgets('选股页跟随主题色（AccentScope）', (tester) async {
      await tester.pumpWidget(AccentScope(
        color: AccentColor.green.color,
        child: MaterialApp(
          home: Scaffold(
            body: ScreeningPage(
                dbPath: dbPath,
                screenFn: (a, b) async => (
                  total: 1,
                  picked: const <ScreenRow>[],
                  dataDate: null,
                  blockedStale: 0,
                  blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
                ),
              ),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('量比>2'));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pumpAndSettle();

      final btn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '开始选股'));
      expect(btn.style?.backgroundColor?.resolve({}), AccentColor.green.color);
    });
  });

  group('设置页', () {
    testWidgets('外层重建后 token 输入不丢：controller 不随 build 重建', (tester) async {
      Widget pump() => MaterialApp(
            home: Scaffold(
              body: SettingsPage(
                initialToken: 'old',
                configPath: '${tmp.path}/.env',
                dbPath: dbPath,
              ),
            ),
          );
      await tester.pumpWidget(pump());
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'typed');
      await tester.pump();

      await tester.pumpWidget(pump()); // 模拟外层重建（外壳 setState 重建设置页）
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'typed',
          reason: 'controller 提升到 State 后，重建不应把输入重置回 initialToken');
    });

    testWidgets('保存 token 到配置文件', (tester) async {
      final envPath = '${tmp.path}/sub/.env';
      var written = <String, String>{};
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            initialToken: 'old',
            configPath: envPath,
            dbPath: dbPath,
            writeConfig: (path, content) async => written[path] = content,
          ),
        ),
      ));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'newtok');
      await tester.tap(find.text('保存配置'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(written[envPath], contains('TUSHARE_TOKEN=newtok'));
      expect(find.textContaining('已保存'), findsOneWidget);
    });

    testWidgets('展示 4 个主题色色板，点击触发回调', (tester) async {
      AccentColor? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            accent: AccentColor.red,
            onAccentChanged: (a) => picked = a,
          ),
        ),
      ));
      await tester.pump();

      expect(find.byKey(const ValueKey('accent-red')), findsOneWidget);
      expect(find.byKey(const ValueKey('accent-charcoal')), findsOneWidget);
      expect(find.byKey(const ValueKey('accent-blue')), findsOneWidget);
      expect(find.byKey(const ValueKey('accent-green')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('accent-blue')));
      await tester.pump();
      expect(picked, AccentColor.blue);
    });

    testWidgets('点同步按钮触发回调', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            onSyncPressed: () => pressed++,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('同步数据'));
      await tester.pump();
      expect(pressed, 1);
    });

    testWidgets('检查更新：无新版时弹「已是最新版本」', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            checkUpdate: () async => null,
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('已是最新版本'), findsOneWidget);
    });

    testWidgets('检查更新：发现新版时展示版本与下载地址', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            checkUpdate: () async =>
                UpdateInfo(latestVersion: '9.9.9', downloadUrl: 'https://example.com/apk'),
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.textContaining('9.9.9'), findsOneWidget);
    });

    testWidgets('检查更新：有直链时下载带进度并自动触发安装', (tester) async {
      // 与宿主机解耦：强制按 macOS 取直链（foundation 不变量在测试体末检查，须在体内恢复）
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        String? selfUpdatedPath;
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              configPath: '${tmp.path}/.env',
              dbPath: dbPath,
              checkUpdate: () async => UpdateInfo(
                latestVersion: '9.9.9',
                downloadUrl: 'https://example.com/releases',
                // 桌面自替换走 zip，不是 dmg（契约见 self_update_flow_test.dart）：
                // macOS 端下载 zip 后由原生逻辑替换应用包，dmg 只是给人手动装的。
                assets: const {'macos': 'https://example.com/AStock-9.9.9-macOS.zip'},
              ),
              downloadPackage: (url, fileName, {onProgress, client, saveDir}) async {
                onProgress?.call(50, 100);
                onProgress?.call(100, 100);
                return File('${tmp.path}/$fileName')..writeAsStringSync('pkg');
              },
              // macOS 走原生自替换，不再走 installPackage（那条是 dmg 时代的路径）。
              // 注入假 runner，否则测试会打到不存在的 MethodChannel。
              selfUpdate: (zipPath) async => selfUpdatedPath = zipPath,
            ),
          ),
        ));
        await tester.pump();
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        // macOS 走自替换，按钮文案与其它端区分（明确告知会自动装并重启）
        expect(find.text('下载并自动安装'), findsOneWidget);
        await tester.tap(find.text('下载并自动安装'));
        await tester.pumpAndSettle();
        // 自替换路径多一道确认（应用要退出几秒，不能默认就动手）
        await tester.tap(find.text('安装并重启'));
        await tester.pumpAndSettle();

        expect(selfUpdatedPath, endsWith('AStock-9.9.9-macOS.zip'),
            reason: 'macOS 自替换要的是 zip：dmg 挂载后要用户手动拖拽，'
                'zip 才能被 updater.sh 直接解压替换');
        // 自替换成功后 App 随即退出，这里断言不到"安装完成"弹框，
        // 只确认脚本被调起且拿到的是 zip 路径。
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('检查更新：无本平台直链时提供「打开下载页」兜底', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS; // iOS 无应用内自更新
      var opened = 0;
      try {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SettingsPage(
              configPath: '${tmp.path}/.env',
              dbPath: dbPath,
              launchUrl: (uri) async => opened++,
              checkUpdate: () async => UpdateInfo(
                latestVersion: '9.9.9',
                downloadUrl: 'https://example.com/releases',
                assets: const {'android': 'https://example.com/a.apk'}, // iOS 取不到本平台直链
              ),
            ),
          ),
        ));
        await tester.pump();
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();

        expect(find.text('打开下载页'), findsOneWidget);
        expect(find.text('下载并安装'), findsNothing);
        await tester.tap(find.text('打开下载页'));
        await tester.pumpAndSettle();
        expect(opened, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('同步进行中按钮禁用并显示转圈状态', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            syncing: true,
            syncMsg: '同步中：20260930 5561 行',
          ),
        ),
      ));
      await tester.pump();

      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '同步中…'),
      );
      expect(button.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.textContaining('同步中'), findsWidgets);
    });

    testWidgets('回补历史：选档位后把年数回调给外壳', (tester) async {
      int? years;
      var usedForce = true; // 默认路径必须是不带 force 的正常回补
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            onBackfillPressed: (int y, {bool force = false}) {
              years = y;
              usedForce = force;
            },
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('回补历史'));
      await tester.pump();
      await tester.tap(find.text('近 2 年'));
      await tester.pump();

      expect(years, 2);
      expect(usedForce, isFalse, reason: '不勾选完整重拉时 force 必须为 false');
      expect(find.text('近 2 年'), findsNothing, reason: '选择后弹窗应关闭');
    });

    testWidgets('回补历史：勾选完整重拉后回调 force=true', (tester) async {
      int? years;
      bool? usedForce;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            onBackfillPressed: (int y, {bool force = false}) {
              years = y;
              usedForce = force;
            },
          ),
        ),
      ));
      await tester.pump();

      await tester.tap(find.text('回补历史'));
      await tester.pump();
      await tester.tap(find.text('完整重拉'));
      await tester.pump();
      await tester.tap(find.text('近 1 年'));
      await tester.pump();

      expect(years, 1);
      expect(usedForce, isTrue, reason: '勾选后必须带 force 交给外壳');
      expect(find.text('近 1 年'), findsNothing, reason: '选择后弹窗应关闭');
    });

    testWidgets('回补历史：同步进行中禁用入口', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            syncing: true,
          ),
        ),
      ));
      await tester.pump();

      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '回补历史'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('历史覆盖状态：已覆盖 3 年时设置页与弹窗清晰展示已补齐且无需重复回补', (tester) async {
      final today = stamp(DateTime.now());
      final threeYearsAgo = stamp(DateTime(DateTime.now().year - 3,
          DateTime.now().month, DateTime.now().day));
      final fullCoverage = HistoryCoverage(
        minDate: threeYearsAgo,
        maxDate: today,
        tradeDays: 728,
        totalBars: 3800000,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            coverage: fullCoverage,
            onBackfillPressed: (y, {force = false}) {},
          ),
        ),
      ));
      await tester.pump();

      // 设置页主面板显示已补齐状态与区间
      expect(find.textContaining('历史数据已补齐（覆盖近 3 年）'), findsOneWidget);
      expect(find.textContaining('$threeYearsAgo ～ $today'), findsOneWidget);
      expect(find.textContaining('728 个交易日'), findsOneWidget);

      // 点开回补历史弹窗
      await tester.tap(find.text('回补历史'));
      await tester.pump();

      // 弹窗内包含已补齐说明与各档位标注
      expect(find.textContaining('已完整覆盖近 3 年历史数据，无需重复回补'), findsOneWidget);
      expect(find.text('近 1 年 (已补齐)'), findsOneWidget);
      expect(find.text('近 2 年 (已补齐)'), findsOneWidget);
      expect(find.text('近 3 年 (已补齐)'), findsOneWidget);
    });

    testWidgets('历史覆盖状态：仅覆盖 1 年时提示历史深度不足并引导回补', (tester) async {
      final partialCoverage = HistoryCoverage(
        minDate: stamp(DateTime(DateTime.now().year - 1, DateTime.now().month,
            DateTime.now().day)),
        maxDate: stamp(DateTime.now()),
        tradeDays: 245,
        totalBars: 1300000,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            coverage: partialCoverage,
            onBackfillPressed: (y, {force = false}) {},
          ),
        ),
      ));
      await tester.pump();

      expect(find.textContaining('历史数据已覆盖近 1 年（建议回补 2～3 年）'), findsOneWidget);

      await tester.tap(find.text('回补历史'));
      await tester.pump();

      expect(find.text('近 1 年 (已补齐)'), findsOneWidget);
      expect(find.text('近 2 年'), findsOneWidget);
      expect(find.text('近 3 年'), findsOneWidget);
    });

    testWidgets('历史覆盖状态：不足 1 年时提示历史数据不足 1 年', (tester) async {
      final underOneYear = HistoryCoverage(
        minDate: stamp(DateTime.now().subtract(const Duration(days: 30))),
        maxDate: stamp(DateTime.now()),
        tradeDays: 25,
        totalBars: 130000,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            coverage: underOneYear,
            onBackfillPressed: (y, {force = false}) {},
          ),
        ),
      ));
      await tester.pump();

      expect(find.textContaining('历史数据不足 1 年（建议回补历史）'), findsOneWidget);
    });

    testWidgets('历史覆盖状态：历史很深但末根断更时,提示去同步而不是"不足 1 年"', (tester) async {
      // 库里有 6 年历史、交易日密度也够，只有末根停在 2025-01-01（早已断更）。
      // isYearsCovered 有三种 false 原因（深度不够 / 末根断更 / 密度不足），
      // 一律按"年份不够"降级会把用户指去补历史——而真正该做的是恢复同步。
      const stale = HistoryCoverage(
        minDate: '20200101',
        maxDate: '20250101',
        tradeDays: 900,
        totalBars: 3000000,
      );
      expect(stale.isYearsCovered(3), isFalse);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            coverage: stale,
            onBackfillPressed: (y, {force = false}) {},
          ),
        ),
      ));
      await tester.pump();

      expect(find.textContaining('已断更'), findsOneWidget);
      expect(find.textContaining('请先同步'), findsOneWidget);
      expect(find.textContaining('不足 1 年'), findsNothing,
          reason: '深度足够，只是断更，不能报"不足 1 年"');
      expect(find.textContaining('20200101 ～ 20250101'), findsOneWidget,
          reason: '区间照旧展示，用户要能看出数据停在哪天');

      await tester.tap(find.text('回补历史'));
      await tester.pump();
      expect(find.textContaining('已断更'), findsWidgets,
          reason: '弹窗里也要说明是断更，而不是"历史不足 1 年"');
      expect(find.textContaining('历史不足 1 年'), findsNothing);
    });
  });
  
  
  group('同步到新数据后自动刷新回测报告', () {
    /// 造一份最小报告，供注入的 runBacktestFn 返回。
    BacktestReport fakeReport() => BacktestReport(
          generatedAt: DateTime(2026, 10, 5).toIso8601String(),
          horizons: const [10],
          stockCount: 3,
          baseline: const {},
          results: const {},
        );

    testWidgets('同步有新增行时自动重算回测', (tester) async {
      var backtests = 0;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: (_) async {},
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 1, rows: 5560),
        runBacktestFn: (_, {reportPath}) async {
          backtests++;
          return fakeReport();
        },
      ));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(backtests, 1, reason: '有新数据就应重算一次报告');
    });

    testWidgets('回补历史：设置页选档后外壳按年数算起点走回补同步', (tester) async {
      String? usedFrom;
      var backfills = 0;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: (_) async {},
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 0, rows: 0),
        runBackfillFn: ({required dbPath, required token, required fromDate,
            bool force = false, onProgress}) async {
          backfills++;
          usedFrom = fromDate;
          return const SyncResult(dates: 500, rows: 200000);
        },
        runBacktestFn: (_, {reportPath}) async => fakeReport(),
      ));
      await tester.pump();
      await scrollTo(tester, find.text('设置'));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回补历史'));
      await tester.pump();
      await tester.tap(find.text('近 3 年'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(backfills, 1);
      // 容忍测试跨零点：今天或昨天起算的 3 年前都算对
      final expected = {
        backfillFromDate(DateTime.now(), 3),
        backfillFromDate(DateTime.now().subtract(const Duration(days: 1)), 3),
      };
      expect(expected, contains(usedFrom));
      // 消息同时出现在工作台状态行与设置弹窗里
      expect(find.textContaining('回补完成'), findsWidgets);
    });

    testWidgets('回补历史：勾选完整重拉时外壳把 force 传进回补入口', (tester) async {
      bool? usedForce;
      var backfills = 0;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: (_) async {},
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 0, rows: 0),
        runBackfillFn: ({required dbPath, required token, required fromDate,
            bool force = false, onProgress}) async {
          backfills++;
          usedForce = force;
          return const SyncResult(dates: 500, rows: 200000);
        },
        runBacktestFn: (_, {reportPath}) async => fakeReport(),
      ));
      await tester.pump();
      await scrollTo(tester, find.text('设置'));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回补历史'));
      await tester.pump();
      await tester.tap(find.text('完整重拉'));
      await tester.pump();
      await tester.tap(find.text('近 1 年'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(backfills, 1);
      expect(usedForce, isTrue, reason: '勾选完整重拉后外壳必须把 force 传下去');
    });

    testWidgets('回补回执带库内最早日期与备源失败只数，用户能验收覆盖是否到位', (tester) async {
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: (_) async {},
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 0, rows: 0),
        runBackfillFn: ({required dbPath, required token, required fromDate,
            bool force = false, onProgress}) async {
          return const SyncResult(
            dates: 500,
            rows: 200000,
            earliestDate: '20250106',
            failedSymbols: 37,
          );
        },
        runBacktestFn: (_, {reportPath}) async => fakeReport(),
      ));
      await tester.pump();
      await scrollTo(tester, find.text('设置'));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回补历史'));
      await tester.pump();
      await tester.tap(find.text('近 3 年'));
      await tester.pump();
      await tester.pumpAndSettle();

      // 回补 3 年但库内最早只有 20250106：一眼看出没补齐，不用再猜行数含义
      expect(find.textContaining('库内最早 20250106'), findsWidgets);
      expect(find.textContaining('37 只'), findsWidgets,
          reason: '备源单只失败不能静默，回执要点名失败只数并提示重跑');
    });

    testWidgets('同步失败时状态行以「同步失败」开头（不是「同步中失败」）', (tester) async {
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: (_) async {},
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            throw Exception('boom'),
        runBacktestFn: (_, {reportPath}) async => fakeReport(),
      ));
      await tester.pump();
      await scrollTo(tester, find.text('设置'));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步数据'));
      await tester.pumpAndSettle();

      // describeSyncError 兜底文案本身含「同步失败」，不能用正向包含断言；
      // 判据是外壳前缀不得再拼出「同步中失败」。
      expect(find.textContaining('同步中失败'), findsNothing,
          reason: '失败文案应为「同步失败：…」而非「同步中失败：…」');
    });

    testWidgets('报告缺失（如手机首次安装）时同步完成后自动补算一次', (tester) async {
      var backtests = 0;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: (_) async {},
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 0, rows: 0),
        runBacktestFn: (_, {reportPath}) async {
          backtests++;
          return fakeReport();
        },
      ));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(backtests, 1, reason: '没有报告时规则排序与评分/目标价都不可用，应补算');
    });

    testWidgets('报告已存在且同步 0 行：不重算', (tester) async {
      ReportStore(reportPathFor(dbPath)).save(fakeReport());
      var backtests = 0;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: 'tok', dbPath: dbPath),
        showOnboarding: false,
        persistAccent: (_) async {},
        runSyncFn: ({required dbPath, required token, onProgress}) async =>
            const SyncResult(dates: 0, rows: 0),
        runBacktestFn: (_, {reportPath}) async {
          backtests++;
          return fakeReport();
        },
      ));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(backtests, 0, reason: '报告在就不重复跑，重算只由新增数据触发');
    });
  });
    group('规则列表显示回测统计', () {
      /// 造一份只有 2 条规则、2 个持有期的小报告。
      BacktestReport fakeReport() => backtestAll(
            [
              StockData(
                symbol: 'S',
                bars: [
                  for (var i = 0; i < 90; i++)
                    kbar(close: 10.0 + 0.1 * i, volume: 100, date: DateTime(2024, 1, 1).add(Duration(days: i))),
                ],
              ),
            ],
            builtInRules,
            horizons: kDefaultHorizons,
          );
  
      testWidgets('传入报告后规则名下方显示最近一年的超额收益与基准', (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ScreeningPage(
              dbPath: dbPath,
              screenFn: (_, _) async => (
                total: 1,
                picked: const <ScreenRow>[],
                dataDate: null,
                blockedStale: 0,
                blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
              ),
              backtestReport: fakeReport(),
            ),
          ),
        ));
        await tester.pump();
  
        // 显示的是「超额 + 基准」并且**保留**原来的胜率/PF/信号数——口径变更
        // 是补充不是替换（见 rule_stat_line_test.dart 的回归测试）。
        expect(find.textContaining('超额'), findsWidgets);
        expect(find.textContaining('基准'), findsWidgets);
        expect(find.textContaining('24年'), findsWidgets);
        expect(find.textContaining('胜率'), findsWidgets);
        expect(find.textContaining('PF '), findsWidgets);
        expect(find.textContaining('信号 '), findsWidgets);
        // 本例样本只有几十个，必须标注出来，不能让弱数字冒充硬结论。
        expect(find.textContaining('样本少'), findsWidgets);
      });
  
      testWidgets('主力规则名后挂「主力」徽标，位置完全由排序决定', (tester) async {
        // 2026-10-07 起主力不再钉首位：排序与回测超额同口径是硬约束，
        // 主力身份改用名字后的徽标表达。徽标有且只有一个（kMainRuleId）。
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ScreeningPage(
              dbPath: dbPath,
              screenFn: (_, _) async => (
                total: 1,
                picked: const <ScreenRow>[],
                dataDate: null,
                blockedStale: 0,
                blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
              ),
              backtestReport: fakeReport(),
            ),
          ),
        ));
        await tester.pump();

        expect(find.text('主力'), findsOneWidget);
      });

      testWidgets('不传报告时不显示统计行（不占高度）', (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ScreeningPage(
              dbPath: dbPath,
              screenFn: (_, _) async => (
                total: 1,
                picked: const <ScreenRow>[],
                dataDate: null,
                blockedStale: 0,
                blockedCorporateAction: 0, blockedSuspension: 0, timings: null,
              ),
            ),
          ),
        ));
        await tester.pump();
  
        expect(find.textContaining('超额'), findsNothing);
        expect(find.text('收盘价站上MA20'), findsOneWidget);
      });
    });

  group('桌面端常驻选股池（P1d）', () {
    void desktop(WidgetTester tester) {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('注入 screenFn 时桌面走注入路径（不调默认 runScreening）', (tester) async {
      desktop(tester);
      var called = false;
      await tester.pumpWidget(StockApp(
        config: AppConfig(tushareToken: '', dbPath: dbPath),
        showOnboarding: false,
        screenFn: (dbPath, rules) async {
          called = true;
          return (
            total: 1,
            picked: [fakeRow('600000.SH', name: '浦发银行')],
            dataDate: '20260930',
            blockedStale: 0,
            blockedCorporateAction: 0,
            blockedSuspension: 0,
            timings: null,
          );
        },
      ));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('收盘价站上MA20'));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(called, isTrue, reason: '桌面端应走注入的 screenFn，不是默认 runScreening');
    });
  });
}
