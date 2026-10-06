/// 规则回测：逐日滚动评估规则，统计信号日之后 N 日的收益分布，
/// 并与**同一起点集合、同一时间窗**的无条件基准（base rate）对比。
///
/// 没有基准，胜率高不高无从谈起——一条规则 55% 胜率可能是好消息也可能是坏消息，
/// 取决于同期随便买一只股票有多少概率上涨。
library;

import 'dart:math' as math;

import 'models.dart';
import 'rules.dart';

/// 回测报告覆盖的持有期（天）。页面展示与 CLI 默认都用这套。
const kDefaultHorizons = [5, 10, 20];

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
class BacktestStats {
  const BacktestStats({
    required this.count,
    required this.winRate,
    required this.avgReturn,
    required this.medianReturn,
    required this.bestReturn,
    required this.worstReturn,
    required this.profitFactor,
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
    var gain = 0.0, loss = 0.0;
    for (final x in xs) {
      if (x > 0) {
        gain += x;
      } else if (x < 0) {
        loss += -x;
      }
    }
    return BacktestStats(
      count: xs.length,
      winRate: xs.where((x) => x > 0).length / xs.length,
      avgReturn: xs.reduce((a, b) => a + b) / xs.length,
      medianReturn: _median(xs),
      bestReturn: xs.reduce(math.max),
      worstReturn: xs.reduce(math.min),
      profitFactor: (gain == 0 || loss == 0) ? 0 : gain / loss,
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

  Map<String, dynamic> toJson() => {
        'count': count,
        'winRate': winRate,
        'avgReturn': avgReturn,
        'medianReturn': medianReturn,
        'bestReturn': bestReturn,
        'worstReturn': worstReturn,
        'profitFactor': profitFactor,
      };

  factory BacktestStats.fromJson(Map<String, dynamic> json) => BacktestStats(
        count: json['count'] as int,
        winRate: (json['winRate'] as num).toDouble(),
        avgReturn: (json['avgReturn'] as num).toDouble(),
        medianReturn: (json['medianReturn'] as num).toDouble(),
        bestReturn: (json['bestReturn'] as num).toDouble(),
        worstReturn: (json['worstReturn'] as num).toDouble(),
        profitFactor: (json['profitFactor'] as num).toDouble(),
      );
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
BacktestResult backtestRule(
  List<StockData> stocks,
  Rule rule, {
  required int forwardDays,
}) {
  if (forwardDays <= 0) {
    throw ArgumentError('forwardDays 必须为正，实际 $forwardDays');
  }
  final outcomes = <SignalOutcome>[];
  for (final stock in stocks) {
    final bars = stock.bars;
    if (evaluableDays(bars.length, forwardDays) == 0) continue;
    final series = IndicatorSeries.from(bars);
    final lastEval = bars.length - 1 - forwardDays;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
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
Baseline baseline(List<StockData> stocks, {required int forwardDays}) {
  if (forwardDays <= 0) {
    throw ArgumentError('forwardDays 必须为正，实际 $forwardDays');
  }
  final returns = <double>[];
  for (final stock in stocks) {
    final bars = stock.bars;
    if (evaluableDays(bars.length, forwardDays) == 0) continue;
    final lastEval = bars.length - 1 - forwardDays;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      returns.add((bars[t + forwardDays].close / bars[t].close - 1) * 100);
    }
  }
  return Baseline(forwardDays: forwardDays, returns: returns);
}

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
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
    );
  }
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

  for (final stock in stocks) {
    final bars = stock.bars;
    // 可评估日统一取最大持有期的范围，保证三个持有期覆盖同一批交易日、彼此可比。
    if (bars.length < IndicatorSnapshot.minBars + maxH) continue;
    final series = IndicatorSeries.from(bars);
    final lastEval = bars.length - 1 - maxH;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      final from = bars[t].close;
      final year = bars[t].date.year;
      // 前瞻收益每个持有期只算一次：原来基准桶与信号桶各算一遍。
      final fwdByH = [for (final h in hs) (bars[t + h].close / from - 1) * 100];
      for (var i = 0; i < baseFlat.length; i++) {
        baseFlat[i].add(fwdByH[i], year);
      }
      // 逐条规则判定：绝大多数规则在标量条件就返回 false，不碰 Tape。
      final snap = series.at(t);
      var k = 0;
      for (final r in rules) {
        if (r.test(snap)) {
          for (var i = 0; i < hs.length; i++) {
            sigFlat[k + i].add(fwdByH[i], year);
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

  int _count = 0;
  double _sum = 0, _gain = 0, _loss = 0;
  int _wins = 0;
  double? _best, _worst;

  void add(double value, int year) {
    (_byYear[year] ??= []).add(value);
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

  /// 年份升序；首次访问时顺带把各年桶原地排序（收尾只发生一次）。
  late final List<int> _sortedYears = () {
    final ys = _byYear.keys.toList()..sort();
    for (final y in ys) {
      _byYear[y]!.sort();
    }
    return ys;
  }();

  BacktestStats statsOfYear(int year) {
    final bucket = _byYear[year];
    if (bucket == null) return BacktestStats.empty;
    bucket.sort(); // 已被 _sortedYears 排过时是 O(n) 已序扫描
    return _statsOfSorted(bucket);
  }

  BacktestStats overall() {
    if (_count == 0) return BacktestStats.empty;
    return BacktestStats(
      count: _count,
      winRate: _wins / _count,
      avgReturn: _sum / _count,
      medianReturn: _medianOfUnion(),
      bestReturn: _best!,
      worstReturn: _worst!,
      profitFactor: (_gain == 0 || _loss == 0) ? 0 : _gain / _loss,
    );
  }

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
    );
  }

  /// 全样本中位数：对各年份有序桶做多路归并，只走到中位数位置就停。
  ///
  /// 段数 = 年份数（全市场约 3），所以这是 O(中位数位置 × 年份数) 的线性扫描，
  /// 比对全部元素再整体排序便宜一个数量级，且**仍是精确值**。
  double _medianOfUnion() {
    if (_count == 0) return 0;
    if (_count == 1) return _byYear.values.first[0];
    final ys = _sortedYears;
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

/// 按回测报告的 10 日胜率给规则 id 降序排序。
///
/// 刻意在**显示时**算而不是把顺序硬编码进 `builtInRules`：胜率是数据相关的，
/// 写进源码后一刷新报告就过期。无报告、或某规则没有回测数据（胜率按 −1 处理）时，
/// 该规则排在后面并保持 [ids] 里的原始顺序，避免每次刷新排序抖动。
List<String> ruleIdsSortedByWinRate(List<String> ids, BacktestReport? report) {
  if (report == null) return ids;
  double winOf(String id) => report.result(id, 10)?.winRate ?? -1;
  final ordered = [...ids];
  ordered.sort((a, b) {
    final byWin = winOf(b).compareTo(winOf(a));
    return byWin != 0 ? byWin : ids.indexOf(a).compareTo(ids.indexOf(b));
  });
  return ordered;
}

/// 按「组内最高 10 日胜率」给规则分组降序排序。
///
/// 只排序组内规则还不够——最好的规则可能埋在第三个分组里。把分组也按
/// 组内最高胜率排，包含最强规则的分组就会排到最前。
/// 无报告时保持 [groups] 的声明顺序。
List<MapEntry<String, List<String>>> ruleGroupsSortedByWinRate(
  Map<String, List<String>> groups,
  BacktestReport? report,
) {
  final order = {for (var i = 0; i < groups.length; i++) groups.keys.elementAt(i): i};
  final entries = groups.entries.toList();
  if (report == null) return entries;
  double topOf(List<String> ids) =>
      ids.map((id) => report.result(id, 10)?.winRate ?? -1).reduce(math.max);
  entries.sort((a, b) {
    final byTop = topOf(b.value).compareTo(topOf(a.value));
    return byTop != 0 ? byTop : order[a.key]!.compareTo(order[b.key]!);
  });
  return entries;
}

/// 规则是否「跨年稳健」：在**每一个有数据的年份**，10 日胜率都跑赢该年的无条件基准。
///
/// 全样本均值会把"只有某一年特别 high"的规则抬上来，所以拿它当筛选条件比按全样本
/// 胜率排序更可靠。某一年没有可用数据（如 MA250 需要 250 根，早年算不出来）时跳过该年，
/// 不视为不稳健——但也因此不能算"验证过"。
bool isRuleYearlyRobust(BacktestReport report, String ruleId, {int horizon = 10}) {
  for (final y in report.yearly.keys) {
    final st = report.yearly[y]?[ruleId]?[horizon];
    final base = report.yearlyBaseline[y]?[horizon];
    if (st == null || base == null || st.count == 0) continue;
    if (st.winRate <= base.winRate) return false;
  }
  return true;
}

/// 跨年稳健的规则 id 列表（保持 [rules] 的声明顺序）。
List<String> robustRuleIds(BacktestReport? report, List<Rule> rules) {
  if (report == null) return const [];
  return [
    for (final r in rules)
      if (isRuleYearlyRobust(report, r.id)) r.id
  ];
}

/// 回测报告的历史快照（月度跟踪用）。
///
/// 目的：现在所有结论都是**样本内**的。真正的考验是未来，而唯一的验证手段是
/// 持续记录、隔一段时间重跑、看胜率有没有漂移。这份快照把一个月的报告固化下来，
/// `tool/report_all.dart --archive` 每次重跑都会追加一条。
class BacktestSnapshot {
  const BacktestSnapshot({
    required this.generatedAt,
    required this.dataDate,
    required this.stockCount,
    required this.evaluableDays,
    required this.ruleWinRate,
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

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt,
        'dataDate': dataDate,
        'stockCount': stockCount,
        'evaluableDays': evaluableDays,
        'ruleWinRate': ruleWinRate,
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
      );

  /// 从一份完整报告 + 数据截止日提炼快照。
  factory BacktestSnapshot.of(BacktestReport r, String dataDate, {int horizon = 10}) =>
      BacktestSnapshot(
        generatedAt: r.generatedAt,
        dataDate: dataDate,
        stockCount: r.stockCount,
        evaluableDays: r.baseline[horizon]?.count ?? 0,
        ruleWinRate: {
          for (final e in r.results.entries)
            if (e.value[horizon] != null && e.value[horizon]!.count > 0)
              e.key: e.value[horizon]!.winRate,
        },
      );
}

/// 月度跟踪台账：按时间顺序排列的报告快照。
class BacktestHistory {
  const BacktestHistory(this.snapshots);

  final List<BacktestSnapshot> snapshots;

  bool get isEmpty => snapshots.isEmpty;

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
