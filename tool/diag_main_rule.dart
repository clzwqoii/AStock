/// 主规则画像诊断：回答"选出来的到底是一批什么票、抄底失败会有多疼"。
///
/// 四段：
///   1. 当前选股结果画像（是不是清一色「大跌的票」）
///   2. 按信号日形态拆分（上涨/下跌 × 收盘位置）的前瞻收益
///   3. 新鲜度检查（末日快照会把「化石股票」当成今天的信号）
///   4. 除权/复牌假信号（库内为不复权价，除权日的机械跌幅会被当成超卖）
///   5. 常见过滤口径在样本内的表现（诊断用，不是调参建议）
///
/// 与 bin/screen.dart 同口径：`loadAllStocks(excludeSpecialStocks: true)`。
/// 前瞻收益只用 `bars[0..t]` 构造快照（IndicatorSeries），无前瞻偏差。
///
/// 用法:
///   dart run tool/diag_main_rule.dart [--db 路径] [--rule 规则id] [--forward 10] [--recent 60]
library;

// ignore_for_file: avoid_print

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/indicators.dart' as ind;
import 'package:stock/core/market.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/screener.dart';
import 'package:stock/data/bar_repository.dart';

/// 停牌护栏回溯根数（先量化再定阈值）。
const kSuspensionLookback = 20;

/// 交易日历阈值：某日全市场有至少这么多只股票有行，才算"全市场共同交易日"。
/// 与 tool/fill_gaps.dart 同口径——节假日全市场都没行，不能被误判成个股停牌。
const kCalendarMinRows = 4000;

/// 信号日形态分桶。按「当日涨跌方向 × 收盘位置」切——
/// 量比>1.5 是主规则的共同前提，所以差异只能来自当日 K 线的方向与收盘位置。
enum SignalDayShape {
  /// 上涨且收在当日振幅上半部：主动性买盘，像样的放量反弹。
  upStrong('上涨·收上半部'),

  /// 上涨但收在下半部：冲高回落，反弹被压回。
  upWeak('上涨·收下半部'),

  /// 下跌但收在上半部：长下影，日内被拉回。
  downStrong('下跌·收上半部'),

  /// 下跌且收在下半部：放量下跌收在低点＝最像"抄底抄在半山腰"。
  downWeak('下跌·收下半部');

  const SignalDayShape(this.label);

  final String label;
}

SignalDayShape shapeOf(double pctChange, double closePos) {
  if (pctChange >= 0) {
    return closePos >= 0.5 ? SignalDayShape.upStrong : SignalDayShape.upWeak;
  }
  return closePos >= 0.5 ? SignalDayShape.downStrong : SignalDayShape.downWeak;
}

class _Bucket {
  final returns = <double>[];
  final dayMoves = <double>[];

  void add(double ret, double dayMove) {
    returns.add(ret);
    dayMoves.add(dayMove);
  }

  BacktestStats get stats => BacktestStats.of(returns);

  double get medianDayMove {
    if (dayMoves.isEmpty) return 0;
    final s = [...dayMoves]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }
}

String _pct(double v, {int digits = 2}) => '${v.toStringAsFixed(digits)}%';

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

void _printBucket(String indent, String name, _Bucket b) {
  final s = b.stats;
  if (s.count == 0) {
    print('$indent${name.padRight(24)} 0 个信号');
    return;
  }
  print('$indent${name.padRight(24)} '
      '信号 ${s.count.toString().padLeft(5)}  '
      '胜率 ${(s.winRate * 100).toStringAsFixed(1)}%  '
      '均收益 ${_pct(s.avgReturn)}  '
      'p10 ${_pct(s.p10 ?? 0)}  '
      '最差 ${_pct(s.worstReturn, digits: 1)}  '
      'PF ${s.profitFactor.toStringAsFixed(2)}  '
      '信号日中位涨跌 ${_pct(b.medianDayMove)}');
}

/// 一次信号扫描的全部中间量：形态 / 跳空 / 各过滤口径是否通过 / 新旧程度。
class _Signal {
  _Signal({
    required this.symbol,
    required this.date,
    required this.ret,
    required this.dayMove,
    required this.closePos,
    required this.gap,
    required this.barsSinceGap,
    required this.maxSuspensionGap,
    required this.bias20,
    required this.rsi14,
    required this.fresh,
  });

