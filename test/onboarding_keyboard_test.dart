/// 引导页在真机上的三个坑：键盘弹起时内容被顶出屏幕、内容放不下无法滚动、
/// token 打码后看不出粘贴对不对。这里用小屏 + 模拟键盘 inset 回归。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/ui/onboarding.dart';

Future<void> _open(WidgetTester tester, double height, {double keyboard = 0}) async {
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.binding.setSurfaceSize(Size(400, height));
  if (keyboard > 0) {
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  }
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => OnboardingDialog(onSubmit: (_) async {}),
            ),
            child: const Text('打开引导'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('打开引导'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('键盘弹起后：输入框与按钮被推到键盘上方（与无键盘相比明显上移）', (tester) async {
    await _open(tester, 640);
    final before = tester.getRect(find.widgetWithText(FilledButton, '完成并开始')).bottom;
    expect(tester.takeException(), isNull, reason: '不应出现布局溢出');

    // 收起键盘再弹出，模拟真机上 autofocus 拉起键盘
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final after = tester.getRect(find.widgetWithText(FilledButton, '完成并开始')).bottom;
    final field = tester.getRect(find.byType(TextField));

    expect(after, lessThan(before), reason: '键盘弹起后整个 dialog 应上移');
    expect(field.bottom, lessThanOrEqualTo(after), reason: '输入框不能被按钮挡住');
    expect(tester.takeException(), isNull, reason: '键盘弹起后仍不应有溢出');
  });

  testWidgets('小屏内容放不下时可滚动（SingleChildScrollView 接管）', (tester) async {
    await _open(tester, 420, keyboard: 250);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 仍能点到输入框与按钮
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '完成并开始'), findsOneWidget);
  });

  testWidgets('token 可切换明暗（粘贴出错时能自查）', (tester) async {
    await _open(tester, 900);
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    await tester.tap(find.byTooltip('显示 Token'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
  });

  testWidgets('键盘「完成」键直接提交 token', (tester) async {
    String? submitted;
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => OnboardingDialog(onSubmit: (t) async => submitted = t),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'abc123');
    await tester.showKeyboard(find.byType(TextField)); // 先让输入框拿到键盘
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(submitted, 'abc123');
  });
}
