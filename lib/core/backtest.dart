/// 规则回测：逐日滚动评估规则，统计信号日之后 N 日的收益分布，
/// 并与**同一起点集合、同一时间窗**的无条件基准（base rate）对比。
///
/// 没有基准，胜率高不高无从谈起——一条规则 55% 胜率可能是好消息也可能是坏消息，
/// 取决于同期随便买一只股票有多少概率上涨。
library;

import 'dart:math' as math;

import 'market.dart';
import 'market_state.dart';
import 'models.dart';
import 'rules.dart';

/// 回测报告覆盖的持有期（天）。页面展示与 CLI 默认都用这套。
const kDefaultHorizons = [5, 10, 20];

/// 「最近半年」窗口的交易日数。App（runBacktest）、CLI（report_all --archive）、
/// 探针三处共用一个常量——台账里的连红计数要求每期快照的窗口口径一致。
const kRecentWindowTradingDays = 120;

/// 报告生成时刻（供落盘与"是否过期"判断用）。
typedef BacktestClock = String Function();

/// 一次信号及其后续收益。
class SignalOutcome {
  const SignalOutcome({
    required this.symbol,
    required this.date,
    required this.close,
    required this.forwardReturn,
  });

  /// 股票代码。
  final String symbol;

  /// 信号日（K 线日期）。
  final DateTime date;

  /// 信号日收盘价。
  final double close;

  /// 信号日之后 forwardDays 日的收益率（%）。前瞻窗口不足的信号不会产生 outcome。
  final double forwardReturn;
}

/// 一组前瞻收益的统计量。可序列化——报告落盘只需要它，
/// 不需要保留每一个信号（全量信号有上百万个，JSON 会到 GB 级）。
/// 一条规则的信号在月份上的分布。
///
/// ## 为什么需要这一项
///
/// 现有的 count / winRate / 盈亏比都答不上一个问题：
/// **这条规则的胜率是均匀赚来的，还是靠一两个月爆发撑起来的？**
///
/// 实测 `rsi_oversold_volume` 三年 7496 个信号里有 **73.7% 集中在
/// 2024-02 单月**（那个月全市场基准胜率 80.3%，规则胜率 98.4%）。
/// 按全样本胜率排它是第一名，但剔除那个月后只剩 1875 个信号散布在 35 个月。
/// 没有这个字段，任何人重新看这份报告都会得出"严格版更强"的结论——
/// 而这正是发生过的事。
///
/// [topMonthShare] 越接近 1 越可疑。[monthsWithSignals] 越接近样本期内的
/// 总月数越可信。两者要一起看：单月占比高但月份多，可能只是信号多。
class RuleProfile {
  const RuleProfile({
    required this.signalCount,
    required this.monthsWithSignals,
    required this.topMonthShare,
    this.topMonth,
  });

  final int signalCount;
  final int monthsWithSignals;

  /// 最大单月信号数 / 总信号数，取值 (0, 1]。
  final double topMonthShare;

  /// 占比最高的那个月，`yyyyMM`（如 [202402] = 2024 年 2 月）。
  ///
  /// 用于在 UI 上点名具体月份——只说"集中"没用，用户需要知道该避开
  /// 哪一段行情。旧报告没有这个字段，读成 null（未知），此时退回到
  /// 笼统的"集中单月"，**不猜月份**。
  final int? topMonth;

  static const empty =
      RuleProfile(signalCount: 0, monthsWithSignals: 0, topMonthShare: 0);

  Map<String, dynamic> toJson() => {
        'signalCount': signalCount,
        'monthsWithSignals': monthsWithSignals,
        'topMonthShare': topMonthShare,
        if (topMonth != null) 'topMonth': topMonth,
      };

  factory RuleProfile.fromJson(Map<String, dynamic> json) {
    final raw = json['topMonthShare'];
    return RuleProfile(
      signalCount: json['signalCount'] as int,
      monthsWithSignals: json['monthsWithSignals'] as int,
      // 旧报告没有这个字段：读成 0（= 未知），避免把 null 当"不集中"
      topMonthShare: (raw as num?)?.toDouble() ?? 0,
      topMonth: (json['topMonth'] as num?)?.toInt(),
    );
  }
}

/// 单月信号占比超过此值即视为"集中"，跨年稳健的判定要因此打折。
const kRuleTopMonthShareCeiling = 0.6;

/// 主力月占比判定所需的最小信号量。低于此值时占比没有意义
/// （1 个信号 → 100%，但不是"集中"而是"没有数据"）。
const kRuleTopMonthShareMinSignals = 100;

class BacktestStats {
  const BacktestStats({
    required this.count,
    required this.winRate,
    required this.avgReturn,
    required this.medianReturn,
    required this.bestReturn,
    required this.worstReturn,
    required this.profitFactor,
    this.p10,
    this.p25,
    this.p75,
    this.p90,
    this.stdDev,
  });

  /// 全空统计（该年/该持有期无任何样本）。[BacktestStats.of] 对空列表也返回同一组值，
  /// 抽成常量供两处共用，避免"空"的表示出现第二种写法。
  static const empty = BacktestStats(
    count: 0,
    winRate: 0,
    avgReturn: 0,
    medianReturn: 0,
    bestReturn: 0,
    worstReturn: 0,
    profitFactor: 0,
  );

  factory BacktestStats.of(List<double> xs) {
    if (xs.isEmpty) return empty;
    final n = xs.length;
    var gain = 0.0, loss = 0.0, sum = 0.0;
    var winCount = 0;
    for (final x in xs) {
      sum += x;
      if (x > 0) {
        gain += x;
        winCount++;
      } else if (x < 0) {
        loss += -x;
      }
    }
    final sorted = [...xs]..sort();
    return BacktestStats(
      count: n,
      winRate: winCount / n,
      avgReturn: sum / n,
      medianReturn: _medianOfSorted(sorted),
      bestReturn: sorted.last,
      worstReturn: sorted.first,
      profitFactor: (gain == 0 || loss == 0) ? 0 : gain / loss,
      p10: _percentileOfSorted(sorted, 0.10),
      p25: _percentileOfSorted(sorted, 0.25),
      p75: _percentileOfSorted(sorted, 0.75),
      p90: _percentileOfSorted(sorted, 0.90),
      stdDev: _stdDevOfSorted(sorted, sum),
    );
  }

  final int count;
  final double winRate;
  final double avgReturn;
  final double medianReturn;
  final double bestReturn;
  final double worstReturn;

  /// 盈亏比 = 盈利总额 / 亏损总额；任一侧为 0 时返回 0（未定义，不外推）。
  final double profitFactor;

  /// 收益分布的 10/25/75/90 分位（%）。用于买卖预测价：
  /// 止损取 p10、乐观目标取 p75、中性目标用 [avgReturn]。
  /// **旧报告没有这些字段，读回为 null** —— UI 必须据此隐藏止损/目标列，
  /// 而不是把 null 当 0 显示成"止损价 0 元"。
  final double? p10;
  final double? p25;
  final double? p75;
  final double? p90;

  /// 收益样本标准差（%，样本方差 n-1）。空统计为 null。
  final double? stdDev;

  Map<String, dynamic> toJson() => {
        'count': count,
        'winRate': winRate,
        'avgReturn': avgReturn,
        'medianReturn': medianReturn,
        'bestReturn': bestReturn,
        'worstReturn': worstReturn,
        'profitFactor': profitFactor,
        'p10': p10,
        'p25': p25,
        'p75': p75,
        'p90': p90,
        'stdDev': stdDev,
      };

  factory BacktestStats.fromJson(Map<String, dynamic> json) => BacktestStats(
        count: json['count'] as int,
        winRate: (json['winRate'] as num).toDouble(),
        avgReturn: (json['avgReturn'] as num).toDouble(),
        medianReturn: (json['medianReturn'] as num).toDouble(),
        bestReturn: (json['bestReturn'] as num).toDouble(),
        worstReturn: (json['worstReturn'] as num).toDouble(),
        profitFactor: (json['profitFactor'] as num).toDouble(),
        // 分位数是后加的字段；旧报告缺失时读成 null（不抛），由 UI 降级隐藏。
        p10: (json['p10'] as num?)?.toDouble(),
        p25: (json['p25'] as num?)?.toDouble(),
        p75: (json['p75'] as num?)?.toDouble(),
        p90: (json['p90'] as num?)?.toDouble(),
        stdDev: (json['stdDev'] as num?)?.toDouble(),
      );
}


/// 样本标准差（n-1）。[sum] 为调用方已有的总和（[Tape] 累加了 sum，
/// 不必为算方差再走一遍求均值）。单样本返回 0。
double _stdDevOfSorted(List<double> sorted, double sum) {
  final n = sorted.length;
  if (n < 2) return 0;
  final m = sum / n;
  var acc = 0.0;
  for (final x in sorted) {
    final d = x - m;
    acc += d * d;
  }
  return math.sqrt(acc / (n - 1));
}