  final String symbol;
  final DateTime date;
  final double ret;
  final double dayMove;
  final double closePos;
  final double gap;

  /// 距最近一次异常跳空（除权/复牌）的 K 线根数，0 = 当天就是。
  final int barsSinceGap;

  /// 信号日往前 [kSuspensionLookback] 根内最大的"停牌洞"（单位=交易日）。
  /// 1 = 根根相邻（没有洞）。
  final int maxSuspensionGap;

  /// 信号日收盘相对 MA20 的乖离（%）。
  final double bias20;
  final double rsi14;

  /// 信号日是否就是该股的末根（= 库里最新数据，选股当天真的能看到）。
  final bool fresh;

  SignalDayShape get shape => shapeOf(dayMove, closePos);
  /// 当日是否除权除息 / 长期停牌复牌（按该股票的涨跌停幅度判定）。
  bool get abnormalGap => gap.abs() > 21;
}

Future<void> main(List<String> args) async {
  var dbPath = AppConfig.load().dbPath;
  var ruleId = kMainRuleId;
  var forwardDays = 10;
  var recentDays = 60;

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--db':
        dbPath = args[++i];
      case '--rule':
        ruleId = args[++i];
      case '--forward':
        forwardDays = int.parse(args[++i]);
      case '--recent':
        recentDays = int.parse(args[++i]);
      default:
        throw ArgumentError('未知参数 ${args[i]}');
    }
  }

  final rule = ruleById(ruleId);
  final repo = BarRepository(dbPath);
  final stocks = repo.loadAllStocks(excludeSpecialStocks: true);
  repo.close();

  final poolLast = _poolLastDate(stocks);
  print('库=$dbPath');
  print('池=${stocks.length} 只（已剔除 ST/退市/科创板）  池内最大交易日='
      '${poolLast.toIso8601String().substring(0, 10)}');
  print('规则=${rule.id} ${rule.name}');
  print('  ${rule.desc}');
  print('持有期=$forwardDays 日；近期窗口=最近 $recentDays 个交易日');

  // 「最近 N 个交易日」一律按池内自然交易日历切窗，不按信号日切——
  // 信号是聚堆出现的（暴跌日一天几十个），按信号日切会把窗口悄悄缩短成几天。
  final poolDates = {for (final s in stocks) for (final b in s.bars) b.date}.toList()..sort();
  final cutoff =
      poolDates.length > recentDays ? poolDates[poolDates.length - 1 - recentDays] : poolDates.first;

  _currentHits(stocks, rule, poolLast);
  print('');
  _dailyProfile(stocks, rule, poolDates, poolLast, recentDays);
  print('');
  _freshness(stocks, rule, poolLast);

  final calendar = _tradingCalendar(stocks);
  final signals = _scan(stocks, rule, forwardDays, poolLast, calendar);
  print('');
  _shapeSplit(signals, stocks, forwardDays, cutoff);
  print('');
  _gapSplit(signals, cutoff);
  print('');
  _variants(signals, cutoff);
  print('');
  _pollutionWindow(signals, cutoff);
  print('');
  _missedDetection(signals, cutoff);
  print('');
  _suspensionImpact(signals, cutoff);
}

// ── 公共：池内最大交易日 ──────────────────────────────────────

DateTime _poolLastDate(List<StockData> stocks) {
  var latest = stocks.first.bars.last.date;
  for (final s in stocks) {
    final d = s.bars.last.date;
    if (d.isAfter(latest)) latest = d;
  }
  return latest;
}

// ── 1. 当前选股结果画像 ────────────────────────────────────────

