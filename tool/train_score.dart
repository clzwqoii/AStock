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
import 'package:stock/core/score.dart';
import 'package:stock/core/rules.dart';
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

  var scanned = 0;
  for (final stock in stocks) {
    final bars = stock.bars;
    if (bars.length < IndicatorSnapshot.minBars + _horizon) continue;
    final series = IndicatorSeries.from(bars);
    final sinceGap = barsSinceCorporateAction(stock.symbol, bars);
    final last = bars.length - 1 - _horizon;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      if (sinceGap[t] < kCorporateActionLookbackBars) continue; // 除权污染日
      scanned++;
      final snap = series.at(t);
      final ids = [for (final r in builtInRules) if (r.test(snap)) r.id];
      if (ids.isEmpty) continue; // 只训"会被选股选出来"的日子
      final x = featureVector(snap, hitRuleIds: ids);
      final y = (bars[t + _horizon].close / bars[t].close - 1) > 0 ? 1 : 0;
      final year = bars[t].date.year;
      if (_trainYears.contains(year)) {
        trainX.add(x);
        trainY.add(y);
        trainIds.add(ids);
      } else if (year == _holdoutYear) {
        holdX.add(x);
        holdY.add(y);
        holdIds.add(ids);
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
  print('');
  print('══ 判定 ════════════════════════════════════════');
  if (bAuc == null || aAuc == null) {
    print('样本不足，无法判定——保持方案 A。');
    exit(0);
  }
  final delta = bAuc - aAuc;
  print('AUC 差（B − A）= ${(delta >= 0 ? "+" : "")}${delta.toStringAsFixed(4)}');
  if (delta < 0.01) {
    print('结论：**不值得替换**。连续特征相对"命中规则的加权胜率"几乎没有');
    print('增量信息（AUC 差 < 0.01）。继续用方案 A，把模型从仓库删掉，');
    print('别为一个不带来增量的模型多背一份月度重训负担。');
    exit(0);
  }
  print('结论：方案 B 在 holdout 上 AUC 高出 ${delta.toStringAsFixed(4)}，达到替换线。');
  if (bAuc < 0.58) {
    print('但绝对水平仍低（< 0.58，接近随机）。**建议上线排序、不要当概率展示**。');
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
