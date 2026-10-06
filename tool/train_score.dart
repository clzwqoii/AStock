/// 训练「评分方案 B」逻辑回归，并与方案 A 在 holdout 年份上正面对比。
///
/// ## 这个工具存在的唯一目的
///
/// 判断方案 B 值不值得替掉方案 A。**它预设不了结论**：如果 holdout 上
/// 方案 B 的 AUC 不显著高于方案 A，就应该继续用 A，并把这件事写进文档。
/// 早先在 RSI/量能/中枢突破上已经连撞三次"看起来该有效、其实没有增量"。
///
/// ## 切分
///
/// 训练 = 2024 + 2025，holdout = 2026。**按日历年切，不按时间点随机切**：
/// 随机切会让相邻交易日的样本同时出现在训练和测试里，而相邻日子高度
/// 相关（同一段行情），holdout AUC 会虚高。
///
/// ## 样本
///
/// 只取「至少命中一条内置规则」的交易日。评分要排序的就是这批股票，
/// 在全样本上训练会稀释我们真正关心的那部分。
///
/// **与选股/回测同口径加除权护栏**：库内是不复权价，除权后 20 根内的指标
/// 是断层造成的假信号。训练集若还含它们，学到的就是"除权后更容易跌"这种
/// 与策略假设无关的东西（那批样本 10 日胜率 40.6%，低于无条件基准）。
///
/// 用法: dart run tool/train_score.dart [dbPath]
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:stock/config.dart';
import 'package:stock/app_logic.dart' show loadBacktestReport;
import 'package:stock/core/features.dart';
import 'package:stock/core/logreg.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/score.dart';
import 'package:stock/data/bar_repository.dart';

/// 前向收益持有期。与 [kScoreHorizon] 对齐，评分和回测页才对得上。
const _horizon = 10;

/// 训练年份 / holdout 年份。
const _trainYears = {2024, 2025};
const _holdoutYear = 2026;

/// L2 系数（和形式）。样本多时需要一定正则，否则可分子集会过拟合。
const _l2 = 200.0;