void _currentHits(List<StockData> stocks, Rule rule, DateTime poolLast) {
  final hits = screenWithHits(stocks, [rule]);
  print('');
  print('═══ 1. 当前选股结果（末日快照，共 ${hits.length} 只）═══');
  if (hits.isEmpty) return;

  final rows = <_HitRow>[];
  for (final h in hits) {
    final b = h.stock.bars;
    final n = b.length;
    rows.add(_HitRow(
      symbol: h.stock.symbol,
      close: b[n - 1].close,
      pctChange: h.snapshot.pctChange,
      rsi14: h.snapshot.rsi14,
      volumeRatio: h.snapshot.volumeRatio,
      closePos: h.snapshot.closePos,
      ret5: (b[n - 1].close / b[n - 6].close - 1) * 100,
      ret20: n >= 21 ? (b[n - 1].close / b[n - 21].close - 1) * 100 : 0,
      bias20: ind.biasPctOf(b[n - 1].close, _meanClose(b, 20)),
      bias60: n >= 60 ? ind.biasPctOf(b[n - 1].close, _meanClose(b, 60)) : null,
      lastDate: b.last.date,
    ));
  }

  final down = rows.where((r) => r.pctChange < 0).length;
  final downWeak = rows.where((r) => r.pctChange < 0 && r.closePos < 0.5).length;
  final belowMa20 = rows.where((r) => r.bias20 < 0).length;
  final belowMa60 = rows.where((r) => (r.bias60 ?? 1) < 0).length;

  print('当日收跌：$down/${rows.length}；其中"跌且收在当日下半部（弱收盘）"：$downWeak');
  print('收盘在 MA20 下方：$belowMa20；在 MA60 下方：$belowMa60');
  print('信号日中位涨跌 ${_pct(_median([for (final r in rows) r.pctChange]))}'
      '；近5日中位 ${_pct(_median([for (final r in rows) r.ret5]))}'
      '；近20日中位 ${_pct(_median([for (final r in rows) r.ret20]))}');
  final ret20 = [for (final r in rows) r.ret20]..sort();
  print('近20日跌幅：最差 ${_pct(ret20.first)}  中位 ${_pct(_median(ret20))}  最好 ${_pct(ret20.last)}');
  print('RSI14 中位 ${_median([for (final r in rows) r.rsi14]).toStringAsFixed(1)}'
      '；量比中位 ${_median([for (final r in rows) r.volumeRatio]).toStringAsFixed(2)}');
  print('');
  print('逐只（按近20日跌幅从狠到轻）：');
  final worst = [...rows]..sort((a, b) => a.ret20.compareTo(b.ret20));
  for (final r in worst) {
    final stale = r.lastDate.isBefore(poolLast) ? ' ⚠末根非今日' : '';
    print('  ${r.symbol.padRight(10)} '
        '收 ${r.close.toStringAsFixed(2).padLeft(7)}  '
        '当日 ${_pct(r.pctChange)}  5日 ${_pct(r.ret5)}  20日 ${_pct(r.ret20)}  '
        'RSI ${r.rsi14.toStringAsFixed(1)}  量比 ${r.volumeRatio.toStringAsFixed(2)}  '
        'MA20乖离 ${_pct(r.bias20)}  MA60乖离 ${r.bias60 == null ? '—' : _pct(r.bias60!)}$stale');
  }
}

double _meanClose(List<Bar> bars, int n) {
  final from = bars.length - n;
  var sum = 0.0;
  for (var i = from; i < bars.length; i++) {
    sum += bars[i].close;
  }
  return sum / n;
}

class _HitRow {
  _HitRow({
    required this.symbol,
    required this.close,
    required this.pctChange,
    required this.rsi14,
    required this.volumeRatio,
    required this.closePos,
    required this.ret5,
    required this.ret20,
    required this.bias20,
    required this.bias60,
    required this.lastDate,
  });

  final String symbol;
  final double close;
  final double pctChange;
  final double rsi14;
  final double volumeRatio;
  final double closePos;
  final double ret5;
  final double ret20;
  final double bias20;
  final double? bias60;
  final DateTime lastDate;
}

// ── 2. 最近 N 个交易日逐日画像 ───────────────────────────────

/// 一天的命中构成。
class _DayHit {
  _DayHit({
    required this.symbol,
    required this.fossil,
    required this.gapDay,
    required this.move,
    required this.ret20,
    required this.bias20,
  });

  final String symbol;

  /// 该股这一根不是它的末根（= 停牌/退市后的化石信号）。
  final bool fossil;

  /// 当日开盘相对前收盘跳空超过 11%（除权/复牌）。
  final bool gapDay;
  final double move;
  final double ret20;
  final double bias20;
}