/// 同一起点集合、同一时间窗内的无条件收益基准。
class Baseline {
  Baseline({required this.forwardDays, required this.returns})
      : stats = BacktestStats.of(returns);

  const Baseline.fromStats({
    required this.forwardDays,
    required this.stats,
  }) : returns = const <double>[];

  final int forwardDays;

  /// 每个可评估日的收益率（%）。仅在内存中有意义；落盘只存 [stats]。
  final List<double> returns;

  /// 统计量（落盘与取数都走它）。
  final BacktestStats stats;

  int get count => stats.count;
  double get winRate => stats.winRate;
  double get avgReturn => stats.avgReturn;
  double get medianReturn => stats.medianReturn;
  double get bestReturn => stats.bestReturn;
  double get worstReturn => stats.worstReturn;
  double get profitFactor => stats.profitFactor;
  double? get p10 => stats.p10;
  double? get p25 => stats.p25;
  double? get p75 => stats.p75;
  double? get p90 => stats.p90;
  double? get stdDev => stats.stdDev;

  Map<String, dynamic> toJson() => {'forwardDays': forwardDays, ...stats.toJson()};

  factory Baseline.fromJson(Map<String, dynamic> json) => Baseline.fromStats(
        forwardDays: json['forwardDays'] as int,
        stats: BacktestStats.fromJson(json),
      );
}

/// 一条规则的滚动回测结果。
class BacktestResult {
  BacktestResult({
    required this.ruleId,
    required this.forwardDays,
    required List<SignalOutcome> outcomes,
  })  : stats = BacktestStats.of([for (final o in outcomes) o.forwardReturn]),
        outcomes = outcomes;

  /// 从落盘的统计量还原（没有逐信号明细，[outcomes] 为空）。
  const BacktestResult.fromStats({
    required this.ruleId,
    required this.forwardDays,
    required this.stats,
  }) : outcomes = const [];

  final String ruleId;
  final int forwardDays;

  /// 逐信号明细；仅在内存中有意义，落盘只存 [stats]。
  final List<SignalOutcome> outcomes;

  /// 统计量（取数与落盘都走它）。
  final BacktestStats stats;

  int get count => stats.count;
  double get winRate => stats.winRate;
  double get avgReturn => stats.avgReturn;
  double get medianReturn => stats.medianReturn;
  double get bestReturn => stats.bestReturn;
  double get worstReturn => stats.worstReturn;
  double get profitFactor => stats.profitFactor;
  double? get p10 => stats.p10;
  double? get p25 => stats.p25;
  double? get p75 => stats.p75;
  double? get p90 => stats.p90;
  double? get stdDev => stats.stdDev;

  Map<String, dynamic> toJson() => {
        'ruleId': ruleId,
        'forwardDays': forwardDays,
        ...stats.toJson(),
      };

  factory BacktestResult.fromJson(Map<String, dynamic> json) =>
      BacktestResult.fromStats(
        ruleId: json['ruleId'] as String,
        forwardDays: json['forwardDays'] as int,
        stats: BacktestStats.fromJson(json),
      );
}

/// 可评估日：每只股票 t ∈ [minBars, 末根 − forwardDays]。
/// 首日至少要 [IndicatorSnapshot.minBars] 根历史、末日要留出 forwardDays 根未来。
int evaluableDays(int barCount, int forwardDays) {
  if (barCount < IndicatorSnapshot.minBars + forwardDays) return 0;
  return barCount - forwardDays - IndicatorSnapshot.minBars;
}

/// 对 [stocks] 滚动回测 [rule]：每只股票在每个可评估日评一次规则，
/// 命中则记录信号日与之后 [forwardDays] 日的收益。
///
/// 快照只用 `bars[0..t]` 构造（见 [IndicatorSeries]），因此**不存在前瞻偏差**。
/// 同一只股票可能在多个日期重复出信号，信号之间不独立。
///
/// [corporateActionLookbackBars] 是除权/复牌护栏的回溯根数，默认
/// [kCorporateActionLookbackBars]，与选股入口（`screener`）共用同一份判定——
/// 库内是不复权价，除权日的价位断层会把指标砸成假信号，那些日子在选股侧
/// 本来就不会出现；回测若还统计它们，报告与用户实际看到的结果就不同源。
/// 传 0 关闭（用于复现 2026-10-06 之前的口径做对照）。
///
/// **这里刻意没有"末根必须最新"过滤**：逐日回放里那等于要求这只票活到数据
/// 末尾，是未来信息（存活者偏差），会让回测系统性偏乐观。选股侧要它、
/// 回测侧不要，这个不对称是故意的。
BacktestResult backtestRule(
  List<StockData> stocks,
  Rule rule, {
  required int forwardDays,
  int corporateActionLookbackBars = kCorporateActionLookbackBars,
  int suspensionLookbackBars = kSuspensionLookbackBars,
}) {
  if (forwardDays <= 0) {
    throw ArgumentError('forwardDays 必须为正，实际 $forwardDays');
  }
  final calendar = tradingCalendar(stocks);
  final outcomes = <SignalOutcome>[];
  for (final stock in stocks) {
    final bars = stock.bars;
    if (evaluableDays(bars.length, forwardDays) == 0) continue;
    final series = IndicatorSeries.from(bars);
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    final gapDays = tradingDaysSincePrevBar(bars, calendar);
    final lastEval = bars.length - 1 - forwardDays;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      if (corporateActionLookbackBars > 0 &&
          sinceGap[t] < corporateActionLookbackBars) {
        continue;
      }
      if (hasSuspensionGapNearby(gapDays, t,
          lookbackBars: suspensionLookbackBars)) {
        continue;
      }
      if (!rule.test(series.at(t))) continue;
      final from = bars[t].close, to = bars[t + forwardDays].close;
      outcomes.add(SignalOutcome(
        symbol: stock.symbol,
        date: bars[t].date,
        close: from,
        forwardReturn: (to / from - 1) * 100,
      ));
    }
  }
  return BacktestResult(ruleId: rule.id, forwardDays: forwardDays, outcomes: outcomes);
}

/// 与 [backtestRule] 覆盖同一批可评估日，但不做任何规则过滤，
/// 统计所有可评估日的前瞻收益，作为 base rate。
///
/// 除权护栏必须与 [backtestRule] 一致：只滤信号不滤基准，等于让信号从
/// "干净日子"里选、基准还含污染日，对比反而失真。
Baseline baseline(
  List<StockData> stocks, {
  required int forwardDays,
  int corporateActionLookbackBars = kCorporateActionLookbackBars,
  int suspensionLookbackBars = kSuspensionLookbackBars,
}) {
  if (forwardDays <= 0) {
    throw ArgumentError('forwardDays 必须为正，实际 $forwardDays');
  }
  final calendar = tradingCalendar(stocks);
  final returns = <double>[];
  for (final stock in stocks) {
    final bars = stock.bars;
    if (evaluableDays(bars.length, forwardDays) == 0) continue;
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    final gapDays = tradingDaysSincePrevBar(bars, calendar);
    final lastEval = bars.length - 1 - forwardDays;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      if (corporateActionLookbackBars > 0 &&
          sinceGap[t] < corporateActionLookbackBars) {
        continue;
      }
      if (hasSuspensionGapNearby(gapDays, t,
          lookbackBars: suspensionLookbackBars)) {
        continue;
      }
      returns.add((bars[t + forwardDays].close / bars[t].close - 1) * 100);
    }
  }
  return Baseline(forwardDays: forwardDays, returns: returns);
}

/// 中位数。**入参必须已排序**（调用方手上已有有序序列，避免重复排序）。
double _medianOfSorted(List<double> s) {
  if (s.isEmpty) return 0;
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}



/// 分位数（[p] ∈ [0,1]，线性插值，与 numpy.percentile 默认口径一致）。
/// **入参必须已排序**（调用方手上已有有序序列，不重复排序）；
/// 用途：止损价取 p10、乐观目标取 p75。
double _percentileOfSorted(List<double> s, double p) {
  final n = s.length;
  if (n == 1) return s[0];
  final pos = p * (n - 1);
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return s[lo];
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}


/// 解析 `年 → 规则id → 持有期 → 统计`。
Map<int, Map<String, Map<int, BacktestStats>>> _intKeyedStats3(Object? raw) {
  if (raw == null) return const {};
  return {
    for (final y in (raw as Map<String, dynamic>).entries)
      int.parse(y.key): {
        for (final r in (y.value as Map<String, dynamic>).entries)
          r.key: {
            for (final e in (r.value as Map<String, dynamic>).entries)
              int.parse(e.key): BacktestStats.fromJson(e.value),
          },
      },
  };
}

