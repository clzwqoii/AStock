import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/screener.dart';

import 'fixtures.dart';

void main() {
  // 39 根横盘 10.0 + 最后一根 10.5（+5%）
  final bothPass = stockOf([...List.filled(39, 10.0), 10.5], symbol: 'S1', lastVolume: 300);
  final onlyPct = stockOf([...List.filled(39, 10.0), 10.5], symbol: 'S2');
  final onlyVolume = stockOf(List.filled(40, 10.0), symbol: 'S3', lastVolume: 300);
  final nonePass = stockOf(List.filled(40, 10.0), symbol: 'S4');
  final tooShort = stockOf(List.filled(10, 10.0), symbol: 'SHORT');
  final stocks = [bothPass, onlyPct, onlyVolume, nonePass, tooShort];

  final volume = ruleById('volume_surge');
  final pct = ruleById('pct_change_up');

  group('screen', () {
    test('组合规则 = 全部满足才入选', () {
      expect(screen(stocks, [volume, pct]).map((s) => s.symbol), ['S1']);
    });

    test('单规则选股（选哪条用哪条）', () {
      expect(screen(stocks, [pct]).map((s) => s.symbol), ['S1', 'S2']);
      expect(screen(stocks, [volume]).map((s) => s.symbol), ['S1', 'S3']);
    });

    test('空规则列表抛 ArgumentError', () {
      expect(() => screen(stocks, []), throwsArgumentError);
    });

    test('历史不足 20 根的股票被跳过', () {
      expect(screen([tooShort], [volume]), isEmpty);
    });
  });

  group('screenWithHits', () {
    test('返回每只入选股票命中的规则 id（组合 = 全部命中）', () {
      final hits = screenWithHits(stocks, [volume, pct]);
      expect(hits.map((h) => h.stock.symbol), ['S1']);
      expect(hits.single.matchedRuleIds, ['volume_surge', 'pct_change_up']);
    });

    test('规则顺序与传入一致，便于 UI 按勾选顺序展示', () {
      final hits = screenWithHits(stocks, [pct, volume]);
      expect(hits.single.matchedRuleIds, ['pct_change_up', 'volume_surge']);
    });

    test('单规则选股时命中列表就是那一条', () {
      expect(screenWithHits(stocks, [pct]).map((h) => h.matchedRuleIds.single), [
        'pct_change_up',
        'pct_change_up',
      ]);
    });

    test('空规则列表同样抛 ArgumentError（与 screen 一致）', () {
      expect(() => screenWithHits(stocks, []), throwsArgumentError);
    });

    test('与 screen 同口径：结果集完全一致', () {
      expect(screenWithHits(stocks, [volume, pct]).map((h) => h.stock), screen(stocks, [volume, pct]));
    });

    test('命中结果直接带回筛选时的快照（调用方不必再 fromStock 重建）', () {
      final hits = screenWithHits(stocks, [volume, pct]);
      final s = hits.single.stock;
      expect(hits.single.snapshot.close, s.bars.last.close);
      expect(hits.single.snapshot.pctChange, IndicatorSnapshot.fromStock(s).pctChange);
    });
  });
  
  group('MA60 有效突破规则的短历史兜底', () {
    /// 历史不足有效突破窗口（70 根 / 79 根）的股票：不入选，且不抛 StateError。
    StockData shortStock(String symbol, int bars) => StockData(
          symbol: symbol,
          bars: [for (var i = 0; i < bars; i++) kbar(close: 20.0 + 0.05 * i)],
        );
  
    test('有效突破规则下短历史股票被跳过、长历史形态 A 入选', () {
      final stocks = [
        shortStock('SHORT_A', 69), // 不足 70 根
        shortStock('SHORT_B', 78), // 不足 79 根
        StockData(symbol: 'BO', bars: barsMa60Breakout()),
      ];
      final hits = screenWithHits(stocks, [ruleById('ma60_breakout_confirmed')]);
      expect(hits.map((h) => h.stock.symbol), ['BO']);
    });
  
    test('回踩确认规则下短历史股票被跳过、长历史形态 B 入选', () {
      final stocks = [
        shortStock('SHORT_A', 69),
        shortStock('SHORT_B', 78), // 不足 79 根
        StockData(symbol: 'PB', bars: barsMa60Pullback()),
      ];
      final hits = screenWithHits(stocks, [ruleById('ma60_breakout_pullback')]);
      expect(hits.map((h) => h.stock.symbol), ['PB']);
    });
  
    test('组合选股：两条 MA60 突破规则同时勾选时，形态 A 与形态 B 不会同时入选', () {
      final stocks = [
        StockData(symbol: 'BO', bars: barsMa60Breakout()),
        StockData(symbol: 'PB', bars: barsMa60Pullback()),
      ];
      final rules = [ruleById('ma60_breakout_confirmed'), ruleById('ma60_breakout_pullback')];
      expect(screenWithHits(stocks, rules), isEmpty);
    });
  
    test('组合选股：有效突破 ∧ 收盘价站上MA60', () {
      final stocks = [
        StockData(symbol: 'BO', bars: barsMa60Breakout()),
        StockData(symbol: 'PB', bars: barsMa60Pullback()),
      ];
      final rules = [ruleById('ma60_breakout_confirmed'), ruleById('close_above_ma60')];
      expect(screenWithHits(stocks, rules).map((h) => h.stock.symbol), ['BO']);
    });
  });

  group('新鲜度护栏', () {
    // 指定末根日期造序列（其余每日 -1 天），末根放量以命中 volume_surge。
    StockData dated(
      String symbol,
      DateTime lastDate, {
      int bars = 30,
      double lastVolume = 300,
    }) =>
        StockData(
          symbol: symbol,
          bars: [
            for (var i = 0; i < bars; i++)
              Bar(
                date: lastDate.subtract(Duration(days: bars - 1 - i)),
                open: 10,
                high: 11,
                low: 9.9,
                close: i == bars - 1 ? 10.5 : 10.0,
                volume: i == bars - 1 ? lastVolume : 100,
              ),
          ],
        );

    final today = DateTime(2024, 1, 1);

    test('末根滞后池内最大交易日超过 maxLastBarLagDays 直接出池', () {
      final all = [
        dated('FOSSIL', DateTime(2023, 1, 1)), // 滞后 366 天
        dated('FRESH', today),
      ];
      expect(screenWithHits(all, [volume]).map((h) => h.stock.symbol), ['FRESH']);
      // 关掉护栏才复现旧口径
      expect(
        screenWithHits(all, [volume], maxLastBarLagDays: 0)
            .map((h) => h.stock.symbol)
            .toList()
          ..sort(),
        ['FOSSIL', 'FRESH'],
      );
    });

    test('滞后在阈值之内（停牌几天）仍然保留', () {
      final all = [
        dated('SUSPENDED', today.subtract(const Duration(days: 5))),
        dated('FRESH', today),
      ];
      expect(
        screenWithHits(all, [volume]).map((h) => h.stock.symbol).toList()..sort(),
        ['FRESH', 'SUSPENDED'],
      );
    });
  });

  group('除权/复牌护栏', () {
    test('信号日落在除权后 20 根内不出信号', () {
      // 前 30 根收 10.0，第 30 根（下标 30）主板除权（开盘 7.7 = -23%），
      // 之后停在新价位，末根放量以命中 volume_surge。
      final bars = [
        for (var i = 0; i < 40; i++)
          i < 30
              ? kbar(close: 10.0)
              : kbar(open: 7.7, high: 7.8, low: 7.6, close: 7.75,
                  volume: i == 39 ? 300 : 100),
      ];
      final hit = StockData(symbol: 'EXDIV', bars: bars);
      expect(screenWithHits([hit], [volume]).map((h) => h.stock.symbol), isEmpty);
      // 关掉护栏（lookbackBars=0）就复现旧口径：能选出来
      expect(
        screenWithHits([hit], [volume], corporateActionLookbackBars: 0)
            .map((h) => h.stock.symbol),
        ['EXDIV'],
      );
    });

    test('除权满 20 根之后恢复正常选股', () {
      // 同样的除权，但信号日距除权已 25 根
      final bars = [
        for (var i = 0; i < 56; i++)
          i < 30
              ? kbar(close: 10.0)
              : kbar(open: 7.7, high: 7.8, low: 7.6, close: 7.75,
                  volume: i == 55 ? 300 : 100),
      ];
      expect(
        screenWithHits([StockData(symbol: 'EXDIV', bars: bars)], [volume])
            .map((h) => h.stock.symbol),
        ['EXDIV'],
      );
    });
  });

  group('screenDiagnostics 计数', () {
    // 30 根 10.0 且末根 +5%、放量 → 命中 volume_surge；日期统一取 2024-01-01。
    StockData fresh() => stockOf(
          [...List.filled(39, 10.0), 10.5],
          symbol: 'FRESH',
          lastVolume: 300,
        );

    test('无护栏阻挡时两个计数都是 0', () {
      final d = screenDiagnostics([fresh()], [volume]);
      expect(d.hits.single.stock.symbol, 'FRESH');
      expect(d.blockedStale, 0);
      expect(d.blockedCorporateAction, 0);
    });

    test('只数"本来会入选"的：不中规则的陈旧票不计入', () {
      // 同样陈旧，但末根不放量 → volume_surge 不命中，不该被算成"挡掉的假信号"
      final staleNoHit = StockData(
        symbol: 'STALE_NOHIT',
        bars: [
          for (var i = 0; i < 30; i++)
            Bar(
              date: DateTime(2023, 1, 1).add(Duration(days: i)),
              open: 10,
              high: 11,
              low: 9.9,
              close: 10.0,
              volume: 100,
            ),
        ],
      );
      final d = screenDiagnostics([fresh(), staleNoHit], [volume]);
      expect(d.hits.map((h) => h.stock.symbol), ['FRESH']);
      expect(d.blockedStale, 0, reason: '本来就不会入选的陈旧票不该计入');
    });

    test('陈旧且本来会入选 → 计入 blockedStale', () {
      final staleHit = StockData(
        symbol: 'STALE_HIT',
        bars: [
          for (var i = 0; i < 30; i++)
            Bar(
              date: DateTime(2023, 1, 1).add(Duration(days: i)),
              open: 10,
              high: 11,
              low: 9.9,
              close: i == 29 ? 10.5 : 10.0,
              volume: i == 29 ? 300 : 100,
            ),
        ],
      );
      final d = screenDiagnostics([fresh(), staleHit], [volume]);
      expect(d.hits.map((h) => h.stock.symbol), ['FRESH']);
      expect(d.blockedStale, 1);
      expect(d.blockedCorporateAction, 0);
    });

    test('除权污染窗口内且本来会入选 → 计入 blockedCorporateAction', () {
      final bars = [
        for (var i = 0; i < 40; i++)
          i < 30
              ? kbar(close: 10.0)
              : kbar(open: 7.7, high: 7.8, low: 7.6, close: 7.75,
                  volume: i == 39 ? 300 : 100),
      ];
      final d =
          screenDiagnostics([StockData(symbol: 'EXDIV', bars: bars)], [volume]);
      expect(d.hits, isEmpty);
      expect(d.blockedCorporateAction, 1);
      expect(d.blockedStale, 0);
    });

    test('关掉护栏后计数归零、结果回到旧口径', () {
      final bars = [
        for (var i = 0; i < 40; i++)
          i < 30
              ? kbar(close: 10.0)
              : kbar(open: 7.7, high: 7.8, low: 7.6, close: 7.75,
                  volume: i == 39 ? 300 : 100),
      ];
      final d = screenDiagnostics(
        [StockData(symbol: 'EXDIV', bars: bars)],
        [volume],
        maxLastBarLagDays: 0,
        corporateActionLookbackBars: 0,
      );
      expect(d.hits.map((h) => h.stock.symbol), ['EXDIV']);
      expect(d.blockedStale, 0);
      expect(d.blockedCorporateAction, 0);
    });
  });
}
