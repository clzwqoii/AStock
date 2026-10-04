/// 选股规则引擎：指标快照、规则与内置规则目录。
library;

import 'indicators.dart' as ind;
import 'models.dart';

/// 某只股票最近一日的指标快照，含规则所需的前一日值（用于金叉/上穿判断）。
class IndicatorSnapshot {
  IndicatorSnapshot._({
    required this.close,
    required this.ma5,
    required this.prevMa5,
    required this.ma10,
    required this.prevMa10,
    required this.ma20,
    required this.dif,
    required this.prevDif,
    required this.dea,
    required this.prevDea,
    required this.rsi14,
    required this.volumeRatio,
    required this.pctChange,
  });

  /// 快照所需的完整历史：MA20 需 20 根，前一日 MA5/MA10 需 11 根。
  static const minBars = 20;

  final double close;
  final double ma5;
  final double prevMa5;
  final double ma10;
  final double prevMa10;
  final double ma20;
  final double dif;
  final double prevDif;
  final double dea;
  final double prevDea;
  final double rsi14;
  final double volumeRatio;
  final double pctChange;

  factory IndicatorSnapshot.fromStock(StockData stock) {
    final bars = stock.bars;
    if (bars.length < minBars) {
      throw StateError('${stock.symbol} 历史不足 $minBars 根，实际 ${bars.length}');
    }
    final closes = [for (final b in bars) b.close];
    final last = bars.length - 1;
    final prev = last - 1;
    final m5 = ind.smaSeries(closes, 5);
    final m10 = ind.smaSeries(closes, 10);
    final m20 = ind.smaSeries(closes, 20);
    final m = ind.macd(closes);
    return IndicatorSnapshot._(
      close: closes[last],
      ma5: m5[last]!,
      prevMa5: m5[prev]!,
      ma10: m10[last]!,
      prevMa10: m10[prev]!,
      ma20: m20[last]!,
      dif: m.dif[last],
      prevDif: m.dif[prev],
      dea: m.dea[last],
      prevDea: m.dea[prev],
      rsi14: ind.rsi(closes, 14),
      volumeRatio: ind.volumeRatio(bars),
      pctChange: ind.pctChange(bars),
    );
  }
}

/// 一条选股规则：对末日指标快照做布尔判断。
class Rule {
  const Rule({required this.id, required this.name, required this.test});

  final String id;
  final String name;
  final bool Function(IndicatorSnapshot) test;
}

/// 内置规则目录。UI 从这里列出可选规则；单规则选股传一条，组合选股传多条（AND）。
final List<Rule> builtInRules = [
  Rule(
    id: 'close_above_ma20',
    name: '收盘价站上MA20',
    test: (s) => s.close > s.ma20,
  ),
  Rule(
    id: 'ma5_golden_ma10',
    name: 'MA5上穿MA10',
    test: (s) => s.prevMa5 <= s.prevMa10 && s.ma5 > s.ma10,
  ),
  Rule(
    id: 'macd_golden_cross',
    name: 'MACD金叉',
    test: (s) => s.prevDif <= s.prevDea && s.dif > s.dea,
  ),
  Rule(
    id: 'rsi_oversold',
    name: 'RSI超卖(RSI14<30)',
    test: (s) => s.rsi14 < 30,
  ),
  Rule(
    id: 'rsi_overbought',
    name: 'RSI超买(RSI14>70)',
    test: (s) => s.rsi14 > 70,
  ),
  Rule(
    id: 'volume_surge',
    name: '量比>2',
    test: (s) => s.volumeRatio > 2,
  ),
  Rule(
    id: 'pct_change_up',
    name: '当日涨幅>3%',
    test: (s) => s.pctChange > 3,
  ),
];

/// 按 id 取内置规则。
Rule ruleById(String id) =>
    builtInRules.firstWhere((r) => r.id == id, orElse: () => throw ArgumentError('未知规则: $id'));
