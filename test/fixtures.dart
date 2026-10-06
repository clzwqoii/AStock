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

/// V 型反转 + 固定 ±0.3 高低带宽（KDJ 需要真实 high/low；纯收盘序列高低相等）。
/// KDJ(9,3,3) 基准（python 独立计算；种子 K=D=50，前 8 根无值，高低相等时 RSV 取 50）：
///   k[8]=36.66666666666668   d[8]=45.555555555555564  j[8]=18.8888888888889
///   k[19]=10.308293865170379 d[19]=11.541469325851809 j[19]=7.8419429438075205
///   k[20]=16.748739119990137 d[20]=13.277225923897918 j[20]=23.69176551217458
///   k[38]=93.39653452226122  d[38]=92.94864065425686  j[38]=94.29232225826993
///   k[39]=93.42377663802921  d[39]=93.10701931551432  j[39]=94.05729128305899
/// KDJ 金叉发生在下标 20（K 上穿 D）。
List<Bar> barsWithBand() => [
      for (final c in closesVRecovery())
        Bar(date: DateTime(2024), open: c, high: c + 0.3, low: c - 0.3, close: c, volume: 100),
    ];

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

// ── 60 日线「有效突破」序列（基准值由 python 独立计算，断言见 rules_test）──
//
// 形态 A [barsMa60Breakout]（70 根 = breakoutWindowLength(11) + 60 − 1，
// 即有效突破窗口所需的最小历史）：
//   60 日横盘 20.0 → 6 日回落到 MA60 下方（突破前 5 日全部在线下）
//   → 第 66 根放量长阳（量 300、量比 3.0、突破日乖离 5.967%、
//     收盘位于当日振幅上半部 0.5714）上穿 MA60
//   → 第 66~69 根站稳 3 日（每日收盘均在当日 MA60 上方，最低价未深破 2%）。
// 末日基准值：ma5=21.304000000000002 ma10=20.577 ma20=20.2885
//   ma60=20.096166666666665 prevMa60=20.06116666666667
//   ma60Trend5=0.10866666666666447 bias60=9.971221708949486（多头排列成立）
//
// 形态 B [barsMa60Pullback]（83 根 ≥ pullbackWindowLength(20) + 60 − 1 = 79）：
//   64 日横盘 → 10 日回落线下 → 第 74 根放量上穿（突破日乖离 5.001%、量比 3.0）
//   → 站稳 4 日（75~78）→ 3 日缩量回踩（79~81，量 80 ≤ 突破日 300×0.8；
//     最低价 19.95/19.92/19.90 贴住 MA60，但收盘均不破线）
//   → 第 82 根放量阳线（量比 3.70、收盘位置 0.8801、收盘 21.8
//     收复回踩段最高收盘 21.6）。
// 末日基准值：ma5=20.82 ma10=20.919999999999998 ma20=20.4145
//   ma60=20.138166666666667 ma60Trend5=0.06833333333333158
//   bias60=8.252158008425138
// 注意：形态 B 突破后 MA5(20.82) < MA10(20.92) —— 真回踩必然把短期均线搅乱，
// 因此形态 B 只要求 MA20 > MA60，不要求完整多头排列（见 rules.dart 注释）。

/// 6 日回落段：从 MA60 上方跌到下方（形态 A 用）。
const _ma60Dip6 = [19.9, 19.85, 19.8, 19.82, 19.88, 19.92];

/// 10 日回落段：更长的前期线下盘整（形态 B 用）。
const _ma60Dip10 = [
  19.9, 19.85, 19.8, 19.82, 19.88, 19.92, 19.95, 19.98, 19.99, 19.9,
];

/// 有效突破序列专用日 K：开高低收/量/额可分别指定；
/// 未指定的高低取收盘 ±0.5%，额取「收盘×成交量」（与量比同口径，规则只用比值）。
/// [date] 默认全部取 2024——选股只比较前一日值，不关心绝对日期；
/// 回测要按日切快照，必须传递增日期。
Bar kbar({
  required double close,
  double? open,
  double? high,
  double? low,
  double volume = 100.0,
  double? amount,
  DateTime? date,
}) =>
    Bar(
      date: date ?? DateTime(2024),
      open: open ?? close,
      high: high ?? close * 1.005,
      low: low ?? close * 0.995,
      close: close,
      volume: volume,
      amount: amount ?? close * volume,
    );

/// 形态 A 收盘序列（70 根）。
List<double> closesMa60Breakout() => [
      ...List.filled(60, 20.0),
      ..._ma60Dip6,
      21.2, 21.5, 21.8, 22.1,
    ];