/// AUC 评估的样本上限。auc 是 O(n_pos×n_neg)，holdout 有几万正样本时
/// 直接算是几十亿次比较——抽到这个规模后 AUC 估计已稳定到小数点后三位。
const _aucSampleCap = 20000;

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : AppConfig.load().dbPath;
  final repo = BarRepository(dbPath);
  final stocks = repo.loadAllStocks();
  final dataDate = repo.maxTradeDate();
  repo.close();

  final trainX = <List<double>>[];
  final trainY = <int>[];
  final trainIds = <List<String>>[];
  final holdX = <List<double>>[];
  final holdY = <int>[];
  final holdIds = <List<String>>[];
  // 判定门槛要按天聚类，所以必须留住信号日与前瞻收益
  final holdDays = <String>[];
  final holdRet = <double>[];

  // 停牌洞要用全市场交易日历判；日历一次算清（与 screener/backtest 同口径）
  final calendar = tradingCalendar(stocks);
  var scanned = 0;
  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < IndicatorSnapshot.minBars + _horizon) continue;
    final series = IndicatorSeries.from(bars);
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    final gapDays = tradingDaysSincePrevBar(bars, calendar);
    final last = bars.length - 1 - _horizon;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      if (sinceGap[t] < kCorporateActionLookbackBars) continue; // 除权污染日
      if (hasSuspensionGapNearby(gapDays, t)) continue; // 停牌污染日
      scanned++;
      final snap = series.at(t);
      final ids = [for (final r in builtInRules) if (r.test(snap)) r.id];
      if (ids.isEmpty) continue; // 只训"会被选股选出来"的日子
      final x = featureVector(snap, hitRuleIds: ids);
      final ret = (bars[t + _horizon].close / bars[t].close - 1) * 100;
      final y = ret > 0 ? 1 : 0;
      final year = bars[t].date.year;
      if (_trainYears.contains(year)) {
        trainX.add(x);
        trainY.add(y);
        trainIds.add(ids);
      } else if (year == _holdoutYear) {
        holdX.add(x);
        holdY.add(y);
        holdIds.add(ids);
        holdDays.add(_ymd(bars[t].date));
        holdRet.add(ret);
      }
    }
  }

  print('══ 评分方案 B 训练 ══');
  print('数据截至 $dataDate；扫描 $scanned 个可评估日');
  print('训练（${_trainYears.join("+")}）：${trainX.length} 样本，'
      '正例率 ${(_rate(trainY) * 100).toStringAsFixed(1)}%');
  print('holdout（$_holdoutYear）：${holdX.length} 样本，'
      '正例率 ${(_rate(holdY) * 100).toStringAsFixed(1)}%');

  final sw = Stopwatch()..start();
  final model = LogRegModel.train(trainX, trainY, maxIter: 60, l2: _l2);
  sw.stop();
  print('训练耗时 ${sw.elapsedMilliseconds}ms（IRLS）');

  // ── holdout 指标 ──
  final holdScore = model.predictAll(holdX);
  final bAuc = _aucCapped(holdScore, holdY);
  print('');
  print('══ holdout（$_holdoutYear）════════════════════');
  print('方案 B（逻辑回归）  AUC = ${bAuc?.toStringAsFixed(4) ?? "无法计算"}'
      '  logLoss = ${model.logLoss(holdX, holdY).toStringAsFixed(4)}');

  // ── 方案 A：加权胜率（同一批样本、同一个 holdout）──
  final report = loadBacktestReport(dbPath);
  if (report == null) {
    print('⚠ 没有回测报告，无法对比方案 A。先跑 dart run tool/report_all.dart');
    exit(1);
  }
  final aScores = <double>[];
  for (var i = 0; i < holdX.length; i++) {
    aScores.add(scoreOf(report, hitRuleIds: holdIds[i], horizon: _horizon).score);
  }
  final aAuc = _aucCapped(aScores, holdY);
  final aLogLoss = _logLossOf(aScores.map((e) => e / 100).toList(), holdY);
  print('方案 A（加权胜率）  AUC = ${aAuc?.toStringAsFixed(4) ?? "无法计算"}'
      '  logLoss = ${aLogLoss.toStringAsFixed(4)}');

  // ── 校准：把 holdout 按预测概率分箱，看是否"说 80 分真有 80%"──
  print('');
  print('══ 方案 B 校准（holdout）════════════════════════');
  _calibration(holdScore, holdY);

  // ── 判定 ──
  //
  // 门槛从"AUC 差 > 0.01"改成**按天聚类的 bootstrap CI 是否排除 0**。
  // 理由：信号按天高度聚集（实测 holdout 78 万样本只来自 171 个独立交易日），
  // 逐样本算 AUC 差等于把 1 个观测当成几千个用，CI 会窄到失真。本项目在规则层
  // 已经栽过：「+KDJ金叉：+1.8pp 是噪声（z=1.21，se=1.51pp）」。
  print('');
  print('══ 判定 ══════════════════════════════════════════');
  if (bAuc == null || aAuc == null) {
    print('样本不足，无法判定——保持方案 A。');
    exit(0);
  }
  final days = holdDays.toSet().length;
  final delta = bAuc - aAuc;
  final deltaCi = _clusterBootstrapDelta(holdX, holdY, holdDays, aScores, holdScore);
  print('逐样本 AUC 差（B − A）= ${(delta >= 0 ? "+" : "")}${delta.toStringAsFixed(4)}'
      '（仅参考，聚集效应会让它虚高）');
  print('按天聚类 bootstrap（重抽单位=交易日，$days 天，$_bootRounds 轮）：'
      'ΔCI = [${deltaCi.$1.toStringAsFixed(4)}, ${deltaCi.$2.toStringAsFixed(4)}]');
  // 模型在 App 里的真实工作是"在同一条规则选出的几只之间排高低"：
  // 方案 A 对同规则的命中给同一个分，所以这一维完全由方案 B 决定，
  // 而它此前从未被检验过。
  final within = _withinRuleRanking(holdDays, holdIds, holdRet, holdScore);
  if (within != null) {
    print('主规则命中内部排序（按天配对，同一天内比高低）：'
        '高半 ${within.$1.toStringAsFixed(2)}% vs 低半 ${within.$2.toStringAsFixed(2)}% · '
        '差 ${(within.$1 - within.$2).toStringAsFixed(2)}pp · '
        'CI [${within.$3.toStringAsFixed(2)}, ${within.$4.toStringAsFixed(2)}]pp'
        '${within.$3 <= 0 && within.$4 >= 0 ? ' ← 含 0，噪声' : ''}');
  } else {
    print('主规则命中内部排序：样本太少（<20 天有 ≥4 个命中），无法判定');
  }
  if (deltaCi.$1 <= 0) {
    print('结论：**不值得替换**。按天聚类后 AUC 差的下界 ≤ 0，逐样本那点差距是');
    print('聚集效应造出来的假象。继续用方案 A，别为一个没有增量的模型');
    print('每月多背一次重训。');
    exit(0);
  }
  print('结论：按天聚类后 AUC 差的下界 > 0，方案 B 的增量在统计上站得住。');
  if (bAuc < 0.58) {
    print('但绝对水平仍低（< 0.58，接近随机）。**只用于排序，不要当概率展示**；');
    print('0.58 只是参考刻度，不是门槛——门槛是上面那个 CI。');
  }

  // ── 落盘系数 ──
  final path = '${File(dbPath).parent.path}/score-model.json';
  await File(path).writeAsString(jsonEncode({
    'version': 1,
    'trainedAt': DateTime.now().toIso8601String(),
    'trainYears': _trainYears.toList(),
    'holdoutYear': _holdoutYear,
    'horizon': _horizon,
    'l2': _l2,
    'features': featureNames,
    'holdoutAuc': bAuc,
    'holdoutLogLoss': model.logLoss(holdX, holdY),
    'planAAuc': aAuc,
    ...model.toJson(),
  }));
  print('系数已写入 $path');

  // 顺便检查最重要的特征方向是否符合交易假设
  print('');
  print('══ 特征系数（标准化后，正=提高上涨概率）═════════');
  final pairs = <(String, double)>[
    for (var i = 0; i < model.weights.length; i++) (featureNames[i], model.weights[i])
  ]..sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));
  for (final (name, w) in pairs.take(15)) {
    print('  ${name.padRight(28)} ${w >= 0 ? "+" : ""}${w.toStringAsFixed(4)}');
  }
  exit(0);
}

