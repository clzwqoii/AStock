/// 命令行选股：用本地库跑规则引擎。
/// 用法: dart run bin/screen.dart <规则id...>   （多个规则 = 组合 AND）
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/screener.dart';
import 'package:stock/data/bar_repository.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run bin/screen.dart <规则id...>（多个规则 = 组合选股）');
    print('可用规则:');
    for (final r in builtInRules) {
      print('  ${r.id.padRight(18)} ${r.name}');
    }
    return;
  }
  final repo = BarRepository(AppConfig.load().dbPath);
  try {
    final stocks = repo.loadAllStocks(excludeSpecialStocks: true);
    final rules = [for (final id in args) ruleById(id)];
    final picked = screen(stocks, rules);
    print('股票总数: ${stocks.length}（按规则 ${args.join(' + ')} 筛选，已剔除 ST/退市/科创板）');
    print('入选 ${picked.length} 只:');
    for (final s in picked.take(30)) {
      print('  ${s.symbol.padRight(10)} 收盘 ${s.last.close}');
    }
    if (picked.length > 30) print('  ...（共 ${picked.length} 只）');
  } on ArgumentError catch (e) {
    stderr.writeln('${e.message}');
    exitCode = 1;
  } finally {
    repo.close();
  }
}
