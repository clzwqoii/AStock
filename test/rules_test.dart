import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';

import 'fixtures.dart';

/// V 型反转股票。
StockData vRecovery() => StockData(
      symbol: '600000',
      bars: [for (final c in closesVRecovery()) bar(close: c)],
    );

void main() {
  final v = vRecovery();
  final crash = stockOf(closesCrash());

  Rule ruleOf(String id) => ruleById(id);

  IndicatorSnapshot snap(StockData s) => IndicatorSnapshot.fromStock(s);

  group('builtInRules', () {
    test('目录至少 7 条且 id 唯一', () {
      expect(builtInRules.length, greaterThanOrEqualTo(7));
      expect(builtInRules.map((r) => r.id).toSet().length, builtInRules.length);
    });

    test('收盘价站上 MA20', () {
      expect(ruleOf('close_above_ma20').test(snap(v)), isTrue);
      expect(ruleOf('close_above_ma20').test(snap(crash)), isFalse);
    });

    test('MA5 上穿 MA10 只在交叉日为真', () {
      final crossDay =
          stockOf(closesVRecovery().take(24).toList(), symbol: 'X');
      final dayBefore =
          stockOf(closesVRecovery().take(23).toList(), symbol: 'X');
      expect(ruleOf('ma5_golden_ma10').test(snap(crossDay)), isTrue);
      expect(ruleOf('ma5_golden_ma10').test(snap(dayBefore)), isFalse);
      expect(ruleOf('ma5_golden_ma10').test(snap(crash)), isFalse);
    });

    test('MACD 金叉只在交叉日为真', () {
      final crossDay =
          stockOf(closesVRecovery().take(24).toList(), symbol: 'X');
      final dayBefore =
          stockOf(closesVRecovery().take(23).toList(), symbol: 'X');
      expect(ruleOf('macd_golden_cross').test(snap(crossDay)), isTrue);
      expect(ruleOf('macd_golden_cross').test(snap(dayBefore)), isFalse);
      expect(ruleOf('macd_golden_cross').test(snap(crash)), isFalse);
    });

    test('RSI 超卖与超买', () {
      expect(ruleOf('rsi_oversold').test(snap(crash)), isTrue);
      expect(ruleOf('rsi_oversold').test(snap(v)), isFalse);
      expect(ruleOf('rsi_overbought').test(snap(v)), isTrue);
      expect(ruleOf('rsi_overbought').test(snap(crash)), isFalse);
    });

    test('量比大于 2', () {
      expect(ruleOf('volume_surge').test(snap(stockOf(closesVRecovery(), lastVolume: 300))), isTrue);
      expect(ruleOf('volume_surge').test(snap(v)), isFalse);
    });

    test('当日涨幅大于 3%', () {
      final jump = stockOf([...List.filled(39, 10.0), 10.5]);
      final flat = stockOf(List.filled(40, 10.0));
      expect(ruleOf('pct_change_up').test(snap(jump)), isTrue);
      expect(ruleOf('pct_change_up').test(snap(flat)), isFalse);
    });
  });

  group('IndicatorSnapshot', () {
    test('V 型反转末日快照与独立基准一致', () {
      final s = IndicatorSnapshot.fromStock(vRecovery());
      expect(s.close, 24.3);
      expect(s.ma5, closeTo(23.3, 1e-9));
      expect(s.prevMa5, closeTo(22.8, 1e-9));
      expect(s.ma10, closeTo(22.05, 1e-9));
      expect(s.prevMa10, closeTo(21.55, 1e-9));
      expect(s.ma20, closeTo(19.55, 1e-9));
      expect(s.dif, closeTo(1.694253775402938, 1e-9));
      expect(s.prevDif, closeTo(1.5654038808830428, 1e-9));
      expect(s.dea, closeTo(1.1005897510920888, 1e-9));
      expect(s.prevDea, closeTo(0.9521737450143762, 1e-9));
      expect(s.rsi14, closeTo(85.00915283788616, 1e-9));
      expect(s.volumeRatio, 1.0);
      expect(s.pctChange, closeTo(2.1008403361344534, 1e-9));
    });

    test('KDJ 字段与独立基准一致（带宽序列），且不影响收盘类指标', () {
      final s = IndicatorSnapshot.fromStock(StockData(symbol: '600000', bars: barsWithBand()));
      expect(s.k, closeTo(93.42377663802921, 1e-9));
      expect(s.d, closeTo(93.10701931551432, 1e-9));
      expect(s.j, closeTo(94.05729128305899, 1e-9));
      expect(s.prevK, closeTo(93.39653452226122, 1e-9));
      expect(s.prevD, closeTo(92.94864065425686, 1e-9));
      expect(s.ma20, closeTo(19.55, 1e-9)); // 带宽不改变收盘类指标
    });

    test('连续一字板（整段高低相等）KDJ 为中性 50', () {
      final s = IndicatorSnapshot.fromStock(stockOf(List.filled(40, 10.0)));
      expect(s.k, closeTo(50.0, 1e-9));
      expect(s.d, closeTo(50.0, 1e-9));
      expect(s.j, closeTo(50.0, 1e-9));
      expect(s.prevK, closeTo(50.0, 1e-9));
      expect(s.prevD, closeTo(50.0, 1e-9));
    });

    test('历史不足 20 根抛 StateError', () {
      final short = StockData(
        symbol: '000001',
        bars: [for (final c in closesVRecovery().take(10)) bar(close: c)],
      );
      expect(() => IndicatorSnapshot.fromStock(short), throwsStateError);
    });
  });
}
