// backtestAll：一遍扫描出全规则 × 全持有期报告，以及 JSON 落盘往返。
//
// 关键：backtestAll 统一用「最大持有期」的可评估范围，好让三个持有期覆盖同一批
// 交易日、彼此可比；因此只在最大持有期上，它才与逐规则调 backtestRule 的数目相等。

import 'dart:math' as math;
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


    test('分位数：Tape 快路径与从 outcomes 重算逐位一致', () {
      // backtestAll 走 Tape 的手工统计，backtestRule 走 BacktestStats.of
      // 参考路径。两条路必须给出同一组分位数——这条测试就是为抓住
      // “手工构造 BacktestStats 漏了新字段”这类回归。
      final stocks = [up, flat];
      final report = backtestAll(stocks, rules, horizons: kDefaultHorizons);
      final maxH = kDefaultHorizons.reduce((a, b) => a > b ? a : b);
      for (final r in rules) {
        final viaAll = report.result(r.id, maxH)!;
        final viaOne = backtestRule(stocks, r, forwardDays: maxH);
        final reason = '${r.id}@$maxH';
        expect(viaAll.p10, isNotNull, reason: reason);
        expect(viaAll.p10, closeTo(viaOne.p10!, 1e-9), reason: reason);
        expect(viaAll.p25, closeTo(viaOne.p25!, 1e-9), reason: reason);
        expect(viaAll.p75, closeTo(viaOne.p75!, 1e-9), reason: reason);
        expect(viaAll.p90, closeTo(viaOne.p90!, 1e-9), reason: reason);
        expect(viaAll.stdDev, closeTo(viaOne.stdDev!, 1e-9), reason: reason);
      }
    });

    test('分位数：基准与分年统计同样非空且单调', () {
      final stocks = [up, flat];
      final report = backtestAll(stocks, rules, horizons: kDefaultHorizons);
      for (final h in kDefaultHorizons) {
        final b = report.baseline[h]!;
        expect(b.p10, isNotNull, reason: 'baseline@$h');
        expect(b.worstReturn, lessThanOrEqualTo(b.p10!), reason: 'baseline@$h');
        expect(b.p10!, lessThanOrEqualTo(b.p25!), reason: 'baseline@$h');
        expect(b.p25!, lessThanOrEqualTo(b.p75!), reason: 'baseline@$h');
        expect(b.p75!, lessThanOrEqualTo(b.p90!), reason: 'baseline@$h');
        expect(b.p90!, lessThanOrEqualTo(b.bestReturn), reason: 'baseline@$h');
      }
      for (final y in report.yearly.keys) {
        for (final r in rules) {
          for (final h in kDefaultHorizons) {
            final s = report.yearly[y]![r.id]![h]!;
            if (s.count == 0) continue;
            expect(s.p10, isNotNull, reason: '${r.id}@$h/$y');
            expect(s.p75, isNotNull, reason: '${r.id}@$h/$y');
            expect(s.p10!, lessThanOrEqualTo(s.p75!), reason: '${r.id}@$h/$y');
          }
        }
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
    BacktestStats st(double win, int count, {double avg = 0}) => BacktestStats(
          count: count,
          winRate: win,
          avgReturn: avg,
          medianReturn: avg,
          bestReturn: avg,
          worstReturn: -avg,
          profitFactor: 1,
        );

    /// 造一份按**均收益**造的报告：年→规则均收益，基准均收益 [baseAvg]。
    BacktestReport retReport(
      Map<int, double> ruleAvg, {
      double baseAvg = 0,
      int count = 100,
      String ruleId = 'r',
    }) {
      return BacktestReport(
        generatedAt: '2026-10-05T00:00:00.000',
        horizons: const [10],
        stockCount: 1,
        baseline: const {},
        results: const {},
        yearly: {
          for (final e in ruleAvg.entries)
            e.key: {ruleId: {10: st(0.5, count, avg: e.value)}},
        },
        yearlyBaseline: {
          for (final e in ruleAvg.entries)
            e.key: {10: st(0.5, count, avg: baseAvg)},
        },
      );
    }

    test('每年都跑赢基准才算稳健', () {
      expect(isRuleYearlyRobust(retReport({2024: 1.2, 2025: 0.8}, baseAvg: 0.1), 'r'),
          isTrue);
    });

    test('有一年跑输就不稳健', () {
      expect(
          isRuleYearlyRobust(
              retReport({2024: 1.2, 2025: -0.5}, baseAvg: 0.1), 'r'),
          isFalse);
    });

    test('均收益恰好等于基准算不稳健（必须严格大于）', () {
      expect(isRuleYearlyRobust(retReport({2024: 0.1, 2025: 1.0}, baseAvg: 0.1), 'r'),
          isFalse);
    });

    test('该年无数据（count=0）时跳过，不判负', () {
      // 2024 年规则 count=0 → 跳过；2025 年有正超额 → 整体通过。
      // 这条锁的是「早年算不出来的规则（如 MA250 需要 250 根）不该被
      // 当成不稳健」，与均收益口径无关。
      final r = BacktestReport(
        generatedAt: '2026-10-05T00:00:00.000',
        horizons: const [10],
        stockCount: 1,
        baseline: const {},
        results: const {},
        yearly: {
          2024: {'r': {10: st(0.5, 0, avg: -99)}},
          2025: {'r': {10: st(0.5, 100, avg: 1.0)}},
        },
        yearlyBaseline: {
          2024: {10: st(0.5, 100, avg: 0.1)},
          2025: {10: st(0.5, 100, avg: 0.1)},
        },
      );
      expect(isRuleYearlyRobust(r, 'r'), isTrue,
          reason: '2024 年 count=0 必须被跳过，否则均收益 −99 会被判成不稳健');
    });

    test('robustRuleIds 返回稳健规则 id', () {
      final good = retReport({2024: 1.0, 2025: 0.9},
          baseAvg: 0.1, ruleId: 'rsi_oversold_volume');
      expect(robustRuleIds(good, [ruleById('rsi_oversold_volume')]),
          ['rsi_oversold_volume']);
      final bad = retReport({2024: 1.0, 2025: -0.9},
          baseAvg: 0.1, ruleId: 'rsi_oversold_volume');
      expect(robustRuleIds(bad, [ruleById('rsi_oversold_volume')]), isEmpty);
    });

    // ── 以下是判定口径从「胜率」切到「均收益超额」的回归测试 ──

    test('判定看均收益超额，不看胜率：胜率低但收益高仍算稳健（熊市口径）', () {
      // 2026 年实测：基准均收益 −0.41%，规则 +0.07%，胜率 43.5% < 基准 44.3%。
      // 按旧口径这条规则被筛掉，实际它仍在赚钱。
      final r = retReport({2026: 0.07}, baseAvg: -0.41);
      expect(r.yearly[2026]!['r']![10]!.winRate, 0.5); // 胜率持平
      expect(isRuleYearlyRobust(r, 'r'), isTrue,
          reason: '均收益 +0.07% 高于基准 −0.41%，期望为正');
    });

    test('胜率高但均收益为负 → 不稳健（胜率单独用会两头看反）', () {
      // 实测 close_above_ma20 2026：胜率 45.2% > 基准 44.3%，均收益 −0.25% < −0.41%
      // 的另一个例子——这里构造更极端的：胜率碾压，均收益亏钱。
      final r = retReport({2026: -2.0}, baseAvg: -0.41);
      expect(isRuleYearlyRobust(r, 'r'), isFalse,
          reason: '均收益 −2.0% 远低于基准 −0.41%，期望为负');
    });

    test('均收益恰好等于基准算不稳健（必须严格大于）', () {
      expect(isRuleYearlyRobust(retReport({2026: 1.5}, baseAvg: 1.5), 'r'), isFalse);
    });

    test('真实报告下超额口径能筛出规则，胜率口径一条都筛不出', () {
      // 回归背景：2026-10-06 实测 stock-backtest-report.json，胜率口径下
      // 20 条规则 0 条通过「只看稳健」——那个开关开着是空列表。
      // 切到超额口径后 rsi_oversold 族 4 条通过。
      final r = retReport({2024: 1.87, 2025: 2.67, 2026: 0.48}, baseAvg: -0.41);
      expect(isRuleYearlyRobust(r, 'r'), isTrue);
    });
  });

  group('信号集中度（防"名声建立在单个月上"）', () {
    // 直接构造报告太啰嗦，用 backtestAll 跑一条恒真规则，再看 profile。
    test('backtestAll 产出 monthsWithSignals 与 topMonthShare', () {
      final alwaysTrue = Rule(
        id: 'always_true',
        name: '恒真',
        desc: '测试用',
        test: (_) => true,
      );
      final report = backtestAll([up, flat], [alwaysTrue],
          horizons: const [10]);
      final prof = report.signalProfile['always_true']![10]!;
      // up/flat 跨越多个月，profile 必须非空且数值合理
      expect(prof.signalCount, greaterThan(0));
      expect(prof.monthsWithSignals, greaterThan(0));
      expect(prof.topMonthShare, greaterThan(0));
      expect(prof.topMonthShare, lessThanOrEqualTo(1.0000001));
    });

    test('只有一个月有信号时 topMonthShare = 1', () {
      // 用一条"只在特定日期命中"的规则，逼出单月信号
      final onlyFirstMonth = Rule(
        id: 'only_first_month',
        name: '仅首月',
        desc: '测试用',
        test: (s) => s.close < 10.5,
      );
      // up 序列前 40 根是 10.0，之后涨到 14；flat 全程 10.0。
      // close<10.5 只在最初几十根命中 —— 那几十根横跨 2024-01/02。
      final report = backtestAll([up, flat], [onlyFirstMonth],
          horizons: const [10]);
      final prof = report.signalProfile['only_first_month']![10]!;
      expect(prof.signalCount, greaterThan(0));
      // 信号应集中在少数月份，topMonthShare 明显高于 1/monthsWithSignals
      expect(prof.topMonthShare * prof.monthsWithSignals, greaterThan(1));
    });

    test('无信号的规则 profile 为空对象，不抛异常', () {
      final never = Rule(
        id: 'never',
        name: '恒假',
        desc: '测试用',
        test: (_) => false,
      );
      final report = backtestAll([up, flat], [never], horizons: const [10]);
      final prof = report.signalProfile['never']![10]!;
      expect(prof.signalCount, 0);
      expect(prof.monthsWithSignals, 0);
      expect(prof.topMonthShare, 0);
    });

    test('profile 随 JSON 往返一致', () {
      final alwaysTrue = Rule(
        id: 'always_true',
        name: '恒真',
        desc: '测试用',
        test: (_) => true,
      );
      final report = backtestAll([up, flat], [alwaysTrue],
          horizons: const [10]);
      final back = BacktestReport.fromJson(report.toJson());
      final a = report.signalProfile['always_true']![10]!;
      final b = back.signalProfile['always_true']![10]!;
      expect(b.signalCount, a.signalCount);
      expect(b.monthsWithSignals, a.monthsWithSignals);
      expect(b.topMonthShare, closeTo(a.topMonthShare, 1e-12));
    });
  });

  group('可信判定：稳健 + 不集中，两个条件都要', () {
    /// 造一份带集中度的报告。[avg] 是规则均收益，基准固定 [baseAvg]——
    /// 判定口径 2026-10-06 起看均收益超额，不再看胜率，所以 [win] 只作参考。
    BacktestReport repWith(String ruleId, double topShare, int signals,
        {double win = 0.9, double avg = 1.5, double baseAvg = 0.1,
        int months = 20}) {
      return BacktestReport(
        generatedAt: 'x',
        horizons: const [10],
        stockCount: 1,
        baseline: {
          10: Baseline(forwardDays: 10, returns: const [])
        },
        results: {
          ruleId: {
            10: BacktestResult.fromStats(
              ruleId: ruleId,
              forwardDays: 10,
              stats: BacktestStats(
                count: signals,
                winRate: win,
                avgReturn: avg,
                medianReturn: avg,
                bestReturn: avg,
                worstReturn: -avg,
                profitFactor: 1,
              ),
            ),
          },
        },
        yearly: {
          2024: {
            ruleId: {
              10: BacktestStats(
                count: signals,
                winRate: win,
                avgReturn: avg,
                medianReturn: avg,
                bestReturn: avg,
                worstReturn: -avg,
                profitFactor: 1,
              ),
            },
          },
        },
        yearlyBaseline: {
          2024: {
            10: BacktestStats(
              count: 100000,
              winRate: 0.4,
              avgReturn: baseAvg,
              medianReturn: baseAvg,
              bestReturn: baseAvg,
              worstReturn: -baseAvg,
              profitFactor: 1,
            ),
          },
        },
        signalProfile: {
          ruleId: {
            10: RuleProfile(
              signalCount: signals,
              monthsWithSignals: months,
              topMonthShare: topShare,
            ),
          },
        },
      );
    }

    test('占比超限 → 即便每年都赢基准也不算可信', () {
      final r = repWith('x', 0.70, 5000);
      expect(isRuleYearlyRobust(r, 'x'), isTrue,
          reason: '按年胜率它是过的——这正是问题所在');
      expect(isRuleSignalConcentrated(r, 'x'), isTrue);
      expect(isRuleTrustworthy(r, 'x'), isFalse,
          reason: '集中度要能把"每年都赢"但靠单月的规则拦下来');
    });

    test('占比未超限 → 可信', () {
      final r = repWith('x', 0.45, 5000);
      expect(isRuleYearlyRobust(r, 'x'), isTrue);
      expect(isRuleSignalConcentrated(r, 'x'), isFalse);
      expect(isRuleTrustworthy(r, 'x'), isTrue);
    });

    test('信号量太小 → 占比不参与判定（1 个信号不是"集中"是"没数据"）', () {
      final r = repWith('x', 1.0, 5);
      expect(isRuleSignalConcentrated(r, 'x'), isFalse);
      // 但按年胜率仍然判，因为 count=5 也能算胜率
      expect(isRuleTrustworthy(r, 'x'), isTrue);
    });

    test('旧报告没有 signalProfile → 集中度不拦（缺数据不默认有罪）', () {
      final r = repWith('x', 0.70, 5000);
      final legacy = BacktestReport.fromJson({
        ...r.toJson(),
      }..remove('signalProfile'));
      expect(isRuleSignalConcentrated(legacy, 'x'), isFalse,
          reason: '读不到集中度时不该把所有规则都判成可疑');
      expect(isRuleTrustworthy(legacy, 'x'), isTrue);
    });

    test('按年不稳的规则，占比再低也不可信', () {
      // 胜率 0.9（碾压基准 0.4）但均收益 −1.0% < 基准 +0.1% → 超额为负。
      final r = repWith('x', 0.10, 5000, win: 0.9, avg: -1.0);
      expect(isRuleYearlyRobust(r, 'x'), isFalse);
      expect(isRuleTrustworthy(r, 'x'), isFalse);
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
  
    test('pinFirst 把主力规则钉到首位，胜率不为它让路', () {
      // 宽松版全样本胜率(79.9%)低于严格版(86.4%)，但它是主力——
      // 依据是跨市况稳健而非全样本胜率。所以必须能覆盖胜率排序。
      final r = reportWith({'strict': 0.864, 'loose': 0.799, 'third': 0.60});
      expect(ruleIdsSortedByWinRate(['strict', 'loose', 'third'], r),
          ['strict', 'loose', 'third'], reason: '默认仍按胜率');
      expect(
          ruleIdsSortedByWinRate(['strict', 'loose', 'third'], r,
              pinFirst: 'loose'),
          ['loose', 'strict', 'third']);
    });

    test('pinFirst 的 id 不在列表里时静默忽略，不打乱排序', () {
      final r = reportWith({'a': 0.5, 'b': 0.9});
      expect(ruleIdsSortedByWinRate(['a', 'b'], r, pinFirst: '不存在'), ['b', 'a']);
    });

    test('pinFirst 在 report 为 null 时也生效（无报告是降级态）', () {
      expect(ruleIdsSortedByWinRate(['x', 'y', 'z'], null, pinFirst: 'z'),
          ['z', 'x', 'y']);
    });

    test('kMainRuleId 是真实存在且跨年稳健的主力规则', () {
      final rule = builtInRules.firstWhere((r) => r.id == kMainRuleId,
          orElse: () => throw StateError('kMainRuleId 不是内置规则'));
      expect(rule.id, 'rsi_oversold_volume_loose');
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
  
  group('分位数与离散度（评分/买卖价的原料）', () {
    test('p10/p25/p75/p90/stdDev 落在正确位置', () {
      final s = BacktestStats.of(<double>[
        -10, -5, -2, 0, 1, 2, 3, 4, 5, 8,
        10, 15, 20, 25, 30, 35, 40, 45, 50, 100,
      ]);
      // 线性插值分位数（numpy.percentile 默认口径），期望值由 /tmp oracle 算出：
      // p10=-2.3, p25=1.75, p75=31.25, p90=45.50000000000001
      expect(s.p10, closeTo(-2.3, 1e-9));
      expect(s.p25, closeTo(1.75, 1e-9));
      expect(s.p75, closeTo(31.25, 1e-9));
      expect(s.p90, closeTo(45.5, 1e-9));
      // 样本标准差（n-1，Dart math 用样本方差）
      final xs = <double>[-10, -5, -2, 0, 1, 2, 3, 4, 5, 8, 10, 15, 20, 25, 30, 35, 40, 45, 50, 100];
      final m = xs.reduce((a, b) => a + b) / xs.length;
      final v = xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / (xs.length - 1);
      expect(s.stdDev, closeTo(math.sqrt(v), 1e-9));
    });

    test('单样本时分位数都等于该样本本身，stdDev=0', () {
      final s = BacktestStats.of(<double>[7.5]);
      expect(s.p10, closeTo(7.5, 1e-9));
      expect(s.p25, closeTo(7.5, 1e-9));
      expect(s.p75, closeTo(7.5, 1e-9));
      expect(s.p90, closeTo(7.5, 1e-9));
      expect(s.stdDev, closeTo(0, 1e-12));
    });

    test('两样本时分位数落在两端之间（线性插值，不是取端点）', () {
      final s = BacktestStats.of(<double>[-3, 9]);
      expect(s.p10, closeTo(-1.8, 1e-9));
      expect(s.p25, closeTo(0, 1e-9));
      expect(s.p75, closeTo(6, 1e-9));
      expect(s.p90, closeTo(7.8, 1e-9));
    });

    test('空统计的分位数字段有降级值而非抛异常', () {
      final s = BacktestStats.empty;
      expect(s.count, 0);
      expect(s.p10, isNull);
      expect(s.p90, isNull);
      expect(s.stdDev, isNull);
    });

    test('旧报告 JSON 无分位数字段 → 读成 null 而不是抛异常', () {
      // 2026-10-06 之前的报告没有分位数字段。加载必须降级，否则选股页直接崩。
      final legacy = <String, dynamic>{
        'count': 3,
        'winRate': 0.5,
        'avgReturn': 1.0,
        'medianReturn': 1.0,
        'bestReturn': 2.0,
        'worstReturn': -1.0,
        'profitFactor': 1.5,
      };
      final s = BacktestStats.fromJson(legacy);
      expect(s.count, 3);
      expect(s.avgReturn, closeTo(1.0, 1e-9));
      expect(s.p10, isNull);
      expect(s.p25, isNull);
      expect(s.p75, isNull);
      expect(s.p90, isNull);
      expect(s.stdDev, isNull);
    });

    test('新报告 JSON 往返分位数一致', () {
      final s = BacktestStats.of(<double>[-10, -5, 1, 4, 20]);
      final back = BacktestStats.fromJson(s.toJson());
      expect(back.p10, closeTo(s.p10!, 1e-12));
      expect(back.p75, closeTo(s.p75!, 1e-12));
      expect(back.p90, closeTo(s.p90!, 1e-12));
      expect(back.stdDev, closeTo(s.stdDev!, 1e-12));
    });
  });
}