/// 解析 `年 → 持有期 → 统计`。
Map<int, Map<int, BacktestStats>> _intKeyedStats2(Object? raw) {
  if (raw == null) return const {};
  return {
    for (final y in (raw as Map<String, dynamic>).entries)
      int.parse(y.key): {
        for (final e in (y.value as Map<String, dynamic>).entries)
          int.parse(e.key): BacktestStats.fromJson(e.value),
      },
  };
}

/// 全部规则 × 全部持有期的回测报告。
///
/// 之所以有这东西：逐规则逐持有期单独跑是 O(规则数 × 持有期数) 遍扫描，
/// 15 条规则 × 3 个持有期要 6 分钟；[backtestAll] 一遍扫描共享 `IndicatorSeries.at(t)`，
/// 同样内容约 15 秒。页面要用，所以必须有。
class BacktestReport {
  const BacktestReport({
    required this.generatedAt,
    required this.horizons,
    required this.stockCount,
    required this.baseline,
    required this.results,
    this.yearly = const {},
    this.yearlyBaseline = const {},
    this.signalProfile = const {},
    this.marketState,
    this.recent = const {},
    this.recentBaseline = const {},
  });

  /// 报告生成时间（ISO8601 字符串）。
  final String generatedAt;

  /// 持有期列表（升序）。
  final List<int> horizons;

  /// 参与回测的股票数。
  final int stockCount;

  /// 无条件基准：持有期 → Baseline。
  final Map<int, Baseline> baseline;

  /// 规则结果：规则 id → 持有期 → BacktestResult。
  final Map<String, Map<int, BacktestResult>> results;

  /// 按自然年拆分的统计：年 → 规则 id → 持有期 → BacktestStats。
  /// 用来在 UI 上直接看"这条规则是不是每年都稳"——跨行情稳健性比全样本均值重要得多。
  final Map<int, Map<String, Map<int, BacktestStats>>> yearly;

  /// 按自然年的无条件基准：年 → 持有期 → 统计。
  final Map<int, Map<int, BacktestStats>> yearlyBaseline;

  /// 信号集中度：规则 id → 持有期 → [RuleProfile]。
  /// 缺失键（某持有期无信号）表示 profile 为空，用 [RuleProfile.empty]。
  final Map<String, Map<int, RuleProfile>> signalProfile;

  /// 市场状态（等权口径自算，见 [assessMarketState]）。
  /// 旧版报告无此字段，读回为 null，UI 整块不渲染（重新回测即出现）。
  final MarketState? marketState;

  /// 最近 N 交易日窗口（口径见 [backtestAll] 的 `recentWindowTradingDays`）：
  /// 规则 id → 持有期 → 切片。未启用窗口时为空。
  final Map<String, Map<int, RecentSlice>> recent;

  /// 最近窗口的无条件基准：持有期 → 切片。
  final Map<int, RecentSlice> recentBaseline;

  /// 某规则某持有期的集中度；无信号时返回 [RuleProfile.empty]。
  RuleProfile profileOf(String ruleId, int horizon) =>
      signalProfile[ruleId]?[horizon] ?? RuleProfile.empty;

  /// 取某规则在某持有期的结果；无则为 null。
  BacktestResult? result(String ruleId, int horizon) =>
      results[ruleId]?[horizon];

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt,
        'horizons': horizons,
        'stockCount': stockCount,
        'baseline': {
          for (final e in baseline.entries) '${e.key}': e.value.toJson(),
        },
        'results': {
          for (final r in results.entries)
            r.key: {
              for (final e in r.value.entries) '${e.key}': e.value.toJson(),
            },
        },
        'yearly': {
          for (final y in yearly.entries)
            '${y.key}': {
              for (final r in y.value.entries)
                r.key: {
                  for (final e in r.value.entries) '${e.key}': e.value.toJson(),
                },
            },
        },
        'yearlyBaseline': {
          for (final y in yearlyBaseline.entries)
            '${y.key}': {
              for (final e in y.value.entries) '${e.key}': e.value.toJson(),
            },
        },
        'signalProfile': {
          for (final r in signalProfile.entries)
            r.key: {
              for (final e in r.value.entries) '${e.key}': e.value.toJson(),
            },
        },
        if (marketState != null) 'marketState': marketState!.toJson(),
        'recent': {
          for (final r in recent.entries)
            r.key: {
              for (final e in r.value.entries) '${e.key}': e.value.toJson(),
            },
        },
        'recentBaseline': {
          for (final e in recentBaseline.entries) '${e.key}': e.value.toJson(),
        },
      };

  factory BacktestReport.fromJson(Map<String, dynamic> json) {
    Map<int, T> intKeyed<T>(Object? raw, T Function(Object?) parse) => {
          for (final e in (raw as Map<String, dynamic>).entries)
            int.parse(e.key): parse(e.value),
        };
    return BacktestReport(
      generatedAt: json['generatedAt'] as String,
      horizons: [for (final h in json['horizons'] as List) h as int],
      stockCount: json['stockCount'] as int,
      baseline: intKeyed(json['baseline'], (v) => Baseline.fromJson(v as Map<String, dynamic>)),
      results: {
        for (final r in (json['results'] as Map<String, dynamic>).entries)
          r.key: intKeyed(r.value, (v) => BacktestResult.fromJson(v as Map<String, dynamic>)),
      },
      yearly: _intKeyedStats3(json['yearly']),
      yearlyBaseline: _intKeyedStats2(json['yearlyBaseline']),
      signalProfile: {
        for (final r in
            (json['signalProfile'] as Map<String, dynamic>?)?.entries ??
                const <String, dynamic>{}.entries)
          r.key: {
            for (final e in (r.value as Map<String, dynamic>).entries)
              int.parse(e.key): RuleProfile.fromJson(e.value),
          },
      },
      marketState: json['marketState'] == null
          ? null
          : MarketState.fromJson(json['marketState'] as Map<String, dynamic>),
      recent: {
        for (final r in (json['recent'] as Map<String, dynamic>?)?.entries ??
            const <String, dynamic>{}.entries)
          r.key: {
            for (final e in (r.value as Map<String, dynamic>).entries)
              int.parse(e.key): RecentSlice.fromJson(e.value),
          },
      },
      recentBaseline: {
        for (final e in (json['recentBaseline'] as Map<String, dynamic>?)?.entries ??
            const <String, dynamic>{}.entries)
          int.parse(e.key): RecentSlice.fromJson(e.value),
      },
    );
  }
}

/// 最近窗口切片：窗口内统计量 + 按日平均收益（给按天重抽的 CI 用）。
class RecentSlice {
  const RecentSlice({required this.stats, required this.dayMeanReturn});

  final BacktestStats stats;

  // 常用统计量转发，调用方免一层 .stats。
  int get count => stats.count;
  double get winRate => stats.winRate;
  double get avgReturn => stats.avgReturn;

  /// 交易日（YYYYMMDD）→ 该日全部样本的平均收益（%）。
  /// 规则切片只含有信号的日子；与基准切片取交集才是 CI 的重抽池。
  final Map<int, double> dayMeanReturn;

  Map<String, dynamic> toJson() => {
        'stats': stats.toJson(),
        'dayMean': {for (final e in dayMeanReturn.entries) '${e.key}': e.value},
      };

  factory RecentSlice.fromJson(Map<String, dynamic> json) => RecentSlice(
        stats: BacktestStats.fromJson(json['stats'] as Map<String, dynamic>),
        dayMeanReturn: {
          for (final e in (json['dayMean'] as Map<String, dynamic>? ?? const {}).entries)
            int.parse(e.key): (e.value as num).toDouble(),
        },
      );
}

