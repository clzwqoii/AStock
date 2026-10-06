/// 训练集体检 + 三个候选优化的实盘对照实验。
///
/// ## 这个工具为什么存在
///
/// `tool/train_score.dart` 报的是**逐样本** AUC，而信号按天高度聚集
/// （暴跌日一天几十上百个、平日一两个）。同一天的信号共享同一段行情，
/// 不是独立观测——逐样本算标准误等于把 1 个观测当成 100 个用，CI 会窄到失真，
/// 于是"噪声"被当成"提升"。本项目在规则层已经栽过这一跤
/// （docs：「+KDJ金叉：+1.8pp 是噪声（z=1.21，se=1.51pp）」）。
///
/// 所以这里做三件事：
///
/// 1. **训练集体检**：样本量、按天聚集程度、有效独立观测数（≈有信号的天数）；
/// 2. **按天聚类的 bootstrap**：重抽单位是"交易日"而不是"样本"，给出
///    AUC(B)−AUC(A) 的 95% CI。CI 含 0 就说明当前模型的优势是噪声——
///    此时任何"加特征/换模型"的方案都在测同一个噪声；
/// 3. **两个标签口径的对照实验**：`binary`（10 日涨跌）vs `excess`
///    （10 日收益 − 当日全池中位数）。后者锐化目标，理论上对排序更有信息量，
///    但必须实测。同时给出**十分位价差**（top decile 平均收益 − bottom decile），
///    因为它比 AUC 更贴近"排最前面那批到底强多少"。
///
/// 全部实验在工具内闭环：特征矩阵就地构造，**不改 `featureNames` 契约**。
/// 只有赢了才往 `features.dart` 提升。
///
/// 用法: dart run tool/diag_train_set.dart [--db 路径] [--rounds 200] [--train-cap 300000]
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:stock/app_logic.dart' show loadBacktestReport;
import 'package:stock/config.dart';
import 'package:stock/core/features.dart';
import 'package:stock/core/logreg.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/score.dart';
import 'package:stock/data/bar_repository.dart';

const _horizon = 10;
const _l2 = 200.0;

/// 与 train_score 同一批规则：特征表里登记的那几条。
final _modelRules = [
  for (final n in featureNames.where((e) => e.startsWith('rule_')))
    ruleById(n.substring(5))
];

/// 一次信号样本。两个标签都存，避免为比标签重扫全市场。
class _S {
  _S({
    required this.day,
    required this.hitIds,
    required this.year,
    required this.ret,
    required this.excess,
    required this.x,
    required this.scoreB,
    required this.scoreA,
  });

  final String day;
  final int year;

  /// 10 日前向收益（%）。
  final double ret;

  /// ret − 当日全池中位收益（%）。>0 = 跑赢当天随便买一只。
  final double excess;

  final List<double> x;

  /// 命中的规则 id（主规则内部排序用）。
  final List<String> hitIds;

  /// 当日截面百分位（仅在 --xs-feats 时填）。
  List<double>? rank;
  final double scoreB;
  final double scoreA;

  int get y => ret > 0 ? 1 : 0;
  int get yEx => excess > 0 ? 1 : 0;
}

