import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/ui/colors.dart';
import 'package:stock/ui/mobile_home.dart';
import 'package:stock/ui/screening_page.dart';

/// 规则名下统计行的配色：涨跌色随主题联动——绿色主题下绿涨红跌，
/// 其余主题红涨绿跌（A股惯例）。
///
/// 桌面侧栏与移动端规则面板各有一份 `_statLine`，两处必须同色：
/// 只改一处会出现"同一规则在两个平台颜色不同"。
///
/// 范围仅限统计行：结果表 / K 线固定红涨绿跌，不随主题变。
void main() {
  BacktestStats st(double avg) => BacktestStats(
        count: 900,
        winRate: 0.5,
        avgReturn: avg,
        medianReturn: avg,
        bestReturn: avg,
        worstReturn: avg,
        profitFactor: 1.0,
      );

  /// 主力规则超额 +2.50pp（2.09 − (−0.41)），另一条 −0.51pp（−0.92 − (−0.41)）。
  BacktestReport report() => BacktestReport(
        generatedAt: '2026-10-06T00:00:00.000',
        horizons: const [10],
        stockCount: 100,
        baseline: const {},
        results: const {},
        yearly: {
          2026: {
            kMainRuleId: {10: st(2.09)},
            _otherRuleId: {10: st(-0.92)},
          },
        },
        yearlyBaseline: {
          2026: {10: st(-0.41)},
        },
        signalProfile: const {},
      );

  void expectColors(WidgetTester tester,
      {required Color up, required Color down}) {
    final positive = tester.widget<Text>(find.textContaining('超额 +2.50pp'));
    expect(positive.style?.color, up, reason: '正超额应为涨色');

    final negative = tester.widget<Text>(find.textContaining('超额 -0.51pp'));
    expect(negative.style?.color, down, reason: '负超额应为跌色');
  }

  Future<void> pumpDesktop(WidgetTester tester, AccentColor accent) async {
    await tester.pumpWidget(MaterialApp(
      home: AccentScope(
        color: accent.color,
        child: Scaffold(
          body: ScreeningPage(dbPath: '/tmp/x.db', backtestReport: report()),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> pumpMobile(WidgetTester tester, AccentColor accent) async {
    tester.view.physicalSize = const Size(1170, 2532); // 390×844 @3x
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: AccentScope(
        color: accent.color,
        child: Scaffold(
          body: MobileScreening(
            dbPath: '/tmp/x.db',
            syncing: false,
            syncMsg: null,
            syncedDate: null,
            backtestReport: report(),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  // 非绿色主题一律红涨绿跌；三个都循环一遍，免得实现写成
  // "只有红色主题才红涨"这种更窄的判据也能蒙混过关。
  for (final accent in AccentColor.values.where((a) => a != AccentColor.green)) {
    testWidgets('桌面侧栏统计行（${accent.label}主题）：红涨绿跌', (tester) async {
      await pumpDesktop(tester, accent);
      expectColors(tester, up: AppColors.red, down: AppColors.down);
    });
  }

  testWidgets('桌面侧栏统计行（绿色主题）：绿涨红跌', (tester) async {
    await pumpDesktop(tester, AccentColor.green);
    expectColors(tester, up: AppColors.down, down: AppColors.red);
  });

  testWidgets('移动端面板统计行（红主题）：红涨绿跌', (tester) async {
    await pumpMobile(tester, AccentColor.red);
    expectColors(tester, up: AppColors.red, down: AppColors.down);
  });

  testWidgets('移动端面板统计行（绿色主题）：绿涨红跌', (tester) async {
    await pumpMobile(tester, AccentColor.green);
    expectColors(tester, up: AppColors.down, down: AppColors.red);
  });
}

/// 用来当"负超额"样本的非主力规则：不写死 id，规则库增删后仍然成立。
final _otherRuleId = builtInRules.firstWhere((r) => r.id != kMainRuleId).id;
