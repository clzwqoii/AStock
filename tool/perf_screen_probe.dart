/// 一次性性能探针：分阶段计时 runScreening 的各环节，并逐条内置规则实测筛选耗时。
/// 用法：dart run tool/perf_screen_probe.dart [dbPath] [--depth N]
/// --depth N：每只股票只保留末尾 N 根（模拟安卓端浅历史），不带则用全量。
library;

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/core/screener.dart';
import 'package:stock/data/bar_repository.dart';

void main(List<String> args) {
  var dbPath = AppConfig.load().dbPath;
  int? depth;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--depth') {
      depth = int.parse(args[i + 1]);
      i++; // 值已消费，下一轮跳过
    } else if (!args[i].startsWith('--')) {
      dbPath = args[i];
    }
  }

  final repo = BarRepository(dbPath);
  try {
    var t = Stopwatch()..start();
    final all = repo.loadAllStocks(excludeSpecialStocks: true);
    final loadMs = t.elapsedMilliseconds;
    t.reset();
    final names = repo.stockNames();
    final namesMs = t.elapsedMilliseconds;
    stdout.writeln('loadAllStocks: ${all.length} 只, ${loadMs}ms');
    stdout.writeln('stockNames: ${names.length} 条, ${namesMs}ms');

    var stocks = all;
    if (depth != null) {
      stocks = [
        for (final s in all)
          StockData(
              symbol: s.symbol,
              bars: s.bars.length > depth
                  ? s.bars.sublist(s.bars.length - depth)
                  : s.bars),
      ];
      stdout.writeln('已截断到末尾 $depth 根（模拟安卓深度）');
    }

    // 基线：护栏成本（不含规则）——单独跑一条恒假规则即可近似。
    final alwaysFalse = Rule(
        id: '__probe_false', name: 'probe', desc: '', test: (_) => false);
    var sw = Stopwatch()..start();
    final base = screenDiagnostics(stocks, [alwaysFalse]);
    final baselineMs = sw.elapsedMilliseconds;
    stdout.writeln('筛选基线（恒假规则，护栏+快照成本）: ${baselineMs}ms'
        '（stale=${base.blockedStale} ca=${base.blockedCorporateAction}'
        ' susp=${base.blockedSuspension}）');

    // 快照构建单独计时：全池每只一次。
    sw.reset();
    var snapCount = 0;
    for (final s in stocks) {
      if (s.bars.length < 20) continue;
      // ignore: unused_local_variable
      final snap = IndicatorSnapshot.fromStock(s);
      snapCount++;
    }
    stdout.writeln('全池 IndicatorSnapshot 构建 ×$snapCount: ${sw.elapsedMilliseconds}ms');

    // 逐规则计时：跑两轮，报第二轮（排除 JIT 预热）。
    stdout.writeln('--- 逐规则筛选耗时（单规则 × 全池，第二轮）---');
    final rows = <({String id, int ms1, int ms2, int hits})>[];
    for (final r in builtInRules) {
      sw.reset();
      final h1 = screenDiagnostics(stocks, [r]).hits.length;
      final ms1 = sw.elapsedMilliseconds;
      sw.reset();
      final hits = screenDiagnostics(stocks, [r]).hits.length;
      assert(hits == h1);
      rows.add((id: r.id, ms1: ms1, ms2: sw.elapsedMilliseconds, hits: hits));
    }
    rows.sort((a, b) => b.ms2.compareTo(a.ms2));
    for (final row in rows) {
      stdout.writeln('${row.id.padRight(28)}'
          ' 首轮 ${row.ms1.toString().padLeft(5)}ms'
          ' 次轮 ${row.ms2.toString().padLeft(5)}ms'
          '  命中 ${row.hits}');
    }
  } finally {
    repo.close();
  }
}
