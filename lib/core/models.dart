/// 行情领域模型。规则引擎与 UI 共用的最小数据结构。
library;

/// 一根日 K。
class Bar {
  const Bar({
    required this.date,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    this.amount = 0,
  });

  final DateTime date;
  final double open;
  final double high;
  final double low;
  final double close;

  /// 成交量（股或手，随数据源口径，指标只做比值运算）。
  final double volume;

  /// 成交额（千元，tushare 口径；仅展示用，旧数据可能为 0）。
  final double amount;
}

/// 一只股票的完整日线序列，按日期升序。
class StockData {
  const StockData({required this.symbol, required this.bars});

  final String symbol;
  final List<Bar> bars;

  Bar get last => bars.last;
}
