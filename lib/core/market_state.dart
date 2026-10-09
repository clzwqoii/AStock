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

/// 预算的全局上下文：从完整交易日历派生，在所有分片间共享。
/// 把 [assessMarketState] 里的日历准备逻辑（allDays / windowDays / calIndex）
/// 提到外面，使分片只算 [MarketStateContrib]、合并只走 [marketStateFromContrib]。
class MarketStateCtx {
  final List<DateTime> allDays;
  final Set<DateTime> inWindow;
  final Map<DateTime, int> calIndex;
  final int lastCalIndex;
  final int maPeriod, statWindow, maxLastBarLagTradingDays,
      corporateActionLookbackBars;

  const MarketStateCtx({
    required this.allDays,
    required this.inWindow,
    required this.calIndex,
    required this.lastCalIndex,
    required this.maPeriod,
    required this.statWindow,
    required this.maxLastBarLagTradingDays,
    required this.corporateActionLookbackBars,
  });

  factory MarketStateCtx.fromCalendar(
    Set<DateTime> calendar, {
    int maPeriod = 120,
    int recentDays = 130,
    int statWindow = 20,
    int maxLastBarLagTradingDays = 20,
    int corporateActionLookbackBars = kCorporateActionLookbackBars,
  }) {
    final allDays = calendar.toList()..sort();
    final minStatBars = statWindow + 1;
    final need = maPeriod > minStatBars ? maPeriod : minStatBars;
    final effectiveRecentDays = recentDays < need ? need : recentDays;
    final windowDays = allDays.length > effectiveRecentDays
        ? allDays.sublist(allDays.length - effectiveRecentDays)
        : allDays;
    return MarketStateCtx(
      allDays: allDays,
      inWindow: Set<DateTime>.from(windowDays),
      calIndex: {for (var i = 0; i < allDays.length; i++) allDays[i]: i},
      lastCalIndex: allDays.length - 1,
      maPeriod: maPeriod,
      statWindow: statWindow,
      maxLastBarLagTradingDays: maxLastBarLagTradingDays,
      corporateActionLookbackBars: corporateActionLookbackBars,
    );
  }
}

/// 分片级市场状态贡献：每股可并行算出，再 [mergeMarketStateContrib] 合并。
/// dayKey = d.year * 10000 + d.month * 100 + d.day（与回测最近窗口的 dayKey 同口径）。
class MarketStateContrib {
  final Map<int, double> daySums;
  final Map<int, int> dayCounts;
  final int evaluated, above, highs, lows;

  const MarketStateContrib({
    required this.daySums,
    required this.dayCounts,
    required this.evaluated,
    required this.above,
    required this.highs,
    required this.lows,
  });