/// 逐日重跑规则（只看 `bars[0..t]`，不看未来），统计每天的命中构成：
/// 有多少是化石票、多少踩在除权/复牌日、被选出来之前已经跌了多深。
void _dailyProfile(
  List<StockData> stocks,
  Rule rule,
  List<DateTime> poolDates,
  DateTime poolLast,
  int recentDays,
) {
  final days = poolDates.length <= recentDays
      ? poolDates
      : poolDates.sublist(poolDates.length - recentDays);
  final daySet = days.toSet();
  final perDay = <DateTime, List<_DayHit>>{};
  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < IndicatorSnapshot.minBars) continue;
    final series = IndicatorSeries.from(bars);
    for (var t = IndicatorSnapshot.minBars - 1; t < bars.length; t++) {
      if (!daySet.contains(bars[t].date)) continue;
      if (!rule.test(series.at(t))) continue;
      perDay.putIfAbsent(bars[t].date, () => []).add(_DayHit(
        symbol: stock.symbol,
        // 化石 = 这只票的末根早于池内最大交易日（停牌/退市），
        // 它的"今天"其实是很久以前——不是"这一天之前跌了"的那种化石。
        fossil: bars.last.date.isBefore(poolLast),
        gapDay: t >= 1 && isCorporateActionGap(stock.symbol, bars[t - 1], bars[t]),
        move: (bars[t].close - bars[t - 1].close) / bars[t - 1].close * 100,
        ret20: t >= 20 ? (bars[t].close / bars[t - 20].close - 1) * 100 : 0,
        bias20: ind.biasPctOf(bars[t].close, _meanClose(bars.sublist(0, t + 1), 20)),
      ));
    }
  }

  print('═══ 2. 最近 ${days.length} 个交易日逐日画像 ═══');
  print('日期         命中  化石  除权日  当日中位涨跌  前20日中位跌幅  中位乖离MA20');
  var totalHits = 0, totalFossil = 0, totalGap = 0;
  for (final day in days) {
    final hits = perDay[day] ?? const [];
    if (hits.isEmpty) {
      print('${day.toIso8601String().substring(0, 10)}      0');
      continue;
    }
    totalHits += hits.length;
    if (hits.length <= 8) {
      print('    └ ${hits.map((h) => h.symbol + (h.fossil ? '(化石)' : '') + (h.gapDay ? '(除权/复牌日)' : '')).join(' ')}');
    }
    final fossil = hits.where((h) => h.fossil).length;
    final gap = hits.where((h) => h.gapDay).length;
    totalFossil += fossil;
    totalGap += gap;
    print('${day.toIso8601String().substring(0, 10)}  '
        '${hits.length.toString().padLeft(4)}  '
        '${fossil.toString().padLeft(4)}  '
        '${gap.toString().padLeft(6)}  '
        '${_pct(_median([for (final h in hits) h.move])).padLeft(12)}  '
        '${_pct(_median([for (final h in hits) h.ret20])).padLeft(14)}  '
        '${_pct(_median([for (final h in hits) h.bias20])).padLeft(14)}');
  }
  if (totalHits > 0) {
    print('合计 $totalHits 个信号里：化石票 $totalFossil 个'
        '（${(totalFossil / totalHits * 100).toStringAsFixed(0)}%）、'
        '除权/复牌日 $totalGap 个（${(totalGap / totalHits * 100).toStringAsFixed(0)}%）'
        ' —— 这两类都是"数据造成的假超卖"，不是真的跌到位了');
  }
}

// ── 3. 新鲜度检查 ────────────────────────────────────────────

void _freshness(List<StockData> stocks, Rule rule, DateTime poolLast) {
  final stale = stocks.where((s) => s.bars.last.date.isBefore(poolLast)).toList();
  print('═══ 3. 新鲜度：末日快照 = 「今天就长这样」是个假设 ═══');
  print('末根早于 ${poolLast.toIso8601String().substring(0, 10)} 的股票：'
      '${stale.length}/${stocks.length}（${(stale.length / stocks.length * 100).toStringAsFixed(1)}%）'
      ' —— 早已停牌/退市，选股却把它们当"今天"的信号');
  final fossils = stale.where((s) => poolLast.difference(s.bars.last.date).inDays > 365).toList();
  print('其中滞后一年以上的"化石"：${fossils.length} 只（'
      '${fossils.take(8).map((s) => s.symbol).join(' ')}${fossils.length > 8 ? ' …' : ''}）');

  final hits = screenWithHits(stocks, [rule]);
  final staleHits = hits.where((h) => h.stock.bars.last.date.isBefore(poolLast)).toList();
  print('当前命中 ${hits.length} 只，其中末根不是今日的：${staleHits.length} 只'
      '（${hits.isEmpty ? 0 : (staleHits.length / hits.length * 100).toStringAsFixed(0)}%）');
  for (final h in staleHits) {
    final b = h.stock.bars;
    print('  ⚠ ${h.stock.symbol.padRight(10)} 末根 ${b.last.date.toIso8601String().substring(0, 10)}'
        '（滞后 ${poolLast.difference(b.last.date).inDays} 天）  收 ${b.last.close}  '
        'RSI ${h.snapshot.rsi14.toStringAsFixed(1)} —— 这是两年前的"大跌"，今天买不到');
  }
}