/// 一遍扫描算完 [rules] × [horizons] 的全部信号与基准。
///
/// 每只股票只构造一次 [IndicatorSeries]，每个可评估日只算一次快照，
/// 再分发到所有规则与所有持有期——这是与「逐规则逐持有期调用 backtestRule」
/// 的唯一区别，也是性能差 20 倍的原因。判定逻辑完全一致（同一批 `rule.test`）。
///
/// 返回的报告只带统计量：逐日明细在扫描结束时消化成 [BacktestStats] 即丢弃，
/// 不进 [BacktestReport]——报告要经 Isolate.run 拷回主 isolate 并被外壳常驻
/// 持有，全市场规模下带明细会放大到数百 MB。统计与逐规则 [backtestRule] 逐位一致。
///
/// 可评估日取最大持有期的范围；某持有期的前瞻窗口越界时该信号不计入该持有期。
BacktestReport backtestAll(
  List<StockData> stocks,
  List<Rule> rules, {
  required List<int> horizons,
  int corporateActionLookbackBars = kCorporateActionLookbackBars,
  int suspensionLookbackBars = kSuspensionLookbackBars,
  int? recentWindowTradingDays,
}) {
  if (horizons.isEmpty) throw ArgumentError('horizons 不能为空');
  final hs = [...horizons]..sort();
  if (hs.any((h) => h <= 0)) throw ArgumentError('持有期必须为正，实际 $hs');
  final maxH = hs.last;

  // 每条规则 × 每个持有期一条收益带。全市场实测信号收益 2083 万条，
  // 原实现把它**同时**存进 sigReturns 与 yearlySignals 两套桶——同一批 double
  // 存了两遍，收尾排序耗时与峰值内存都翻倍。改为只存一份（[Tape]），
  // 按年分桶、桶内排序，同时服务全样本与全部分年。
  final sigTapes = <String, Map<int, Tape>>{
    for (final r in rules) r.id: {for (final h in hs) h: Tape()},
  };
  final baseTapes = {for (final h in hs) h: Tape()};

  // 把 (规则 → 持有期 → Tape) 摊平成一条列表：热路径里每天要 append 最多
  // 20×3 次，逐次做 hs[i] / tapes[hs[i]]! 两层哈希查找太贵。
  final sigFlat = <Tape>[];
  for (final r in rules) {
    final byH = sigTapes[r.id]!;
    for (final h in hs) {
      sigFlat.add(byH[h]!);
    }
  }
  final baseFlat = [for (final h in hs) baseTapes[h]!];

  // 停牌洞要用全市场交易日历判（节假日全市场一起休，只有停牌是个股缺）。
  final calendar = tradingCalendar(stocks);

  // 最近窗口：截止日按**交易日**数（日历日差会把春节/国庆算进去）。
  // 窗口内可评估日与全样本共用同一套护栏，逐日双写进两套桶。
  final recentCutoff = recentWindowTradingDays == null || recentWindowTradingDays <= 0
      ? null
      : _recentCutoffDate(calendar, recentWindowTradingDays);
  final recentSig = <String, Map<int, Tape>>{
    if (recentCutoff != null)
      for (final r in rules) r.id: {for (final h in hs) h: Tape()},
  };
  final recentBase = {
    if (recentCutoff != null) for (final h in hs) h: Tape(),
  };
  // 按日累加器：dayKey → [sum, count]。只存窗口段,内存增量约窗口占比。
  final recentSigDays = <String, Map<int, Map<int, List<double>>>>{
    if (recentCutoff != null)
      for (final r in rules) r.id: {for (final h in hs) h: <int, List<double>>{}},
  };
  final recentBaseDays = {
    if (recentCutoff != null)
      for (final h in hs) h: <int, List<double>>{},
  };

  for (final stock in stocks) {
    final bars = stock.bars;
    // 可评估日统一取最大持有期的范围，保证三个持有期覆盖同一批交易日、彼此可比。
    if (bars.length < IndicatorSnapshot.minBars + maxH) continue;
    final series = IndicatorSeries.from(bars);
    // 除权/复牌 + 停牌两个护栏：污染日整日跳过——基准与信号一并剔除，
    // 两侧始终覆盖同一批可评估日（否则"信号从干净日里选、基准还含污染日"会失真）。
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    final gapDays = tradingDaysSincePrevBar(bars, calendar);
    final lastEval = bars.length - 1 - maxH;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      if (corporateActionLookbackBars > 0 &&
          sinceGap[t] < corporateActionLookbackBars) {
        continue;
      }
      if (hasSuspensionGapNearby(gapDays, t,
          lookbackBars: suspensionLookbackBars)) {
        continue;
      }
      final from = bars[t].close;
      final year = bars[t].date.year;
      // 前瞻收益每个持有期只算一次：原来基准桶与信号桶各算一遍。
      final fwdByH = [for (final h in hs) (bars[t + h].close / from - 1) * 100];
      final inRecent = recentCutoff != null && !bars[t].date.isBefore(recentCutoff);
      final dayKey = inRecent
          ? bars[t].date.year * 10000 + bars[t].date.month * 100 + bars[t].date.day
          : 0;
      for (var i = 0; i < baseFlat.length; i++) {
        // 基准 tape 不需要 profile()，不记 monthKey（免去千万次 map 更新）。
        baseFlat[i].add(fwdByH[i], year);
        if (inRecent) {
          recentBase[hs[i]]!.add(fwdByH[i], year);
          final acc =
              recentBaseDays[hs[i]]!.putIfAbsent(dayKey, () => [0.0, 0.0]);
          acc[0] += fwdByH[i];
          acc[1] += 1;
        }
      }
      // 逐条规则判定：绝大多数规则在标量条件就返回 false，不碰 Tape。
      final snap = series.at(t);
      String? mk;
      var k = 0;
      for (final r in rules) {
        if (r.test(snap)) {
          mk ??= '${bars[t].date.year}-${bars[t].date.month.toString().padLeft(2, '0')}';
          for (var i = 0; i < hs.length; i++) {
            sigFlat[k + i].add(fwdByH[i], year, monthKey: mk);
            if (inRecent) {
              recentSig[r.id]![hs[i]]!.add(fwdByH[i], year);
              final acc = recentSigDays[r.id]![hs[i]]!
                  .putIfAbsent(dayKey, () => [0.0, 0.0]);
              acc[0] += fwdByH[i];
              acc[1] += 1;
            }
          }
        }
        k += hs.length;
      }
    }
  }

  // 年份取「基准 ∪ 信号」——只要那一年有可评估日就要出现在分年视图里，
  // 否则某年一条规则都没命中时整年会消失。（信号日必是可评估日，
  // 故实际上基准年份已覆盖全集，这里仍取并集以免口径随实现漂移。）
  final years = <int>{
    for (final tape in baseTapes.values) ...tape.years,
    for (final byH in sigTapes.values) for (final tape in byH.values) ...tape.years,
  };

  return BacktestReport(
    generatedAt: DateTime.now().toIso8601String(),
    horizons: hs,
    stockCount: stocks.length,
    // 原始收益列表在此消化成统计量后随函数结束释放，不进返回值：
    // 报告会被 Isolate.run 结构化拷贝到主 isolate 并常驻到下次重算。
    baseline: {
      for (final h in hs)
        h: Baseline.fromStats(
          forwardDays: h,
          stats: baseTapes[h]!.overall(),
        ),
    },
    results: {
      for (final r in rules)
        r.id: {
          for (final h in hs)
            h: BacktestResult.fromStats(
              ruleId: r.id,
              forwardDays: h,
              stats: sigTapes[r.id]![h]!.overall(),
            ),
        },
    },
    yearly: {
      for (final y in years)
        y: {
          for (final r in rules)
            r.id: {
              for (final h in hs) h: sigTapes[r.id]![h]!.statsOfYear(y),
            },
        },
    },
    yearlyBaseline: {
      for (final y in years)
        y: {for (final h in hs) h: baseTapes[h]!.statsOfYear(y)},
    },
    // 信号集中度。没有它，"全样本胜率最高"会被误读成"最可靠"——
    // 而实测严格版 73.7% 的信号集中在 2024-02 单月。
    signalProfile: {
      for (final r in rules)
        r.id: {for (final h in hs) h: sigTapes[r.id]![h]!.profile()},
    },
    // 市场状态仪表：与回测基准同源的等权口径。顺带算比调用方再扫一遍
    // 全市场便宜（可评估日窗口已在此确定，口径天然一致）。
    marketState: assessMarketState(stocks),
    recent: recentCutoff == null
        ? const {}
        : {
            for (final r in rules)
              r.id: {
                for (final h in hs)
                  h: RecentSlice(
                    stats: recentSig[r.id]![h]!.overall(),
                    dayMeanReturn: _dayMeans(recentSigDays[r.id]![h]!),
                  ),
              },
          },
    recentBaseline: recentCutoff == null
        ? const {}
        : {
            for (final h in hs)
              h: RecentSlice(
                stats: recentBase[h]!.overall(),
                dayMeanReturn: _dayMeans(recentBaseDays[h]!),
              ),
          },
  );
}

/// 窗口起始日：按交易日序取倒数第 [windowDays] 个；交易日不足时取最早一天
/// （等于全部日子进窗口）。
DateTime? _recentCutoffDate(Set<DateTime> calendar, int windowDays) {
  if (calendar.isEmpty) return null;
  final days = calendar.toList()..sort();
  return days.length > windowDays ? days[days.length - windowDays] : days.first;
}

Map<int, double> _dayMeans(Map<int, List<double>> acc) =>
    {for (final e in acc.entries) e.key: e.value[0] / e.value[1]};

