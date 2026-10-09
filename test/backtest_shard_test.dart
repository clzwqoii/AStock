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

/// 140 根：前 40 根 10.0 → 第 40 根跳到 11.0（+10%，命中 pct_change_up）→ 之后继续上行 →
/// 末尾 94 根停在 14.0。140 根 ≥ maPeriod(120)，使市场状态能实际计算（非 insufficient）。
final _upCloses = <double>[
  ...List.filled(40, 10.0),
  11.0, 11.5, 12.0, 12.5, 13.0, 13.5, // 40..45
  ...List.filled(94, 14.0), // 46..139
];

/// 同形态但之后下跌：同样命中 pct_change_up，前瞻收益为负。
final _downCloses = <double>[
  ...List.filled(40, 10.0),
  11.0, 10.5, 10.0, 9.5, 9.0, 8.5, // 40..45
  ...List.filled(94, 8.0), // 46..139
];

/// 全程横盘：只作基准样本，不出任何涨幅信号。
final _flatCloses = List<double>.filled(140, 10.0);

/// 双精度加法不满足结合律，顺序一变均值就漂——所以这里用精确相等而非 closeTo。
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

/// overall() 统计的容差版：avgReturn/profitFactor/stdDev 依赖 `_sum`/`_gain`/`_loss`
/// 的累积顺序，并行合并的求和序与串行 `add()` 不同 → ulp 级差异。其余字段精确相等。
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

