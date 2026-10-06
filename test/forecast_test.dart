import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/score.dart';

BacktestStats _st(
  double win,
  double avg,
  int n, {
  double? p10,
  double? p25,
  double? p75,
  double? p90,
  double? sd,
}) =>
    BacktestStats(
      count: n,
      winRate: win,
      avgReturn: avg,
      medianReturn: avg,
      bestReturn: avg + 10,
      worstReturn: avg - 10,
      profitFactor: 2,
      p10: p10,
      p25: p25,
      p75: p75,
      p90: p90,
      stdDev: sd,
    );

BacktestReport _report() {
  BacktestResult r(String id, double win, double avg, int n,
          {double? p10, double? p25, double? p75, double? p90, double? sd}) =>
      BacktestResult.fromStats(
        ruleId: id,
        forwardDays: 10,
        stats: _st(win, avg, n, p10: p10, p25: p25, p75: p75, p90: p90, sd: sd),
      );
  return BacktestReport(
    generatedAt: '2026-10-06T00:00:00.000',
    horizons: const [10],
    stockCount: 5672,
    baseline: {
      10: Baseline.fromStats(
        forwardDays: 10,
        stats: _st(0.50, 0.2, 1000000, p10: -5, p25: -2, p75: 6, p90: 10, sd: 12),
      ),
    },
    results: {
      'rsi_oversold_volume': {10: r('rsi_oversold_volume', 0.90, 19.0451, 7496,
          p10: -2.7175, p25: 7.3238, p75: 30.0152, p90: 40.0498, sd: 18.8747)},
      'tiny_signal': {10: r('tiny_signal', 0.99, 90, 5,
          p10: 5, p25: 30, p75: 80, p90: 95, sd: 20)},
      'no_tail': {10: r('no_tail', 0.80, 12, 500)}, // 无分位数：模拟旧报告
      'neg_rule': {10: r('neg_rule', 0.30, -8, 300, p10: -12, p25: -10, p75: -2, p90: 1, sd: 6)},
    },
    yearly: const {},
    yearlyBaseline: const {},
  );
}

void main() {
  group('priceForecast 买卖预测价', () {
    test('单规则：目标/止损/乐观价由 avgReturn 与 p10/p75 派生', () {
      // oracle（/tmp）：entry=10, target=11.90451, stop=9.72825,
      //                  optimistic=13.00152, rr=7.0083164673413245
      final f = priceForecast(
        _report(),
        close: 10.0,
        hitRuleIds: const ['rsi_oversold_volume'],
      );
      expect(f.entry, closeTo(10.0, 1e-12));
      expect(f.target, closeTo(11.904509999999998, 1e-12));
      expect(f.stop, closeTo(9.728250000000001, 1e-12));
      expect(f.optimistic, closeTo(13.00152, 1e-12));
      expect(f.riskReward, closeTo(7.0083164673413245, 1e-12));
      expect(f.lowConfidence, isFalse);
    });

    test('多规则按样本量加权，不用算术平均', () {
      // oracle: 加权 avg=19.09239696040528, p10=-2.712355685908545
      final f = priceForecast(
        _report(),
        close: 10.0,
        hitRuleIds: const ['rsi_oversold_volume', 'tiny_signal'],
      );
      expect(f.target, closeTo(11.909239696040528, 1e-12));
      expect(f.stop, closeTo(9.728764431409147, 1e-12));
      expect(f.riskReward, closeTo(7.039046191322089, 1e-12));
    });

    test('止损方向错误时盈亏比必须为空，不能给个看起来合理的数', () {
      // tiny_signal 的 p10=+5 > 0 → 所谓"止损价"高于买入价，盈亏比无意义。
      final f = priceForecast(
        _report(),
        close: 10.0,
        hitRuleIds: const ['tiny_signal'],
      );
      expect(f.target, closeTo(19.0, 1e-9));
      expect(f.stop, closeTo(10.5, 1e-9));
      expect(f.stop!, greaterThan(f.entry),
          reason: 'p10>0 意味着历史最差 10% 也是赚的');
      expect(f.riskReward, isNull,
          reason: '止损价在买入价之上时，(目标-买入)/(买入-止损) 是负的，'
              '显示出来只会误导，宁可留空');
      expect(f.reason, isNotEmpty);
    });

    test('报告缺分位数字段（旧报告）→ 目标仍可算，止损与盈亏比留空', () {
      final f = priceForecast(
        _report(),
        close: 20.0,
        hitRuleIds: const ['no_tail'],
      );
      expect(f.target, closeTo(22.4, 1e-9)); // avg 12% 是老字段，一定有
      expect(f.stop, isNull);
      expect(f.optimistic, isNull);
      expect(f.riskReward, isNull);
      expect(f.reason, isNotEmpty, reason: '必须告诉用户为什么没有止损');
    });

    test('无命中/无报告 → 全空且低置信', () {
      for (final f in [
        priceForecast(_report(), close: 10.0),
        priceForecast(null, close: 10.0, hitRuleIds: const ['x']),
      ]) {
        expect(f.entry, closeTo(10.0, 1e-12));
        expect(f.target, isNull);
        expect(f.stop, isNull);
        expect(f.riskReward, isNull);
        expect(f.lowConfidence, isTrue);
        expect(f.reason, isNotEmpty);
      }
    });

    test('涨跌幅换算：负数平均收益时目标价低于买入价', () {
      final f = priceForecast(
        _report(),
        close: 10.0,
        hitRuleIds: const ['neg_rule'],
      );
      expect(f.target, lessThan(f.entry));
    });

    test('盈亏比 = 潜在盈利 / 潜在亏损，与报告 profitFactor 同向可印证', () {
      final f = priceForecast(
        _report(),
        close: 10.0,
        hitRuleIds: const ['rsi_oversold_volume'],
      );
      // 目标涨幅 19.05% / 止损跌幅 2.72% ≈ 7.0，方向上应与 PF 17.06 一致
      expect(f.riskReward!, greaterThan(1));
      expect(f.target!, greaterThan(f.entry));
      expect(f.stop!, lessThan(f.entry));
    });
  });
}