/// 按天重抽的窗口超额 CI：重抽单位是**交易日**（同一天内样本共享行情、
/// 不独立，逐样本重抽会把 CI 虚窄——全历史才 171 个独立交易日）。
///
/// 池 = 规则与基准日均值键的交集（规则无信号的日子不进池，不算 0 超额）。
/// 返回点估计（日均超额，pp）与 bootstrap 均值的 95% 双侧 CI；种子固定可复现。
({double excess, double ciLow, double ciHigh}) recentExcessCI({
  required Map<int, double> ruleDayMean,
  required Map<int, double> baseDayMean,
  int rounds = 200,
  int? seed,
}) {
  final days =
      ruleDayMean.keys.where(baseDayMean.containsKey).toList()..sort();
  if (days.isEmpty) return (excess: 0.0, ciLow: 0.0, ciHigh: 0.0);
  final excessByDay = [for (final d in days) ruleDayMean[d]! - baseDayMean[d]!];
  final mean = excessByDay.reduce((a, b) => a + b) / excessByDay.length;
  if (days.length == 1 || rounds <= 1) {
    return (excess: mean, ciLow: mean, ciHigh: mean);
  }
  final rng = math.Random(seed);
  final n = excessByDay.length;
  final boots = List<double>.filled(rounds, 0);
  for (var r = 0; r < rounds; r++) {
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += excessByDay[rng.nextInt(n)];
    }
    boots[r] = s / n;
  }
  boots.sort();
  return (
    excess: mean,
    ciLow: boots[((0.025 * (rounds - 1)).round())],
    ciHigh: boots[((0.975 * (rounds - 1)).round())],
  );
}

/// 一组带年份标签的前瞻收益。
///
/// **按年份分桶存储**：收尾时各年桶用 [List.sort]（double 特化路径，没有
/// 下标数组与闭包比较器的间接层）各排一次，之后：
/// - 分年统计 = 直接取该年有序桶，中位数按下标取，零额外排序；
/// - 全样本中位数 = 各年有序桶做多路归并，只走到中位数位置就停，仍是精确值，
///   不用近似（月度台账 `~/.stock/backtest-history.json` 的口径不能变）。
///
/// 旧实现把 (年, 收益) 全序编成一套下标数组、用闭包比较器排序：全市场
/// 约 2000 万条实测收尾排序 5.7s；分桶后约 4.0s，且归并/取段不再有 `o[]` 间接访问。
///
/// [BacktestStats] 里与顺序相关的量（均值/盈亏比的 sum/gain/loss）在 [add]
/// 时按插入序增量累积，加法顺序与旧实现「收尾对插入序单遍统计」完全一致——
/// 统计量逐位不变，与逐规则 [backtestRule] 路径的一致性测试靠这一点锁死。
class Tape {
  final _byYear = <int, List<double>>{};
  /// 按月计信号数。只存计数不存收益：集中度统计只需要"哪个月有几个信号"，
  /// 存收益会让常驻内存翻一倍。
  final _byMonth = <String, int>{};

  int _count = 0;
  double _sum = 0, _gain = 0, _loss = 0;
  int _wins = 0;
  double? _best, _worst;

  void add(double value, int year, {String? monthKey}) {
    assert(_sortedYearsCache == null, 'Tape.add 不得在统计之后调用（桶已被就地排序）');
    (_byYear[year] ??= []).add(value);
    if (monthKey != null) _byMonth[monthKey] = (_byMonth[monthKey] ?? 0) + 1;
    // 顺序敏感的统计量按插入序累积，与旧实现的收尾单遍统计逐位一致。
    _count++;
    _sum += value;
    if (value > 0) {
      _gain += value;
      _wins++;
    } else if (value < 0) {
      _loss += -value;
    }
    if (_best == null || value > _best!) _best = value;
    if (_worst == null || value < _worst!) _worst = value;
  }

  int get length => _count;

  /// 出现过的年份（= 桶键，读取 O(年份数)，无需独立集合）。
  Iterable<int> get years => _byYear.keys;

  List<int>? _sortedYearsCache;

  /// 年份升序；首次调用时把各年桶原地排序（收尾只发生一次）。
  ///
  /// 排序是**就地副作用**：调过本方法后不得再 [add]（只有收尾阶段调用，天然满足）。
  /// 返回的年份列表给多路归并当段索引，逐日路径不要调用。
  List<int> _ensureSorted() {
    final cached = _sortedYearsCache;
    if (cached != null) return cached;
    final ys = _byYear.keys.toList()..sort();
    for (final y in ys) {
      _byYear[y]!.sort();
    }
    return _sortedYearsCache = ys;
  }

  BacktestStats statsOfYear(int year) {
    final bucket = _byYear[year];
    if (bucket == null) return BacktestStats.empty;
    _ensureSorted(); // 桶必须有序：_statsOfSorted 按位置取中位数与分位数
    return _statsOfSorted(bucket);
  }

  /// 信号集中度。见 [RuleProfile] 的说明——这一项是为了抓
  /// "规则的声誉建立在少数几个月上"这类结构性问题。
  RuleProfile profile() {
    if (_count == 0 || _byMonth.isEmpty) {
      return const RuleProfile(signalCount: 0, monthsWithSignals: 0, topMonthShare: 0);
    }
    var top = 0;
    int? topMonth;
    for (final e in _byMonth.entries) {
      if (e.value > top) {
        top = e.value;
        // monthKey 形如 '2024-02' → 202402。
        final parts = e.key.split('-');
        if (parts.length == 2) {
          final y = int.tryParse(parts[0]);
          final m = int.tryParse(parts[1]);
          if (y != null && m != null) topMonth = y * 100 + m;
        }
      }
    }
    return RuleProfile(
      signalCount: _count,
      monthsWithSignals: _byMonth.length,
      topMonthShare: top / _count,
      topMonth: topMonth,
    );
  }

  BacktestStats overall() {
    if (_count == 0) return BacktestStats.empty;
    final sorted = _sortedUnion;
    return BacktestStats(
      count: _count,
      winRate: _wins / _count,
      avgReturn: _sum / _count,
      medianReturn: _medianOfUnion(),
      bestReturn: _best!,
      worstReturn: _worst!,
      profitFactor: (_gain == 0 || _loss == 0) ? 0 : _gain / _loss,
      p10: _percentileOfSorted(sorted, 0.10),
      p25: _percentileOfSorted(sorted, 0.25),
      p75: _percentileOfSorted(sorted, 0.75),
      p90: _percentileOfSorted(sorted, 0.90),
      stdDev: _stdDevOfSorted(sorted, _sum),
    );
  }

  /// 全样本的有序收益序列。各年份桶在 [_ensureSorted] 首次调用时已各自有序，
  /// 这里做一次多路归并得到全局有序序列，分位数才能直接按位置取值。
  /// 只在收尾统计时算一次并缓存（`Tape` 的其余路径不碰它）。
  late final List<double> _sortedUnion = () {
    if (_count == 0) return const <double>[];
    final ys = _ensureSorted();
    if (ys.length == 1) return _byYear[ys.first]!;
    final out = List<double>.filled(_count, 0);
    final cursor = List<int>.filled(ys.length, 0);
    for (var i = 0; i < _count; i++) {
      var bestSeg = -1;
      var bestVal = double.infinity;
      for (var k = 0; k < ys.length; k++) {
        final bucket = _byYear[ys[k]]!;
        final c = cursor[k];
        if (c >= bucket.length) continue;
        if (bucket[c] < bestVal) {
          bestVal = bucket[c];
          bestSeg = k;
        }
      }
      out[i] = bestVal;
      cursor[bestSeg]++;
    }
    return out;
  }();

  /// 有序列表的单遍统计：与旧 `_statsOfRange` 逐位一致（同一批值、同一求和顺序）。
  BacktestStats _statsOfSorted(List<double> sorted) {
    final n = sorted.length;
    var sum = 0.0, gain = 0.0, loss = 0.0;
    var best = sorted[0], worst = sorted[0];
    var wins = 0;
    for (final v in sorted) {
      sum += v;
      if (v > 0) {
        gain += v;
        wins++;
      } else if (v < 0) {
        loss += -v;
      }
      if (v > best) best = v;
      if (v < worst) worst = v;
    }
    final mid = n ~/ 2;
    final a = sorted[mid];
    return BacktestStats(
      count: n,
      winRate: wins / n,
      avgReturn: sum / n,
      medianReturn: n.isOdd ? a : (sorted[mid - 1] + a) / 2,
      bestReturn: best,
      worstReturn: worst,
      profitFactor: (gain == 0 || loss == 0) ? 0 : gain / loss,
      p10: _percentileOfSorted(sorted, 0.10),
      p25: _percentileOfSorted(sorted, 0.25),
      p75: _percentileOfSorted(sorted, 0.75),
      p90: _percentileOfSorted(sorted, 0.90),
      stdDev: _stdDevOfSorted(sorted, sum),
    );
  }

