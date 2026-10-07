/// 一次性端到端探针：完全复刻 runScreening 的路径（isolate + 报告 + 评分 + 行组装），
/// 逐规则测真实墙钟时间。
library;
import 'dart:io';
import 'package:stock/app_logic.dart';
import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : AppConfig.load().dbPath;
  // 预热一次（JIT + 文件缓存）
  await runScreening(dbPath, [ruleById('rsi_oversold_volume')]);
  for (final r in builtInRules) {
    final sw = Stopwatch()..start();
    final res = await runScreening(dbPath, [r]);
    final ms = sw.elapsedMilliseconds;
    stdout.writeln('${r.id.padRight(28)} ${ms.toString().padLeft(6)}ms'
        '  命中 ${res.picked.length}');
  }
}
