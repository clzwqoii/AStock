/// 命令行选股：用本地库跑规则引擎。
/// 用法: dart run bin/screen.dart <规则id...>   （多个规则 = 组合 AND）
///
/// 数据卫生护栏默认开启，与 App 内选股同一口径：
/// - 末根滞后池内最大交易日 30 天以上的票（停牌/退市的化石序列）出池；
/// - 信号日落在除权/复牌后 20 根内的不出信号（库内是不复权价，
///   除权日的价位断层会把指标砸成假超卖）。
/// `--raw` 关掉两个护栏，用于复现护栏上线前的口径做对照。
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/screener.dart';
import 'package:stock/data/bar_repository.dart';

Future<void> main(List<String> args) async {
  final ids = <String>[];
  var raw = false;
  for (final a in args) {
    if (a == '--raw') {
      raw = true;
    } else {
      ids.add(a);
    }
  }
  if (ids.isEmpty) {
    print('用法: dart run bin/screen.dart <规则id...>（多个规则 = 组合选股）');
    print('可用规则:');
    for (final r in builtInRules) {
      print('  ${r.id.padRight(18)} ${r.name}');
    }
    print('  --raw             关掉数据卫生护栏（复现护栏上线前的口径）');
    return;
  }
  final repo = BarRepository(AppConfig.load().dbPath);
  try {
    final stocks = repo.loadAllStocks(excludeSpecialStocks: true);
    final rules = [for (final id in ids) ruleById(id)];
    final screened = raw
        ? screenDiagnostics(
            stocks,
            rules,
            maxLastBarLagDays: 0,
            corporateActionLookbackBars: 0,
            suspensionLookbackBars: 0,
          )
        : screenDiagnostics(stocks, rules);
    final picked = [for (final h in screened.hits) h.stock];
    print('股票总数: ${stocks.length}（按规则 ${ids.join(' + ')} 筛选，已剔除 ST/退市/科创板）');
    if (raw) {
      print('⚠ --raw：已关掉新鲜度、除权与停牌护栏，结果含停牌/退市化石票、除权日假信号及停牌复牌失真信号');
    } else {
      final blocked = screened.blockedStale +
          screened.blockedCorporateAction +
          screened.blockedSuspension;
      if (blocked == 0) {
        print('护栏：未挡掉任何本会入选的信号');
      } else {
        print('护栏：挡掉 $blocked 只本会入选的假信号'
            '（停牌/退市化石票 ${screened.blockedStale} + '
            '除权/复牌日 ${screened.blockedCorporateAction} + '
            '停牌复牌污染 ${screened.blockedSuspension}）');
      }
    }
    print('入选 ${picked.length} 只:');
    for (final s in picked.take(30)) {
      final bars = s.bars;
      final ret20 = bars.length > 21
          ? (bars.last.close / bars[bars.length - 21].close - 1) * 100
          : 0.0;
      print('  ${s.symbol.padRight(10)} 收盘 ${s.last.close}  '
          '信号日 ${bars.last.date.toIso8601String().substring(0, 10)}  '
          '近20日 ${ret20.toStringAsFixed(1)}%');
    }
    if (picked.length > 30) print('  ...（共 ${picked.length} 只）');
  } on ArgumentError catch (e) {
    stderr.writeln('${e.message}');
    exitCode = 1;
  } finally {
    repo.close();
  }
}