// ── 3. 信号扫描 ──────────────────────────────────────────────

List<_Signal> _scan(
  List<StockData> stocks,
  Rule rule,
  int forwardDays,
  DateTime poolLast,
  Set<DateTime> calendar,
) {
  final out = <_Signal>[];
  for (final stock in stocks) {
    final bars = stock.bars;
    if (evaluableDays(bars.length, forwardDays) == 0) continue;
    final series = IndicatorSeries.from(bars);
    // 除权污染窗口一律走 core 的同一份判定，不在工具里另写一套
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    // 停牌洞要用**交易日历**判：节假日全市场一起休，停牌只有这只票缺。
    // 只用日历日差会把每个春节/国庆都算成"停牌"。
    final gapDays = _tradingDaysSincePrev(stock.symbol, bars, calendar);
    final lastEval = bars.length - 1 - forwardDays;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      if (!rule.test(series.at(t))) continue;
      out.add(_Signal(
        symbol: stock.symbol,
        date: bars[t].date,
        ret: (bars[t + forwardDays].close / bars[t].close - 1) * 100,
        dayMove: (bars[t].close - bars[t - 1].close) / bars[t - 1].close * 100,
        closePos: ind.closePos(bars[t]),
        gap: (bars[t].open / bars[t - 1].close - 1) * 100,
        barsSinceGap: sinceGap[t],
        maxSuspensionGap: _maxGapInWindow(gapDays, t, kSuspensionLookback),
        bias20: ind.biasPctOf(bars[t].close, _meanClose(bars.sublist(0, t + 1), 20)),
        rsi14: series.at(t).rsi14,
        fresh: bars[t].date == stock.bars.last.date,
      ));
    }
  }
  return out;
}

// ── 4. 按信号日形态拆分 ──────────────────────────────────────

void _shapeSplit(
  List<_Signal> signals,
  List<StockData> stocks,
  int forwardDays,
  DateTime cutoff,
) {
  print('═══ 4. 按信号日形态拆分（持有 $forwardDays 日）═══');
  _windowReport('全样本', signals, stocks, forwardDays, null);
  _windowReport(
      '近窗（起 ${cutoff.toIso8601String().substring(0, 10)}）',
      signals,
      stocks,
      forwardDays,
      cutoff);
  _loserTail(signals, forwardDays);
}

/// [from] 为 null = 全样本；否则只看到此日期（含）之后的信号与基准。
void _windowReport(
  String title,
  List<_Signal> signals,
  List<StockData> stocks,
  int forwardDays,
  DateTime? from,
) {
  final set = from == null ? signals : signals.where((s) => !s.date.isBefore(from)).toList();
  final base = _baseline(stocks, forwardDays, from: from);
  print('$title：信号 ${set.length} 个；同窗口无条件基准 胜率 '
      '${(base.winRate * 100).toStringAsFixed(1)}%  均收益 ${_pct(base.avgReturn)}  '
      'p10 ${_pct(base.p10 ?? 0)}  最差 ${_pct(base.worstReturn, digits: 1)}');
  final buckets = {for (final s in SignalDayShape.values) s: _Bucket()};
  for (final s in set) {
    buckets[s.shape]!.add(s.ret, s.dayMove);
  }
  for (final s in SignalDayShape.values) {
    _printBucket('  ', s.label, buckets[s]!);
  }
  print('');
}

