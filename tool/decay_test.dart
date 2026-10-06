/// 衰减曲线的统计检验：超额逐年下滑到底是趋势还是小样本噪声？
///
/// ## 为什么需要这个
///
/// `RSI超卖·放量` 的分年超额是 +41.8 / +25.8 / +9.7pp，看着一路下滑。
/// 但 2025 年只有 662 个信号、2026 年 516 个，**最后两点的误差棒很大**。
/// 如果 +9.7pp 与 0 不可区分，那结论是"2026 年没信号"而不是"策略衰减"；
/// 处置完全不同（前者要扩参数拿信号，后者该停用）。
///
/// 所以这里逐点做「超额是否显著异于 0」的 z 检验，再做相邻两年
/// 「下滑是否显著」的 z 检验。只报数字不给结论，结论由人下。
///
/// 用法: dart run tool/decay_test.dart [dbPath]
library;

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math' as math;

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';
import 'package:stock/data/report_store.dart';

/// 被检验的规则。
const _ruleIds = ['rsi_oversold_volume', 'rsi_oversold_volume_loose'];

/// 持有期。与 [kScoreHorizon] 对齐。
const _horizon = 10;

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  final dataDate = repo.maxTradeDate();
  repo.close();

  final report = ReportStore(
          '${File(args.isNotEmpty ? args[0] : AppConfig.load().dbPath).parent.path}'
          '/stock-backtest-report.json')
      .load();
  if (report == null) {
    print('没有回测报告，先跑 dart run tool/report_all.dart');
    exit(1);
  }

  for (final id in _ruleIds) {
    _reportRule(report, id);
  }
  print('数据截至 $dataDate；样本 ${stocks.length} 只股票');
  exit(0);
}

void _reportRule(BacktestReport report, String ruleId) {
  final rule = ruleById(ruleId);
  print('');
  print('══ ${rule.name}（$ruleId）· 持有期 $_horizon 日 ══');
  final years = report.yearly.keys.toList()..sort();
  final rows = <({int year, double excess, double se, int n1, int n0})>[];
  for (final y in years) {
    final s = report.yearly[y]![ruleId]![_horizon];
    final b = report.yearlyBaseline[y]![_horizon]!;
    if (s == null || s.count == 0) {
      print('  $y  无信号');
      continue;
    }
    final excess = s.winRate - b.winRate;
    // 两比例之差的SE。基准样本量极大（百万级），但保险起见仍计入。
    final se = math.sqrt(
        s.winRate * (1 - s.winRate) / s.count +
            b.winRate * (1 - b.winRate) / b.count);
    rows.add((year: y, excess: excess, se: se, n1: s.count, n0: b.count));
    final z = se > 0 ? excess / se : 0.0;
    final lo = (excess - 1.96 * se) * 100;
    final hi = (excess + 1.96 * se) * 100;
    print('  $y  ${s.count} 信号（基准 ${b.count} 样本）  '
        '胜率 ${(s.winRate * 100).toStringAsFixed(1)}% vs '
        '${(b.winRate * 100).toStringAsFixed(1)}%  '
        '超额 ${(excess * 100).toStringAsFixed(1)}pp  '
        '95%CI[${lo.toStringAsFixed(1)}, ${hi.toStringAsFixed(1)}]pp  '
        'z=${z.toStringAsFixed(1)}  '
        '${z.abs() > 2 ? (excess > 0 ? "显著跑赢 ✓" : "显著跑输 ✗") : "与基准不可区分"}');
  }

  // 相邻两年下滑是否显著
  for (var i = 1; i < rows.length; i++) {
    final a = rows[i - 1];
    final b = rows[i];
    final drop = (a.excess - b.excess) * 100;
    // 差值方差 = 两方差之和（不同年份样本基本不重叠，近似独立）
    final se = (math.sqrt(a.se * a.se + b.se * b.se)) * 100;
    final z = se > 0 ? drop / se : 0.0;
    print('     ${a.year}→${b.year} 超额下降 ${drop.toStringAsFixed(1)}pp '
        '± ${(1.96 * se).toStringAsFixed(1)}pp，z=${z.toStringAsFixed(1)} '
        '${z.abs() > 2 ? "→ 下滑是真实的" : "→ 下滑在噪声范围内"}');
  }
}
