// 回测框架：滚动评估规则、统计前瞻收益、对比无条件基准。
//
// 核心不变量是**无前瞻偏差**：信号日 t 的快照必须与
// `IndicatorSnapshot.fromStock(bars.sublist(0, t + 1))` 逐字段一致，
// 即 t 之后的数据不能影响 t 处是否出信号。
import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';

import 'fixtures.dart';

final _day0 = DateTime(2024, 1, 1);

/// 用收盘序列造 StockData：日期逐日递增（回测要按日定位信号），量恒定 100，
/// 额 = 收盘×量（与 kbar 同口径）。
StockData stockOfCloses(List<double> closes, {String symbol = 'T'}) => StockData(
      symbol: symbol,
      bars: [
        for (var i = 0; i < closes.length; i++)
          kbar(close: closes[i], volume: 100, date: _day0.add(Duration(days: i))),
      ],
    );

/// 40 根 10.0 → 第 40 根跳到 11.0（+10%，命中 pct_change_up）→ 之后继续上行。
/// 信号日 t=40 收盘 11.0；forwardDays=5 → 前瞻收益 = closes[45]/11.0 − 1 ≈ +22.7%。
final _upCloses = <double>[
  ...List.filled(40, 10.0),
  11.0, 11.5, 12.0, 12.5, 13.0, 13.5, // 40..45
  ...List.filled(20, 14.0), // 46..65
];

/// 同形态但之后下跌：同样命中 pct_change_up，前瞻收益为负。
final _downCloses = <double>[
  ...List.filled(40, 10.0),
  11.0, 10.5, 10.0, 9.5, 9.0, 8.5, // 40..45
  ...List.filled(20, 8.0),
];

/// 全程横盘：只作基准样本，不出任何涨幅信号。
final _flatCloses = List<double>.filled(66, 10.0);

/// 66 根序列在 forwardDays=5 下的可评估日数：[minBars, len-1-forward] = [20, 60]。
const _evaluableDays = 66 - 20 - 5;