void main() {
  test('并行分片合并与串行 backtestAll 逐位一致', () {
    final rules = [
      ruleById('pct_change_up'),
      ruleById('close_above_ma20'),
      ruleById('ma5_golden_ma10'),
    ];
    const hs = [5, 10];
    const recentWindow = 30;

    final allStocks = [
      stockOfCloses(_upCloses, symbol: 'U1'),
      stockOfCloses(_upCloses, symbol: 'U2'),
      stockOfCloses(_downCloses, symbol: 'D1'),
      stockOfCloses(_downCloses, symbol: 'D2'),
      stockOfCloses(_flatCloses, symbol: 'F1'),
      stockOfCloses(_flatCloses, symbol: 'F2'),
    ];

    final expected = backtestAll(allStocks, rules,
        horizons: hs, recentWindowTradingDays: recentWindow);

    final calendar = tradingCalendar(allStocks);
    final recentCutoff =
        recentCutoffDate(calendar, recentWindow);
    final msCtx = MarketStateCtx.fromCalendar(calendar,
        maPeriod: 120,
        recentDays: 130,
        statWindow: 20,
        maxLastBarLagTradingDays: 20,
        corporateActionLookbackBars: kCorporateActionLookbackBars);

    // 3 个连续分片：[U1,U2], [D1,D2], [F1,F2]
    final shards = [
      scanStocksShard(
        stocks: allStocks.sublist(0, 2),
        rules: rules,
        hs: hs,
        calendar: calendar,
        recentCutoffDate: recentCutoff,
        msCtx: msCtx,
      ),
      scanStocksShard(
        stocks: allStocks.sublist(2, 4),
        rules: rules,
        hs: hs,
        calendar: calendar,
        recentCutoffDate: recentCutoff,
        msCtx: msCtx,
      ),
      scanStocksShard(
        stocks: allStocks.sublist(4, 6),
        rules: rules,
        hs: hs,
        calendar: calendar,
        recentCutoffDate: recentCutoff,
        msCtx: msCtx,
      ),
    ];

    final actual = mergeShards(shards,
        rules: rules,
        hs: hs,
        calendar: calendar,
        recentCutoffDate: recentCutoff,
        msCtx: msCtx);

    // 基准
    for (final h in hs) {
      sameStatsOverall(actual.baseline[h]!.stats, expected.baseline[h]!.stats,
          'baseline h=$h');
    }

    // 规则结果
    for (final r in rules) {
      for (final h in hs) {
        sameStatsOverall(
          actual.results[r.id]![h]!.stats,
          expected.results[r.id]![h]!.stats,
          'results ${r.id} h=$h',
        );
      }
    }

    // 分年
    for (final y in expected.yearly.keys) {
      for (final r in rules) {
        for (final h in hs) {
          sameStats(
            actual.yearly[y]![r.id]![h]!,
            expected.yearly[y]![r.id]![h]!,
            'yearly $y ${r.id} h=$h',
          );
        }
      }
    }

    // 分年基准
    for (final y in expected.yearlyBaseline.keys) {
      for (final h in hs) {
        sameStats(
          actual.yearlyBaseline[y]![h]!,
          expected.yearlyBaseline[y]![h]!,
          'yearlyBaseline $y h=$h',
        );
      }
    }

    // 信号集中度
    for (final r in rules) {
      for (final h in hs) {
        final a = actual.signalProfile[r.id]![h]!;
        final b = expected.signalProfile[r.id]![h]!;
        expect(a.signalCount, b.signalCount,
            reason: 'profile ${r.id} h=$h count');
        expect(a.monthsWithSignals, b.monthsWithSignals,
            reason: 'profile ${r.id} h=$h months');
        expect(a.topMonthShare, b.topMonthShare,
            reason: 'profile ${r.id} h=$h share');
        expect(a.topMonth, b.topMonth,
            reason: 'profile ${r.id} h=$h topMonth');
      }
    }

    // 最近窗口
    for (final r in rules) {
      for (final h in hs) {
        sameStatsOverall(
          actual.recent[r.id]![h]!.stats,
          expected.recent[r.id]![h]!.stats,
          'recent ${r.id} h=$h',
        );
        final aDays = actual.recent[r.id]![h]!.dayMeanReturn;
        final bDays = expected.recent[r.id]![h]!.dayMeanReturn;
        expect(aDays.length, bDays.length,
            reason: 'recent ${r.id} h=$h days len');
        for (final key in bDays.keys) {
          expect(aDays[key], closeTo(bDays[key]!, 1e-9),
              reason: 'recent ${r.id} h=$h day $key');
        }
      }
    }

    // 最近基准
    for (final h in hs) {
      sameStatsOverall(
        actual.recentBaseline[h]!.stats,
        expected.recentBaseline[h]!.stats,
        'recentBaseline h=$h',
      );
      final aDays = actual.recentBaseline[h]!.dayMeanReturn;
      final bDays = expected.recentBaseline[h]!.dayMeanReturn;
      expect(aDays.length, bDays.length,
          reason: 'recentBaseline h=$h days len');
      for (final key in bDays.keys) {
        expect(aDays[key], closeTo(bDays[key]!, 1e-9),
            reason: 'recentBaseline h=$h day $key');
      }
    }

    // 市场状态：ulp 级差异用 closeTo，枚举/计数/日期精确相等
    expect(
        actual.marketState!.regime, expected.marketState!.regime);
    expect(actual.marketState!.stockCount,
        expected.marketState!.stockCount);
    expect(actual.marketState!.asOfDate,
        expected.marketState!.asOfDate);
    expect(actual.marketState!.maGap,
        closeTo(expected.marketState!.maGap, 1e-9));
    expect(actual.marketState!.ret20,
        closeTo(expected.marketState!.ret20, 1e-9));
    expect(
        actual.marketState!.breadthAboveMa20,
        closeTo(
            expected.marketState!.breadthAboveMa20, 1e-9));
    expect(
        actual.marketState!.newHighLowDiff20,
        closeTo(
            expected.marketState!.newHighLowDiff20, 1e-9));
  });

  // ── 预排序收尾：worker 就地排序各年桶，主 isolate 对有序桶走 k 路归并，
  //    免掉收尾 10s 级的整体重排（实测 bucketSort 是聚合阶段最大头）。──

  test('scanStocksShard 快照的各年桶已升序（收尾免重排的前提）', () {
    final rules = [ruleById('pct_change_up')];
    const hs = [5, 10];
    final stocks = [
      stockOfCloses(_upCloses, symbol: 'U1'),
      stockOfCloses(_downCloses, symbol: 'D1'),
    ];
    final calendar = tradingCalendar(stocks);
    final shard = scanStocksShard(
      stocks: stocks,
      rules: rules,
      hs: hs,
      calendar: calendar,
    );
    void expectSorted(Map<int, List<double>> byYear, String what) {
      for (final e in byYear.entries) {
        for (var i = 1; i < e.value.length; i++) {
          expect(e.value[i] >= e.value[i - 1], isTrue,
              reason: '$what ${e.key} 年桶在 $i 处降序：'
                  '${e.value[i - 1]} → ${e.value[i]}');
        }
      }
    }

    for (final byH in shard.sigTapes.values) {
      for (final e in byH.entries) {
        expectSorted(e.value.byYear, 'sig h=${e.key}');
      }
    }
    for (final e in shard.baseTapes.entries) {
      expectSorted(e.value.byYear, 'base h=${e.key}');
    }
  });

  test('mergeShardDetails：有序分片合并后各年桶 = 拼接后升序（逐位）', () {
    final rules = [ruleById('pct_change_up')];
    const hs = [5, 10];
    final stocks = [
      stockOfCloses(_upCloses, symbol: 'U1'),
      stockOfCloses(_downCloses, symbol: 'D1'),
      stockOfCloses(_flatCloses, symbol: 'F1'),
    ];
    final calendar = tradingCalendar(stocks);
    final shards = [
      for (final s in stocks)
        scanStocksShard(stocks: [s], rules: rules, hs: hs, calendar: calendar),
    ];
    final merged = mergeShardDetails(shards);
    for (final h in hs) {
      final byYear = merged.baseTapes[h]!.byYear;
      expect(byYear.keys.toSet(),
          {for (final s in shards) ...s.baseTapes[h]!.byYear.keys},
          reason: 'base h=$h 年键并集');
      for (final y in byYear.keys) {
        final ref = [
          for (final s in shards) ...?s.baseTapes[h]!.byYear[y],
        ]..sort();
        expect(byYear[y], ref, reason: 'base h=$h y=$y 桶序');
      }
    }
  });

  test('mergeShardDetails：无序分片（旧缓存格式）统计仍正确（拼接回退路径）', () {
    TapeSnapshot scrambled(TapeSnapshot s) => TapeSnapshot(
          byYear: {
            for (final e in s.byYear.entries) e.key: e.value.reversed.toList(),
          },
          byMonth: s.byMonth,
          count: s.count,
          sum: s.sum,
          gain: s.gain,
          loss: s.loss,
          wins: s.wins,
          best: s.best,
          worst: s.worst,
        );

    final rules = [ruleById('pct_change_up')];
    const hs = [5, 10];
    final stocks = [
      stockOfCloses(_upCloses, symbol: 'U1'),
      stockOfCloses(_downCloses, symbol: 'D1'),
      stockOfCloses(_flatCloses, symbol: 'F1'),
    ];
    final calendar = tradingCalendar(stocks);
    final shards = [
      for (final s in stocks)
        scanStocksShard(stocks: [s], rules: rules, hs: hs, calendar: calendar),
    ];
    final normal = mergeShardDetails(shards);

    // 模拟旧格式缓存：把第一个分片的桶反转（多重集不变，桶序不再升序）
    final s0 = shards[0];
    shards[0] = ShardDetail(
      stockCount: s0.stockCount,
      sigTapes: {
        for (final e in s0.sigTapes.entries)
          e.key: {
            for (final he in e.value.entries) he.key: scrambled(he.value),
          },
      },
      baseTapes: {
        for (final e in s0.baseTapes.entries) e.key: scrambled(e.value),
      },
      recentSigDays: s0.recentSigDays,
      recentBaseDays: s0.recentBaseDays,
      stockLens: s0.stockLens,
    );
    final fromOldCache = mergeShardDetails(shards);

    const id = 'pct_change_up';
    final rn = aggregateDetail(normal, ruleIds: [id], hs: hs, msCtx: null);
    final rs = aggregateDetail(fromOldCache, ruleIds: [id], hs: hs, msCtx: null);
    // 分年统计走 _statsOfSorted：桶多重集相同 → 逐位一致
    for (final y in rn.yearly.keys) {
      for (final h in hs) {
        sameStats(rs.yearly[y]![id]![h]!, rn.yearly[y]![id]![h]!,
            '旧缓存格式 y=$y h=$h');
      }
    }
    for (final h in hs) {
      sameStatsOverall(rs.results[id]![h]!.stats, rn.results[id]![h]!.stats,
          '旧缓存格式 overall h=$h');
      sameStatsOverall(rs.baseline[h]!.stats, rn.baseline[h]!.stats,
          '旧缓存格式 baseline h=$h');
    }
  });
}
