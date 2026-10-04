/// 选股规则筛选入口：把规则列表应用到一批股票。
library;

import 'models.dart';
import 'rules.dart';

/// 一次筛选的命中结果：股票本身 + **命中的规则 id**（组合选股 = 全部命中）。
class ScreenHit {
  const ScreenHit(this.stock, this.matchedRuleIds);

  final StockData stock;

  /// 命中的规则 id，顺序与传入的规则一致；AND 筛选下长度 == 规则条数。
  final List<String> matchedRuleIds;
}

/// 用选定规则筛选股票，全部规则满足才入选（AND）。
/// 单规则选股传一条；组合选股传多条。历史不足 [minBars] 根的股票直接跳过。
List<StockData> screen(
  List<StockData> stocks,
  List<Rule> rules, {
  int minBars = IndicatorSnapshot.minBars,
}) =>
    [for (final h in screenWithHits(stocks, rules, minBars: minBars)) h.stock];

/// 与 [screen] 同口径，但额外带回每只股票命中的规则 id（结果表「命中规则」列用）。
List<ScreenHit> screenWithHits(
  List<StockData> stocks,
  List<Rule> rules, {
  int minBars = IndicatorSnapshot.minBars,
}) {
  if (rules.isEmpty) {
    throw ArgumentError('至少选择一条规则');
  }
  final hits = <ScreenHit>[];
  for (final stock in stocks) {
    if (stock.bars.length < minBars) continue;
    final snap = IndicatorSnapshot.fromStock(stock);
    final matched = [for (final r in rules) if (r.test(snap)) r.id];
    if (matched.length == rules.length) hits.add(ScreenHit(stock, matched));
  }
  return hits;
}