  /// 全样本中位数：对各年份有序桶做多路归并，只走到中位数位置就停。
  ///
  /// 段数 = 年份数（全市场约 3），所以这是 O(中位数位置 × 年份数) 的线性扫描，
  /// 比对全部元素再整体排序便宜一个数量级，且**仍是精确值**。
  double _medianOfUnion() {
    if (_count == 0) return 0;
    if (_count == 1) return _byYear.values.first[0];
    final ys = _ensureSorted();
    final segCount = ys.length;
    // 奇数取第 (n~/2) 位；偶数取第 (n~/2 - 1) 与 (n~/2) 位的均值。
    final wantHi = _count ~/ 2;
    final wantLo = _count.isEven ? wantHi - 1 : wantHi;
    final cursor = List<int>.filled(segCount, 0);
    var emitted = 0;
    double? vLo, vHi;
    while (emitted <= wantHi) {
      // 取各段当前最小值
      var bestSeg = -1;
      var bestVal = double.infinity;
      for (var k = 0; k < segCount; k++) {
        final bucket = _byYear[ys[k]]!;
        final i = cursor[k];
        if (i >= bucket.length) continue;
        final v = bucket[i];
        if (v < bestVal) {
          bestVal = v;
          bestSeg = k;
        }
      }
      if (bestSeg < 0) break; // 已排完
      if (emitted == wantLo) vLo = bestVal;
      if (emitted == wantHi) {
        vHi = bestVal;
        break;
      }
      cursor[bestSeg]++;
      emitted++;
    }
    if (vHi == null) return 0;
    if (vLo == null) return vHi;
    return (vLo + vHi) / 2;
  }
}

/// 排序键 tier：0=最近样本够年份的统计、1=样本少（标注过的不硬数字）、
/// 2=无统计行。第二位是该年相对基准的超额（pp）；tier 2 时无意义。
(int, double) _excessSortKey(BacktestReport report, String id) {
  final s = ruleStatLine(report, id, 10);
  return switch (s) {
    null => (2, 0.0),
    _ => (s.smallSample ? 1 : 0, s.excessPp),
  };
}

/// 按回测报告的**超额收益**（[ruleStatLine] 同口径：最近样本够年份相对同年基准）
/// 给规则 id 降序排序——与统计行的红绿色一致，红的排前面。**排序完全决定顺序**：
/// 主力规则（[kMainRuleId]）不钉首位，由 UI 在名字旁挂「主力」徽标标识
/// （2026-10-07 用户拍板：排序必须与回测结果对应，钉首位会让它再次矛盾）。
///
/// 刻意在**显示时**算而不是把顺序硬编码进 `builtInRules`：超额是数据相关的，
/// 写进源码后一刷新报告就过期。无报告、或某规则没有统计行时，该规则排在
/// 样本少规则的后面并保持 [ids] 里的原始顺序，避免每次刷新排序抖动。
/// 样本少（[kRuleStatLineMinSamples] 以下）的规则再排在其后：小样本的
/// 均收益是噪声，不能靠一个 +5pp 的单月数字跳到样本够的规则前面。
List<String> ruleIdsSortedByExcess(List<String> ids, BacktestReport? report) {
  final ordered = [...ids];
  if (report != null) {
    final keys = {for (final id in ids) id: _excessSortKey(report, id)};
    ordered.sort((a, b) {
      final ka = keys[a]!, kb = keys[b]!;
      final byTier = ka.$1.compareTo(kb.$1);
      if (byTier != 0) return byTier;
      final byExcess = kb.$2.compareTo(ka.$2);
      return byExcess != 0 ? byExcess : ids.indexOf(a).compareTo(ids.indexOf(b));
    });
  }
  return ordered;
}

/// 按「组内最高超额」给规则分组降序排序（口径同 [ruleIdsSortedByExcess]）。
///
/// 只排序组内规则还不够——最好的规则可能埋在第三个分组里。把分组也按
/// 组内最好规则的（tier, 超额）排，包含最强规则的分组就会排到最前。
/// 无报告时保持 [groups] 的声明顺序。
List<MapEntry<String, List<String>>> ruleGroupsSortedByExcess(
  Map<String, List<String>> groups,
  BacktestReport? report,
) {
  final order = {for (var i = 0; i < groups.length; i++) groups.keys.elementAt(i): i};
  final entries = groups.entries.toList();
  if (report == null) return entries;
  (int, double) bestOf(List<String> ids) {
    var best = (2, 0.0);
    for (final id in ids) {
      final k = _excessSortKey(report, id);
      if (k.$1 < best.$1 || (k.$1 == best.$1 && k.$2 > best.$2)) best = k;
    }
    return best;
  }

  entries.sort((a, b) {
    final ka = bestOf(a.value), kb = bestOf(b.value);
    final byTier = ka.$1.compareTo(kb.$1);
    if (byTier != 0) return byTier;
    final byExcess = kb.$2.compareTo(ka.$2);
    return byExcess != 0 ? byExcess : order[a.key]!.compareTo(order[b.key]!);
  });
  return entries;
}

/// 跨年一致性判定的结论。`mixed` 与 `unknown` 都不上色，但语义不同：
/// 前者"判过了，结果不一致"，后者"没证据"。
enum YearlyVerdict {
  /// 每个有数据的年份，10 日均收益都严格高于该年基准：历史有优势。
  robust,

  /// 每个有数据的年份，均收益都严格低于该年基准：历史无优势。
  loser,

  /// 有的年份赢、有的输：判过了但结论不一致。
  mixed,

  /// 一个可判年份都没有：不是"看不出"而是"没证据"。
  ///
  /// 旧报告 JSON 缺 `yearly` / `yearlyBaseline` 键时 [BacktestReport.fromJson]
  /// 容错成空 map，这里就是这种情况——此时不许给出任何结论。
  unknown,
}

/// 按「分年均收益是否都赢该年基准」判定规则。
///
/// 这是全期超额列红绿与 [isRuleYearlyRobust] / [isRuleYearlyLoser] 的**唯一**判定源：
/// 口径是分年均收益超额（不是全期点估计，也不是显著性），UI 不得另写一套。
YearlyVerdict yearlyVerdict(BacktestReport report, String ruleId, {int horizon = 10}) {
  var judged = false;
  var allWin = true;
  var allLose = true;
  for (final y in report.yearly.keys) {
    final st = report.yearly[y]?[ruleId]?[horizon];
    final base = report.yearlyBaseline[y]?[horizon];
    if (st == null || base == null || st.count == 0) continue;
    judged = true;
    if (st.avgReturn <= base.avgReturn) allWin = false; // 必须严格赢
    if (st.avgReturn >= base.avgReturn) allLose = false; // 必须严格输
  }
  if (!judged) return YearlyVerdict.unknown;
  if (allWin) return YearlyVerdict.robust;
  if (allLose) return YearlyVerdict.loser;
  return YearlyVerdict.mixed;
}

/// 规则是否「跨年稳健」：在**每一个有数据的年份**，10 日**均收益**都跑赢该年的无条件基准。
///
/// 全样本均值会把"只有某一年特别 high"的规则抬上来，所以拿它当筛选条件比按全样本
/// 胜率排序更可靠。某一年没有可用数据（如 MA250 需要 250 根，早年算不出来）时跳过该年，
/// 不视为不稳健——但也因此不能算"验证过"。
///
/// ## 为什么用均收益而不是胜率（2026-10-06 口径变更）
///
/// 实测证据（`tool/audit_rules.dart` + `~/.stock/stock-backtest-report.json`）：
/// 基准均收益 2025 年 +1.72%（牛）、2026 年 −0.41%（熊）。在熊市里
/// **胜率低于基准常常不代表失效**——它可能只是"赢小钱、输小钱"，期望仍为正。
/// `rsi_oversold` 2026 年胜率 43.5% < 基准 44.3%（旧口径判它失效），
/// 均收益却 +0.07% > 基准 −0.41%（按超额它仍然可用）。
///
/// 反向也成立：胜率碾压而均收益为负的规则同样要筛掉。所以判定改看均收益。
///
/// **这次变更顺带修了一个一直存在的 bug**：胜率口径下，真实报告里 20 条规则
/// **0 条**通过「只看稳健规则」——那个开关打开就是空列表。超额口径下有 4 条
/// （rsi_oversold_volume / rsi_oversold_volume_loose / rsi_oversold /
/// ma60_breakout_pullback）。
///
/// 注：规则列表的**排序**也用超额（`ruleIdsSortedByExcess`，与统计行红绿
/// 同口径），但那仍是纯排序选择，不涉及"能不能用"的判断，与这里的
/// 稳健判定不必一致。
///
/// 注 2：一个可判年份都没有（[YearlyVerdict.unknown]）时**返回 true**（保持历史行为）。
/// 它的调用方是「只看稳健规则」这类"不默认有罪"的筛子，改判会把缺 `yearly`
/// 的旧报告筛成空表。反过来"不默认有优势"的**上色**必须走 [yearlyVerdict]，
/// 只看 `robust`/`loser`——否则同一份旧报告会把所有超额为正的规则染红。
bool isRuleYearlyRobust(BacktestReport report, String ruleId, {int horizon = 10}) {
  final v = yearlyVerdict(report, ruleId, horizon: horizon);
  return v == YearlyVerdict.robust || v == YearlyVerdict.unknown;
}