Future<void> main(List<String> args) async {
  var dbPath = AppConfig.load().dbPath;
  var rounds = 200;
  var trainCap = 300000;
  var xsFeats = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--db':
        dbPath = args[++i];
      case '--rounds':
        rounds = int.parse(args[++i]);
      case '--train-cap':
        trainCap = int.parse(args[++i]);
      case '--xs-feats':
        xsFeats = true;
      default:
        throw ArgumentError('未知参数 ${args[i]}');
    }
  }

  final repo = BarRepository(dbPath);
  final stocks = repo.loadAllStocks();
  final model = _loadModel(dbPath);
  final report = loadBacktestReport(dbPath);
  repo.close();
  print('库=$dbPath  池=${stocks.length} 只（与 train_score 同口径，不剔 ST）');

  // ── 第一遍：当日全池收益中位数（excess 标签的基准）──
  // 只用同一天的横截面信息，不进特征，所以不是前视；
  // 但它必须覆盖**全部**股票而不是只覆盖命中规则的股票，
  // 否则基准会被"被选中的子集"污染。
  print('第一遍：算当日全池收益中位数…');
  final dayReturns = <String, List<double>>{};
  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < IndicatorSnapshot.minBars + _horizon) continue;
    final last = bars.length - 1 - _horizon;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      (dayReturns[_ymd(bars[t].date)] ??= []).add(
        (bars[t + _horizon].close / bars[t].close - 1) * 100,
      );
    }
  }
  final dayMedian = {
    for (final e in dayReturns.entries) e.key: _median(e.value)
  };

  // ── 第二遍：收集样本 ──
  print('第二遍：收集信号样本…');
  final byDayCollect = <String, List<_S>>{};
  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < IndicatorSnapshot.minBars + _horizon) continue;
    final series = IndicatorSeries.from(bars);
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    final last = bars.length - 1 - _horizon;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      if (sinceGap[t] < kCorporateActionLookbackBars) continue;
      final snap = series.at(t);
      final ids = [for (final r in _modelRules) if (r.test(snap)) r.id];
      if (ids.isEmpty) continue;
      final ret = (bars[t + _horizon].close / bars[t].close - 1) * 100;
      final day = _ymd(bars[t].date);
      byDayCollect.putIfAbsent(day, () => []).add(_S(
        day: day,
        year: bars[t].date.year,
        ret: ret,
        excess: ret - (dayMedian[day] ?? 0),
        hitIds: ids,
        x: featureVector(snap, hitRuleIds: ids),
        scoreB: model?.predictProba(featureVector(snap, hitRuleIds: ids)) ?? 0.5,
        scoreA: (scoreOf(report, hitRuleIds: ids, horizon: _horizon).score) / 100,
      ));
    }
  }
  final all = [for (final v in byDayCollect.values) ...v];
  print('样本 ${all.length} 个 / ${byDayCollect.length} 个交易日');
  _concentration(all);
  print('');

  if (xsFeats) {
    _addCrossSectionalRanks(byDayCollect);
    print('已追加 6 个当日截面排名特征（rsi14/量比/收盘位置/乖离20/涨跌幅/额比）');
  }

  final train = all.where((s) => s.year <= 2025).toList();
  final hold = all.where((s) => s.year == 2026).toList();
  final trainSub = _subsample(train, trainCap);
  print('训练（2024+2025）${train.length} → 抽样 ${trainSub.length}；'
      'holdout（2026）${hold.length}');
  _labelStats('binary ', train, hold, (s) => s.y);
  _labelStats('excess ', train, hold, (s) => s.yEx);
  print('');

  // ── 实验 1：当前模型 + 按天聚类 bootstrap ──
  print('═══ 实验 1：线上方案 B vs 方案 A（按天聚类 bootstrap，$rounds 轮）═══');
  final holdSub = _subsample(hold, 100000);
  _compare('binary 标签', holdSub, (s) => s.y, (s) => s.scoreB, (s) => s.scoreA,
      rounds: rounds);
  _compare('excess 标签', holdSub, (s) => s.yEx, (s) => s.scoreB, (s) => s.scoreA,
      rounds: rounds);
  print('');

  // ── 实验 2：换标签重训，看 AUC 与十分位价差 ──
  print('═══ 实验 2：换标签重训（同一批特征，只改 y）═══');
  for (final label in [
    ('binary（10日涨跌）', _yBin),
    ('excess（减当日中位）', _yEx),
  ]) {
    final m = LogRegModel.train(
      [for (final s in trainSub) s.x],
      [for (final s in trainSub) label.$2(s)],
      maxIter: 60,
      l2: _l2,
    );
    final scores = [for (final s in holdSub) m.predictProba(s.x)];
    final ys = [for (final s in holdSub) label.$2(s)];
    final a = _aucFast(scores, ys);
    final ci = _bootstrapByDay(holdSub, (s) => m.predictProba(s.x), label.$2, rounds);
    final dec = _deciles(holdSub, (s) => m.predictProba(s.x), (s) => s.ret);
    print('标签=${label.$1}  AUC=${a?.toStringAsFixed(4)}  '
        'CI=[${ci.$1.toStringAsFixed(4)}, ${ci.$2.toStringAsFixed(4)}]');
    print('   十分位价差（top−bottom）= ${dec.toStringAsFixed(2)}pp'
        '；top10% 均收益 ${_topMean(holdSub, (s) => m.predictProba(s.x), (s) => s.ret).toStringAsFixed(2)}%'
        ' vs 全体 ${_mean([for (final s in holdSub) s.ret]).toStringAsFixed(2)}%');
    _topKByDay(holdSub, (s) => m.predictProba(s.x), (s) => s.ret);
  }

  if (xsFeats) {
    print('');
    print('═══ 实验 3：加截面排名特征（把绝对值换成"今天在全市场排第几"）═══');
    for (final label in [
      ('binary（10日涨跌）', _yBin),
      ('excess（减当日中位）', _yEx),
    ]) {
      final m = LogRegModel.train(
        [for (final s in trainSub) [...s.x, ...s.rank!]],
        [for (final s in trainSub) label.$2(s)],
        maxIter: 60,
        l2: _l2,
      );
      final scores = [for (final s in holdSub) m.predictProba([...s.x, ...s.rank!])];
      final ys = [for (final s in holdSub) label.$2(s)];
      final a = _aucFast(scores, ys);
      final ci = _bootstrapByDay(holdSub, (s) => m.predictProba([...s.x, ...s.rank!]),
          label.$2, rounds);
      print('标签=${label.$1}  AUC=${a?.toStringAsFixed(4)}  '
          'CI=[${ci.$1.toStringAsFixed(4)}, ${ci.$2.toStringAsFixed(4)}]');
      print('   十分位价差 ${_deciles(holdSub, (s) => m.predictProba([...s.x, ...s.rank!]), (s) => s.ret).toStringAsFixed(2)}pp');
      _topKByDay(holdSub, (s) => m.predictProba([...s.x, ...s.rank!]), (s) => s.ret);
    }
  }

  _withinRule(all);
}