/// bootstrap 轮数。200 轮对 95% 分位数已经够稳。
const _bootRounds = 200;

/// 评估集抽样上限：聚类 bootstrap 每轮要把 AUC 算一遍，秩口径 O(n log n)，
/// 但几十万样本 × 200 轮仍要几分钟。取到 20 万后 AUC 估稳到小数点后三位。
const _evalCap = 200000;

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

/// 按天聚类的 bootstrap：重抽单位是**交易日**（保留当日全部样本），
/// 返回 ΔAUC = AUC(B) − AUC(A) 的 95% CI。
///
/// 为什么不能逐样本重抽：同一天的信号共享同一段行情，不是独立观测。
/// 逐样本重抽会让 CI 窄到失真，把噪声当成提升。
(double, double) _clusterBootstrapDelta(
  List<List<double>> holdX,
  List<int> holdY,
  List<String> holdDays,
  List<double> aScores,
  List<double> bScores,
) {
  final step = holdX.length / _evalCap;
  final idx = [
    for (var i = 0; i < _evalCap && i < holdX.length; i++) (i * step).floor()
  ];
  final byDay = <String, List<int>>{};
  for (final i in idx) {
    byDay.putIfAbsent(holdDays[i], () => []).add(i);
  }
  final days = byDay.keys.toList()..sort();
  if (days.length < 20) {
    // 独立观测太少，CI 没有意义。返回必然"不显著"的区间，让调用方按
    // "不值得替换"处理，而不是拿一个假的窄 CI 去放行。
    return (double.negativeInfinity, double.negativeInfinity);
  }
  final rnd = math.Random(20261006);
  final out = <double>[];
  for (var r = 0; r < _bootRounds; r++) {
    final ys = <int>[], b = <double>[], a = <double>[];
    for (var i = 0; i < days.length; i++) {
      for (final j in byDay[days[rnd.nextInt(days.length)]]!) {
        ys.add(holdY[j]);
        b.add(bScores[j]);
        a.add(aScores[j]);
      }
    }
    final ab = aucByRank(b, ys), aa = aucByRank(a, ys);
    if (ab != null && aa != null) out.add(ab - aa);
  }
  out.sort();
  return (out[(out.length * 0.025).floor()], out[(out.length * 0.975).floor()]);
}

