/// 查看回测报告的月度台账：每条规则的胜率随数据截止日怎么变。
///
/// 用途：现在所有结论都是样本内的，唯一的验证手段是持续记录、隔段时间重跑、
/// 看胜率有没有漂移。`tool/report_all.dart --archive` 每次重跑都会追加一期。
///
/// 用法: dart run tool/report_history.dart [台账路径]
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:stock/core/backtest.dart';

void main(List<String> args) {
  // 台账路径默认与报告同目录
  final path = args.isNotEmpty ? args[0] : _defaultHistory();
  final f = File(path);
  if (!f.existsSync()) {
    print('还没有台账：$path');
    print('先跑一次 dart run tool/report_all.dart --archive');
    return;
  }
  final h = BacktestHistory.fromJson(
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
  if (h.isEmpty) {
    print('台账是空的');
    return;
  }

  print('台账：$path');
  print('共 ${h.snapshots.length} 期');
  for (final s in h.snapshots) {
    print('  ${s.dataDate}  生成于 ${s.generatedAt}  '
        '股票 ${s.stockCount}  样本 ${s.evaluableDays}  规则 ${s.ruleWinRate.length} 条');
  }

  final comparable = h.comparableRuleIds();
  if (comparable.isEmpty) {
    print('');
    print('还没有任何规则出现两次以上——至少 archive 两期才能看漂移。');
    return;
  }

  print('');
  print('══ 胜率随数据截止日的变化（10 日）══');
  final header = ['规则'.padRight(24)] +
      [for (final s in h.snapshots) s.dataDate.padLeft(10)];
  print('  ${header.join('')}');
  for (final id in comparable) {
    final cells = <String>[];
    for (final s in h.snapshots) {
      final w = s.ruleWinRate[id];
      cells.add(w == null ? '—'.padLeft(10) : '${(w * 100).toStringAsFixed(1)}%'.padLeft(10));
    }
    print('  ${id.padRight(24)}${cells.join('')}');
  }

  print('');
  print('══ 首末两期的变化 ══');
  final first = h.snapshots.first;
  final last = h.snapshots.last;
  for (final id in comparable) {
    final a = first.ruleWinRate[id];
    final b = last.ruleWinRate[id];
    if (a == null || b == null) continue;
    final d = (b - a) * 100;
    print('  ${id.padRight(24)} ${(a * 100).toStringAsFixed(1).padLeft(5)}% → '
        '${(b * 100).toStringAsFixed(1).padLeft(5)}%  '
        '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)}pp');
  }
}

String _defaultHistory() {
  final home = Platform.environment['HOME'] ?? '.';
  return '$home/.stock/backtest-history.json';
}