/// 同一起点集合、同一时间窗的无条件基准（不做任何规则过滤）。
BacktestStats _baseline(List<StockData> stocks, int forwardDays, {DateTime? from}) {
  final rets = <double>[];
  for (final stock in stocks) {
    final bars = stock.bars;
    if (evaluableDays(bars.length, forwardDays) == 0) continue;
    final lastEval = bars.length - 1 - forwardDays;
    for (var t = IndicatorSnapshot.minBars; t <= lastEval; t++) {
      if (from != null && bars[t].date.isBefore(from)) continue;
      rets.add((bars[t + forwardDays].close / bars[t].close - 1) * 100);
    }
  }
  return BacktestStats.of(rets);
}

void _loserTail(List<_Signal> signals, int forwardDays) {
  final losers = [for (final s in signals) if (s.ret < 0) s.ret]..sort();
  if (losers.isEmpty) return;
  double q(double p) => losers[(losers.length * p).floor().clamp(0, losers.length - 1)];
  final total = signals.length;
  print('"失败一次有多疼"（亏损信号的 $forwardDays 日跌幅，n=${losers.length}，'
      '即全部信号的 ${(losers.length / total * 100).toStringAsFixed(1)}%）：');
  print('  中位 ${_pct(losers[losers.length ~/ 2])}  '
      'p25 ${_pct(q(0.25))}  p10 ${_pct(q(0.10))}  p5 ${_pct(q(0.05))}  '
      '最差 ${_pct(losers.first)}');
  final lt10 = losers.where((x) => x <= -10).length;
  final lt20 = losers.where((x) => x <= -20).length;
  print('  亏 >10%：$lt10 个（占全部信号 ${(lt10 / total * 100).toStringAsFixed(2)}%）；'
      '亏 >20%：$lt20 个');
}

// ── 5. 除权/复牌假信号 ───────────────────────────────────────

void _gapSplit(List<_Signal> signals, DateTime cutoff) {
  final normal = _Bucket(), downGap = _Bucket(), upGap = _Bucket();
  for (final s in signals) {
    if (!s.abnormalGap) {
      normal.add(s.ret, s.dayMove);
    } else if (s.gap < 0) {
      downGap.add(s.ret, s.dayMove);
    } else {
      upGap.add(s.ret, s.dayMove);
    }
  }
  print('═══ 5. 除权/复牌造成的假信号（开盘跳空超过该股当日涨跌停幅度）═══');
  print('全样本：');
  _printBucket('  ', '正常交易日', normal);
  _printBucket('  ', '向下跳空(除权/大幅低开)', downGap);
  _printBucket('  ', '向上跳空(复牌/大幅高开)', upGap);
  final recent = signals.where((s) => !s.date.isBefore(cutoff)).toList();
  print('近窗：');
  _printBucket('  ', '正常交易日', _pick(recent, (s) => !s.abnormalGap));
  _printBucket('  ', '异常跳空(任一方向)', _pick(recent, (s) => s.abnormalGap));
  final art = signals.where((s) => s.abnormalGap).length;
  print('全部信号里踩在异常跳空日的：$art/${signals.length}'
      '（${(art / signals.length * 100).toStringAsFixed(2)}%）'
      ' —— 库内是不复权价，除权日的机械跌幅必然砸出 RSI 超卖');
}

_Bucket _pick(List<_Signal> xs, bool Function(_Signal) test) {
  final b = _Bucket();
  for (final s in xs) {
    if (test(s)) b.add(s.ret, s.dayMove);
  }
  return b;
}

// ── 7. 除权后污染持续多久 ───────────────────────────────────

