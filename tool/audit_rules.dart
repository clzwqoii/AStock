/// 规则体检表：把每条规则的全样本数字拆开，暴露被单月行情绑架的数字。
///
/// ## 这个工具为什么存在
///
/// UI 上规则名下那行（`10日 80.3% · PF 9.92 · 13535信号`）只取全样本合并值，
/// 不带基准、不分年、不看信号集中度。实测 `rsi_oversold_volume_loose`：
/// 全样本 PF 9.92，但 2026 年只有 1.58，而且 46.8% 的信号挤在 2024-02 单月——
/// 那行数字完全不能代表现在还能不能用。
///
/// 所以这里不改 UI，先出一张体检表，让判断有依据。判据一律复用
/// `lib/core/backtest.dart` 已有的口径（`isRuleYearlyRobust` 的跨年跑赢基准、
/// `RuleProfile.topMonthShare` 的集中度），不另立标准。
///
/// 用法: dart run tool/audit_rules.dart [--report 路径] [--horizon 10]
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:stock/app_logic.dart' show loadBacktestReport;
import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';

/// 某一年要至少这么多信号，"这一年的超额收益"才算数。
/// 太少时一两个极端值就能把均收益拉飞（项目既有教训：几百以下别当结论）。
const kMinSamplesPerYear = 500;

