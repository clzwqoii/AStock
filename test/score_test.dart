import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/features.dart';
import 'package:stock/core/rules.dart';

import 'fixtures.dart';
import 'package:stock/core/logreg.dart';
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

/// 迷你报告：三条规则 + 基准，样本量差异巨大，用来验证加权与低置信降级。
  // 迷你报告：三条规则 + 基准。样本量差异巨大，用来验证加权与低置信降级。
  BacktestReport miniReport() => BacktestReport(
        generatedAt: '2026-10-06T00:00:00.000',
        horizons: const [10],
        stockCount: 5672,
        baseline: {
          10: Baseline.fromStats(
            forwardDays: 10,
            stats: BacktestStats(
              count: 1000000,
              winRate: 0.50,
              avgReturn: 0.2,
              medianReturn: 0.1,
              bestReturn: 50,
              worstReturn: -40,
              profitFactor: 1.05,
              p10: -5,
              p25: -2,
              p75: 6,
              p90: 10,
              stdDev: 12,
            ),
          ),
        },
        results: {
          'rsi_oversold_volume': {
            10: BacktestResult.fromStats(
              ruleId: 'rsi_oversold_volume',
              forwardDays: 10,
              stats: _st(0.90, 19.05, 7496,
                  p10: -2.72, p25: 7.32, p75: 30.02, p90: 40.05, sd: 18.87),
            ),
          },
          'tiny_signal': {
            10: BacktestResult.fromStats(
              ruleId: 'tiny_signal',
              forwardDays: 10,
              stats: _st(0.99, 90, 5,
                  p10: 5, p25: 30, p75: 80, p90: 95, sd: 20),
            ),
          },
          'weak_rule': {
            10: BacktestResult.fromStats(
              ruleId: 'weak_rule',
              forwardDays: 10,
              stats: _st(0.40, -1.5, 800,
                  p10: -9, p25: -5, p75: 2, p90: 4, sd: 5),
            ),
          },
        },
        yearly: const {},
        yearlyBaseline: const {},
      );