/// 形态 A：突破并站稳 MA60。第 66 根为突破日。
List<Bar> barsMa60Breakout() {
  final c = closesMa60Breakout();
  return [
    for (var i = 0; i < c.length; i++)
      kbar(
        close: c[i],
        volume: i == 66 ? 300.0 : (i >= 67 ? 150.0 : 100.0),
        open: i == 66 ? 20.6 : null,
        high: i == 66 ? 21.2 * 1.015 : null,
        low: i == 66 ? 21.2 * 0.98 : null,
      ),
  ];
}

/// 形态 B 收盘序列（83 根）。
List<double> closesMa60Pullback() => [
      ...List.filled(64, 20.0),
      ..._ma60Dip10,
      21.0,
      21.2, 21.4, 21.6, 21.55, // 站稳 75..78
      20.3, 20.2, 20.25, // 缩量回踩 79..81
      21.8, // 再启动 82
    ];

/// 形态 B：突破 → 缩量回踩不破 → 放量阳线收复。第 74 根为突破日。
List<Bar> barsMa60Pullback() {
  final c = closesMa60Pullback();
  return [
    for (var i = 0; i < c.length; i++)
      kbar(
        close: c[i],
        volume: i == 74
            ? 300.0
            : (i >= 75 && i <= 78
                ? 150.0
                : (i >= 79 && i <= 81 ? 80.0 : (i == 82 ? 400.0 : 100.0))),
        open: i == 82 ? 20.6 : null,
        high: i == 82 ? 21.8 * 1.005 : null,
        low: i == 79
            ? 19.95
            : (i == 80 ? 19.92 : (i == 81 ? 19.9 : (i == 82 ? 21.0 : null))),
      ),
  ];
}

/// 形态 A 的变体：按下标替换某些日 K（用于拆掉单条条件造反例）。
List<Bar> barsMa60BreakoutWith(Map<int, Bar> replace, {int? take}) {
  final base = barsMa60Breakout();
  final bars = take == null ? base : base.take(take).toList();
  return [for (var i = 0; i < bars.length; i++) replace[i] ?? bars[i]];
}

/// 形态 B 的变体：同上。
List<Bar> barsMa60PullbackWith(Map<int, Bar> replace, {int? take}) {
  final base = barsMa60Pullback();
  final bars = take == null ? base : base.take(take).toList();
  return [for (var i = 0; i < bars.length; i++) replace[i] ?? bars[i]];
}

// ── MA250（年线）序列（基准值由 python 独立计算）──
//
// 形态「年线上翘」（271 根 = MA250 所需 250 根 + 21 根余量）：
// 200 日从 25 线性跌到 21 → 71 日从 21 温和回升到 26.38。
// 末日基准值：ma250=23.06412 ma250Trend5=0.033279999999997756
//   bias250=14.723648680287837（多头排列成立、MA20 > MA250）
//
// 形态「年线下行」（270 根）：长下跌后仅弱反弹，MA250 继续向下。
// 末日基准值：ma250=22.5232 ma250Trend5=-0.029200000000003
//   bias250=3.004901612559485（MA20 > MA250，但 MA250 自身仍向下）
//
// 形态「急拉追高」（271 根）：MA250 同样上翘，但乖离 48.7% 远超上限。
// 末日基准值：ma250=24.4756 ma250Trend5=0.22639999999999816
//   bias250=48.71954109398749

/// 年线上翘（MA250 走平或上翘，且乖离在 15% 以内）。
List<double> closesMa250Up() => [
      for (var i = 0; i < 200; i++) 25.0 - 0.02 * i,
      for (var k = 0; k < 71; k++) 21.0 + 0.078 * k,
    ];

/// 年线仍下行（长下跌后仅弱反弹）。
List<double> closesMa250Down() => [
      for (var i = 0; i < 200; i++) 25.0 - 0.02 * i,
      ...List.filled(30, 21.0),
      ...List.filled(5, 21.5), ...List.filled(5, 21.8), ...List.filled(5, 22.0),
      ...List.filled(5, 22.2), ...List.filled(5, 22.5), ...List.filled(5, 22.8),
      ...List.filled(5, 23.0), ...List.filled(5, 23.2),
    ];

/// 急拉追高（MA250 上翘但乖离远超 15%）。
List<double> closesMa250Stretched() => [
      for (var i = 0; i < 200; i++) 25.0 - 0.02 * i,
      for (var k = 0; k < 71; k++) 21.0 + 0.22 * k,
    ];