void main(List<String> args) {
  var reportPath = '${AppConfig.load().dbPath.substring(0, AppConfig.load().dbPath.lastIndexOf('/'))}'
      '/stock-backtest-report.json';
  var horizon = 10;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--report':
        reportPath = args[++i];
      case '--horizon':
        horizon = int.parse(args[++i]);
      default:
        throw ArgumentError('未知参数 ${args[i]}');
    }
  }

  final report = loadBacktestReport('', reportPath: reportPath);
  if (report == null) {
    stderr.writeln('读不到回测报告：$reportPath');
    exit(1);
  }

  final base = report.baseline[horizon];
  print('报告：$reportPath');
  print('样本 ${report.stockCount} 只 · 口径 $horizon日 · 生成于 ${report.generatedAt}');
  print('');
  if (base == null) {
    stderr.writeln('报告里没有 $horizon日 基准');
    exit(1);
  }
  print('无条件基准：胜率 ${pct(base.winRate)} · PF ${base.profitFactor.toStringAsFixed(2)}'
      ' · 均收益 ${base.avgReturn.toStringAsFixed(2)}% · 样本 ${base.count}');
  print('');

  final years = report.yearly.keys.toList()..sort();
  print('—' * 118);
  _head(horizon, years);
  print('—' * 118);

  final rows = <List<String>>[];
  var flagged = 0;
  for (final rule in builtInRules) {
    final all = report.result(rule.id, horizon);
    if (all == null || all.count == 0) continue;
    final yearly = <int, BacktestStats>{};
    for (final y in years) {
      final st = report.yearly[y]?[rule.id]?[horizon];
      final b = report.yearlyBaseline[y]?[horizon];
      if (st == null || b == null || st.count == 0) continue;
      yearly[y] = st;
    }
    final latestYear = yearly.keys.isEmpty ? null : yearly.keys.reduce(math.max);
    final latest = latestYear == null ? null : yearly[latestYear];
    final latestBase = latestYear == null ? null : report.yearlyBaseline[latestYear]?[horizon];
    final profile = report.signalProfile[rule.id]?[horizon] ?? RuleProfile.empty;

    // 判定口径：**均收益超额**，不是胜率。
    //
    // 为什么不用胜率：2026 年基准均收益 −0.41%（熊市），这时"胜率低于基准"
    // 经常只是"赢小钱、输小钱"，期望仍为正。实测 rsi_oversold 2026 年胜率
    // 43.5% < 基准 44.3%，但均收益 +0.07% > 基准 −0.41%——按胜率判它是失效，
    // 按超额收益判它仍然可用。所以下面每个年份都同时算两个口径，
    // 告警只由超额收益驱动，胜率仅作参考列展示。
    var yearsBeatenByReturn = 0, yearsBeatenByWin = 0, yearsWithEdge = 0;
    final yearDetail = <String>[];
    for (final e in yearly.entries) {
      final b = report.yearlyBaseline[e.key]?[horizon];
      if (b == null || b.count == 0) continue;
      final byReturn = e.value.avgReturn > b.avgReturn;
      final byWin = e.value.winRate > b.winRate;
      if (byReturn) yearsBeatenByReturn++;
      if (byWin) yearsBeatenByWin++;
      // 有超额收益、且不是靠极少数样本撑起来的，才算"这一站得住"。
      if (byReturn && e.value.count >= kMinSamplesPerYear) yearsWithEdge++;
      yearDetail.add('${e.key}:${_signedPct(e.value.avgReturn - b.avgReturn)}');
    }

    final notes = <String>[];
    if (profile.topMonthShare >= 0.35 && profile.signalCount >= kRuleTopMonthShareMinSignals) {
      notes.add('信号集中 ${(profile.topMonthShare * 100).toStringAsFixed(0)}%/单月');
    }
    if (latest != null && latestBase != null && latestBase.count > 0) {
      final excess = latest.avgReturn - latestBase.avgReturn;
      if (excess <= 0) {
        notes.add('$latestYear年超额${_signedPct(excess, suffix: 'pp')}');
      }
    }
    if (all.count < 500) notes.add('样本仅 ${all.count}');
    if (yearsWithEdge == 0 && yearly.isNotEmpty) notes.add('无一年有正超额');
    if (notes.isNotEmpty) flagged++;

    rows.add([
      rule.id,
      rule.name,
      (latest == null ? '—' : latest.avgReturn.toStringAsFixed(2)),
      latestBase == null ? '—' : latestBase.avgReturn.toStringAsFixed(2),
      latest == null || latestBase == null ? '—' : _signedPct(latest.avgReturn - latestBase.avgReturn),
      latest == null ? '—' : latest.profitFactor.toStringAsFixed(2),
      latest == null ? '—' : pct(latest.winRate),
      latestBase == null ? '—' : pct(latestBase.winRate),
      all.avgReturn.toStringAsFixed(2),
      '$yearsWithEdge/${yearly.length}',
      '$yearsBeatenByReturn/${yearly.length}',
      '$yearsBeatenByWin/${yearly.length}',
      '${profile.topMonthShare * 100 ~/ 1}%',
      yearDetail.join(' '),
      notes.isEmpty ? 'OK' : notes.join(' / '),
    ]);
  }

  // 最差的排前面：告警多的先看；同样有告警时，最近年超额低的排前面。
  rows.sort((a, b) {
    final c = b.last.compareTo(a.last);
    return c != 0 ? c : a[4].compareTo(b[4]);
  });
  for (final r in rows) {
    var line = '${r[0].padRight(26)}${r[1].padRight(16)}';
    line += '${r[2].padRight(8)}${r[3].padRight(8)}${r[4].padRight(9)}'
        '${r[5].padRight(8)}${r[6].padRight(8)}${r[7].padRight(8)}';
    line += '${r[8].padRight(8)}${r[9].padRight(6)}${r[10].padRight(6)}'
        '${r[11].padRight(6)}${r[12].padRight(6)}';
    line += '\n${' ' * 42}分年超额：${r[13]}';
    line += '\n${' ' * 42}→ ${r[14]}';
    print(line);
  }
  print('—' * 118);
  print('');
  print('共 ${rows.length} 条规则，其中 $flagged 条有告警。');
  print('');
  print('读法（判定口径 = 均收益超额，不是胜率）：');
  print('  · 「${years.last}收益/基准/超额」= 最近一年与同期随机买入的对比，'
      '这是唯一回答"现在还能不能用"的三个数。');
  print('  · 「有超额年数」= 有几个年份均收益跑赢基准（每年样本 ≥$kMinSamplesPerYear 才算）。');
  print('  · 「胜率年数」仅作参考：熊市里"赢小钱输小钱"会让胜率低于基准而期望仍为正，'
      '所以它不参与判定。');
  print('  · 「集中」= 最大单月信号占比，≥35% 且样本 ≥$kRuleTopMonthShareMinSignals '
      '说明数字主要来自一段行情。');
  print('  · 「OK」= 近一年有正超额 + 至少一年站得住 + 信号不过度集中 + 全样本 ≥500。');
}

void _head(int horizon, List<int> years) {
  final latest = years.isEmpty ? '—' : '${years.last}年';
  print('${'规则 id'.padRight(26)}${'名称'.padRight(16)}'
      '${'$latest收益'.padRight(8)}${'基准'.padRight(8)}${'超额'.padRight(9)}'
      '${'${latest}PF'.padRight(8)}${'$latest胜率'.padRight(8)}${'基准胜率'.padRight(8)}'
      '${'全收益'.padRight(8)}${'超额年'.padRight(6)}${'收益年'.padRight(6)}'
      "${'胜率年'.padRight(6)}${'集中'.padRight(6)}");
}

String pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

/// 带符号的百分点差（均收益之差，单位 pp）。
String _signedPct(double v, {String suffix = 'pp'}) =>
    '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}$suffix';