/// 只在主规则的命中内排个高低。
///
/// ## 为什么这是唯一重要的口径
///
/// 前面所有指标都在回答"从几千个信号里挑前几名强不强"，而 App 不是这么用的：
/// 用户勾**一条**规则，引擎当天只回几只（2026-09-30 那天主规则就 1 只），
/// 列表按评分排序。所以模型的真实作用只有一个：
/// **在同一条规则选出的那几只之间区分强弱**。
///
/// 方案 A 对同一条规则的所有命中给同一个分（它只用规则的加权胜率），
/// 于是"规则内排序"完全由方案 B 的连续特征决定——这一维度此前从未被测过。
void _withinRule(List<_S> all) {
  if (all.isEmpty) return;
  print('');
  print('═══ 实验 4：主规则命中内部排序（模型在 App 里的真实用法）═══');
  final main = all
      .where((s) => s.hitIds.contains(kMainRuleId))
      .toList();
  if (main.isEmpty || main.first.scoreB == 0.5 && main.every((e) => e.scoreB == 0.5)) {
    print('没有可用模型，跳过。先跑 dart run tool/train_score.dart');
    return;
  }
  print('主规则 $kMainRuleId 命中 ${main.length} 个 / '
      '${main.map((e) => e.day).toSet().length} 天'
      '（每天中位 ${_median([for (final d in _groupCounts(main)) d.toDouble()]).toStringAsFixed(0)} 只）');
  for (final year in [2024, 2025, 2026]) {
    final set = main.where((s) => s.year == year).toList();
    if (set.isEmpty) continue;
    final sorted = [...set]..sort((a, b) => b.scoreB.compareTo(a.scoreB));
    final half = sorted.length ~/ 2;
    final top = sorted.take(half).map((e) => e.ret).toList();
    final bottom = sorted.reversed.take(half).map((e) => e.ret).toList();
    final allR = [for (final e in set) e.ret];
    print('  $year：全体均收益 ${_mean(allR).toStringAsFixed(2)}% · '
        '评分高的半 ${_mean(top).toStringAsFixed(2)}% · '
        '评分低的半 ${_mean(bottom).toStringAsFixed(2)}% · '
        '差 ${(_mean(top) - _mean(bottom)).toStringAsFixed(2)}pp');
  }
  // 按天配对：同一天内比高低，跨天比等于比行情。必须分年看——
  // 2024 是训练期（样本内），2026 才是真正的样本外。
  for (final year in [2024, 2025, 2026]) {
    final byDay = <String, List<_S>>{};
    for (final s in main.where((e) => e.year == year)) {
      byDay.putIfAbsent(s.day, () => []).add(s);
    }
    double dayPaired(bool topHalf) {
      var acc = 0.0;
      var n = 0;
      for (final rows in byDay.values) {
        if (rows.length < 4) continue;
        final sorted = [...rows]..sort((a, b) => b.scoreB.compareTo(a.scoreB));
        final k = sorted.length ~/ 2;
        final pick = topHalf ? sorted.take(k) : sorted.reversed.take(k);
        acc += _mean([for (final e in pick) e.ret]);
        n++;
      }
      return n == 0 ? double.nan : acc / n;
    }

    final hi = dayPaired(true), lo = dayPaired(false);
    // 按天重抽，给这个差一个 CI：每天只有 2v2 只票，裸差值的噪声极大
    final rnd = math.Random(20261006);
    final days = byDay.values.where((e) => e.length >= 4).toList();
    final diffs = <double>[];
    for (var r = 0; r < 400; r++) {
      var accHi = 0.0, accLo = 0.0;
      var n = 0;
      for (var i = 0; i < days.length; i++) {
        final rows = days[rnd.nextInt(days.length)];
        final sorted = [...rows]..sort((a, b) => b.scoreB.compareTo(a.scoreB));
        final k = sorted.length ~/ 2;
        accHi += _mean([for (final e in sorted.take(k)) e.ret]);
        accLo += _mean([for (final e in sorted.reversed.take(k)) e.ret]);
        n++;
      }
      if (n > 0) diffs.add((accHi - accLo) / n);
    }
    diffs.sort();
    final loCi = diffs[(diffs.length * 0.025).floor()];
    final hiCi = diffs[(diffs.length * 0.975).floor()];
    print('  $year 按天配对（${days.length} 天，每天 2v2）：'
        '高半 ${hi.toStringAsFixed(2)}% vs 低半 ${lo.toStringAsFixed(2)}% · '
        '差 ${(hi - lo).toStringAsFixed(2)}pp · '
        '95%CI [${loCi.toStringAsFixed(2)}, ${hiCi.toStringAsFixed(2)}]pp'
        '${loCi <= 0 && hiCi >= 0 ? '  ← 含 0，噪声' : ''}'
        '${year <= 2025 ? '（样本内）' : '（样本外）'}');
  }
}

