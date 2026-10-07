/// 一次性探针：ScreeningService 池子复用的端到端收益（两次选股对比）。
library;
import 'dart:io';
import 'package:stock/app_logic.dart';
import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : AppConfig.load().dbPath;
  final svc = ScreeningService();
  for (final ruleId in ['rsi_oversold_volume_loose', 'close_above_ma60', 'pivot_breakout']) {
    final sw = Stopwatch()..start();
    final r = await svc.screen(dbPath, [ruleById(ruleId)]);
    stdout.writeln('${ruleId.padRight(26)} ${sw.elapsedMilliseconds}ms'
        '  加载 ${r.timings!.loadMs}ms 复用=${r.timings!.poolReused} 命中 ${r.picked.length}');
  }
  // 数据变化后再跑一次：应重载
  final r = await svc.screen(dbPath, [ruleById('rsi_oversold_volume_loose')]);
  stdout.writeln('复用路径：加载 ${r.timings!.loadMs}ms 复用=${r.timings!.poolReused}');
  svc.dispose();
}
