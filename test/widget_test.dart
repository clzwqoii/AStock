import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/config.dart';
import 'package:stock/ui/stock_app.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ui');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('主窗口只显示工作台（无页签），侧栏设置按钮打开设置弹框', (tester) async {
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: '${tmp.path}/empty.db'),
      showOnboarding: false,
    ));
    await tester.pump();

    expect(find.byType(TabBar), findsNothing);
    expect(find.text('开始选股'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('主题色'), findsOneWidget);
    expect(find.textContaining('tushare Token'), findsOneWidget);
  });

  testWidgets('无 token 首次启动显示引导页：三步 + token 输入 + 完成回调', (tester) async {
    String? saved;
    final urls = <Uri>[];
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: '${tmp.path}/e.db'),
      persistToken: (t) async => saved = t,
      launchUrl: (u) async => urls.add(u),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('欢迎'), findsOneWidget);
    expect(find.textContaining('注册'), findsWidgets);
    await tester.tap(find.text('打开 tushare.pro'));
    await tester.pump();
    expect(urls.single.host, 'tushare.pro');

    await tester.enterText(find.byType(TextField), 'abc123');
    await tester.tap(find.text('完成并开始'));
    await tester.pumpAndSettle();
    expect(saved, 'abc123');
    expect(find.textContaining('欢迎'), findsNothing);
  });

  testWidgets('设置页含注册引导链接', (tester) async {
    final urls = <Uri>[];
    await tester.pumpWidget(StockApp(
      config: AppConfig(tushareToken: '', dbPath: '${tmp.path}/e.db'),
      showOnboarding: false,
      launchUrl: (u) async => urls.add(u),
    ));
    await tester.pump();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tushare.pro'), findsWidgets);
  });
}