List<int> _groupCounts(List<_S> xs) {
  final m = <String, int>{};
  for (final s in xs) {
    m[s.day] = (m[s.day] ?? 0) + 1;
  }
  return m.values.toList();
}

/// 在 [x] 里的列位置（见 featureNames 顺序）。
const _xRsi14 = 0, _xPctChange = 6, _xVolumeRatio = 7, _xAmountRatio = 8;
const _xClosePos = 9, _xBias20 = 10;

/// 给每个样本追加"当天截面百分位"（0~1）。
///
/// 为什么这是关键缺口：现有 26 个特征全是**绝对的时间序列值**——RSI 15 就是 15。
/// 但"今天 RSI=15"在全市场崩盘那天和风平浪静那天完全是两回事，绝对特征
/// 表达不了"相对今天别的股票有多极端"。而 excess 标签（跑赢当天中位数）
/// 问的恰恰是相对问题。所以第 1 条（改标签）如果没有截面特征配套，
/// 就是让模型去学一个它看不见的目标。
void _addCrossSectionalRanks(Map<String, List<_S>> byDay) {
  for (final rows in byDay.values) {
    if (rows.length < 2) {
      for (final r in rows) {
        r.rank = const [0.5, 0.5, 0.5, 0.5, 0.5, 0.5];
      }
      continue;
    }
    final cols = [_xRsi14, _xVolumeRatio, _xClosePos, _xBias20, _xPctChange, _xAmountRatio];
    final sorted = <int, List<double>>{};
    for (final c in cols) {
      final v = [for (final r in rows) r.x[c]]..sort();
      sorted[c] = v;
    }
    for (final r in rows) {
      r.rank = [
        for (final c in cols) _percentileOf(sorted[c]!, r.x[c]),
      ];
    }
  }
}

/// v 在已排序数组中的百分位（0~1）。用二分，O(log n)。
double _percentileOf(List<double> sorted, double v) {
  var lo = 0, hi = sorted.length;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (sorted[mid] < v) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo / sorted.length;
}

