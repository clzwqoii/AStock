import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';

/// 规则名下的统计行到底显示什么。
///
/// ## 为什么测这里而不测 widget
///
/// UI 那行只是把 [RuleStatLine] 的字符串画出来，真正要锁住的是**口径**：
/// 显示超额收益而不是胜率。改口径的判断依据在
/// `tool/audit_rules.dart` 的实测里——2026 年基准均收益 −0.41%，此时
/// `rsi_oversold` 胜率 43.5% 低于基准 44.3%（看着失效），但均收益 +0.07%
/// 高于基准（实际仍在赚钱）。所以这层必须有测试，否则以后有人"顺手"
/// 改回胜率显示，没人拦得住。
///
/// 取样口径与 [BacktestReport.yearlyBaseline] 保持一致：只用同一年、
/// 同持有期的基准比，不跨年混算。
void main() {
  BacktestReport report({
    required Map<int, Map<String, Map<int, BacktestStats>>> yearly,
    required Map<int, Map<int, BacktestStats>> yearlyBaseline,
    Map<String, Map<int, RuleProfile>> profile = const {},
  }) {
    return BacktestReport(
      generatedAt: '2026-10-06T00:00:00.000',
      horizons: const [10],
      stockCount: 100,
      baseline: const {},
      results: const {},
      yearly: yearly,
      yearlyBaseline: yearlyBaseline,
      signalProfile: profile,
    );
  }

  BacktestStats st(int count, double avg, double win, {double pf = 1}) =>
      BacktestStats(
        count: count,
        winRate: win,
        avgReturn: avg,
        medianReturn: avg,
        bestReturn: avg,
        worstReturn: -avg,
        profitFactor: pf,
      );

  test('最近一年取最新有数据的年份，并给出与同年基准的超额', () {
    final r = report(
      yearly: {
        2025: {'a': {10: st(800, 4.0, 0.70)}},
        2026: {'a': {10: st(900, 1.75, 0.579)}},
      },
      yearlyBaseline: {
        2025: {10: st(800, 1.72, 0.555)},
        2026: {10: st(800, -0.41, 0.443)},
      },
    );

    final line = ruleStatLine(r, 'a', 10);

    expect(line, isNotNull);
    expect(line!.year, 2026);
    expect(line.avgReturn, 1.75);
    expect(line.baselineReturn, -0.41);
    // 1.75 − (−0.41) = +2.16pp
    expect(line.excessPp, closeTo(2.16, 0.005));
  });

  test('胜率低于基准但均收益高于基准时，仍然算正超额（熊市口径）', () {
    final r = report(
      yearly: {
        2026: {'a': {10: st(900, 0.07, 0.435)}},
      },
      yearlyBaseline: {
        2026: {10: st(800, -0.41, 0.443)},
      },
    );

    final line = ruleStatLine(r, 'a', 10)!;

    // 胜率 43.5% < 44.3%，按旧口径会判失效；按超额 +0.48pp 判仍可用。
    expect(line.winRate, lessThan(line.baselineWinRate));
    expect(line.excessPp, greaterThan(0));
  });

  test('样本太少的年份不算数：取有足够样本的最近一年', () {
    final r = report(
      yearly: {
        2025: {'a': {10: st(900, 4.0, 0.70)}},
        // 只有 1 个样本，均收益再高也是噪声，不能拿它当"最近一年"。
        2026: {'a': {10: st(1, 99.0, 1.0)}},
      },
      yearlyBaseline: {
        2025: {10: st(800, 1.72, 0.555)},
        2026: {10: st(800, -0.41, 0.443)},
      },
    );

    final line = ruleStatLine(r, 'a', 10)!;

    expect(line.year, 2025);
    expect(line.excessPp, closeTo(2.28, 0.005));
    expect(line.smallSample, isFalse);
  });

  test('所有年份样本都不足时仍然显示，但标记为样本少', () {
    // 全部年份都不足 kRuleStatLineMinSamples（例如刚上线的新规则）时
    // 整行消失会让用户以为 App 坏了——退回"最近有数据的一年"并明确标注。
    final r = report(
      yearly: {
        2026: {'a': {10: st(60, 2.0, 0.60)}},
      },
      yearlyBaseline: {
        2026: {10: st(60, -0.41, 0.443)},
      },
    );

    final line = ruleStatLine(r, 'a', 10)!;

    expect(line.year, 2026);
    expect(line.smallSample, isTrue);
    expect(line.label, contains('样本少'));
  });

  test('样本数为 0 的年份不参与，退回上一个有信号的年份', () {
    final r = report(
      yearly: {
        2025: {'a': {10: st(900, 4.0, 0.70)}},
        2026: {'a': {10: st(0, 0.0, 0.0)}},
      },
      yearlyBaseline: {
        2025: {10: st(800, 1.72, 0.555)},
        2026: {10: st(0, 0.0, 0.0)},
      },
    );

    expect(ruleStatLine(r, 'a', 10)!.year, 2025);
  });

  test('无年度数据时返回 null，UI 不占高度', () {
    final r = report(yearly: const {}, yearlyBaseline: const {});
    expect(ruleStatLine(r, 'a', 10), isNull);
  });

  test('该年基准缺失时不返回，避免拿全样本基准冒充当年基准', () {
    final r = report(
      yearly: {
        2026: {'a': {10: st(900, 1.75, 0.579)}},
      },
      yearlyBaseline: const {},
    );
    expect(ruleStatLine(r, 'a', 10), isNull);
  });

  test('显示文案含超额与基准，正超额带 + 号', () {
    final r = report(
      yearly: {
        2026: {'rsi_oversold': {10: st(900, 0.07, 0.435)}},
      },
      yearlyBaseline: {
        2026: {10: st(800, -0.41, 0.443)},
      },
    );

    final text = ruleStatLine(r, 'rsi_oversold', 10)!.label;

    expect(text, contains('26年'));
    expect(text, contains('+0.48'));
    expect(text, contains('-0.41'));
  });

  test('显示文案保留胜率/PF/基准/信号数——口径是补充不是替换', () {
    // 回归背景：第一版把原来的「胜率 · PF · 信号数」整个换成了超额，
    // 用户反馈那三项仍有参考价值、不该从界面上消失。判据换成超额之后，
    // 三项一个都不能少，只是多出超额与基准。
    final r = report(
      yearly: {
        2026: {'rsi_oversold': {10: st(1897, 0.07, 0.435, pf: 1.02)}},
      },
      yearlyBaseline: {
        2026: {10: st(800, -0.41, 0.443, pf: 0.90)},
      },
    );

    final text = ruleStatLine(r, 'rsi_oversold', 10)!.label;

    expect(text, contains('胜率 43.5%'));
    expect(text, contains('PF 1.02'));
    expect(text, contains('基准 -0.41%'));
    expect(text, contains('信号 1897'));
    expect(text, contains('超额 +0.48pp'));
    // 顺序：年份 → 均收益 → 超额 → 胜率 → PF → 基准 → 信号数
    final order = [
      text.indexOf('26年'),
      text.indexOf('超额'),
      text.indexOf('胜率'),
      text.indexOf('PF'),
      text.indexOf('基准'),
      text.indexOf('信号 '),
    ];
    expect(order, orderedEquals(List.of(order)..sort()),
        reason: '各段顺序应为 $order，实际文案：$text');
  });

  test('年份只写后两位：25年 而不是 2025年', () {
    // 这一行要放七段数字，手机上宽度有限，全写会把告警挤出视野。
    final r = report(
      yearly: {
        2025: {'a': {10: st(601, 8.37, 0.837, pf: 5.03)}},
      },
      yearlyBaseline: {
        2025: {10: st(800, 1.72, 0.555, pf: 1.73)},
      },
    );

    final line = ruleStatLine(r, 'a', 10)!;

    expect(line.year, 2025, reason: '完整年份仍保留在数据里');
    expect(line.yearLabel, '25年');
    expect(line.label, startsWith('25年 '));
    expect(line.label, isNot(contains('2025年')));
  });

  test('集中标记写出具体月份：25年2月，而不是笼统的"信号集中单月"', () {
    // 用户反馈：「信号集中单月」没说清是哪个月，光看标签没法判断
    // 该避开哪段行情。实测 rsi_oversold_volume 的主力月是 2024-02。
    final r = report(
      yearly: {
        2025: {'a': {10: st(601, 8.37, 0.837, pf: 5.03)}},
      },
      yearlyBaseline: {
        2025: {10: st(800, 1.72, 0.555, pf: 1.73)},
      },
      profile: {
        'a': {
          10: const RuleProfile(
            signalCount: 7210,
            monthsWithSignals: 30,
            topMonthShare: 0.72,
            topMonth: 202402,
          ),
        },
      },
    );

    final line = ruleStatLine(r, 'a', 10)!;

    expect(line.concentrated, isTrue);
    expect(line.concentratedLabel, '24年2月');
    expect(line.label, contains(' · 24年2月'));
    expect(line.label, isNot(contains('信号集中单月')));
  });

  test('旧报告没有 topMonth → 退回"集中单月"，不显示 0 月', () {
    // 旧报告的 RuleProfile 没有 topMonth 字段：缺数据不猜月份。
    final r = report(
      yearly: {
        2025: {'a': {10: st(601, 8.37, 0.837, pf: 5.03)}},
      },
      yearlyBaseline: {
        2025: {10: st(800, 1.72, 0.555, pf: 1.73)},
      },
      profile: {
        'a': {
          10: const RuleProfile(
            signalCount: 7210,
            monthsWithSignals: 30,
            topMonthShare: 0.72,
          ),
        },
      },
    );

    final line = ruleStatLine(r, 'a', 10)!;

    expect(line.concentratedLabel, '集中单月');
    expect(line.label, isNot(contains('年0月')));
  });

  test('信号挤在单月时标记出来，不让被单段行情绑架的数字冒充稳健', () {
    final r = report(      yearly: {
        2026: {'a': {10: st(900, 1.75, 0.579)}},
      },
      yearlyBaseline: {
        2026: {10: st(800, -0.41, 0.443)},
      },
      profile: {
        'a': {
          10: const RuleProfile(
            signalCount: 7210,
            monthsWithSignals: 30,
            topMonthShare: 0.72,
          ),
        },
      },
    );

    final line = ruleStatLine(r, 'a', 10)!;

    expect(line.concentrated, isTrue);
    expect(line.label, contains('单月'));
  });

  test('样本不足 100 时不标记集中——1 个信号不是"集中"是"没数据"', () {
    final r = report(
      yearly: {
        2026: {'a': {10: st(900, 1.75, 0.579)}},
      },
      yearlyBaseline: {
        2026: {10: st(800, -0.41, 0.443)},
      },
      profile: {
        'a': {
          10: const RuleProfile(
            signalCount: 1,
            monthsWithSignals: 1,
            topMonthShare: 1.0,
          ),
        },
      },
    );

    expect(ruleStatLine(r, 'a', 10)!.concentrated, isFalse);
  });
}
