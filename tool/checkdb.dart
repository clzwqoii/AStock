/// 打印本地库的基本情况：股票数、交易日数、日期范围、总行数。
/// 用法: dart run tool/checkdb.dart [db路径]
library;

// ignore_for_file: avoid_print

import 'package:stock/config.dart';
import 'package:stock/data/bar_repository.dart';

void main(List<String> args) {
  final repo = BarRepository(args.isNotEmpty ? args[0] : AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  final dates = <String>{};
  for (final s in stocks) {
    for (final b in s.bars) {
      dates.add('${b.date.year.toString().padLeft(4, '0')}'
          '${b.date.month.toString().padLeft(2, '0')}'
          '${b.date.day.toString().padLeft(2, '0')}');
    }
  }
  final sorted = dates.toList()..sort();
  print('股票数=${stocks.length}  交易日数=${sorted.length}  总行数=${repo.barCount()}');
  if (sorted.isNotEmpty) {
    print('最早=${sorted.first}  最晚=${sorted.last}');
    print('前5个: ${sorted.take(5).join(' ')}');
    print('后5个: ${sorted.reversed.take(5).toList().reversed.join(' ')}');
  }
  repo.close();
}