/// 每日 top-k：按天分组、当天内按分排序取前 k 只，求这些"真的会去看"的票的
/// 平均收益与胜率，并与**当天全体**（= 不看排序、全买）对比。
///
/// 为什么不是十分位：2026-09-30 那天主规则只选出 1 只，用户实际看的就是前几名。
/// 十分位价差把 3800 只里的前 380 只算进去，严重高估用户体感。
void _topKByDay(List<_S> xs, double Function(_S) score, double Function(_S) ret) {
  final byDay = <String, List<_S>>{};
  for (final s in xs) {
    byDay.putIfAbsent(s.day, () => []).add(s);
  }
  for (final k in const [3, 5, 10, 20]) {
    var sumTop = 0.0, sumAll = 0.0, winTop = 0.0;
    var n = 0;
    for (final day in byDay.values) {
      if (day.length < k) continue;
      final s = [...day]..sort((a, b) => score(b).compareTo(score(a)));
      final top = s.take(k).map(ret);
      sumTop += top.reduce((x, v) => x + v) / k;
      sumAll += _mean([for (final e in day) ret(e)]);
      winTop += top.where((r) => r > 0).length / k;
      n++;
    }
    if (n == 0) continue;
    print('   每日 top$k（$n 天）：均收益 ${(sumTop / n).toStringAsFixed(2)}% · '
        '胜率 ${(winTop / n * 100).toStringAsFixed(1)}% · '
        'vs 当天全体 ${(sumAll / n).toStringAsFixed(2)}%');
  }
}

int _yBin(_S s) => s.y;
int _yEx(_S s) => s.yEx;

// ── 统计小工具 ──────────────────────────────────────────────

void _concentration(List<_S> all) {
  final perDay = <String, int>{};
  for (final s in all) {
    perDay[s.day] = (perDay[s.day] ?? 0) + 1;
  }
  final counts = [for (final d in perDay.values) d]..sort();
  final top10 = counts.reversed.take(10).fold(0, (a, b) => a + b);
  print('有信号的天数 $perDay.length；每天信号数：中位 ${counts[counts.length ~/ 2]} · '
      'p90 ${counts[(counts.length * 0.9).floor()]} · 最多 $counts.last');
  print('最重的 10 天占全部样本 ${(top10 / all.length * 100).toStringAsFixed(1)}% '
      '→ 独立观测数≈$perDay.length 天，不是 $all.length 个样本');
}

void _labelStats(String name, List<_S> train, List<_S> hold, int Function(_S) y) {
  double rate(List<_S> xs) =>
      xs.isEmpty ? 0 : xs.where((e) => y(e) == 1).length / xs.length * 100;
  print('$name 正例率：训练 ${rate(train).toStringAsFixed(1)}% · '
      'holdout ${rate(hold).toStringAsFixed(1)}%');
}

void _compare(
  String label,
  List<_S> hold,
  int Function(_S) y,
  double Function(_S) b,
  double Function(_S) a, {
  required int rounds,
}) {
  final ys = [for (final s in hold) y(s)];
  final ab = _aucFast([for (final s in hold) b(s)], ys);
  final aa = _aucFast([for (final s in hold) a(s)], ys);
  final ciB = _bootstrapByDay(hold, b, y, rounds);
  final ciDelta = _bootstrapDelta(hold, b, a, y, rounds);
  print('$label：AUC(B)=${ab?.toStringAsFixed(4)} CI=[${ciB.$1.toStringAsFixed(4)}, ${ciB.$2.toStringAsFixed(4)}]'
      ' · AUC(A)=${aa?.toStringAsFixed(4)}'
      ' · ΔCI=[${ciDelta.$1.toStringAsFixed(4)}, ${ciDelta.$2.toStringAsFixed(4)}]'
      '${ciDelta.$1 <= 0 && ciDelta.$2 >= 0 ? '  ← 含 0，不显著' : '  ← 不含 0'}');
}

