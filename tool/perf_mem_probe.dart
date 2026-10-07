/// 一次性探针：选股池的常驻内存代价。
/// 对照 1：未加载时的 RSS；对照 2：单发选股（加载→筛选→释放）后的峰值 RSS。
library;
import 'dart:io';
import 'package:stock/app_logic.dart';
import 'package:stock/config.dart';
import 'package:stock/core/rules.dart';

void rss(String tag) {
  final info = ProcessInfo.currentRss;
  stdout.writeln('$tag: currentRss=${(info / 1024 / 1024).toStringAsFixed(0)}MB');
}

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : AppConfig.load().dbPath;
  rss('启动后');
  await runScreening(dbPath, [ruleById('rsi_oversold_volume_loose')]);
  rss('单发选股 1 次后（峰值已发生，isolate 已退出）');
  await runScreening(dbPath, [ruleById('rsi_oversold_volume_loose')]);
  rss('单发选股 2 次后');

  // 常驻服务持有池子时的 RSS
  final svc = ScreeningService(idleTimeout: const Duration(hours: 1));
  await svc.screen(dbPath, [ruleById('rsi_oversold_volume_loose')]);
  rss('常驻服务持有池子时');
  await svc.screen(dbPath, [ruleById('close_above_ma60')]);
  rss('常驻服务第二次选股后');
  svc.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 500));
  rss('dispose 后');
}