/// 不复权价在除权日有一个永久的价位断层，RSI(Wilder 14) 要把这个 -27% 的
/// "假跌幅"平滑掉需要约 14 根 K 线，MA60 更久。这里把信号按"距最近一次
/// 除权/复牌有几根"分桶，看污染窗口到底有多长、各窗口内的收益差多少。
void _pollutionWindow(List<_Signal> signals, DateTime cutoff) {
  print('═══ 7. 除权后污染窗口（近 N 根内出现过除权/复牌）═══');
  print('窗口     剔除信号   剔除后剩余   剩余胜率    剩余均收益   剩余p10    被剔除者胜率  被剔除者均收益');
  for (final n in const [0, 1, 5, 10, 14, 20, 60]) {
    // n=0 只看"信号当日就是除权日"，其余为"近 n 根内出现过除权/复牌"
    final keep = n == 0
        ? (_Signal s) => s.barsSinceGap > 0
        : (_Signal s) => s.barsSinceGap >= n;
    final drop = n == 0
        ? (_Signal s) => s.barsSinceGap == 0
        : (_Signal s) => s.barsSinceGap < n;
    final kept = _pick(signals, keep);
    final dropped = _pick(signals, drop);
    final a = kept.stats, b = dropped.stats;
    print('近${n.toString().padLeft(2)}根   '
        '${b.count.toString().padLeft(7)}   '
        '${a.count.toString().padLeft(9)}   '
        '${(a.winRate * 100).toStringAsFixed(1).padLeft(8)}%  '
        '${_pct(a.avgReturn).padLeft(10)}  '
        '${_pct(a.p10 ?? 0).padLeft(8)}  '
        '${b.count == 0 ? '       —' : (b.winRate * 100).toStringAsFixed(1).padLeft(11)}%  '
        '${b.count == 0 ? '        —' : _pct(b.avgReturn).padLeft(11)}');
  }
  final recent = signals.where((s) => !s.date.isBefore(cutoff)).toList();
  print('近窗同步（只算信号量）：');
  for (final n in const [0, 5, 14, 20]) {
    final dropped = _pick(recent, (s) => s.barsSinceGap < n);
    print('  近${n.toString().padLeft(2)}根内被剔除：${dropped.stats.count}/${recent.length}'
        '（${(dropped.stats.count / recent.length * 100).toStringAsFixed(1)}%）');
  }
}


// ── 9. 护栏漏检：涨跌停之内的送转（主要是北交所） ─────────────────

/// 现行除权判定用"开盘跳空超过涨跌停幅度"。北交所 ±30%，于是 10 转 3（−23%）
/// 这类送转会被判成合法跌停开盘而漏检。这里量出漏检到底有多大：
/// 统计所有"跳空超过本代码涨跌停 + 1pp、但不超过 30%"的日子（= 疑似漏检的除权），
/// 以及它们之后 20 根内产生了多少主规则信号。
void _missedDetection(List<_Signal> signals, DateTime cutoff) {
  final missed = signals
      .where((s) => s.gap.abs() > 21 && s.gap.abs() <= 30)
      .toList();
  final byCode = <String, int>{};
  for (final s in missed) {
    final bse = s.symbol.startsWith('920');
    byCode[bse ? '北交所920' : '其他(本应被抓住)'] =
        (byCode[bse ? '北交所920' : '其他(本应被抓住)'] ?? 0) + 1;
  }
  print('═══ 9. 护栏漏检量级（跳空 21%~30%，超过主板/双创限幅但北交所内）═══');
  print('全样本这类信号：${missed.length}/${signals.length}'
      '（${(missed.length / signals.length * 100).toStringAsFixed(2)}%） $byCode');
  final bse = missed.where((s) => s.symbol.startsWith('920')).toList();
  print('其中**现行护栏确实漏检**的（仅北交所，跳空在 ±30% 内）：'
      '${bse.length}/${signals.length}'
      '（${(bse.length / signals.length * 100).toStringAsFixed(2)}%）');
  print('  ${bse.take(6).map((s) => '${s.symbol}(${s.gap.toStringAsFixed(0)}%)').join(' ')}'
      '${bse.length > 6 ? ' …' : ''}');
  final recent = signals.where((s) => !s.date.isBefore(cutoff)).toList();
  final bseRecent = recent.where((s) =>
      s.symbol.startsWith('920') && s.gap.abs() > 21 && s.gap.abs() <= 30).length;
  print('近窗漏检：$bseRecent/${recent.length}'
      '（${recent.isEmpty ? 0 : (bseRecent / recent.length * 100).toStringAsFixed(1)}%）');
  print('注：这是**上限**——北交所那批里既有真送转，也有合法的大幅低开/高开，'
      '真实漏检比这小。非北交所的跳空超 21% 现行护栏已经全部抓住。');
}

// ── 10. 停牌洞对信号的污染 ─────────────────────────────────