/// 按天聚类的 bootstrap：重抽单位是交易日，保留当日全部样本。
(double, double) _bootstrapByDay(
  List<_S> xs,
  double Function(_S) score,
  int Function(_S) y,
  int rounds,
) {
  final byDay = <String, List<_S>>{};
  for (final s in xs) {
    byDay.putIfAbsent(s.day, () => []).add(s);
  }
  final days = byDay.keys.toList()..sort();
  final rnd = math.Random(20261006);
  final out = <double>[];
  for (var r = 0; r < rounds; r++) {
    final picked = <_S>[];
    for (var i = 0; i < days.length; i++) {
      picked.addAll(byDay[days[rnd.nextInt(days.length)]]!);
    }
    final a = _aucFast([for (final s in picked) score(s)], [for (final s in picked) y(s)]);
    if (a != null) out.add(a);
  }
  out.sort();
  return (out[(out.length * 0.025).floor()], out[(out.length * 0.975).floor()]);
}

(double, double) _bootstrapDelta(
  List<_S> xs,
  double Function(_S) b,
  double Function(_S) a,
  int Function(_S) y,
  int rounds,
) {
  final byDay = <String, List<_S>>{};
  for (final s in xs) {
    byDay.putIfAbsent(s.day, () => []).add(s);
  }
  final days = byDay.keys.toList()..sort();
  final rnd = math.Random(20261006);
  final out = <double>[];
  for (var r = 0; r < rounds; r++) {
    final picked = <_S>[];
    for (var i = 0; i < days.length; i++) {
      picked.addAll(byDay[days[rnd.nextInt(days.length)]]!);
    }
    final ys = [for (final s in picked) y(s)];
    final ab = _aucFast([for (final s in picked) b(s)], ys);
    final aa = _aucFast([for (final s in picked) a(s)], ys);
    if (ab != null && aa != null) out.add(ab - aa);
  }
  out.sort();
  return (out[(out.length * 0.025).floor()], out[(out.length * 0.975).floor()]);
}

/// 秩口径 AUC（同分取平均秩），O(n log n)。
/// core 的 `auc()` 是 O(n_pos×n_neg)，bootstrap 里跑不起，这里另写一份。
double? _aucFast(List<double> scores, List<int> labels) {
  if (scores.length != labels.length) throw ArgumentError('长度不一致');
  final idx = List<int>.generate(scores.length, (i) => i)
    ..sort((a, b) => scores[a].compareTo(scores[b]));
  var rankSumPos = 0.0;
  var nPos = 0;
  var i = 0;
  while (i < idx.length) {
    var j = i;
    while (j < idx.length && scores[idx[j]] == scores[idx[i]]) {
      j++;
    }
    // 并列块的平均秩（1 起）
    final avgRank = (i + j + 1) / 2;
    for (var k = i; k < j; k++) {
      if (labels[idx[k]] == 1) {
        rankSumPos += avgRank;
        nPos++;
      }
    }
    i = j;
  }
  final nNeg = labels.length - nPos;
  if (nPos == 0 || nNeg == 0) return null;
  return (rankSumPos - nPos * (nPos + 1) / 2) / (nPos * nNeg);
}

/// 按预测分排序分组后，最高一档与最低一档的平均**收益**差（pp）。
double _deciles(List<_S> xs, double Function(_S) score, double Function(_S) ret) {
  final s = [...xs]..sort((a, b) => score(b).compareTo(score(a)));
  final k = s.length ~/ 10;
  if (k == 0) return 0;
  final top = [for (final e in s.take(k)) ret(e)];
  final bottom = [for (final e in s.reversed.take(k)) ret(e)];
  return _mean(top) - _mean(bottom);
}

double _topMean(List<_S> xs, double Function(_S) score, double Function(_S) ret) {
  final s = [...xs]..sort((a, b) => score(b).compareTo(score(a)));
  final k = math.max(1, s.length ~/ 10);
  return _mean([for (final e in s.take(k)) ret(e)]);
}

double _mean(List<double> xs) => xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

double _median(List<double> xs) {
  final s = [...xs]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

List<_S> _subsample(List<_S> xs, int cap) {
  if (xs.length <= cap) return xs;
  final step = xs.length / cap;
  return [for (var i = 0; i < cap; i++) xs[(i * step).floor()]];
}

LogRegModel? _loadModel(String dbPath) {
  final f = File('${_parent(dbPath)}/score-model.json');
  if (!f.existsSync()) return null;
  final m = LogRegModel.fromJsonString(f.readAsStringSync());
  if (m != null && m.featureCount != featureNames.length) return null;
  return m;
}

String _parent(String p) => p.substring(0, p.lastIndexOf('/'));

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';