  static const empty = MarketStateContrib(
    daySums: {},
    dayCounts: {},
    evaluated: 0,
    above: 0,
    highs: 0,
    lows: 0,
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
  final ctx = MarketStateCtx.fromCalendar(tradingCalendar(stocks),
      maPeriod: maPeriod,
      recentDays: recentDays,
      statWindow: statWindow,
      maxLastBarLagTradingDays: maxLastBarLagTradingDays,
      corporateActionLookbackBars: corporateActionLookbackBars);
  return marketStateFromContrib(marketStateContrib(stocks, ctx), ctx);
}

/// 分片级市场状态贡献：逐股扫描窗口内每日收盘均值与宽度/新高新低计数。
/// 与原 [assessMarketState] 内的两段循环逐位等价（sum/count 按股票→bar 序累积，
/// 宽度/高低是独立整数累加器，合并顺序不影响整数结果）。
MarketStateContrib marketStateContrib(
    List<StockData> stocks, MarketStateCtx ctx) {
  final daySums = <int, double>{};
  final dayCounts = <int, int>{};
  final minStatBars = ctx.statWindow + 1;
  var evaluated = 0, above = 0, highs = 0, lows = 0;
  for (final s in stocks) {
    for (final b in s.bars) {
      if (!ctx.inWindow.contains(b.date)) continue;
      final dayKey =
          b.date.year * 10000 + b.date.month * 100 + b.date.day;
      daySums[dayKey] = (daySums[dayKey] ?? 0) + b.close;
      dayCounts[dayKey] = (dayCounts[dayKey] ?? 0) + 1;
    }
    if (s.bars.length < minStatBars) continue;
    final at = ctx.calIndex[s.bars.last.date];
    if (at == null) continue;
    if (ctx.maxLastBarLagTradingDays >= 0 &&
        ctx.lastCalIndex - at > ctx.maxLastBarLagTradingDays) {
      continue;
    }
    if (ctx.corporateActionLookbackBars > 0) {
      if (!isCleanSignalDay(s.symbol, s.bars, s.bars.length - 1,
          lookbackBars: ctx.corporateActionLookbackBars)) {
        continue;
      }
    }
    evaluated++;
    final tailBars = s.bars.sublist(s.bars.length - minStatBars);
    final tailCloses = [for (final b in tailBars) b.close];
    final lastClose = tailCloses.last;
    if (lastClose > sma(tailCloses, ctx.statWindow)) above++;
    if (lastClose >= tailCloses.reduce((a, b) => a > b ? a : b)) highs++;
    if (lastClose <= tailCloses.reduce((a, b) => a < b ? a : b)) lows++;
  }
  return MarketStateContrib(
    daySums: daySums,
    dayCounts: dayCounts,
    evaluated: evaluated,
    above: above,
    highs: highs,
    lows: lows,
  );
}

/// 合并多分片贡献：daySums/dayCounts 按日键累加，宽度整数直接求和。
/// 浮点 sum 的分组顺序与串行路径可能 ulp 级不同，市场状态测试用 closeTo。
MarketStateContrib mergeMarketStateContrib(List<MarketStateContrib> parts) {
  final daySums = <int, double>{};
  final dayCounts = <int, int>{};
  var evaluated = 0, above = 0, highs = 0, lows = 0;
  for (final p in parts) {
    for (final e in p.daySums.entries) {
      daySums[e.key] = (daySums[e.key] ?? 0) + e.value;
    }
    for (final e in p.dayCounts.entries) {
      dayCounts[e.key] = (dayCounts[e.key] ?? 0) + e.value;
    }
    evaluated += p.evaluated;
    above += p.above;
    highs += p.highs;
    lows += p.lows;
  }
  return MarketStateContrib(
    daySums: daySums,
    dayCounts: dayCounts,
    evaluated: evaluated,
    above: above,
    highs: highs,
    lows: lows,
  );
}

/// 由合并后的贡献 + 全局上下文重建 [MarketState]。
/// 逻辑与原 [assessMarketState] 收尾段逐字一致：重建等权指数序列、算
/// maGap/ret/宽度/新高新低。
MarketState marketStateFromContrib(
    MarketStateContrib contrib, MarketStateCtx ctx) {
  final asOf = ctx.allDays.isEmpty
      ? ''
      : '${ctx.allDays.last.year}-${ctx.allDays.last.month.toString().padLeft(2, '0')}-'
          '${ctx.allDays.last.day.toString().padLeft(2, '0')}';
  final minStatBars = ctx.statWindow + 1;
  final need = ctx.maPeriod > minStatBars ? ctx.maPeriod : minStatBars;
  if (ctx.allDays.length < need) {
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
  final windowDays = [
    for (final d in ctx.allDays) if (ctx.inWindow.contains(d)) d,
  ];
  final index = [
    for (final d in windowDays) _indexPointFromContrib(d, contrib),
  ];
  final last = index.last;
  final ma = index.sublist(index.length - ctx.maPeriod).reduce((a, b) => a + b) /
      ctx.maPeriod;
  final maGap = (last - ma) / ma * 100;
  final ret = (last / index[index.length - 1 - ctx.statWindow] - 1) * 100;
  return MarketState(
    regime: classifyRegime(maGap: maGap, ret20: ret),
    asOfDate: asOf,
    stockCount: contrib.evaluated,
    maGap: maGap,
    ret20: ret,
    breadthAboveMa20:
        contrib.evaluated == 0 ? 0 : contrib.above / contrib.evaluated,
    newHighLowDiff20: contrib.evaluated == 0
        ? 0
        : (contrib.highs - contrib.lows) / contrib.evaluated,
  );
}

/// 等权指数在某交易日的点位（从 [MarketStateContrib] 的 dayKey 映射取值）。
double _indexPointFromContrib(DateTime d, MarketStateContrib contrib) {
  final dayKey = d.year * 10000 + d.month * 100 + d.day;
  final n = contrib.dayCounts[dayKey];
  assert(n != null && n > 0, '交易日历含 $d，但全市场当天一行行情都没有');
  if (n == null || n == 0) return 0.0;
  return contrib.daySums[dayKey]! / n;
}