/// 交易日历：某一天有 >=[kCalendarMinRows] 只股票有行，就认为是全市场共同交易日。
/// 这样节假日（全市场都没行）不会被误判成个股停牌。
Set<DateTime> _tradingCalendar(List<StockData> stocks) {
  final count = <DateTime, int>{};
  for (final s in stocks) {
    for (final b in s.bars) {
      count[b.date] = (count[b.date] ?? 0) + 1;
    }
  }
  return {for (final e in count.entries) if (e.value >= kCalendarMinRows) e.key};
}

/// 逐日"距上一根隔了几个交易日"（1 = 相邻）。第 0 根记为 1。
/// 用交易日历而不是日历日差：后者会把每个春节/国庆都算成停牌。
List<int> _tradingDaysSincePrev(String tsCode, List<Bar> bars, Set<DateTime> cal) {
  final out = List<int>.filled(bars.length, 1);
  if (cal.isEmpty) return out;
  for (var i = 1; i < bars.length; i++) {
    var n = 0;
    var d = bars[i - 1].date;
    while (d.isBefore(bars[i].date)) {
      d = d.add(const Duration(days: 1));
      if (cal.contains(d)) n++;
    }
    out[i] = n <= 0 ? 1 : n;
  }
  return out;
}

int _maxGapInWindow(List<int> gapDays, int t, int lookback) {
  final from = t - lookback + 1 < 1 ? 1 : t - lookback + 1;
  var m = 1;
  for (var i = from; i <= t; i++) {
    if (gapDays[i] > m) m = gapDays[i];
  }
  return m;
}

void _suspensionImpact(List<_Signal> signals, DateTime cutoff) {
  print('═══ 10. 停牌洞污染（回溯 $kSuspensionLookback 根内最大停牌天数）═══');
  void row(String title, List<_Signal> xs) {
    if (xs.isEmpty) return;
    final st = BacktestStats.of([for (final s in xs) s.ret]);
    print('  ${title.padRight(12)} 信号 ${st.count.toString().padLeft(5)}  '
        '胜率 ${(st.winRate * 100).toStringAsFixed(1)}%  均收益 ${_pct(st.avgReturn)}  '
        'p10 ${_pct(st.p10 ?? 0)}  最差 ${_pct(st.worstReturn, digits: 1)}');
  }

  print('全样本：');
  for (final k in ['无洞(1天)', '小洞(2-4天)', '中洞(5-9天)', '大洞(≥10天)']) {
    row(k, signals.where((s) => _suspBucket(s) == k).toList());
  }
  final recent = signals.where((s) => !s.date.isBefore(cutoff)).toList();
  if (recent.isNotEmpty) {
    print('近窗：');
    for (final k in ['无洞(1天)', '小洞(2-4天)', '中洞(5-9天)', '大洞(≥10天)']) {
      row(k, recent.where((s) => _suspBucket(s) == k).toList());
    }
  }
}

String _suspBucket(_Signal s) => s.maxSuspensionGap <= 1
    ? '无洞(1天)'
    : s.maxSuspensionGap <= 4
        ? '小洞(2-4天)'
        : s.maxSuspensionGap <= 9
            ? '中洞(5-9天)'
            : '大洞(≥10天)';

// ── 11. 常见过滤口径的样本内表现 ──────────────────────────────

void _variants(List<_Signal> signals, DateTime cutoff) {
  final variants = <String, bool Function(_Signal)>{
    '原样': (_) => true,
    '＋排除除权/复牌日': (s) => !s.abnormalGap,
    '＋信号日为阳线': (s) => s.dayMove > 0,
    '＋收盘位置≥0.5': (s) => s.closePos >= 0.5,
    '＋阳线且收上半部': (s) => s.dayMove > 0 && s.closePos >= 0.5,
    '＋收盘站上MA20': (s) => s.bias20 > 0,
    '＋RSI14<20（严格版阈值）': (s) => s.rsi14 < 20,
  };

  print('═══ 6. 过滤口径在样本内的表现（诊断，不是调参建议）═══');
  for (final entry in [
    MapEntry('全样本', signals),
    MapEntry('近窗', signals.where((s) => !s.date.isBefore(cutoff)).toList()),
  ]) {
    print('${entry.key}（信号 ${entry.value.length} 个）：');
    for (final e in variants.entries) {
      _printBucket('  ', e.key, _pick(entry.value, e.value));
    }
    print('');
  }
}