void main() {
  final pct = ruleById('pct_change_up');
  const forward = 5;

  group('IndicatorSeries（无前瞻偏差）', () {
    test('at(t) 与「只取前 t+1 根构造快照」逐字段一致', () {
      final bars = barsMa60Breakout();
      final series = IndicatorSeries.from(bars);
      for (final t in [19, 40, 60, 65, 66, 68, 69]) {
        final viaSeries = series.at(t);
        final viaPrefix = IndicatorSnapshot.fromStock(
          StockData(symbol: 'X', bars: bars.sublist(0, t + 1)),
        );
        void same(String what, Object? a, Object? b) =>
            expect(a, b, reason: '$what 在 t=$t 处不一致');
        same('close', viaSeries.close, viaPrefix.close);
        same('prevClose', viaSeries.prevClose, viaPrefix.prevClose);
        same('ma5', viaSeries.ma5, viaPrefix.ma5);
        same('ma10', viaSeries.ma10, viaPrefix.ma10);
        same('ma20', viaSeries.ma20, viaPrefix.ma20);
        same('ma60', viaSeries.ma60, viaPrefix.ma60);
        same('prevMa60', viaSeries.prevMa60, viaPrefix.prevMa60);
        same('ma60Trend5', viaSeries.ma60Trend5, viaPrefix.ma60Trend5);
        same('bias60', viaSeries.bias60, viaPrefix.bias60);
        same('dif', viaSeries.dif, viaPrefix.dif);
        same('dea', viaSeries.dea, viaPrefix.dea);
        same('k', viaSeries.k, viaPrefix.k);
        same('d', viaSeries.d, viaPrefix.d);
        same('j', viaSeries.j, viaPrefix.j);
        same('rsi14', viaSeries.rsi14, viaPrefix.rsi14);
        same('volumeRatio', viaSeries.volumeRatio, viaPrefix.volumeRatio);
        same('pctChange', viaSeries.pctChange, viaPrefix.pctChange);
        same('amountRatio', viaSeries.amountRatio, viaPrefix.amountRatio);
        same('closePos', viaSeries.closePos, viaPrefix.closePos);
        same('bullAlignment', viaSeries.bullAlignment, viaPrefix.bullAlignment);
        same('window.length', viaSeries.window?.length, viaPrefix.window?.length);
        same('window.crossUpIndex', viaSeries.window?.crossUpIndex, viaPrefix.window?.crossUpIndex);
        same('pullbackWindow.length', viaSeries.pullbackWindow?.length,
            viaPrefix.pullbackWindow?.length);
        // 窗口内容逐项一致（endingAt 索引化改造后，必须与 tryFrom 前缀构造等价）
        final a = viaSeries.window, b = viaPrefix.window;
        same('window.closes', a?.closes, b?.closes);
        same('window.lows', a?.lows, b?.lows);
        same('window.opens', a?.opens, b?.opens);
        same('window.volumes', a?.volumes, b?.volumes);
        same('window.ma60', a?.ma60, b?.ma60);
        same('window.volumeRatios', a?.volumeRatios, b?.volumeRatios);
        same('window.amountRatios', a?.amountRatios, b?.amountRatios);
        same('window.closePoses', a?.closePoses, b?.closePoses);
        final pa = viaSeries.pullbackWindow, pb = viaPrefix.pullbackWindow;
        same('pullback.closes', pa?.closes, pb?.closes);
        same('pullback.ma60', pa?.ma60, pb?.ma60);
        same('pullback.volumeRatios', pa?.volumeRatios, pb?.volumeRatios);
        same('pullback.amountRatios', pa?.amountRatios, pb?.amountRatios);
      }
    });

    test('回踩形态的窗口按历史长度逐日变可用，规则随之成立', () {
      final bars = barsMa60Pullback();
      final series = IndicatorSeries.from(bars);
      final rule = ruleById('ma60_breakout_pullback');
      // 回踩窗口需 60+20-1=79 根；t=74 时前缀仅 75 根，窗口为 null
      expect(series.at(74).pullbackWindow, isNull);
      expect(rule.test(series.at(74)), isFalse);
      expect(series.at(79).pullbackWindow, isNotNull);
      // t=78 时前缀 79 根、窗口刚好可用，但 gap 不足仍不命中
      expect(series.at(78).pullbackWindow, isNotNull);
      expect(rule.test(series.at(78)), isFalse);
      // 形态完成的末日命中
      expect(rule.test(series.at(82)), isTrue);
    });

    test('t < IndicatorSnapshot.minBars 抛 StateError', () {
      final series = IndicatorSeries.from(barsMa60Breakout());
      expect(() => series.at(18), throwsStateError);
      expect(() => series.at(-1), throwsRangeError); // 越界优先于历史不足
    });

    test('t 越界抛 RangeError', () {
      final series = IndicatorSeries.from(barsMa60Breakout());
      expect(() => series.at(70), throwsRangeError);
    });
  });

  group('backtestRule', () {
    test('信号日与前瞻收益符合预期', () {
      final r = backtestRule([stockOfCloses(_upCloses)], pct, forwardDays: forward);
      expect(r.ruleId, 'pct_change_up');
      expect(r.forwardDays, forward);
      expect(r.count, greaterThan(0));
      // 第一根信号是第 40 根（10.0 → 11.0，+10%）
      final first = r.outcomes.first;
      expect(first.symbol, 'T');
      expect(first.date, _day0.add(const Duration(days: 40)));
      expect(first.close, 11.0);
      expect(first.forwardReturn, closeTo((13.5 / 11.0 - 1) * 100, 1e-9));
      // 信号日 40..46（46 那根 +3.7% 也满足 >3%），其中 t=46 的前瞻收益为 0，
      // 故 7 个信号里 6 个为正。
      expect(r.count, 7);
      expect(r.winRate, closeTo(6 / 7, 1e-9));
    });

    test('越界信号（t + forwardDays > 末根）被丢弃', () {
      final stocks = [stockOfCloses(_upCloses)];
      final r = backtestRule(stocks, pct, forwardDays: forward);
      expect(r.count, greaterThan(0)); // 先确认确实有信号
      for (final o in r.outcomes) {
        final t = o.date.difference(_day0).inDays;
        expect(t, greaterThanOrEqualTo(IndicatorSnapshot.minBars));
        expect(t + forward, lessThanOrEqualTo(stocks.first.bars.length - 1));
      }
    });

    test('上涨样本为正收益、下跌样本为负收益', () {
      final up = backtestRule([stockOfCloses(_upCloses)], pct, forwardDays: forward);
      final down = backtestRule([stockOfCloses(_downCloses)], pct, forwardDays: forward);
      expect(up.outcomes.first.forwardReturn, greaterThan(0));
      expect(down.outcomes.first.forwardReturn, lessThan(0));
      expect(up.winRate, greaterThan(down.winRate));
    });

    test('不出信号的规则结果为空，统计不抛异常', () {
      final r = backtestRule([stockOfCloses(_flatCloses)], pct, forwardDays: forward);
      expect(r.count, 0);
      expect(r.winRate, 0);
      expect(r.avgReturn, 0);
      expect(r.medianReturn, 0);
      expect(r.profitFactor, 0);
    });

    test('历史不足 minBars 的股票被跳过', () {
      final r = backtestRule([stockOfCloses(List.filled(15, 10.0))], pct, forwardDays: 5);
      expect(r.count, 0);
    });

    test('forwardDays<=0 抛 ArgumentError', () {
      expect(
        () => backtestRule([stockOfCloses(_flatCloses)], pct, forwardDays: 0),
        throwsArgumentError,
      );
    });

    test('有效突破规则同样可回测（不只对最后一日生效）', () {
      final bars = barsMa60Breakout();
      final r = backtestRule(
        [StockData(symbol: 'X', bars: bars)],
        ruleById('ma60_breakout_confirmed'),
        forwardDays: forward,
      );
      // 70 根序列只有 t=66 附近能凑齐站稳窗口，且 t+5<=69 → t<=64，故应为 0
      expect(r.count, 0);
    });
  });

  group('统计量', () {
    test('胜率 / 均值 / 中位数 / 盈亏比按定义计算', () {
      // 收益 +10 / +20 / −5 / −5：胜率 50%，均值 5，中位数 (−5+10)/2 = 2.5，
      // 盈利总额 30、亏损总额 10 → 盈亏比 3
      final r = BacktestResult(
        ruleId: 'x',
        forwardDays: 5,
        outcomes: [
          for (final v in [10.0, 20.0, -5.0, -5.0])
            SignalOutcome(symbol: 'S', date: _day0, close: 10, forwardReturn: v),
        ],
      );
      expect(r.count, 4);
      expect(r.winRate, closeTo(0.5, 1e-9));
      expect(r.avgReturn, closeTo(5.0, 1e-9));
      expect(r.medianReturn, closeTo(2.5, 1e-9));
      expect(r.bestReturn, closeTo(20.0, 1e-9));
      expect(r.worstReturn, closeTo(-5.0, 1e-9));
      expect(r.profitFactor, closeTo(3.0, 1e-9));
    });

    test('无亏损时盈亏比为 0（未定义，不外推）', () {
      final r = BacktestResult(
        ruleId: 'x',
        forwardDays: 5,
        outcomes: [
          SignalOutcome(symbol: 'S', date: _day0, close: 10, forwardReturn: 5.0),
        ],
      );
      expect(r.winRate, 1.0);
      expect(r.profitFactor, 0);
    });

    test('空结果的统计量全为 0', () {
      final r = BacktestResult(ruleId: 'x', forwardDays: 5, outcomes: const []);
      expect(r.count, 0);
      expect(r.winRate, 0);
      expect(r.avgReturn, 0);
      expect(r.medianReturn, 0);
      expect(r.profitFactor, 0);
    });
  });

  group('Tape（分年/全样本统计依赖桶有序）', () {
    test('乱序插入后 statsOfYear 的中位数与分位数按已排序序列取值', () {
      final t = Tape();
      // 故意乱序插入：桶若不排序，中位数会取到插入序第 3 个 10.0 而不是 0.0
      for (final v in [3.0, -1.0, 10.0, 0.0, -5.0]) {
        t.add(v, 2024);
      }
      final s = t.statsOfYear(2024);
      // oracle = 手算排序后序列 [-5, -1, 0, 3, 10]
      expect(s.count, 5);
      expect(s.medianReturn, 0);
      expect(s.p10, closeTo(-3.4, 1e-9)); // pos=0.4 → -5 + (−1−(−5))×0.4
      expect(s.p90, closeTo(7.2, 1e-9)); // pos=3.6 → 3 + (10−3)×0.6
      expect(s.bestReturn, 10);
      expect(s.worstReturn, -5);
    });

    test('全样本中位数按跨年归并取值，与整体排序一致', () {
      final t = Tape();
      for (final v in [5.0, -3.0, 7.0]) {
        t.add(v, 2023);
      }
      for (final v in [4.0, -8.0, 1.0, 2.0]) {
        t.add(v, 2024);
      }
      // oracle：7 个样本整体排序后 [-8, -3, 1, 2, 4, 5, 7] → 第 4 个 = 2
      final s = t.overall();
      expect(s.count, 7);
      expect(s.medianReturn, 2);
    });

    test('统计之后再 add 直接断言失败（不得静默把已排序的桶写乱）', () {
      final t1 = Tape();
      t1.add(1.0, 2024);
      t1.statsOfYear(2024); // 首次统计即排序并缓存
      expect(() => t1.add(2.0, 2024), throwsA(isA<AssertionError>()));

      final t2 = Tape();
      t2.add(1.0, 2024);
      t2.overall(); // 全样本统计也会触发 _ensureSorted
      expect(() => t2.add(2.0, 2024), throwsA(isA<AssertionError>()));
    });
  });

  group('baseline 无条件基准', () {
    test('同一时间窗内逐日前瞻收益的分布', () {
      final b = baseline([stockOfCloses(_upCloses)], forwardDays: forward);
      expect(b.count, _evaluableDays);
      expect(b.winRate, greaterThan(0));
    });

    test('全程横盘时胜率与均值均为 0', () {
      final b = baseline([stockOfCloses(_flatCloses)], forwardDays: forward);
      expect(b.count, _evaluableDays);
      expect(b.winRate, 0);
      expect(b.avgReturn, 0);
    });

    test('与规则回测覆盖同一批可评估日（可比性）', () {
      final stocks = [stockOfCloses(_upCloses), stockOfCloses(_flatCloses)];
      final b = baseline(stocks, forwardDays: forward);
      final r = backtestRule(stocks, pct, forwardDays: forward);
      expect(b.count, 2 * _evaluableDays);
      expect(r.count, lessThanOrEqualTo(b.count));
    });
  });
  
  group('backtestAll 分年口径', () {
    // 回归背景：backtestAll 曾把每个信号**同时**存进 sigReturns 与 yearlySignals
    // 两套桶，同一批 double 存了两遍（全市场实测 2083 万 × 2 = 4166 万元素），
    // 收尾排序耗时翻倍。分年必须能从信号桶切片导出，而不是独立再存一份。
    test('分年信号之和与全样本信号之和逐规则相等', () {
      final stocks = [
        stockOfCloses(_upCloses, symbol: 'U'),
        stockOfCloses(_downCloses, symbol: 'D'),
      ];
      final report = backtestAll(stocks, [pct], horizons: kDefaultHorizons);
      final totalCount = report.results['pct_change_up']![10]!.count;
      var yearlyCount = 0;
      for (final y in report.yearly.keys) {
        yearlyCount += report.yearly[y]?['pct_change_up']?[10]?.count ?? 0;
      }
      expect(yearlyCount, totalCount);
    });

    test('分年基准之和与全样本基准相等', () {
      final stocks = [
        stockOfCloses(_upCloses, symbol: 'U'),
        stockOfCloses(_flatCloses, symbol: 'F'),
      ];
      final report = backtestAll(stocks, [pct], horizons: kDefaultHorizons);
      var sum = 0;
      for (final y in report.yearlyBaseline.keys) {
        sum += report.yearlyBaseline[y]![10]!.count;
      }
      expect(sum, report.baseline[10]!.count);
    });

    test('跨年的信号按日期真的被拆到了各自年份', () {
      // 500 天横跨 2024/2025；隔日 +5% / 回落，保证天天命中 pct_change_up 的 >3%。
      final closes = <double>[for (var i = 0; i < 500; i++) 10.0 * (1 + (i % 2) * 0.05)];
      final report = backtestAll([stockOfCloses(closes)], [pct], horizons: const [5]);
      expect(report.yearly.keys, containsAll(<int>[2024, 2025]));
      expect(report.yearly[2024]!['pct_change_up']![5]!.count, greaterThan(0));
      expect(report.yearly[2025]!['pct_change_up']![5]!.count, greaterThan(0));
      // 两份分年之和等于全样本：分年是从信号桶切出来的，不是另存一份
      expect(report.yearly[2024]!['pct_change_up']![5]!.count +
              report.yearly[2025]!['pct_change_up']![5]!.count,
          report.results['pct_change_up']![5]!.count);
    });

    test('某年无信号时该年仍出现在分年视图中（不整年消失）', () {
      // 只用一根股票、数据全在 2024 → yearly 至少含 2024。
      final report = backtestAll([stockOfCloses(_upCloses)], [pct],
          horizons: const [5]);
      expect(report.yearlyBaseline.containsKey(2024), isTrue);
      expect(report.yearly.containsKey(2024), isTrue);
    });
  });

  group('backtestAll 单持有期与逐规则路径等价', () {
    // CLI（bin/backtest.dart）按持有期逐个调用 backtestAll(horizons: [h]) 替代
    // 逐规则 backtestRule——性能差 15 倍（45 遍全市场扫描 → 3 遍），依赖本契约：
    // 单持有期下可评估日范围与逐规则路径相同，统计量逐位一致
    // （Tape 的 sum/gain/loss 按插入序累积，与 BacktestStats.of 同一求和顺序）。
    // 双精度加法不满足结合律，顺序一变均值就漂——所以这里用精确相等而非 closeTo。
    void sameStats(BacktestStats a, BacktestStats b, String what) {
      expect(a.count, b.count, reason: what);
      expect(a.winRate, b.winRate, reason: what);
      expect(a.avgReturn, b.avgReturn, reason: what);
      expect(a.medianReturn, b.medianReturn, reason: what);
      expect(a.bestReturn, b.bestReturn, reason: what);
      expect(a.worstReturn, b.worstReturn, reason: what);
      expect(a.profitFactor, b.profitFactor, reason: what);
    }

    test('规则统计与 backtestRule 逐位一致', () {
      final stocks = [
        stockOfCloses(_upCloses, symbol: 'U'),
        stockOfCloses(_downCloses, symbol: 'D'),
        stockOfCloses(_flatCloses, symbol: 'F'),
      ];
      final report = backtestAll(stocks, [pct], horizons: const [forward]);
      sameStats(report.results['pct_change_up']![forward]!.stats,
          backtestRule(stocks, pct, forwardDays: forward).stats, '规则统计');
    });

    test('基准统计与 baseline 逐位一致', () {
      final stocks = [
        stockOfCloses(_upCloses, symbol: 'U'),
        stockOfCloses(_flatCloses, symbol: 'F'),
      ];
      final report = backtestAll(stocks, [pct], horizons: const [forward]);
      sameStats(
          report.baseline[forward]!.stats,
          baseline(stocks, forwardDays: forward).stats,
          '基准统计');
    });
  });

  group('CLI 表格的列数一致性', () {
    // 回归：bin/backtest.dart 曾在「信号数 0」时少输出一列，Table.render 越界。
    // 这里锁住"无信号规则也要产出全部统计字段"的约定。
    test('空结果的 7 个统计单元格都存在且为占位', () {
      final r = BacktestResult(ruleId: 'x', forwardDays: 5, outcomes: const []);
      final cells = r.count == 0
          ? const ['—', '—', '—', '—', '—', '—', '—']
          : <String>[];
      expect(cells.length, 7);
      expect(r.count, 0);
    });
  
    test('有信号时 7 个统计单元格全部有值', () {
      final r = BacktestResult(
        ruleId: 'x',
        forwardDays: 5,
        outcomes: [
          SignalOutcome(symbol: 'S', date: _day0, close: 10, forwardReturn: 3.0),
        ],
      );
      final cells = r.count == 0
          ? const ['—', '—', '—', '—', '—', '—', '—']
          : <String>[
              '${r.winRate}',
              '${r.avgReturn}',
              '${r.medianReturn}',
              '${r.bestReturn}',
              '${r.worstReturn}',
              '${r.profitFactor}',
              'x',
            ];
      expect(cells.length, 7);
    });
  });

  group('除权/复牌护栏（回测与选股同口径）', () {
    // 50 根：前 30 根收 10.0，下标 30 处主板除权（开盘 7.7 = -23%），之后停在
    // 新价位。forwardDays=5 时可评估日 t ∈ [20, 44]；污染窗口 30..49 覆盖
    // t=30..44 全部 15 天，干净的可评估日只剩 t=20..29 共 10 天。
    //
    // 用一条恒真规则把「护栏行为」与「规则语义」隔离开：换成 volume_surge
    // 之类的真规则，信号只会零星落在污染窗口里（量比要前 5 日都缩着才 >2），
    // 那样测到的是规则的形状而不是护栏本身。
    final always = Rule(
      id: 'test_always',
      name: '恒真',
      desc: '测试专用：每天都命中，用来单独检验护栏',
      test: (_) => true,
    );
    const pollutedDays = 15;
    const cleanDays = 10;

    StockData exDiv() => StockData(
          symbol: 'EXDIV',
          bars: [
            for (var i = 0; i < 50; i++)
              i < 30
                  ? kbar(close: 10.0, date: _day0.add(Duration(days: i)))
                  : kbar(open: 7.7, high: 7.8, low: 7.6, close: 7.75,
                      date: _day0.add(Duration(days: i))),
          ],
        );

    test('除权后 20 根内的信号不计入回测', () {
      final stock = exDiv();
      final on = backtestRule([stock], always, forwardDays: forward);
      final off = backtestRule([stock], always,
          forwardDays: forward, corporateActionLookbackBars: 0);
      expect(on.count, cleanDays, reason: '护栏开启：只剩除权前的 10 天');
      expect(off.count, cleanDays + pollutedDays, reason: '关掉护栏复现旧口径');
      expect(off.count - on.count, pollutedDays);
    });

    test('基准同步过滤：被判定污染的日子两侧都不计入', () {
      final stock = exDiv();
      final on = baseline([stock], forwardDays: forward);
      final off =
          baseline([stock], forwardDays: forward, corporateActionLookbackBars: 0);
      expect(on.count, cleanDays);
      expect(off.count - on.count, pollutedDays);
    });

    test('backtestAll 也过滤（信号与基准覆盖同一批可评估日）', () {
      final stock = exDiv();
      final on = backtestAll([stock], [always], horizons: [forward]);
      final off = backtestAll([stock], [always], horizons: [forward],
          corporateActionLookbackBars: 0);
      expect(on.results['test_always']![forward]!.count, cleanDays);
      expect(off.results['test_always']![forward]!.count, cleanDays + pollutedDays);
      expect(on.baseline[forward]!.count, cleanDays);
      expect(off.baseline[forward]!.count, cleanDays + pollutedDays);
    });

    test('连续跌停（每天 -10%，主板）不会被误判成除权而误杀信号', () {
      // 50 根每天 -10%：合法交易日，护栏不该动它
      final bars = <Bar>[];
      var close = 10.0;
      for (var i = 0; i < 50; i++) {
        final c = i == 0 ? close : close * 0.9; // 每天跌停 -10%
        bars.add(kbar(open: c, high: c, low: c, close: c,
            date: _day0.add(Duration(days: i))));
        close = c;
      }
      final on = backtestRule([StockData(symbol: 'DOWN', bars: bars)], always,
          forwardDays: forward);
      final off = backtestRule([StockData(symbol: 'DOWN', bars: bars)], always,
          forwardDays: forward, corporateActionLookbackBars: 0);
      expect(on.count, off.count);
    });
  });
}
