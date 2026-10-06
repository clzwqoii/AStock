///  sanity check：直接（不经位掩码）统计两两规则的重叠天数，排除 sweep_pairs 的掩码 bug。
/// 用法: dart run tool/check_overlap.dart
library;

// ignore_for_file: avoid_print

import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

Future<void> main(List<String> args) async {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();
  final rules = builtInRules;
  final n = rules.length;
  final cnt = List<int>.filled(n, 0);
  final pair = List<int>.filled(n * n, 0);
  var days = 0;

  for (final s in stocks) {
    final b = s.bars;
    if (b.length < IndicatorSnapshot.minBars + 20) continue;
    final series = IndicatorSeries.from(b);
    final last = b.length - 1 - 20;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      final snap = series.at(t);
      final hit = <int>[];
      for (var i = 0; i < n; i++) {
        if (rules[i].test(snap)) {
          hit.add(i);
          cnt[i]++;
        }
      }
      days++;
      for (final i in hit) {
        for (final j in hit) {
          pair[i * n + j]++;
        }
      }
    }
  }

  print('可评估日 $days');
  for (var i = 0; i < n; i++) {
    print('  ${rules[i].name.padRight(22)} 触发 ${cnt[i]} 天');
  }
  print('');
  final iRsi = rules.indexWhere((r) => r.id == 'rsi_oversold');
  final iAbove60 = rules.indexWhere((r) => r.id == 'close_above_ma60');
  final iBull = rules.indexWhere((r) => r.id == 'ma60_breakout_bull');
  print('直接统计：RSI超卖 ${cnt[iRsi]} · 收盘价站上MA60 ${cnt[iAbove60]} · '
      '两者同时 ${pair[iRsi * n + iAbove60]}');
  print('直接统计：RSI超卖 ${cnt[iRsi]} · MA60上穿·多头排列 ${cnt[iBull]} · '
      '两者同时 ${pair[iRsi * n + iBull]}');
  // 顺带看 RSI 的分布，确认不是 RSI 恒高
  var lo = 0, mid = 0, hi = 0;
  for (final s in stocks) {
    final b = s.bars;
    if (b.length < IndicatorSnapshot.minBars + 20) continue;
    final series = IndicatorSeries.from(b);
    final last = b.length - 1 - 20;
    for (var t = IndicatorSnapshot.minBars; t <= last; t++) {
      final r = series.at(t).rsi14;
      if (r < 30) {
        lo++;
      } else if (r < 70) {
        mid++;
      } else {
        hi++;
      }
    }
  }
  print('RSI 分布：<30 $lo · 30~70 $mid · >70 $hi');
}
