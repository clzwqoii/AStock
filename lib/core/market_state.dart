/// 市场状态判定：全市场等权横截面自算牛/熊/震荡。
///
/// 口径与回测的「无条件基准」同源（等权，不偏袒大票）——官方市值加权指数
/// 被银行石油绑架，「赚指数不赚钱」时它判的牛市对本软件的选股规则没有意义。
/// 数据零新增：全部从库里已有的个股日线算出。
library;

import 'indicators.dart';
import 'market.dart';
import 'models.dart';

/// 分类阈值（%）。“近 20 日涨跌幅”达到 ±3% 且指数在 MA120 正确一侧才算牛/熊；
/// 低于 MA 超过 5% 直接判熊（阴跌磨底近 20 日可能没再跌，但结构已坏）。
/// 定档依据见 docs/project-structure.md「市场状态与近期窗口口径」。
const double kBullRet20 = 3.0;
const double kBearRet20 = -3.0;
const double kBearMaGap = -5.0;

enum MarketRegime {
  bull('牛市'),
  bear('熊市'),
  sideways('震荡'),
  insufficient('数据不足');

  final String label;
  const MarketRegime(this.label);
}

/// 纯分类函数（阈值边界在这里，单独可测）。
MarketRegime classifyRegime({required double maGap, required double ret20}) {
  if (maGap > 0 && ret20 >= kBullRet20) return MarketRegime.bull;
  if (maGap < 0 && (ret20 <= kBearRet20 || maGap <= kBearMaGap)) {
    return MarketRegime.bear;
  }
  return MarketRegime.sideways;
}

class MarketState {
  const MarketState({
    required this.regime,
    required this.asOfDate,
    required this.stockCount,
    required this.maGap,
    required this.ret20,
    required this.breadthAboveMa20,
    required this.newHighLowDiff20,
  });

  final MarketRegime regime;

  /// 数据截至日（YYYY-MM-DD）。
  final String asOfDate;

  /// 参与宽度/新高新低统计的股票数（历史 ≥ statWindow+1 根，且样本本身可信：
  /// 末根滞后在容忍交易日内、近 [kCorporateActionLookbackBars] 根无除权断层）。
  final int stockCount;

  /// 等权指数相对其 MA(maPeriod) 的偏离（%，正 = 均线上方）。
  final double maGap;

  /// 等权指数近 statWindow 日涨跌幅（%）。
  final double ret20;

  /// 站上自身 MA(statWindow) 的股票占比（0~1）。
  final double breadthAboveMa20;

  /// 创 statWindow 日新高 − 新低的股票占比（带符号，0.1 = 新高比新低多 10pp）。
  final double newHighLowDiff20;

  Map<String, Object?> toJson() => {
        'regime': regime.name,
        'asOfDate': asOfDate,
        'stockCount': stockCount,
        'maGap': maGap,
        'ret20': ret20,
        'breadthAboveMa20': breadthAboveMa20,
        'newHighLowDiff20': newHighLowDiff20,
      };

  factory MarketState.fromJson(Map<String, Object?> json) => MarketState(
        regime: MarketRegime.values.asNameMap()[json['regime']] ??
            MarketRegime.insufficient,
        asOfDate: json['asOfDate'] as String? ?? '',
        stockCount: json['stockCount'] as int? ?? 0,
        maGap: (json['maGap'] as num?)?.toDouble() ?? 0,
        ret20: (json['ret20'] as num?)?.toDouble() ?? 0,
        breadthAboveMa20: (json['breadthAboveMa20'] as num?)?.toDouble() ?? 0,
        newHighLowDiff20: (json['newHighLowDiff20'] as num?)?.toDouble() ?? 0,
      );
}

