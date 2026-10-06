/// 规则命中诊断：对本地库跑「60 日线有效突破」两条规则，打印命中数与逐条件淘汰漏斗。
///
/// 用法：`dart run tool/diag_breakout.dart [db路径]`
/// 用途：上线后按实际命中数决定阈值是收紧还是放宽（阈值常量集中在 lib/core/rules.dart）。
/// 漏斗直接用 rules.dart 导出的 explain 函数——与规则本体同一份判定，改阈值不会分叉。
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();
  if (stocks.isEmpty) {
    print('数据库为空（0 只股票），先跑 dart run bin/sync.dart 同步数据');
    return;
  }

  for (final mode in const ['confirmed', 'pullback']) {
    final funnel = <String, int>{};
    var pass = 0, skipped = 0;
    final hits = <String>[];

    for (final s in stocks) {
      if (s.bars.length < IndicatorSnapshot.minBars) {
        skipped++;
        continue;
      }
      final snap = IndicatorSnapshot.fromStock(s);
      final reason = mode == 'confirmed'
          ? explainMa60BreakoutConfirmed(snap, standDays: kBreakoutStandDays)
          : explainMa60BreakoutPullback(snap);
      if (reason == null) {
        pass++;
        if (hits.length < 20) hits.add(s.symbol);
      } else {
        funnel[reason] = (funnel[reason] ?? 0) + 1;
      }
    }

    final label = mode == 'confirmed' ? 'ma60_breakout_confirmed' : 'ma60_breakout_pullback';
    stdout.writeln('── $label ──');
    stdout.writeln('股票 ${stocks.length}（历史不足20根跳过 $skipped）→ 命中 $pass');
    if (hits.isNotEmpty) stdout.writeln('   ${hits.join(' ')}');
    final sorted = funnel.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      stdout.writeln('   ${e.value.toString().padLeft(5)}  淘汰于 ${e.key}');
    }
  }
  exit(0);
}
