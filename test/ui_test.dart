import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/sync_service.dart';
import 'package:stock/ui/colors.dart';
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
  Future<void> pumpWith(
    WidgetTester tester,
    Future<({int total, List<ScreenRow> picked, String? dataDate})> Function(
            String, List<Rule>) screenFn,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ScreeningPage(dbPath: dbPath, screenFn: screenFn)),
    ));
    await tester.pump();
  }

  testWidgets('侧栏 7 个规则开关按分组展示，单选结果传给引擎', (tester) async {
    List<Rule>? passedRules;
    await pumpWith(tester, (dbPath, rules) async {
      passedRules = rules;
      return (total: 2, picked: [fakeRow('S1.SH', name: '威孚高科')], dataDate: '20260930');
    });

    expect(find.byType(Switch), findsNWidgets(7));
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

    testWidgets('多选两条规则=组合选股，副标题展示组合条件', (tester) async {
      List<Rule>? passedRules;
      await pumpWith(tester, (dbPath, rules) async {
        passedRules = rules;
        return (total: 2, picked: [fakeRow('S1.SH')], dataDate: '20260930');
      });

      // 量比>2 是第 6 个开关，当日涨幅>3% 是第 7 个（测试视口高度有限，需滚动到底）。
      await scrollTo(tester, find.byType(Switch).at(5));
      await tester.tap(find.byType(Switch).at(5));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byType(Switch).at(6),
        60,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byType(Switch).at(6));
      await tester.pump();
      await tester.tap(find.text('开始选股'));
      await tester.pumpAndSettle();

      expect(passedRules!.length, 2);
      expect(passedRules!.map((r) => r.id).toSet(), {'volume_surge', 'pct_change_up'});
      expect(find.textContaining('组合：'), findsOneWidget);
    });

    testWidgets('引擎返回空库时提示先同步', (tester) async {
      await pumpWith(tester, (a, b) async => (total: 0, picked: const <ScreenRow>[], dataDate: null));
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
        return (total: 1, picked: [fakeRow('S1.SH', name: '威孚高科')], dataDate: '20260930');
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
      await pumpWith(tester, (a, b) async =>
          (total: 1, picked: [fakeRow('600000.SH')], dataDate: '20260930'));
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
            body: ScreeningPage(dbPath: dbPath, screenFn: (a, b) async => (total: 1, picked: const <ScreenRow>[], dataDate: null)),
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
      // 与宿主机解耦：强制按 macOS 取直链
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      String? installedPath;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsPage(
            configPath: '${tmp.path}/.env',
            dbPath: dbPath,
            checkUpdate: () async => UpdateInfo(
              latestVersion: '9.9.9',
              downloadUrl: 'https://example.com/releases',
              assets: const {'macos': 'https://example.com/AStock-9.9.9-macOS.dmg'},
            ),
            downloadPackage: (url, fileName, {onProgress, client, saveDir}) async {
              onProgress?.call(50, 100);
              onProgress?.call(100, 100);
              return File('${tmp.path}/$fileName')..writeAsStringSync('pkg');
            },
            installPackage: (path) async => installedPath = path,
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载并安装'));
      await tester.pumpAndSettle();

      expect(installedPath, endsWith('AStock-9.9.9-macOS.dmg'));
      expect(find.text('下载完成'), findsOneWidget);
    });

    testWidgets('检查更新：无本平台直链时提供「打开下载页」兜底', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS; // iOS 无应用内自更新
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var opened = 0;
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
  });
}