/// 主规则命中内部的排序质量：按天分组、当天内按评分分两半，比较高半与低半的
/// 平均**收益**（不是 AUC——要知道的是"排前面是否真的更能赚"）。
///
/// 返回 (高半均收益, 低半均收益, CI 下界, CI 上界)；样本太少返回 null。
/// 每天只有几只（实测中位 4 只），所以这是 2v2 的对比，噪声极大，
/// 不给 CI 的数字在这里没有解读价值。
(double, double, double, double)? _withinRuleRanking(
  List<String> holdDays,
  List<List<String>> holdIds,
  List<double> holdRet,
  List<double> bScores,
) {
  final byDay = <String, List<int>>{};
  for (var i = 0; i < holdDays.length; i++) {
    if (!holdIds[i].contains(kMainRuleId)) continue;
    byDay.putIfAbsent(holdDays[i], () => []).add(i);
  }
  final days = byDay.values.where((e) => e.length >= 4).toList();
  if (days.length < 20) return null;

  double halfMean(List<int> rows, bool top) {
    final sorted = [...rows]..sort((x, y) => bScores[y].compareTo(bScores[x]));
    final k = sorted.length ~/ 2;
    final pick = top ? sorted.take(k) : sorted.reversed.take(k);
    var sum = 0.0;
    for (final j in pick) {
      sum += holdRet[j];
    }
    return sum / k;
  }

  double paired(bool top) {
    var acc = 0.0;
    for (final rows in days) {
      acc += halfMean(rows, top);
    }
    return acc / days.length;
  }

  final hi = paired(true), lo = paired(false);
  final rnd = math.Random(20261006);
  final diffs = <double>[];
  for (var r = 0; r < _bootRounds; r++) {
    var acc = 0.0;
    for (var i = 0; i < days.length; i++) {
      final rows = days[rnd.nextInt(days.length)];
      acc += halfMean(rows, true) - halfMean(rows, false);
    }
    diffs.add(acc / days.length);
  }
  diffs.sort();
  return (
    hi,
    lo,
    diffs[(diffs.length * 0.025).floor()],
    diffs[(diffs.length * 0.975).floor()],
  );
}

double _rate(List<int> ys) => ys.isEmpty ? 0 : ys.where((e) => e == 1).length / ys.length;

double? _aucCapped(List<double> scores, List<int> labels) {
  if (scores.length != labels.length) {
    throw ArgumentError('scores 与 labels 长度不一致');
  }
  if (scores.length <= _aucSampleCap) return auc(scores, labels);
  // 均匀抽样子集（按秩抽样会破坏分布，这里按固定步长取）
  final step = scores.length / _aucSampleCap;
  final xs = <double>[];
  final ys = <int>[];
  for (var i = 0; i < _aucSampleCap; i++) {
    final j = (i * step).floor();
    xs.add(scores[j]);
    ys.add(labels[j]);
  }
  return auc(xs, ys);
}

double _logLossOf(List<double> ps, List<int> ys) {
  var acc = 0.0;
  for (var i = 0; i < ps.length; i++) {
    final p = ps[i].clamp(1e-12, 1 - 1e-12);
    acc += ys[i] == 1 ? -math.log(p) : -math.log(1 - p);
  }
  return acc / ps.length;
}

/// 按预测概率分十箱，比较"预测均值"与"实际胜率"。
void _calibration(List<double> scores, List<int> ys) {
  final idx = List<int>.generate(scores.length, (i) => i)
    ..sort((a, b) => scores[a].compareTo(scores[b]));
  const bins = 10;
  final per = idx.length ~/ bins;
  print('  ${'预测概率区间'.padRight(18)}${'样本'.padLeft(8)}'
      '${'预测均值'.padLeft(10)}${'实际胜率'.padLeft(10)}');
  for (var b = 0; b < bins; b++) {
    final start = b * per;
    final end = b == bins - 1 ? idx.length : start + per;
    if (end <= start) continue;
    var pSum = 0.0;
    var win = 0;
    for (var i = start; i < end; i++) {
      pSum += scores[idx[i]];
      win += ys[idx[i]];
    }
    final lo = scores[idx[start]];
    final hi = scores[idx[end - 1]];
    print('  ${(lo * 100).toStringAsFixed(0)}%~${(hi * 100).toStringAsFixed(0)}%'
        '${(end - start).toString().padLeft(8)}'
        '${(pSum / (end - start) * 100).toStringAsFixed(1).padLeft(9)}%'
        '${(win / (end - start) * 100).toStringAsFixed(1).padLeft(9)}%');
  }
}