/// 规则是否**跨年一致性落败** = 分年每个有数据年份的均收都严格低于该年基准。
///
/// [isRuleYearlyRobust] 的镜像：全期表超额列的绿色语义（"历史无优势"）。
/// 与红色同源同口径（分年均收益超额），UI 不得另写一套。
///
/// 与上者的差别只在缺数据：没有可判年份时这里返回 false（不判绿），
/// 所以它可以直接用于上色，但上色统一走 [yearlyVerdict] 更省一次遍历。
bool isRuleYearlyLoser(BacktestReport report, String ruleId, {int horizon = 10}) =>
    yearlyVerdict(report, ruleId, horizon: horizon) == YearlyVerdict.loser;

/// 信号是否过度集中在少数几个月。
///
/// 单独看某条规则每年的胜率会漏掉一种情况：**它每年都赢基准，但赢的原因
/// 是一两个月的爆发**。实测 `rsi_oversold_volume` 三年 7496 个信号里
/// 70.0% 来自 2024-02 单月（那个月全市场基准 80.3%，规则 98.4%），
/// 剔除后只剩 1875 个信号散布在 35 个月。按年胜率它"稳健"，按结构它不可信。
///
/// [kRuleTopMonthShareMinSignals] 以下不判：1 个信号的占比是 100%，
/// 那不是"集中"而是"没有数据"。旧报告没有 [BacktestReport.signalProfile] 时
/// 一律返回 false——**缺数据不默认有罪**，否则升级报告格式会让所有规则一起消失。
bool isRuleSignalConcentrated(BacktestReport report, String ruleId,
    {int horizon = 10}) {
  final p = report.profileOf(ruleId, horizon);
  if (p.signalCount < kRuleTopMonthShareMinSignals) return false;
  return p.topMonthShare > kRuleTopMonthShareCeiling;
}

/// 规则是否**可信** = 跨年稳健 **且** 信号不集中。两个条件都必须满足。
///
/// 之所以要把它们 AND 起来：`isRuleYearlyRobust` 只看胜率，
/// 而胜率是会被单个月绑架的指标。UI 的"只看稳健规则"开关要的是
/// "这条规则的记录我能参考"，那就必须同时满足两者。
bool isRuleTrustworthy(BacktestReport report, String ruleId, {int horizon = 10}) =>
    isRuleYearlyRobust(report, ruleId, horizon: horizon) &&
    !isRuleSignalConcentrated(report, ruleId, horizon: horizon);

/// 跨年稳健的规则 id 列表（保持 [rules] 的声明顺序）。
List<String> robustRuleIds(BacktestReport? report, List<Rule> rules) {
  if (report == null) return const [];
  return [
    for (final r in rules)
      if (isRuleYearlyRobust(report, r.id)) r.id
  ];
}

/// 某一年要至少这么多信号，"这一年的均收益"才算数。
///
/// 太少时一两个极端值就能把均值拉飞——实测 `ma60_breakout_now` 全样本只有
/// 1 个信号、均收益 −3.15%，拿它代表"现在还能不能用"毫无意义。
const kRuleStatLineMinSamples = 500;

/// 规则名下的统计行数据（UI 只负责画，不做口径判断）。
class RuleStatLine {
  const RuleStatLine({
    required this.year,
    required this.avgReturn,
    required this.baselineReturn,
    required this.winRate,
    required this.baselineWinRate,
    required this.profitFactor,
    required this.count,
    required this.concentrated,
    required this.topMonthShare,
    required this.topMonth,
    required this.smallSample,
  });

  /// 取数与展示用的**最近一年**（样本够的那年）。
  final int year;

  /// 该年均收益（%）。
  final double avgReturn;

  /// 同年同持有期的无条件基准均收益（%）。
  final double baselineReturn;

  final double winRate;
  final double baselineWinRate;
  final double profitFactor;
  final int count;

  /// 信号是否挤在单月（复用 [isRuleSignalConcentrated] 的判据）。
  final bool concentrated;

  final double topMonthShare;

  /// 占比最高的那个月（`yyyyMM`）；null = 旧报告读不出。
  final int? topMonth;

  /// 样本数低于 [kRuleStatLineMinSamples]——数字仍显示，但明确标注不够硬。
  final bool smallSample;

  /// 相对同年基准的收益超额（百分点）。
  double get excessPp => avgReturn - baselineReturn;

  /// 画在规则名下面的一行。
  ///
  /// ## 为什么以超额开头，但胜率/PF/信号数一个都不少
  ///
  /// 口径是**超额收益**而不是胜率，这一点是被实测逼出来的：2026 年基准均收益
  /// −0.41%，此时"胜率低于基准"常常只是赢小钱、输小钱，期望仍为正。
  /// `rsi_oversold` 2026 年胜率 43.5% 低于基准 44.3%（旧口径判它失效），
  /// 均收益却 +0.07% 高于基准 −0.41%——按超额它仍然可用。
  ///
  /// 但这**不等于**把胜率/PF/信号数删掉：它们各自回答不同的问题（赢的次数 /
  /// 赚赔幅度 / 样本量），全都还有参考价值。三项都保留，超额与基准是**新增**的
  /// 两段。第一版只显示超额、把这三项拿掉，是交付缺陷——口径变更应该是补充，
  /// 不是替换。
  /// 年份只写后两位（`25年` 不是 `2025年`）——这一行已经要放七段数字，
  /// 手机上宽度有限，全写会把「信号集中单月」这类告警挤出视野。
  String get yearLabel => '${year % 100}年';

  /// 信号集中标记：**点名具体月份**（`24年2月`），而不是笼统的"集中单月"。
  ///
  /// 只说"集中"没用——用户需要知道该避开哪一段行情。实测
  /// `rsi_oversold_volume` 有 65% 的信号来自 2024-02 那个月，看到月份
  /// 才知道那不是常态。旧报告读不出月份时退回笼统说法，**不猜**。
  String get concentratedLabel {
    final m = topMonth;
    if (m == null) return '集中单月';
    return '${m ~/ 100 % 100}年${m % 100}月';
  }

  String get label {
    final tail = [
      if (concentrated) concentratedLabel,
      if (smallSample) '样本少',
    ].join(' · ');
    return '$yearLabel ${_pct(avgReturn)} · 超额 ${_pp(excessPp)}'
        ' · 胜率 ${(winRate * 100).toStringAsFixed(1)}%'
        ' · PF ${profitFactor.toStringAsFixed(2)}'
        ' · 基准 ${_pct(baselineReturn)}'
        ' · 信号 $count${tail.isEmpty ? '' : ' · $tail'}';
  }

  static String _pct(double v) => '${v.toStringAsFixed(2)}%';

  static String _pp(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}pp';

  /// 悬停/长按统计行时弹出的字段说明。放在数据层而不是 UI：桌面侧栏与
  /// 移动规则面板画的是同一行数字，说明文案只写一份，两处 Tooltip 共用。
  static const String helpText =
      '回测统计，10 日持有口径。红 = 正超额（跑赢基准），绿 = 负超额。'
      '26年：统计取最近一个样本够的年份；'
      '首个百分比：该年信号的平均 10 日收益；'
      '超额：平均收益减同年基准；'
      '胜率：信号后 10 日上涨的占比；'
      'PF：盈亏比（赚的总额 ÷ 亏的总额）；'
      '基准：同年随便买一只的平均收益；'
      '信号：样本数。'
      '标月份 = 信号集中在那个月，高胜率可能是行情带来的；'
      '样本少 = 样本不足，数字不够硬。'
      '胜率高不等于赚钱，期望为正（超额 > 0 且 PF > 1）才保得住本金。';
}

