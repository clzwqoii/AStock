/// 规则筛选入口：把规则列表应用到一批股票。
library;

import 'models.dart';
import 'rules.dart';

/// 用选定规则筛选股票，全部规则满足才入选（AND）。
/// 单规则选股传一条；组合选股传多条。历史不足 [minBars] 根的股票直接跳过。
List<StockData> screen(
  List<StockData> stocks,
  List<Rule> rules, {
  int minBars = IndicatorSnapshot.minBars,
}) {
  if (rules.isEmpty) {
    throw ArgumentError('至少选择一条规则');
  }
  return [
    for (final stock in stocks)
      if (stock.bars.length >= minBars &&
          rules.every((r) => r.test(IndicatorSnapshot.fromStock(stock))))
        stock,
  ];
}
