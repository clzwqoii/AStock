import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/market_state.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';

final _day0 = DateTime(2024, 1, 1);

StockData stockOfCloses(List<double> closes, {String symbol = 'T'}) => StockData(
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

/// 150 根：40 根 10.0 → 6 根爬升（+10% 命中 pct_change_up）→ 84 根 14.0 →
/// 第 130 根再 +10% 跳到 15.4（落在「旧跑未评过」的续扫区间，保证增量有规则信号）。
final _upCloses = <double>[
  ...List.filled(40, 10.0),
  11.0, 11.5, 12.0, 12.5, 13.0, 13.5, // 40..45
  ...List.filled(84, 14.0), // 46..129
  ...List.filled(20, 15.4), // 130..149
];

/// 同构下跌形态：主要为基准与新股全评提供样本。
final _downCloses = <double>[
  ...List.filled(40, 10.0),
  11.0, 10.5, 10.0, 9.5, 9.0, 8.5, // 40..45
  ...List.filled(84, 8.0), // 46..129
  ...List.filled(20, 7.2), // 130..149
];

final _flatCloses = List<double>.filled(150, 10.0);

void sameStats(BacktestStats a, BacktestStats b, String what) {
  expect(a.count, b.count, reason: '$what count');
  expect(a.winRate, b.winRate, reason: '$what winRate');
  expect(a.avgReturn, b.avgReturn, reason: '$what avgReturn');
  expect(a.medianReturn, b.medianReturn, reason: '$what medianReturn');
  expect(a.bestReturn, b.bestReturn, reason: '$what bestReturn');
  expect(a.worstReturn, b.worstReturn, reason: '$what worstReturn');
  expect(a.profitFactor, b.profitFactor, reason: '$what profitFactor');
  expect(a.p10, b.p10, reason: '$what p10');
  expect(a.p25, b.p25, reason: '$what p25');
  expect(a.p75, b.p75, reason: '$what p75');
  expect(a.p90, b.p90, reason: '$what p90');
  expect(a.stdDev, b.stdDev, reason: '$what stdDev');
}

/// overall() 容差版：sum/gain/loss 累积序不同 → avgReturn/profitFactor/stdDev
/// ulp 级差异；其余字段（含 count/winRate/中位数/分位数）必须精确相等。
void sameStatsOverall(BacktestStats a, BacktestStats b, String what) {
  expect(a.count, b.count, reason: '$what count');
  expect(a.winRate, b.winRate, reason: '$what winRate');
  expect(a.avgReturn, closeTo(b.avgReturn, 1e-9), reason: '$what avgReturn');
  expect(a.medianReturn, b.medianReturn, reason: '$what medianReturn');
  expect(a.bestReturn, b.bestReturn, reason: '$what bestReturn');
  expect(a.worstReturn, b.worstReturn, reason: '$what worstReturn');
  expect(a.profitFactor, closeTo(b.profitFactor, 1e-9), reason: '$what profitFactor');
  expect(a.p10, b.p10, reason: '$what p10');
  expect(a.p25, b.p25, reason: '$what p25');
  expect(a.p75, b.p75, reason: '$what p75');
  expect(a.p90, b.p90, reason: '$what p90');
  expect(a.stdDev, b.stdDev == null ? isNull : closeTo(b.stdDev!, 1e-9),
      reason: '$what stdDev');
}

final _rules = [
  ruleById('pct_change_up'),
  ruleById('close_above_ma20'),
  ruleById('ma5_golden_ma10'),
];
const _hs = [5, 10];
const _recentWindow = 30;

/// 旧宇宙：各股截断到不同长度（含 35 根的短票与不再增长的红利票）。
final _oldStocks = [
  stockOfCloses(_upCloses.sublist(0, 140), symbol: 'U1'),
  stockOfCloses(_upCloses.sublist(0, 125), symbol: 'U2'),
  stockOfCloses(_downCloses.sublist(0, 130), symbol: 'D1'),
  stockOfCloses(_downCloses.sublist(0, 80), symbol: 'D2'),
  stockOfCloses(_flatCloses.sublist(0, 100), symbol: 'F1'),
  stockOfCloses(_flatCloses.sublist(0, 35), symbol: 'F2'),
];

/// 新宇宙：各股追加 K 线 + 新股 N1（旧缓存里没有）+ F2 零追加（停牌形态）。
final _newStocks = [
  stockOfCloses(_upCloses, symbol: 'U1'),
  stockOfCloses(_upCloses.sublist(0, 135), symbol: 'U2'),
  stockOfCloses(_downCloses.sublist(0, 140), symbol: 'D1'),
  stockOfCloses(_downCloses.sublist(0, 90), symbol: 'D2'),
  stockOfCloses(_flatCloses.sublist(0, 110), symbol: 'F1'),
  stockOfCloses(_flatCloses.sublist(0, 35), symbol: 'F2'),
  stockOfCloses(_downCloses, symbol: 'N1'),
];

final _resumeLens = <String, int>{
  'U1': 140, 'U2': 125, 'D1': 130, 'D2': 80, 'F1': 100, 'F2': 35,
};

MarketStateCtx _msCtx(Set<DateTime> calendar) => MarketStateCtx.fromCalendar(
      calendar,
      maPeriod: 120,
      recentDays: 130,
      statWindow: 20,
      maxLastBarLagTradingDays: 20,
      corporateActionLookbackBars: kCorporateActionLookbackBars,
    );

ShardDetail _scan(
  List<StockData> stocks,
  Set<DateTime> calendar,
  DateTime? cutoff,
  MarketStateCtx msCtx, {
  Map<String, int>? resumeLens,
}) =>
    scanStocksShard(
      stocks: stocks,
      rules: _rules,
      hs: _hs,
      calendar: calendar,
      recentCutoffDate: cutoff,
      msCtx: msCtx,
      resumeLens: resumeLens,
    );

/// 旧全量跑（两片）→ 合并成「缓存态」明细。
(ShardDetail, DateTime) _cachedDetail() {
  final calendar = tradingCalendar(_oldStocks);
  final cutoff = recentCutoffDate(calendar, _recentWindow)!;
  final msCtx = _msCtx(calendar);
  final detail = mergeShardDetails([
    _scan(_oldStocks.sublist(0, 4), calendar, cutoff, msCtx),
    _scan(_oldStocks.sublist(4), calendar, cutoff, msCtx),
  ]);
  return (detail, cutoff);
}

void _expectSameReport(BacktestReport actual, BacktestReport expected) {
  for (final h in _hs) {
    sameStatsOverall(
        actual.baseline[h]!.stats, expected.baseline[h]!.stats, 'baseline h=$h');
  }
  for (final r in _rules) {
    for (final h in _hs) {
      sameStatsOverall(actual.results[r.id]![h]!.stats,
          expected.results[r.id]![h]!.stats, 'results ${r.id} h=$h');
    }
  }
  for (final y in expected.yearly.keys) {
    for (final r in _rules) {
      for (final h in _hs) {
        sameStats(actual.yearly[y]![r.id]![h]!, expected.yearly[y]![r.id]![h]!,
            'yearly $y ${r.id} h=$h');
      }
    }
  }
  for (final y in expected.yearlyBaseline.keys) {
    for (final h in _hs) {
      sameStats(actual.yearlyBaseline[y]![h]!, expected.yearlyBaseline[y]![h]!,
          'yearlyBaseline $y h=$h');
    }
  }
  for (final r in _rules) {
    for (final h in _hs) {
      final a = actual.signalProfile[r.id]![h]!;
      final b = expected.signalProfile[r.id]![h]!;
      expect(a.signalCount, b.signalCount, reason: 'profile ${r.id} h=$h count');
      expect(a.monthsWithSignals, b.monthsWithSignals,
          reason: 'profile ${r.id} h=$h months');
      expect(a.topMonthShare, b.topMonthShare, reason: 'profile ${r.id} h=$h share');
      expect(a.topMonth, b.topMonth, reason: 'profile ${r.id} h=$h topMonth');
    }
  }
  for (final r in _rules) {
    for (final h in _hs) {
      sameStatsOverall(actual.recent[r.id]![h]!.stats,
          expected.recent[r.id]![h]!.stats, 'recent ${r.id} h=$h');
      expect(actual.recent[r.id]![h]!.dayMeanReturn,
          expected.recent[r.id]![h]!.dayMeanReturn,
          reason: 'recent ${r.id} h=$h dayMeans');
    }
  }
  for (final h in _hs) {
    sameStatsOverall(actual.recentBaseline[h]!.stats,
        expected.recentBaseline[h]!.stats, 'recentBaseline h=$h');
    expect(actual.recentBaseline[h]!.dayMeanReturn,
        expected.recentBaseline[h]!.dayMeanReturn,
        reason: 'recentBaseline h=$h dayMeans');
  }
  expect(actual.marketState!.regime, expected.marketState!.regime);
  expect(actual.marketState!.stockCount, expected.marketState!.stockCount);
  expect(actual.marketState!.asOfDate, expected.marketState!.asOfDate);
  expect(actual.marketState!.maGap, closeTo(expected.marketState!.maGap, 1e-9));
  expect(actual.marketState!.ret20, closeTo(expected.marketState!.ret20, 1e-9));
  expect(actual.marketState!.breadthAboveMa20,
      closeTo(expected.marketState!.breadthAboveMa20, 1e-9));
  expect(actual.marketState!.newHighLowDiff20,
      closeTo(expected.marketState!.newHighLowDiff20, 1e-9));
}

void main() {
  test('增量续扫（追加K线+新股+窗口滚动）与全量重跑一致', () {
    final (cached, _) = _cachedDetail();

    final newCalendar = tradingCalendar(_newStocks);
    final newCutoff = recentCutoffDate(newCalendar, _recentWindow)!;
    final newMsCtx = _msCtx(newCalendar);
    final oldCalendar = tradingCalendar(_oldStocks);
    final oldCutoff = recentCutoffDate(oldCalendar, _recentWindow)!;
    // 窗口确实右移：旧 recent 里滚出窗口的日子必须被过滤
    expect(newCutoff.isAfter(oldCutoff), isTrue);

    final cutoffKey = newCutoff.year * 10000 + newCutoff.month * 100 + newCutoff.day;
    final oldForResume = detailForResume(cached, recentCutoffDayKey: cutoffKey);

    final (report, merged) = mergeAndAggregate([
      oldForResume,
      _scan(_newStocks.sublist(0, 4), newCalendar, newCutoff, newMsCtx,
          resumeLens: _resumeLens),
      _scan(_newStocks.sublist(4), newCalendar, newCutoff, newMsCtx,
          resumeLens: _resumeLens),
    ],
        ruleIds: [for (final r in _rules) r.id],
        hs: _hs,
        recentCutoffDate: newCutoff,
        msCtx: newMsCtx);

    final full = backtestAll(_newStocks, _rules,
        horizons: _hs, recentWindowTradingDays: _recentWindow);
    _expectSameReport(report, full);

    // 合并态明细的每股长度 = 新宇宙的实际长度（下次增量的续扫锚点）
    expect(merged.stockLens, {
      for (final s in _newStocks) s.symbol: s.bars.length,
    });
  });

  test('无新数据（resumeLens=当前长度）结果与全量一致', () {
    final (cached, cutoff) = _cachedDetail();
    final calendar = tradingCalendar(_oldStocks);
    final msCtx = _msCtx(calendar);
    final lens = {for (final s in _oldStocks) s.symbol: s.bars.length};
    final sameForResume =
        detailForResume(cached, recentCutoffDayKey: cutoff.year * 10000 + cutoff.month * 100 + cutoff.day);

    final (report, _) = mergeAndAggregate([
      sameForResume,
      _scan(_oldStocks.sublist(0, 4), calendar, cutoff, msCtx, resumeLens: lens),
      _scan(_oldStocks.sublist(4), calendar, cutoff, msCtx, resumeLens: lens),
    ],
        ruleIds: [for (final r in _rules) r.id],
        hs: _hs,
        recentCutoffDate: cutoff,
        msCtx: msCtx);

    final full = backtestAll(_oldStocks, _rules,
        horizons: _hs, recentWindowTradingDays: _recentWindow);
    _expectSameReport(report, full);
  });

  test('detailForResume 过滤滚出窗口的旧 recent 日，其余原样保留', () {
    final (cached, _) = _cachedDetail();
    const cutoffKey = 20240501;

    final filtered = detailForResume(cached, recentCutoffDayKey: cutoffKey);

    // recent 按日明细：滚出窗口的 dayKey 全部消失，保留的都 ≥ cutoffKey
    for (final h in cached.recentBaseDays!.keys) {
      final before = cached.recentBaseDays![h]!;
      final after = filtered.recentBaseDays![h]!;
      expect(after.length, lessThan(before.length), reason: 'h=$h 应有窗口滚出');
      for (final key in after.keys) {
        expect(key >= cutoffKey, isTrue, reason: 'dayKey $key 应被过滤');
      }
    }
    // overall 明细原样保留（引用相等 = 未拷贝）
    expect(filtered.sigTapes, same(cached.sigTapes));
    expect(filtered.baseTapes, same(cached.baseTapes));
    // 合并时的计数语义：旧明细不贡献 stockCount / msContrib / stockLens
    expect(filtered.stockCount, 0);
    expect(filtered.msContrib, isNull);
    expect(filtered.stockLens, isEmpty);
  });
}