/// 取某规则该持有期的统计行数据；无年度数据或当年基准缺失时返回 null。
///
/// 取「最近一个样本够的年份」而不是「最新的一年」：新规则/新数据往往只有
/// 几十个样本，直接用会把噪声当结论（[kRuleStatLineMinSamples]）。
/// 当年基准缺失（如该年无任何可评估日）返回 null——宁可没有这行，
/// 也不拿全样本基准冒充当年基准，那正是把牛市数字套到熊市上的错误。
RuleStatLine? ruleStatLine(
  BacktestReport report,
  String ruleId,
  int horizon,
) {
  // 两轮：先只要样本够的年份；一个都没有（刚上线的新规则）则退回
  // 「最近有数据的一年」并标 smallSample。直接返回 null 会让整行消失，
  // 用户看到的是"这条规则什么统计都没有"，比显示一个标注过的弱数字更糟。
  for (final minSamples in [kRuleStatLineMinSamples, 1]) {
    var bestYear = 0;
    BacktestStats? bestStats, bestBase;
    for (final y in report.yearly.keys) {
      final st = report.yearly[y]?[ruleId]?[horizon];
      final base = report.yearlyBaseline[y]?[horizon];
      if (st == null || base == null) continue;
      if (st.count < minSamples) continue;
      if (base.count == 0) continue;
      if (y > bestYear) {
        bestYear = y;
        bestStats = st;
        bestBase = base;
      }
    }
    if (bestStats == null || bestBase == null) continue;

    final profile = report.profileOf(ruleId, horizon);
    return RuleStatLine(
      year: bestYear,
      avgReturn: bestStats.avgReturn,
      baselineReturn: bestBase.avgReturn,
      winRate: bestStats.winRate,
      baselineWinRate: bestBase.winRate,
      profitFactor: bestStats.profitFactor,
      count: bestStats.count,
      concentrated: isRuleSignalConcentrated(report, ruleId, horizon: horizon),
      topMonthShare: profile.topMonthShare,
      topMonth: profile.topMonth,
      smallSample: bestStats.count < kRuleStatLineMinSamples,
    );
  }
  return null;
}

/// 回测报告的历史快照（月度跟踪用）。
///
/// 目的：现在所有结论都是**样本内**的。真正的考验是未来，而唯一的验证手段是
/// 持续记录、隔一段时间重跑、看胜率有没有漂移。这份快照把一个月的报告固化下来，
/// `tool/report_all.dart --archive` 每次重跑都会追加一条。
/// 某规则某一期的窗口超额记录（台账快照用，判定"连续红"）。
class RecentExcessRec {
  const RecentExcessRec({
    required this.excess,
    required this.ciLow,
    required this.ciHigh,
    required this.days,
  });

  /// 日均超额（pp）与按天重抽 95% CI；[days] = 独立信号日数。
  final double excess;
  final double ciLow;
  final double ciHigh;
  final int days;

  /// 该期是否"红"（显著为正）。样本不足一律不算红。
  bool get isRed => days >= kMinSignificantDays && ciLow > 0;

  Map<String, dynamic> toJson() =>
      {'excess': excess, 'lo': ciLow, 'hi': ciHigh, 'days': days};

  factory RecentExcessRec.fromJson(Map<String, dynamic> json) => RecentExcessRec(
        excess: (json['excess'] as num).toDouble(),
        ciLow: (json['lo'] as num).toDouble(),
        ciHigh: (json['hi'] as num).toDouble(),
        days: json['days'] as int,
      );
}

/// 独立信号日少于此值的窗口超额不参与显著性解读（阈值来自探针实证:
/// 窗口 120 交易日有约 100 个独立基准日,信号日更少的规则 CI 全程跨 0）。
const kMinSignificantDays = 20;

class BacktestSnapshot {
  const BacktestSnapshot({
    required this.generatedAt,
    required this.dataDate,
    required this.stockCount,
    required this.evaluableDays,
    required this.ruleWinRate,
    this.recentExcess,
  });

  /// 报告生成时间（ISO8601）。
  final String generatedAt;

  /// 报告所依据的数据截止日（YYYYMMDD，取库内最大交易日）。
  final String dataDate;

  final int stockCount;

  /// 基准样本数（10 日）。
  final int evaluableDays;

  /// 各规则 10 日胜率：规则 id → 胜率（0~1）。
  final Map<String, double> ruleWinRate;

  /// 各规则窗口超额：规则 id → 记录。旧快照无此字段（null），连红链从
  /// 第一条带数据的快照起算。仅当报告带 recent 数据且基准切片非空时才有。
  final Map<String, RecentExcessRec>? recentExcess;

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt,
        'dataDate': dataDate,
        'stockCount': stockCount,
        'evaluableDays': evaluableDays,
        'ruleWinRate': ruleWinRate,
        if (recentExcess != null && recentExcess!.isNotEmpty)
          'recentExcess': {
            for (final e in recentExcess!.entries) e.key: e.value.toJson(),
          },
      };

  factory BacktestSnapshot.fromJson(Map<String, dynamic> json) => BacktestSnapshot(
        generatedAt: json['generatedAt'] as String,
        dataDate: json['dataDate'] as String,
        stockCount: json['stockCount'] as int,
        evaluableDays: json['evaluableDays'] as int,
        ruleWinRate: {
          for (final e in (json['ruleWinRate'] as Map<String, dynamic>).entries)
            e.key: (e.value as num).toDouble(),
        },
        recentExcess: (json['recentExcess'] as Map<String, dynamic>?)
            ?.map((k, v) => MapEntry(k, RecentExcessRec.fromJson(v as Map<String, dynamic>))),
      );

  /// 从一份完整报告 + 数据截止日提炼快照。
  ///
  /// 报告带 recent 数据时顺带记录每条规则的窗口超额（固定种子，可复现）；
  /// 全部规则都没有窗口记录时该字段为 null。
  factory BacktestSnapshot.of(BacktestReport r, String dataDate, {int horizon = 10}) {
    final baseSlice = r.recentBaseline[horizon];
    Map<String, RecentExcessRec>? recs;
    if (baseSlice != null && baseSlice.dayMeanReturn.isNotEmpty) {
      for (final e in r.recent.entries) {
        final slice = e.value[horizon];
        if (slice == null || slice.dayMeanReturn.isEmpty) continue;
        final ci = recentExcessCI(
          ruleDayMean: slice.dayMeanReturn,
          baseDayMean: baseSlice.dayMeanReturn,
          seed: 7,
        );
        (recs ??= {})[e.key] = RecentExcessRec(
          excess: ci.excess,
          ciLow: ci.ciLow,
          ciHigh: ci.ciHigh,
          days: slice.dayMeanReturn.length,
        );
      }
    }
    return BacktestSnapshot(
      generatedAt: r.generatedAt,
      dataDate: dataDate,
      stockCount: r.stockCount,
      evaluableDays: r.baseline[horizon]?.count ?? 0,
      ruleWinRate: {
        for (final e in r.results.entries)
          if (e.value[horizon] != null && e.value[horizon]!.count > 0)
            e.key: e.value[horizon]!.winRate,
      },
      recentExcess: recs,
    );
  }
}

/// 月度跟踪台账：按时间顺序排列的报告快照。
class BacktestHistory {
  const BacktestHistory(this.snapshots);

  final List<BacktestSnapshot> snapshots;

  bool get isEmpty => snapshots.isEmpty;

  /// 追加/替换一期：同一数据截止日只保留最新一条（当天重跑不算新窗口），
  /// 结果按 dataDate 升序。App（runBacktest）与 CLI（report_all --archive）共用。
  BacktestHistory upsert(BacktestSnapshot snap) => BacktestHistory([
        ...snapshots.where((s) => s.dataDate != snap.dataDate),
        snap,
      ]..sort((a, b) => a.dataDate.compareTo(b.dataDate)));

  /// [ruleId] 的连续红期数：从最新一期往回数，遇到不红（灰/绿）、样本不足、
  /// 或该期没有窗口记录（旧快照/该期无信号）即断。"连续两个窗口都红" = 返回 ≥2。
  int consecutiveReds(String ruleId, {int minDays = kMinSignificantDays}) {
    final ordered = [...snapshots]..sort((a, b) => a.dataDate.compareTo(b.dataDate));
    var n = 0;
    for (final s in ordered.reversed) {
      final rec = s.recentExcess?[ruleId];
      if (rec == null || rec.days < minDays || rec.ciLow <= 0) break;
      n++;
    }
    return n;
  }

  /// 某条规则的胜率随时间变化（按数据截止日升序）。
  /// 只返回至少出现两次的规则——只出现一次的无从判断漂移。
  List<(String, List<double>)> series(String ruleId) {
    final pts = [
      for (final s in snapshots)
        if (s.ruleWinRate.containsKey(ruleId)) s.ruleWinRate[ruleId]!
    ];
    return pts.length < 2 ? const [] : [(ruleId, pts)];
  }

  /// 全部「至少出现两次」的规则，按 id 排序。
  List<String> comparableRuleIds() {
    final counts = <String, int>{};
    for (final s in snapshots) {
      for (final id in s.ruleWinRate.keys) {
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    return (counts.entries.where((e) => e.value >= 2).map((e) => e.key).toList()..sort());
  }

  Map<String, dynamic> toJson() => {
        'snapshots': [for (final s in snapshots) s.toJson()],
      };

  factory BacktestHistory.fromJson(Map<String, dynamic> json) => BacktestHistory([
        for (final s in json['snapshots'] as List)
          BacktestSnapshot.fromJson(s as Map<String, dynamic>),
      ]);
}
