/// 选股规则筛选入口：把规则列表应用到一批股票。
library;

import 'market.dart';
import 'models.dart';
import 'rules.dart';

/// 末根早于「选股池内最大交易日」超过这么多**日历日**的股票直接出池。
///
/// 选股用的是每只股票的**末日快照**，这隐含一个假设：每只票的末根 ≈ 今天。
/// 停牌/退市的股票不满足——库里它们的最后一根可能远在一年前
/// （实测 4776 只的池子里有 18 只，其中 10 只滞后一年以上：海印股份、
/// 中银绒业、鹏都农牧、广汇汽车、正源股份、中航产融、海传证券…）。
/// 它们名字不带 ST/退 前缀，`excludeSpecialStocks` 拦不住，
/// 而它们清一色是"大跌的票"，在下跌尽头极容易被超卖类规则选中：
/// 实测 2026-09-30 那天主规则选出的 4 只里有 2 只是这种两年前的化石信号。
///
/// 30 日历日 ≈ 20 个交易日：短于这个的停牌股仍保留（复牌那天它会是新鲜信号）。
/// 传 0 关闭护栏，用于复现旧口径做对照。
///
/// **回测侧不要这个过滤**：逐日回放里"末根必须等于全池最后交易日"
/// 等于要求这只票活到数据末尾，那是未来信息（存活者偏差），会让回测偏乐观。
const kMaxLastBarLagDays = 30;

/// 一次筛选的命中结果：股票本身 + **命中的规则 id**（组合选股 = 全部命中）。
/// [snapshot] 是筛选时已经建好的末日快照，调用方直接复用——
/// 不要再对同一只股票重复 [IndicatorSnapshot.fromStock]（那会重建整条指标序列）。
class ScreenHit {
  const ScreenHit(this.stock, this.matchedRuleIds, this.snapshot);

  final StockData stock;

  /// 命中的规则 id，顺序与传入规则一致；AND 筛选下长度 == 规则条数。
  final List<String> matchedRuleIds;

  /// 该股末根的指标快照（筛选时构建，与 [IndicatorSnapshot.fromStock(stock)] 等价）。
  final IndicatorSnapshot snapshot;
}

/// 用选定规则筛选股票，全部规则满足才入选（AND）。
/// 单规则选股传一条；组合选股传多条。历史不足 [minBars] 根的股票直接跳过。
List<StockData> screen(
  List<StockData> stocks,
  List<Rule> rules, {
  int minBars = IndicatorSnapshot.minBars,
  int maxLastBarLagDays = kMaxLastBarLagDays,
  int corporateActionLookbackBars = kCorporateActionLookbackBars,
  int suspensionLookbackBars = kSuspensionLookbackBars,
}) =>
    [
      for (final h in screenWithHits(
        stocks,
        rules,
        minBars: minBars,
        maxLastBarLagDays: maxLastBarLagDays,
        corporateActionLookbackBars: corporateActionLookbackBars,
        suspensionLookbackBars: suspensionLookbackBars,
      ))
        h.stock
    ];

/// 与 [screen] 同口径，但额外带回每只股票命中的规则 id（结果表「命中规则」列用）。
///
/// 两个数据卫生护栏（默认开启，传 0 可关）：
/// - [maxLastBarLagDays]：末根陈旧到不是"今天"的股票出池，见 [kMaxLastBarLagDays]；
/// - [corporateActionLookbackBars]：信号日落在除权/复牌后 N 根内不出信号，
///   见 [kCorporateActionLookbackBars]。库内是不复权价，除权日的价位断层
///   会把 RSI 砸成假超卖——那些信号历史上跑不赢基准，不是边角料。
List<ScreenHit> screenWithHits(
  List<StockData> stocks,
  List<Rule> rules, {
  int minBars = IndicatorSnapshot.minBars,
  int maxLastBarLagDays = kMaxLastBarLagDays,
  int corporateActionLookbackBars = kCorporateActionLookbackBars,
  int suspensionLookbackBars = kSuspensionLookbackBars,
}) =>
    screenDiagnostics(
      stocks,
      rules,
      minBars: minBars,
      maxLastBarLagDays: maxLastBarLagDays,
      corporateActionLookbackBars: corporateActionLookbackBars,
      suspensionLookbackBars: suspensionLookbackBars,
    ).hits;

