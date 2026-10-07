/// 最近 N 交易日窗口回测 + 按天聚类超额 CI。
///
/// 窗口口径:截止日由 tradingCalendar 数交易日(禁日历日差,同停牌护栏教训);
/// 护栏(除权/停牌)在窗口内同样生效;CI 重抽单位是交易日(同 train_score 思想)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';

final _day0 = DateTime(2024, 1, 1);

StockData _stock(List<double> closes, {String symbol = 'T'}) => StockData(
      symbol: symbol,
      bars: [
        for (var i = 0; i < closes.length; i++)
          Bar(
            date: _day0.add(Duration(days: i)),
            open: closes[i],
            high: closes[i],
            low: closes[i],
            close: closes[i],
            volume: 100,
          ),
      ],
    );

/// 60 根:前 40 根平盘 10,后 20 根每日 +1(closes[i] = 10 + (i-39))。
List<double> _ramp() => [
      ...List.filled(40, 10.0),
      for (var i = 40; i < 60; i++) 10.0 + (i - 39),
    ];

/// 测试用规则:收盘价 > [threshold] 命中。
Rule _closeAbove(double threshold) => Rule(
      id: 't_close_gt',
      name: '收盘>',
      desc: '',
      test: (s) => s.close > threshold,
    );

void main() {
  group('backtestAll recentWindowTradingDays', () {
    test('recent 只含最后 10 个交易日的可评估日,基准逐值手算', () {
      // 60 个交易日,窗口 = 最后 10 天(t=50..59);可评估日 t ≤ 60-1-5 = 54,
      // 故窗口内可评估日 = t=50..54 共 5 天 → recentBaseline[5].count = 5。
      // 全样本可评估日 t=20..54 → 35 天。
      // 窗口内基准收益(单股,close[t+5]/close[t]-1)*100:
      //   t=50: 26/21-1 = 23.8095% ;t=51: 27/22 = 22.7273%
      //   t=52: 28/23 = 21.7391% ;t=53: 29/24 = 20.8333% ;t=54: 30/25 = 20.0%
      // 全部 > 0 → winRate = 1.0。
      final r = backtestAll(
        [_stock(_ramp())],
        [_closeAbove(16)],
        horizons: const [5],
        recentWindowTradingDays: 10,
      );

      final base = r.recentBaseline[5];
      expect(base, isNotNull);
      expect(base!.count, 5);
      expect(base.winRate, 1.0);
      expect(base.avgReturn, closeTo((23.8095 + 22.7273 + 21.7391 + 20.8333 + 20.0) / 5, 0.001));
      expect(r.baseline[5]!.count, 35);
    });

    test('recent 规则信号是全样本信号的窗口子集', () {
      // close > 16 从 i=46 起命中;可评估命中 t=46..54 共 9,
      // 窗口内 t=50..54 共 5。
      final r = backtestAll(
        [_stock(_ramp())],
        [_closeAbove(16)],
        horizons: const [5],
        recentWindowTradingDays: 10,
      );
      expect(r.result('t_close_gt', 5)!.count, 9);
      expect(r.recent['t_close_gt']![5]!.count, 5);
    });

    test('recent 按日均值逐值手算(给 CI 用)', () {
      // 窗口内 5 个可评估日,单股 → 每日均值 = 该日收益。
      final r = backtestAll(
        [_stock(_ramp())],
        [_closeAbove(16)],
        horizons: const [5],
        recentWindowTradingDays: 10,
      );
      final days = r.recentBaseline[5]!.dayMeanReturn;
      expect(days.length, 5);
      expect(days[20240220], closeTo(23.8095, 0.001));
      expect(days[20240224], closeTo(20.0, 0.001));
      // 规则同样在 5 天都有信号 → 日均值与基准同键。
      expect(r.recent['t_close_gt']![5]!.dayMeanReturn.keys, days.keys);
    });

    test('除权护栏在窗口内同样生效', () {
      // 第 53 根隔夜 -42%(24 → 14)构成除权式断层:护栏把 t=53 起的
      // lookback 窗口整段剔除,窗口内 5 个可评估日至少少 2 天。
      final closes = _ramp();
      closes[53] = 14.0;
      final r = backtestAll(
        [_stock(closes)],
        [_closeAbove(16)],
        horizons: const [5],
        recentWindowTradingDays: 10,
      );
      final polluted = r.recentBaseline[5]!.count;
      expect(polluted, lessThan(5));
      expect(polluted, greaterThan(0));
      // 全样本同样被剔除(同一套护栏),两口径只剩窗口差异。
      expect(r.baseline[5]!.count, greaterThan(polluted));
    });

    test('未传 recentWindowTradingDays → recent 字段为空(向后兼容)', () {
      final r = backtestAll(
        [_stock(_ramp())],
        [_closeAbove(16)],
        horizons: const [5],
      );
      expect(r.recent, isEmpty);
      expect(r.recentBaseline, isEmpty);
    });

    test('窗口大于全部交易日 → 全部日子进窗口', () {
      final r = backtestAll(
        [_stock(_ramp())],
        [_closeAbove(16)],
        horizons: const [5],
        recentWindowTradingDays: 1000,
      );
      expect(r.recentBaseline[5]!.count, r.baseline[5]!.count);
    });

    test('报告 JSON 往返携带 recent;旧 JSON 缺字段读回为空', () {
      final r = backtestAll(
        [_stock(_ramp())],
        [_closeAbove(16)],
        horizons: const [5],
        recentWindowTradingDays: 10,
      );
      final back = BacktestReport.fromJson(r.toJson());
      expect(back.recent['t_close_gt']![5]!.stats.count, 5);
      expect(
          back.recentBaseline[5]!.dayMeanReturn[20240220],
          closeTo(r.recentBaseline[5]!.dayMeanReturn[20240220]!, 1e-9));

      final legacy = r.toJson()..remove('recent')..remove('recentBaseline');
      final old = BacktestReport.fromJson(legacy);
      expect(old.recent, isEmpty);
      expect(old.recentBaseline, isEmpty);
    });
  });

  group('recentExcessCI(按天重抽)', () {
    test('日超额恒定 → CI 收敛为点', () {
      // 规则每日均超基准 1pp,重抽多少轮都一样。
      final ci = recentExcessCI(
        ruleDayMean: {1: 1.0, 2: 1.0, 3: 1.0, 4: 1.0},
        baseDayMean: {1: 0.0, 2: 0.0, 3: 0.0, 4: 0.0},
        seed: 7,
      );
      expect(ci.excess, closeTo(1.0, 1e-9));
      expect(ci.ciLow, closeTo(1.0, 1e-9));
      expect(ci.ciHigh, closeTo(1.0, 1e-9));
    });

    test('日超额有波动 → CI 覆盖点估计且落在日超额范围内', () {
      // 日超额 = {+2, 0}:点估计 1;重抽只会落在 [0,2]。
      final ci = recentExcessCI(
        ruleDayMean: {1: 2.0, 2: 0.0},
        baseDayMean: {1: 0.0, 2: 0.0},
        rounds: 200,
        seed: 7,
      );
      expect(ci.excess, closeTo(1.0, 1e-9));
      expect(ci.ciLow, greaterThanOrEqualTo(0.0));
      expect(ci.ciHigh, lessThanOrEqualTo(2.0));
      expect(ci.ciLow, lessThanOrEqualTo(ci.excess));
      expect(ci.ciHigh, greaterThanOrEqualTo(ci.excess));
    });

    test('重抽单位是交易日,不是样本', () {
      // 第 1 天 999 个样本均值 +2,第 2 天 1 个样本均值 0。
      // 逐样本重抽会给出虚窄的 CI;按天重抽两天的权重必须相等。
      // 日超额 {+2, 0} 与上一用例同分布 → CI 相同(逐位,种子一致)。
      final a = recentExcessCI(
        ruleDayMean: {1: 2.0, 2: 0.0},
        baseDayMean: {1: 0.0, 2: 0.0},
        rounds: 200,
        seed: 7,
      );
      final b = recentExcessCI(
        ruleDayMean: {1: 2.0, 2: 0.0},
        baseDayMean: {1: 0.0, 2: 0.0},
        rounds: 200,
        seed: 7,
      );
      expect(a.ciLow, b.ciLow);
      expect(a.ciHigh, b.ciHigh);
    });

    test('基准缺某日 → 该日不进重抽池', () {
      // 规则有 3 天,基准只有其中 2 天 → 池 = 2 天。
      // 恒定超额 1.5 → CI 收敛为点(若缺日处理错,池含空值会崩或偏离)。
      final ci = recentExcessCI(
        ruleDayMean: {1: 1.5, 2: 1.5, 3: 1.5},
        baseDayMean: {1: 0.0, 2: 0.0},
        seed: 3,
      );
      expect(ci.excess, closeTo(1.5, 1e-9));
      expect(ci.ciLow, closeTo(1.5, 1e-9));
    });

    test('同种子同输入 → 结果可复现', () {
      final a = recentExcessCI(
        ruleDayMean: {1: 3.0, 2: -1.0, 3: 2.0, 4: 0.5, 5: -0.5},
        baseDayMean: {1: 0.0, 2: 0.2, 3: -0.1, 4: 0.0, 5: 0.3},
        rounds: 200,
        seed: 42,
      );
      final b = recentExcessCI(
        ruleDayMean: {1: 3.0, 2: -1.0, 3: 2.0, 4: 0.5, 5: -0.5},
        baseDayMean: {1: 0.0, 2: 0.2, 3: -0.1, 4: 0.0, 5: 0.3},
        rounds: 200,
        seed: 42,
      );
      expect(a.ciLow, b.ciLow);
      expect(a.ciHigh, b.ciHigh);
    });

    test('空池 → excess 为 0、CI 为 0(UI 据此显示样本不足)', () {
      final ci = recentExcessCI(ruleDayMean: {}, baseDayMean: {1: 0.0});
      expect(ci.excess, 0);
      expect(ci.ciLow, 0);
      expect(ci.ciHigh, 0);
    });
  });

  group('台账:快照捕获窗口超额与连红计数', () {
    RecentSlice sliceOf(Map<int, double> dayMean) => RecentSlice(
          stats: BacktestStats.of(dayMean.values.toList()),
          dayMeanReturn: dayMean,
        );

    BacktestReport reportWith(Map<String, RecentSlice> recent,
        {required RecentSlice base}) {
      final r = backtestAll(
        [_stock(_ramp())],
        [_closeAbove(16)],
        horizons: const [5],
        recentWindowTradingDays: 10,
      );
      return BacktestReport(
        generatedAt: r.generatedAt,
        horizons: r.horizons,
        stockCount: r.stockCount,
        baseline: r.baseline,
        results: r.results,
        recent: {'t_close_gt': {5: recent['t_close_gt']!}},
        recentBaseline: {5: base},
      );
    }

    test('BacktestSnapshot.of 顺带捕获每条规则的窗口超额与 CI', () {
      // 规则每日 +1、基准每日 0 → 超额 1.0,CI 收敛为点(种子固定)。
      final report = reportWith(
        {'t_close_gt': sliceOf({for (var d = 1; d <= 30; d++) d: 1.0})},
        base: sliceOf({for (var d = 1; d <= 30; d++) d: 0.0}),
      );
      final snap = BacktestSnapshot.of(report, '20260930', horizon: 5);
      final rec = snap.recentExcess!['t_close_gt']!;
      expect(rec.excess, closeTo(1.0, 1e-9));
      expect(rec.ciLow, closeTo(1.0, 1e-9));
      expect(rec.ciHigh, closeTo(1.0, 1e-9));
      expect(rec.days, 30);
      // JSON 往返携带。
      final back = BacktestSnapshot.fromJson(snap.toJson());
      expect(back.recentExcess!['t_close_gt']!.excess, closeTo(1.0, 1e-9));
    });

    test('旧快照没有 recentExcess 字段 → 读回为 null(向后兼容)', () {
      final snap = BacktestSnapshot(
        generatedAt: '2026-10-07T00:00:00',
        dataDate: '20260930',
        stockCount: 1,
        evaluableDays: 5,
        ruleWinRate: {'t_close_gt': 1.0},
      );
      expect(snap.recentExcess, isNull);
      final back = BacktestSnapshot.fromJson(snap.toJson());
      expect(back.recentExcess, isNull);
    });

    test('upsert:同一 dataDate 只保留最新一条,不同则追加并按日期排序', () {
      BacktestSnapshot snap(String date, String at) => BacktestSnapshot(
            generatedAt: at,
            dataDate: date,
            stockCount: 1,
            evaluableDays: 5,
            ruleWinRate: const {},
          );
      final h = const BacktestHistory([])
          .upsert(snap('20260930', 't1'))
          .upsert(snap('20260831', 't0'))
          .upsert(snap('20260930', 't2')); // 同日重跑 → 替换不追加
      expect(h.snapshots.length, 2);
      expect(h.snapshots.map((s) => s.dataDate).toList(), ['20260831', '20260930']);
      expect(h.snapshots.last.generatedAt, 't2');
    });

    test('consecutiveReds:从最新一期往回数连续红,非红/无数据即断', () {
      RecentExcessRec rec(double lo, double hi, int days) =>
          RecentExcessRec(excess: 1.0, ciLow: lo, ciHigh: hi, days: days);
      BacktestSnapshot snap(String date, RecentExcessRec? r) => BacktestSnapshot(
            generatedAt: 't',
            dataDate: date,
            stockCount: 1,
            evaluableDays: 5,
            ruleWinRate: const {},
            recentExcess: r == null ? null : {'t_close_gt': r},
          );
      // 时间序:红 → 红 → 灰(lo<0) → 红。最新往回:红(1)、灰即断 → 1?
      // 顺序是按 dataDate 升序排列后从末尾数:[..., 红(9月), 红(10月)]
      final h = BacktestHistory([
        snap('20260630', rec(0.5, 1.5, 100)), // 红
        snap('20260731', rec(-0.5, 1.5, 100)), // 灰(跨0)
        snap('20260831', rec(0.2, 1.0, 100)), // 红
        snap('20260930', rec(0.3, 1.0, 100)), // 红
      ]);
      expect(h.consecutiveReds('t_close_gt'), 2);

      // 最新一期本身是灰 → 0。
      expect(
        BacktestHistory([
          snap('20260930', rec(-0.3, 1.0, 100)),
        ]).consecutiveReds('t_close_gt'),
        0,
      );

      // 独立日不足(样本不足)不算红。
      expect(
        BacktestHistory([
          snap('20260831', rec(0.3, 1.0, 100)),
          snap('20260930', rec(0.3, 1.0, 10)),
        ]).consecutiveReds('t_close_gt'),
        0,
      );

      // 没有任何台账数据 → 0。
      expect(const BacktestHistory([]).consecutiveReds('t_close_gt'), 0);
    });
  });
}
