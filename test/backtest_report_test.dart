// backtestAll：一遍扫描出全规则 × 全持有期报告，以及 JSON 落盘往返。
//
// 关键：backtestAll 统一用「最大持有期」的可评估范围，好让三个持有期覆盖同一批
// 交易日、彼此可比；因此只在最大持有期上，它才与逐规则调 backtestRule 的数目相等。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/report_store.dart';

import 'fixtures.dart';

final _day0 = DateTime(2024, 1, 1);

StockData stockOfCloses(List<double> closes, {String symbol = 'T'}) => StockData(
      symbol: symbol,
      bars: [
        for (var i = 0; i < closes.length; i++)
          kbar(close: closes[i], volume: 100, date: _day0.add(Duration(days: i))),
      ],
    );

void main() {
  // 40 根 10.0 → 跳到 11.0 → 之后线性上行。pct_change_up 在 40..46 命中。
  final up = stockOfCloses(<double>[
    ...List.filled(40, 10.0),
    11.0, 11.5, 12.0, 12.5, 13.0, 13.5,
    ...List.filled(20, 14.0),
  ]);
  final flat = stockOfCloses(List<double>.filled(66, 10.0), symbol: 'F');
  final rules = [ruleById('pct_change_up'), ruleById('close_above_ma20')];

  group('backtestAll', () {
    // 注意：backtestAll 统一用「最大持有期」的可评估范围，好让三个持有期覆盖
    // 同一批交易日、彼此可比。所以只在最大持有期上，它才与逐规则跑的数目相等。
    test('在最大持有期上与逐规则调 backtestRule 完全一致', () {
      final stocks = [up, flat];
      final report = backtestAll(stocks, rules, horizons: kDefaultHorizons);
      final maxH = kDefaultHorizons.reduce((a, b) => a > b ? a : b);
      for (final r in rules) {
        final viaAll = report.result(r.id, maxH)!;
        final viaOne = backtestRule(stocks, r, forwardDays: maxH);
        expect(viaAll.count, viaOne.count, reason: '${r.id} @$maxH 信号数');
        expect(viaAll.winRate, closeTo(viaOne.winRate, 1e-12));
        expect(viaAll.avgReturn, closeTo(viaOne.avgReturn, 1e-12));
        expect(viaAll.medianReturn, closeTo(viaOne.medianReturn, 1e-12));
        expect(viaAll.profitFactor, closeTo(viaOne.profitFactor, 1e-12));
      }
    });

    test('基准在最大持有期上与 baseline() 一致', () {
      final stocks = [up, flat];
      final report = backtestAll(stocks, rules, horizons: kDefaultHorizons);
      final maxH = kDefaultHorizons.reduce((a, b) => a > b ? a : b);
      final b = report.baseline[maxH]!;
      final single = baseline(stocks, forwardDays: maxH);
      expect(b.count, single.count);
      expect(b.winRate, closeTo(single.winRate, 1e-12));
      expect(b.avgReturn, closeTo(single.avgReturn, 1e-12));
    });

    test('非最大持有期覆盖的交易日更少（范围统一到最大持有期，保证可比）', () {
      final stocks = [up];
      final report = backtestAll(stocks, rules, horizons: kDefaultHorizons);
      final counts = [for (final h in kDefaultHorizons) report.baseline[h]!.count];
      // 66 根：范围 = [20, 66-1-20] = 26 天，与持有期无关
      expect(counts, everyElement(26));
      // 而单独跑 baseline 时，短持有期能覆盖更多天
      expect(baseline(stocks, forwardDays: 5).count, greaterThan(26));
    });

    test(' horizons 升序、股票数、生成时间都记录', () {
      final report = backtestAll([up], rules, horizons: const [20, 5]);
      expect(report.horizons, [5, 20]);
      expect(report.stockCount, 1);
      expect(report.generatedAt, isNotEmpty);
      expect(DateTime.parse(report.generatedAt), isNotNull);
    });

    test('horizons 为空或非正抛 ArgumentError', () {
      expect(() => backtestAll([up], rules, horizons: const []), throwsArgumentError);
      expect(() => backtestAll([up], rules, horizons: const [0]), throwsArgumentError);
      expect(() => backtestAll([up], rules, horizons: const [-5]), throwsArgumentError);
    });

    test('全部内置规则都能一次跑完（15 条 × 3 持有期）', () {
      final report = backtestAll(
        [up, flat],
        builtInRules,
        horizons: kDefaultHorizons,
      );
      expect(report.results.length, builtInRules.length);
      for (final r in builtInRules) {
        for (final h in kDefaultHorizons) {
          expect(report.result(r.id, h), isNotNull, reason: r.id);
        }
      }
    });

    test('结果可通过 ruleId + horizon 取到，缺失返回 null', () {
      final report = backtestAll([up], rules, horizons: const [5]);
      expect(report.result('pct_change_up', 5), isNotNull);
      expect(report.result('pct_change_up', 10), isNull);
      expect(report.result('不存在的规则', 5), isNull);
    });

    test('报告只带统计量，不携带逐日明细', () {
      // 全市场规模下逐日明细是数百万个对象（baseline returns ~650 万 double、
      // 热门规则数百万 SignalOutcome）；报告要经 Isolate.run 拷回主 isolate
      // 并被外壳常驻持有，明细必须在扫描 isolate 内消化成统计量后丢弃。
      final report = backtestAll([up, flat], rules, horizons: kDefaultHorizons);
      // 统计照旧（另有测试与 backtestRule/baseline 逐位对比）
      expect(report.baseline[kDefaultHorizons.last]!.count, greaterThan(0));
      expect(report.result('pct_change_up', kDefaultHorizons.last)!.count,
          greaterThan(0));
      // 明细不随报告返回
      for (final h in kDefaultHorizons) {
        expect(report.baseline[h]!.returns, isEmpty, reason: 'baseline@$h');
      }
      for (final r in rules) {
        for (final h in kDefaultHorizons) {
          expect(report.result(r.id, h)!.outcomes, isEmpty,
              reason: '${r.id}@$h');
        }
      }
    });
  });

  group('JSON 往返', () {
    test('BacktestReport 落盘再读回完全一致', () {
      final report = backtestAll([up, flat], rules, horizons: kDefaultHorizons);
      final restored = BacktestReport.fromJson(report.toJson());

      expect(restored.generatedAt, report.generatedAt);
      expect(restored.horizons, report.horizons);
      expect(restored.stockCount, report.stockCount);
      for (final h in kDefaultHorizons) {
        expect(restored.baseline[h]!.count, report.baseline[h]!.count);
        expect(restored.baseline[h]!.winRate, closeTo(report.baseline[h]!.winRate, 1e-12));
        expect(restored.baseline[h]!.avgReturn, closeTo(report.baseline[h]!.avgReturn, 1e-12));
      }
      for (final r in rules) {
        for (final h in kDefaultHorizons) {
          final a = restored.result(r.id, h)!, b = report.result(r.id, h)!;
          expect(a.count, b.count);
          expect(a.winRate, closeTo(b.winRate, 1e-12));
          expect(a.avgReturn, closeTo(b.avgReturn, 1e-12));
          expect(a.medianReturn, closeTo(b.medianReturn, 1e-12));
          expect(a.bestReturn, closeTo(b.bestReturn, 1e-12));
          expect(a.worstReturn, closeTo(b.worstReturn, 1e-12));
          expect(a.profitFactor, closeTo(b.profitFactor, 1e-12));
          // 报告本身就不携带逐信号明细（统计在扫描 isolate 内消化，明细既不跨
          // isolate 也不落盘——常驻内存与 JSON 带明细都会上百 MB），
          // 所以往返两侧 outcomes 都为空、统计量必须逐位一致。
          expect(a.outcomes, isEmpty);
          expect(b.outcomes, isEmpty);
        }
      }
    });
  });
  
  group('报告落盘路径一致性', () {
    // 回归：CLI 工具曾把报告写成 <库名>-backtest-report.json 之外的名字，
    // 导致 app 的 reportPathFor 永远读不到、选股页规则列表一行统计都不显示。
    test('reportPathFor 由数据库路径推导，同库必然同路径', () {
      expect(reportPathFor('/Users/x/.stock/stock.db'),
          '/Users/x/.stock/stock-backtest-report.json');
      expect(reportPathFor('stock.db'), './stock-backtest-report.json');
      // 无扩展名也不炸
      expect(reportPathFor('/a/b/mydb'), '/a/b/mydb-backtest-report.json');
      // 不同库不同报告，不会互相覆盖
      expect(reportPathFor('/a/one.db'), isNot(reportPathFor('/a/two.db')));
    });
  
    test('ReportStore 存的就是 reportPathFor 指定的那个文件', () {
      final tmp = Directory.systemTemp.createTempSync('rpath');
      try {
        final db = '${tmp.path}/stock.db';
        final store = ReportStore(reportPathFor(db));
        expect(store.path, '${tmp.path}/stock-backtest-report.json');
        store.save(BacktestReport(
          generatedAt: '2026-10-05T00:00:00.000',
          horizons: const [5],
          stockCount: 1,
          baseline: {5: Baseline(forwardDays: 5, returns: const [])},
          results: {
            'r': {
              5: BacktestResult(ruleId: 'r', forwardDays: 5, outcomes: const []),
            },
          },
        ));
        expect(File(store.path).existsSync(), isTrue);
        expect(store.load()!.stockCount, 1);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('JSON 合法但字段类型/结构不符时返回 null，不抛（TypeError 也算损坏）', () {
      final tmp = Directory.systemTemp.createTempSync('rbad');
      try {
        final path = '${tmp.path}/stock-backtest-report.json';
        // 缺字段 / 字段类型错等「合法 JSON、错误 schema」，多发生在 App 升级
        // 改了报告格式之后。load 必须当损坏处理返回 null，而不是崩掉选股页。
        File(path).writeAsStringSync('{"generatedAt": 123, "horizons": null}');
        expect(ReportStore(path).load(), isNull);
        File(path).writeAsStringSync('[]');
        expect(ReportStore(path).load(), isNull);
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });
  });
  
  group('分年统计', () {
    test('backtestAll 顺带按自然年分桶，与逐年单独跑一致', () {
      // 两天一个"年"太假，这里用跨两年的真实日期序列验证分桶正确性
      final bars = <Bar>[];
      var d = DateTime(2023, 1, 2);
      for (var i = 0; i < 500; i++) {
        bars.add(kbar(
          close: 10.0 + 0.02 * i + (i.isEven ? 0.05 : -0.03),
          volume: 100,
          date: d,
        ));
        d = d.add(const Duration(days: 1));
      }
      final stocks = [StockData(symbol: 'T', bars: bars)];
      final rs = [ruleById('close_above_ma20')];
  
      final report = backtestAll(stocks, rs, horizons: kDefaultHorizons);
      expect(report.yearly, isNotEmpty);
      expect(report.yearlyBaseline, isNotEmpty);
  
      // 分年的信号数之和 == 全样本信号数
      final total = report.result('close_above_ma20', 10)!.count;
      final byYear = [
        for (final y in report.yearly.keys)
          report.yearly[y]!['close_above_ma20']![10]!.count
      ].reduce((a, b) => a + b);
      expect(byYear, total);
  
      // 分年基准样本数之和 == 全样本基准样本数
      final baseTotal = report.baseline[10]!.count;
      final baseByYear = [
        for (final y in report.yearlyBaseline.keys) report.yearlyBaseline[y]![10]!.count
      ].reduce((a, b) => a + b);
      expect(baseByYear, baseTotal);
    });
  
    test('分年统计能序列化往返', () {
      final bars = <Bar>[];
      var d = DateTime(2023, 6, 1);
      for (var i = 0; i < 500; i++) {
        bars.add(kbar(close: 10.0 + 0.02 * i, volume: 100, date: d));
        d = d.add(const Duration(days: 1));
      }
      final r = backtestAll(
        [StockData(symbol: 'T', bars: bars)],
        builtInRules,
        horizons: const [5, 10],
      );
      final back = BacktestReport.fromJson(r.toJson());
      expect(back.yearly.keys.toSet(), r.yearly.keys.toSet());
      for (final y in r.yearly.keys) {
        for (final id in r.yearly[y]!.keys) {
          for (final h in r.yearly[y]![id]!.keys) {
            final a = back.yearly[y]![id]![h]!, b = r.yearly[y]![id]![h]!;
            expect(a.count, b.count);
            expect(a.winRate, closeTo(b.winRate, 1e-12));
            expect(a.avgReturn, closeTo(b.avgReturn, 1e-12));
            expect(a.profitFactor, closeTo(b.profitFactor, 1e-12));
          }
        }
      }
    });
  
    test('旧版没有 yearly 字段的 JSON 也能读（向后兼容）', () {
      final bars = <Bar>[];
      var d = DateTime(2024, 1, 2);
      for (var i = 0; i < 300; i++) {
        bars.add(kbar(close: 10.0 + 0.02 * i, volume: 100, date: d));
        d = d.add(const Duration(days: 1));
      }
      final r = backtestAll(
        [StockData(symbol: 'T', bars: bars)],
        [ruleById('close_above_ma20')],
        horizons: const [5],
      );
      final json = r.toJson()..remove('yearly')..remove('yearlyBaseline');
      final back = BacktestReport.fromJson(json);
      expect(back.yearly, isEmpty);
      expect(back.yearlyBaseline, isEmpty);
      expect(back.result('close_above_ma20', 5)!.count,
          r.result('close_above_ma20', 5)!.count);
    });
  });
  

  group('跨年稳健判定 isRuleYearlyRobust', () {
    BacktestStats st(double win, int count) => BacktestStats(
          count: count,
          winRate: win,
          avgReturn: 0,
          medianReturn: 0,
          bestReturn: 0,
          worstReturn: 0,
          profitFactor: 1,
        );

    /// 持有期 → 统计。
    Map<int, BacktestStats> inner(Map<int, double> byH, int count, {double win = -1}) =>
        {for (final e in byH.entries) e.key: st(win < 0 ? e.value : win, count)};

    /// 造一份分年报告：[yearlyWin] 为 年→持有期→胜率；基准统一 0.5。
    BacktestReport report(Map<int, Map<int, double>> yearlyWin,
        {Set<int>? zeroYears, String ruleId = 'r'}) {
      return BacktestReport(
        generatedAt: '2026-10-05T00:00:00.000',
        horizons: const [10],
        stockCount: 1,
        baseline: const {},
        results: const {},
        yearly: {
          for (final y in yearlyWin.keys)
            y: {ruleId: inner(yearlyWin[y]!, zeroYears?.contains(y) == true ? 0 : 100)},
        },
        yearlyBaseline: {
          for (final y in yearlyWin.keys) y: inner(yearlyWin[y]!, 100, win: 0.5),
        },
      );
    }

    test('每年都跑赢基准才算稳健', () {
      expect(isRuleYearlyRobust(report({2024: {10: 0.6}, 2025: {10: 0.55}}), 'r'),
          isTrue);
    });

    test('有一年跑输就不稳健', () {
      expect(isRuleYearlyRobust(report({2024: {10: 0.6}, 2025: {10: 0.45}}), 'r'),
          isFalse);
    });

    test('恰好等于基准算不稳健（必须严格大于）', () {
      expect(isRuleYearlyRobust(report({2024: {10: 0.5}, 2025: {10: 0.6}}), 'r'),
          isFalse);
    });

    test('该年无数据（count=0）时跳过，不判负', () {
      final r = report({2024: {10: 0.45}, 2025: {10: 0.6}},
          zeroYears: {2024});
      expect(isRuleYearlyRobust(r, 'x'), isTrue);
    });

    test('robustRuleIds 返回稳健规则 id', () {
      final good = report({2024: {10: 0.6}, 2025: {10: 0.6}},
          ruleId: 'rsi_oversold_volume');
      expect(robustRuleIds(good, [ruleById('rsi_oversold_volume')]),
          ['rsi_oversold_volume']);
      final bad = report({2024: {10: 0.6}, 2025: {10: 0.4}},
          ruleId: 'rsi_oversold_volume');
      expect(robustRuleIds(bad, [ruleById('rsi_oversold_volume')]), isEmpty);
    });
  });

  group('月度跟踪台账', () {
    BacktestSnapshot snap(String dataDate, Map<String, double> win) =>
        BacktestSnapshot(
          generatedAt: '${dataDate}T00:00:00.000',
          dataDate: dataDate,
          stockCount: 100,
          evaluableDays: 1000,
          ruleWinRate: win,
        );

    test('快照可序列化往返', () {
      final s = snap('20260131', {'rsi_oversold_volume': 0.7});
      final back = BacktestSnapshot.fromJson(s.toJson());
      expect(back.dataDate, '20260131');
      expect(back.ruleWinRate['rsi_oversold_volume'], 0.7);
      expect(back.stockCount, 100);
      expect(back.evaluableDays, 1000);
    });

    test('comparableRuleIds 只返回出现两次以上的规则', () {
      final h = BacktestHistory([
        snap('20260131', {'a': 0.5, 'b': 0.6}),
        snap('20260228', {'a': 0.55}),
      ]);
      expect(h.comparableRuleIds(), ['a']);
    });

    test('series 至少两个点才返回', () {
      final h = BacktestHistory([
        snap('20260131', {'a': 0.5}),
        snap('20260228', {'a': 0.55}),
      ]);
      // record 没有结构相等性，逐字段断言
      final s = h.series('a');
      expect(s.length, 1);
      expect(s.single.$1, 'a');
      expect(s.single.$2, [0.5, 0.55]);
      expect(h.series('b'), isEmpty);
    });

    test('同一数据截止日只保留最新一条（archive 幂等）', () {
      final merged = BacktestHistory([
        snap('20260131', {'a': 0.5}),
        snap('20260131', {'a': 0.6}),
      ]..sort((x, y) => x.dataDate.compareTo(y.dataDate)));
      // archive 的过滤逻辑：同 dataDate 先去重再追加
      final next = BacktestHistory([
        ...merged.snapshots.where((s) => s.dataDate != '20260131'),
        snap('20260131', {'a': 0.7}),
      ]..sort((x, y) => x.dataDate.compareTo(y.dataDate)));
      expect(next.snapshots.length, 1);
      expect(next.snapshots.single.ruleWinRate['a'], 0.7);
    });

    test('台账可序列化往返', () {
      final h = BacktestHistory([
        snap('20260131', {'a': 0.5}),
        snap('20260228', {'a': 0.55, 'b': 0.6}),
      ]);
      final back = BacktestHistory.fromJson(h.toJson());
      expect(back.snapshots.length, 2);
      expect(back.snapshots.last.ruleWinRate['b'], 0.6);
    });
  });
  group('ruleIdsSortedByWinRate 规则按胜率排序', () {
    /// 造一份报告，让几条规则有已知的 10 日胜率。
    BacktestReport reportWith(Map<String, double> winById) {
      final bars = <Bar>[];
      var d = DateTime(2024, 1, 2);
      for (var i = 0; i < 300; i++) {
        bars.add(kbar(close: 10.0 + 0.02 * i, volume: 100, date: d));
        d = d.add(const Duration(days: 1));
      }
      return BacktestReport(
        generatedAt: '2026-10-05T00:00:00.000',
        horizons: const [10],
        stockCount: 1,
        baseline: {10: Baseline(forwardDays: 10, returns: const [])},
        results: {
          for (final e in winById.entries)
            e.key: {
              10: BacktestResult.fromStats(
                ruleId: e.key,
                forwardDays: 10,
                stats: BacktestStats(
                  count: 100,
                  winRate: e.value,
                  avgReturn: 0,
                  medianReturn: 0,
                  bestReturn: 0,
                  worstReturn: 0,
                  profitFactor: 1,
                ),
              ),
            },
        },
      );
    }
  
    test('按 10 日胜率降序', () {
      final r = reportWith({'a': 0.5, 'b': 0.9, 'c': 0.7});
      expect(ruleIdsSortedByWinRate(['a', 'b', 'c'], r), ['b', 'c', 'a']);
    });
  
    test('没有报告的规则排在后面，且保持声明顺序', () {
      final r = reportWith({'a': 0.5, 'c': 0.7});
      // b 无数据 → 靠后；a/c 按胜率
      expect(ruleIdsSortedByWinRate(['a', 'b', 'c'], r), ['c', 'a', 'b']);
      // 同为无数据时保持原顺序
      expect(ruleIdsSortedByWinRate(['x', 'y'], r), ['x', 'y']);
    });
  
    test('report 为 null 时原样返回（排序不抖动）', () {
      const ids = ['ma250_up', 'rsi_oversold_volume', 'close_above_ma20'];
      expect(ruleIdsSortedByWinRate(ids, null), ids);
    });
  
    test('不修改入参列表', () {
      final ids = ['a', 'b', 'c'];
      final r = reportWith({'a': 0.1, 'b': 0.9, 'c': 0.5});
      ruleIdsSortedByWinRate(ids, r);
      expect(ids, ['a', 'b', 'c']);
    });
  
    test('全部 16 条内置规则都能排（真实报告字段齐全）', () {
      final r = reportWith({for (final x in builtInRules) x.id: 0.5});
      final sorted = ruleIdsSortedByWinRate(
          [for (final x in builtInRules) x.id], r);
      expect(sorted.length, builtInRules.length);
      expect(sorted.toSet(), {for (final x in builtInRules) x.id});
    });
  });
  
  group('ruleGroupsSortedByWinRate 分组按胜率排序', () {
    BacktestReport reportWith(Map<String, double> winById) => BacktestReport(
          generatedAt: '2026-10-05T00:00:00.000',
          horizons: const [10],
          stockCount: 1,
          baseline: {10: Baseline(forwardDays: 10, returns: const [])},
          results: {
            for (final e in winById.entries)
              e.key: {
                10: BacktestResult.fromStats(
                  ruleId: e.key,
                  forwardDays: 10,
                  stats: BacktestStats(
                    count: 100,
                    winRate: e.value,
                    avgReturn: 0,
                    medianReturn: 0,
                    bestReturn: 0,
                    worstReturn: 0,
                    profitFactor: 1,
                  ),
                ),
              },
          },
        );
  
    const groups = <String, List<String>>{
      '趋势': ['a', 'b'],
      '量能': ['c', 'd'],
      '年线': ['e'],
    };
  
    test('按组内最高胜率降序排列分组', () {
      // 趋势最高 0.6、量能最高 0.9、年线 0.5 → 量能 > 趋势 > 年线
      final r = reportWith({'a': 0.6, 'b': 0.5, 'c': 0.9, 'd': 0.3, 'e': 0.5});
      expect(
        ruleGroupsSortedByWinRate(groups, r).map((e) => e.key).toList(),
        ['量能', '趋势', '年线'],
      );
    });
  
    test('report 为 null 时保持声明顺序', () {
      expect(ruleGroupsSortedByWinRate(groups, null).map((e) => e.key).toList(),
          ['趋势', '量能', '年线']);
    });
  
    test('组内最高胜率相同时按声明顺序（排序稳定）', () {
      final r = reportWith({'a': 0.5, 'b': 0.5, 'c': 0.5, 'd': 0.5, 'e': 0.5});
      expect(ruleGroupsSortedByWinRate(groups, r).map((e) => e.key).toList(),
          ['趋势', '量能', '年线']);
    });
  
    test('组内全部无数据时该组靠后', () {
      final r = reportWith({'a': 0.6, 'b': 0.5}); // 量能/年线都无数据
      expect(
        ruleGroupsSortedByWinRate(groups, r).map((e) => e.key).toList(),
        ['趋势', '量能', '年线'],
      );
    });
  
    test('不改写入参 maps 的顺序', () {
      final r = reportWith({'c': 0.9, 'd': 0.3, 'a': 0.6, 'b': 0.5, 'e': 0.5});
      ruleGroupsSortedByWinRate(groups, r);
      expect(groups.keys.toList(), ['趋势', '量能', '年线']);
    });
  });
}