/// [screenWithHits] 的带统计版本：除命中外，还带回三个护栏各**挡掉的入选数**。
///
/// 为什么要这个数：护栏是**静默**起作用的，用户只会看到"入选变少了"，
/// 不知道为什么。实测主规则 2026-09-30 关护栏能选出 4 只，其中 2 只是两年前
/// 就停牌的化石票、1 只的"大跌"来自除权日的机械跌幅——只显示"入选 1 只"，
/// 用户无法区分"规则没信号"和"信号被数据卫生挡了"。
///
/// 计数只算**本来会入选**的票（被挡住的也先判一遍规则）。池子里陈旧的
/// 停牌/退市股有十几只，但它们本来也不会被这条规则选中，报出来只会造成
/// "过滤了好多"的错觉。
///
/// 只有一个实现，[screenWithHits] 与 [screen] 都走这里，避免两条路径分叉。
({List<ScreenHit> hits,
  int blockedStale,
  int blockedCorporateAction,
  int blockedSuspension}) screenDiagnostics(
  List<StockData> stocks,
  List<Rule> rules, {
  int minBars = IndicatorSnapshot.minBars,
  int maxLastBarLagDays = kMaxLastBarLagDays,
  int corporateActionLookbackBars = kCorporateActionLookbackBars,
  int suspensionLookbackBars = kSuspensionLookbackBars,
}) {
  if (rules.isEmpty) {
    throw ArgumentError('至少选择一条规则');
  }
  final poolLast = _poolLastDate(stocks);
  // 停牌洞要用全市场交易日历判（节假日全市场一起休，只有停牌是个股缺），
  // 日历从同一个池子统计，一次算清。
  final calendar = tradingCalendar(stocks);
  var blockedSuspension = 0;
  final hits = <ScreenHit>[];
  var blockedStale = 0, blockedCorporateAction = 0;
  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < minBars) continue;
    // 护栏一：末根不是"今天"（停牌/退市的化石序列）。
    final stale = maxLastBarLagDays > 0 &&
        poolLast.difference(bars.last.date).inDays > maxLastBarLagDays;
    if (stale) {
      // 只为统计"这条规则原本会不会选它"：被挡住的票只有十几只，
      // 多建一次快照的成本可忽略，但计数必须诚实。
      if (_matchesAll(stock, rules)) blockedStale++;
      continue;
    }
    // 护栏二：信号日踩在除权/复牌的指标污染窗口内。
    if (!isCleanSignalDay(
      stock.symbol,
      bars,
      bars.length - 1,
      lookbackBars: corporateActionLookbackBars,
    )) {
      if (_matchesAll(stock, rules)) blockedCorporateAction++;
      continue;
    }
    // 护栏三：停牌复牌后的指标污染窗口（MA/RSI 跨着洞算）。
    // 性能优化：仅当护栏开启时才算，且只算尾部窗口（省去历史白算）。
    // 窗口起点走 [lookbackWindowStart]，与判定函数共用同一处定义。
    if (suspensionLookbackBars > 0) {
      final gapDays = tradingDaysSincePrevBar(
        bars,
        calendar,
        startFrom: lookbackWindowStart(bars.length - 1, suspensionLookbackBars),
      );
      if (hasSuspensionGapNearby(
        gapDays,
        bars.length - 1,
        lookbackBars: suspensionLookbackBars,
      )) {
        if (_matchesAll(stock, rules)) blockedSuspension++;
        continue;
      }
    }
    final snap = IndicatorSnapshot.fromStock(stock);
    final matched = [for (final r in rules) if (r.test(snap)) r.id];
    if (matched.length == rules.length) hits.add(ScreenHit(stock, matched, snap));
  }
  return (
    hits: hits,
    blockedStale: blockedStale,
    blockedCorporateAction: blockedCorporateAction,
    blockedSuspension: blockedSuspension,
  );
}

/// 该股末根是否满足全部规则（护栏统计用：判断"本来会不会入选"）。
bool _matchesAll(StockData stock, List<Rule> rules) {
  final snap = IndicatorSnapshot.fromStock(stock);
  return rules.every((r) => r.test(snap));
}

/// 选股池内最大交易日。所有股票的"末日"都应等于它，否则该股的信号是旧闻。
DateTime _poolLastDate(List<StockData> stocks) {
  var latest = stocks.first.bars.last.date;
  for (final s in stocks) {
    final d = s.bars.last.date;
    if (d.isAfter(latest)) latest = d;
  }
  return latest;
}
