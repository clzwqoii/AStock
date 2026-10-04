/// 测试用行情序列。期望指标值由独立 python 脚本计算（非本实现），作为基准 oracle。
library;

import 'package:stock/core/models.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/tushare_client.dart';

/// 最小 Bar 构造：开高低收都取 close，日期固定。
Bar bar({double close = 10.0, double volume = 100.0}) => Bar(
      date: DateTime(2024),
      open: close,
      high: close,
      low: close,
      close: close,
      volume: volume,
    );

/// 通用 StockData 构造：只有最后一根的成交量可指定。
StockData stockOf(
  List<double> closes, {
  String symbol = 'T',
  double lastVolume = 100.0,
}) => StockData(
      symbol: symbol,
      bars: [
        for (var i = 0; i < closes.length; i++)
          bar(close: closes[i], volume: i == closes.length - 1 ? lastVolume : 100.0),
      ],
    );

/// V 型反转：前 20 根每日 -0.3，后 20 根每日 +0.5。
/// 基准值：dif[38]=1.5654038808830428 dif[39]=1.694253775402938
///        dea[38]=0.9521737450143762 dea[39]=1.1005897510920888
///        ma5[38]=22.8 ma5[39]=23.3 ma10[38]=21.55 ma10[39]=22.05 ma20[39]=19.55
///        rsi14[39]=85.00915283788616；MACD 金叉与 MA5 上穿 MA10 均发生在下标 23。
List<double> closesVRecovery() => [
      for (var i = 0; i < 20; i++) 20.0 - 0.3 * i,
      for (var i = 20; i < 40; i++) 14.3 + 0.5 * (i - 19),
    ];

/// 单边下跌：40 根每日 -0.5。rsi14[39]=0.0，无任何金叉，ma20[39]=15.25。
List<double> closesCrash() => [for (var i = 0; i < 40; i++) 30.0 - 0.5 * i];

const _seedDates = [
  '20260810', '20260811', '20260812', '20260813', '20260814', '20260817', '20260818',
  '20260819', '20260820', '20260821', '20260824', '20260825', '20260826', '20260827',
  '20260828', '20260831', '20260901', '20260902', '20260903', '20260904', '20260907',
  '20260908', '20260909', '20260910', '20260911', '20260914', '20260915', '20260916',
  '20260917', '20260918', '20260921', '20260922', '20260923', '20260924', '20260925',
  '20260928', '20260929', '20260930', '20261001', '20261002',
];

/// 写入两只演示股票到 [dbPath]：S1 末根涨5%+放量(量比3)，S2 只涨5%。
void seedStocks(String dbPath) {
  void addStock(String tsCode, double lastVol) {
    final repo = BarRepository(dbPath);
    repo.upsertBars([
      for (var i = 0; i < 40; i++)
        DailyRow(
          tsCode: tsCode,
          tradeDate: _seedDates[i],
          open: 10.0,
          high: 10.0,
          low: 10.0,
          close: i == 39 ? 10.5 : 10.0,
          vol: i == 39 ? lastVol : 100.0,
          amount: 1,
        ),
    ]);
    repo.close();
  }

  addStock('S1.SH', 300);
  addStock('S2.SZ', 100);
}
