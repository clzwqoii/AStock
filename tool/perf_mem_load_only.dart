/// 一次性探针（配合 /usr/bin/time -l 用）：只加载选股池并持有，测峰值 RSS。
library;
import 'dart:io';
import 'package:stock/config.dart';
import 'package:stock/data/bar_repository.dart';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : AppConfig.load().dbPath;
  if (args.contains('--baseline')) {
    stdout.writeln('baseline done');
    return;
  }
  final repo = BarRepository(dbPath);
  final sw = Stopwatch()..start();
  final stocks = repo.loadAllStocks(excludeSpecialStocks: true);
  final bars = stocks.fold<int>(0, (n, s) => n + s.bars.length);
  stdout.writeln('stocks=${stocks.length} bars=$bars load=${sw.elapsedMilliseconds}ms');
  stdout.writeln('pool held; sleeping');
  await Future<void>.delayed(const Duration(seconds: 2));
  repo.close();
}