/// [maPeriod] 等权指数均线窗口；[recentDays] 参与指数计算的最近交易日数；
/// [statWindow] 近端统计窗口（ret20 / 宽度 MA / 新高新低共用）。
///
/// [maxLastBarLagTradingDays] 与 [corporateActionLookbackBars] 是宽度/新高新低的
/// 样本护栏（见函数内注释）：前者按**交易日**判末根陈旧度（负值 = 关闭），
/// 后者 0 = 关闭除权判定。
///
/// 测试用小窗口注入；生产走默认值。
MarketState assessMarketState(
  List<StockData> stocks, {
  int maPeriod = 120,
  int recentDays = 130,
  int statWindow = 20,
  int maxLastBarLagTradingDays = 20,
  int corporateActionLookbackBars = kCorporateActionLookbackBars,
}) {
  final allDays = tradingCalendar(stocks).toList()..sort();
  final asOf = allDays.isEmpty
      ? ''
      : '${allDays.last.year}-${allDays.last.month.toString().padLeft(2, '0')}-'
          '${allDays.last.day.toString().padLeft(2, '0')}';

  final minStatBars = statWindow + 1;
  final need = maPeriod > minStatBars ? maPeriod : minStatBars;
  if (allDays.length < need) {
    return MarketState(
      regime: MarketRegime.insufficient,
      asOfDate: asOf,
      stockCount: 0,
      maGap: 0,
      ret20: 0,
      breadthAboveMa20: 0,
      newHighLowDiff20: 0,
    );
  }

  // 等权指数：窗口内每个交易日，有行情的股票收盘均值。
  // recentDays 不得小于 need（至少装得下 maPeriod 与 statWindow+1），
  // 否则指数序列不足以支撑均线/区间涨跌幅回溯，会抛 RangeError。
  final effectiveRecentDays = recentDays < need ? need : recentDays;
  final windowDays = allDays.length > effectiveRecentDays
      ? allDays.sublist(allDays.length - effectiveRecentDays)
      : allDays;
  final inWindow = Set<DateTime>.from(windowDays);
  final sum = <DateTime, double>{};
  final count = <DateTime, int>{};
  for (final s in stocks) {
    for (final b in s.bars) {
      if (!inWindow.contains(b.date)) continue;
      sum[b.date] = (sum[b.date] ?? 0) + b.close;
      count[b.date] = (count[b.date] ?? 0) + 1;
    }
  }
  final index = [
    for (final d in windowDays)
      // [tradingCalendar] 只收「当天行数 ≥ max(1, 中位/2)」的日子，windowDays 又全部
      // 取自它，所以这里恒有行——0.0 兜底逻辑上不可达。留着是防御：真到了那一步，
      // 把"当天没行情"当成指数 0 点会把 MA120/ret20 整个拉歪，比抛错更糟；assert
      // 让"将来日历改成工作日候选"这类改动在测试期当场爆，生产仍走兜底不崩。
      _indexPoint(d, sum, count),
  ];

  final last = index.last;
  final ma = index.sublist(index.length - maPeriod).reduce((a, b) => a + b) /
      maPeriod;
  final maGap = (last - ma) / ma * 100;
  final ret = (last / index[index.length - 1 - statWindow] - 1) * 100;

  // 宽度与新高新低是**逐股布尔计数**，样本本身必须先可信（等权指数不受这两条
  // 影响：停牌日没有行不进当日均值，除权跳变被全市场摊薄）：
  // - 停牌/退市股的末根可能滞后数月，用陈旧收盘价参与"今天"的计数，等于把停牌前
  //   的状态一直冻结进分子（回测池不过滤 ST/退市整理股，实测这类股量级不小）；
  // - 库内不复权，末根附近除权留下的永久价位断层会让"个股 vs 自身 MA20"与
  //   "末 N 根高低"误判成破位/新低。
  final calIndex = {for (var i = 0; i < allDays.length; i++) allDays[i]: i};
  final lastCalIndex = allDays.length - 1;

  var evaluated = 0;
  var above = 0;
  var highs = 0;
  var lows = 0;
  for (final s in stocks) {
    if (s.bars.length < minStatBars) continue;
    final at = calIndex[s.bars.last.date];
    if (at == null) continue; // 末根不在共同交易日历里，不参与
    if (maxLastBarLagTradingDays >= 0 &&
        lastCalIndex - at > maxLastBarLagTradingDays) {
      continue; // 停牌/退市：末根已陈旧到不能代表"今天"
    }
    if (corporateActionLookbackBars > 0) {
      if (!isCleanSignalDay(s.symbol, s.bars, s.bars.length - 1,
          lookbackBars: corporateActionLookbackBars)) {
        continue; // 末根落在除权断层后不久：MA/高低点还跨着断层
      }
    }
    evaluated++;
    final tailBars = s.bars.sublist(s.bars.length - minStatBars);
    final tailCloses = [for (final b in tailBars) b.close];
    final lastClose = tailCloses.last;
    if (lastClose > sma(tailCloses, statWindow)) above++;
    if (lastClose >= tailCloses.reduce((a, b) => a > b ? a : b)) highs++;
    if (lastClose <= tailCloses.reduce((a, b) => a < b ? a : b)) lows++;
  }

  return MarketState(
    regime: classifyRegime(maGap: maGap, ret20: ret),
    asOfDate: asOf,
    stockCount: evaluated,
    maGap: maGap,
    ret20: ret,
    breadthAboveMa20: evaluated == 0 ? 0 : above / evaluated,
    newHighLowDiff20: evaluated == 0 ? 0 : (highs - lows) / evaluated,
  );
}

/// 等权指数在某交易日的点位。抽出成函数只为了能放 assert（集合表达式里写不了）。
double _indexPoint(
    DateTime d, Map<DateTime, double> sum, Map<DateTime, int> count) {
  final n = count[d];
  assert(n != null && n > 0, '交易日历含 $d，但全市场当天一行行情都没有');
  return n == null || n == 0 ? 0.0 : sum[d]! / n;
}