void main() {
  group('scoreOf 规则历史胜率聚合评分', () {
    test('单条规则命中 → 分数就是它的历史胜率 × 100', () {
      final s = scoreOf(miniReport(), hitRuleIds: const ['rsi_oversold_volume']);
      expect(s.score, closeTo(90, 1e-9));
      expect(s.rawWinRate, closeTo(0.90, 1e-9));
      expect(s.baselineWinRate, closeTo(0.50, 1e-9));
      expect(s.sampleCount, 7496);
      expect(s.lowConfidence, isFalse);
      expect(s.tier, '高');
      expect(s.reason, isEmpty);
      expect(s.excessPp, closeTo(40, 1e-9));
    });

    test('无命中 / 无报告 → 分数等于基准，且必须标低置信', () {
      final noHit = scoreOf(miniReport());
      expect(noHit.score, closeTo(50, 1e-9));
      expect(noHit.sampleCount, 0);
      expect(noHit.lowConfidence, isTrue);
      expect(noHit.reason, isNotEmpty, reason: '低置信必须给出可展示的原因');

      final noReport = scoreOf(null, hitRuleIds: const ['rsi_oversold_volume']);
      expect(noReport.score, closeTo(50, 1e-9));
      expect(noReport.lowConfidence, isTrue);
      expect(noReport.reason, isNotEmpty);
    });

    test('样本量参与加权：5 个信号的 99% 胜率不能拉高总分', () {
      // oracle: (0.90×7496 + 0.99×5)/7501 = 0.9000599920010665
      final s = scoreOf(
        miniReport(),
        hitRuleIds: const ['rsi_oversold_volume', 'tiny_signal'],
      );
      expect(s.sampleCount, 7501);
      expect(s.rawWinRate, closeTo(0.9000599920010665, 1e-12));
      expect(s.score, closeTo(90.00599920010665, 1e-9));
      // 若误用算术平均会得 0.945 → 94.5 分，这里显式挡住
      expect(s.score, lessThan(91));
    });

    test('只有小样本规则 → 低置信', () {
      final s = scoreOf(miniReport(), hitRuleIds: const ['tiny_signal']);
      expect(s.score, closeTo(99, 1e-9));
      expect(s.sampleCount, 5);
      expect(s.lowConfidence, isTrue, reason: '5 个信号的历史胜率不能当真');
      expect(s.reason, contains('5'));
    });

    test('胜率低于基准时分数必须低于 50', () {
      final s = scoreOf(miniReport(), hitRuleIds: const ['weak_rule']);
      expect(s.score, closeTo(40, 1e-9));
      expect(s.score, lessThan(s.baselineWinRate * 100));
      expect(s.tier, '低');
      expect(s.excessPp, lessThan(0));
    });

    test('未知规则 id 被忽略，不抛异常也不凭空给分', () {
      final s = scoreOf(
        miniReport(),
        hitRuleIds: const ['不存在的规则', 'rsi_oversold_volume'],
      );
      expect(s.sampleCount, 7496);
      expect(s.score, closeTo(90, 1e-9));
      expect(s.hitRuleIds, ['rsi_oversold_volume']);
    });

    test('档位边界：高 ≥85 / 中 70~85 / 低 <70', () {
      expect(_scoreOfWin(0.95).tier, '高');
      expect(_scoreOfWin(0.85).tier, '高');
      expect(_scoreOfWin(0.84).tier, '中');
      expect(_scoreOfWin(0.70).tier, '中');
      expect(_scoreOfWin(0.69).tier, '低');
      expect(_scoreOfWin(0.40).tier, '低');
    });

    test('持有期可取：改 horizon 就换一列统计', () {
      final report = miniReport();
      final at20 = scoreOf(report,
          hitRuleIds: const ['rsi_oversold_volume'], horizon: 20);
      // 迷你报告只有 10 日那一列 → 20 日取不到，必须降级而不是拿 10 日的数糊弄
      expect(at20.lowConfidence, isTrue);
      expect(at20.score, closeTo(50, 1e-9));
      expect(at20.reason, contains('20'));
    });

    test('报告里没有任何规则数据时退到基准', () {
      final bare = BacktestReport(
        generatedAt: 'x',
        horizons: const [10],
        stockCount: 1,
        baseline: {
          10: Baseline.fromStats(
            forwardDays: 10,
            stats: _st(0.5, 0, 100),
          ),
        },
        results: const {},
        yearly: const {},
        yearlyBaseline: const {},
      );
      final s = scoreOf(bare, hitRuleIds: const ['rsi_oversold_volume']);
      expect(s.sampleCount, 0);
      expect(s.lowConfidence, isTrue);
      expect(s.score, closeTo(50, 1e-9));
    });
  });
  
  group('方案 B：逻辑回归接管打分', () {
    test('有模型时分数来自模型而不是加权胜率', () {
      // 同一条规则、同一个快照，方案 A 只会给出固定的 90 分；
      // 方案 B 能按 rsi14/量比等连续特征区分。
      final report = miniReport();
      // 训练样本必须与 featureNames 等宽，否则测的是"维度检查"而不是"接管"
      final model = LogRegModel.train([
        [for (var j = 0; j < featureNames.length; j++) 1.0],
        [for (var j = 0; j < featureNames.length; j++) -1.0],
        [for (var j = 0; j < featureNames.length; j++) 2.0],
        [for (var j = 0; j < featureNames.length; j++) -2.0],
      ], const [1, 0, 1, 0], maxIter: 60, l2: 1);

      final a = scoreOf(report, hitRuleIds: const ['rsi_oversold_volume']);
      final b = scoreOf(report,
          hitRuleIds: const ['rsi_oversold_volume'],
          model: model,
          snapshot: snap());
      expect(a.score, closeTo(90, 1e-9), reason: '方案 A 对该规则是常数分');
      expect(b.score, greaterThanOrEqualTo(0));
      expect(b.score, lessThanOrEqualTo(100));
      expect(b.score, isNot(a.score));
      expect(b.source, 'planB');
      expect(a.source, 'planA');
    });

    test('模型与特征顺序必须一致，对不上就别打分', () {
      final report = miniReport();
      // 维度只有 2 的模型，与 featureNames 长度不符
      final wrongDim = LogRegModel.train([
        [0, 0],
        [1, 1],
      ], const [0, 1], maxIter: 10, l2: 0);
      expect(
          () => scoreOf(report,
              hitRuleIds: const ['rsi_oversold_volume'],
              model: wrongDim,
              snapshot: snap()),
          throwsA(isA<ArgumentError>()),
          reason: '维度不符意味着系数整体错位，比不打分危险得多');
    });

    test('模型缺失/维度不符时回退方案 A，不让选股页崩', () {
      final report = miniReport();
      final wrongDim = LogRegModel.train([
        [0, 0],
        [1, 1],
      ], const [0, 1], maxIter: 10, l2: 0);
      final s = scoreOf(report,
          hitRuleIds: const ['rsi_oversold_volume'],
          model: wrongDim,
          snapshot: snap(),
          fallbackToPlanA: true);
      expect(s.source, 'planA');
      expect(s.score, closeTo(90, 1e-9));
      expect(s.reason, isNotEmpty, reason: '要告诉 UI 为什么退化');
    });

    test('模型给出的分数仍在 0~100', () {
      final model = LogRegModel.train([
        [for (var j = 0; j < featureNames.length; j++) 1.0],
        [for (var j = 0; j < featureNames.length; j++) -1.0],
        [for (var j = 0; j < featureNames.length; j++) 2.0],
        [for (var j = 0; j < featureNames.length; j++) -2.0],
      ], const [1, 0, 1, 0], maxIter: 60, l2: 1);
      for (var i = 0; i < 4; i++) {
        final s = scoreOf(miniReport(),
            hitRuleIds: const ['rsi_oversold_volume'],
            model: model,
            snapshot: snap());
        expect(s.score, greaterThanOrEqualTo(0));
        expect(s.score, lessThanOrEqualTo(100));
      }
    });
  });
}

/// 造一个真实快照喂给特征层（IndicatorSnapshot 只有私有构造器）。
IndicatorSnapshot snap() => IndicatorSeries.from([
      for (var i = 0; i < 30; i++)
        kbar(
          close: 10 + i * 0.1,
          open: 10 + i * 0.1,
          high: 10 + i * 0.1 + 0.05,
          low: 10 + i * 0.1 - 0.05,
          volume: 100 + i.toDouble(),
          date: DateTime(2024, 1, 1).add(Duration(days: i)),
        ),
    ]).at(29);

/// 用胜率直接造一个 StockScore，专测档位边界。
StockScore _scoreOfWin(double win) => StockScore(
      score: win * 100,
      rawWinRate: win,
      baselineWinRate: 0.5,
      sampleCount: 1000,
      hitRuleIds: const ['x'],
      source: 'planA',
      lowConfidence: false,
      reason: '',
    );

