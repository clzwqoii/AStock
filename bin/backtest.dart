/// 命令行回测：滚动评估规则，统计未来 N 日收益，并与无条件基准对比。
///
/// 用法:
///   dart run bin/backtest.dart <规则id...> [--days 5,10,20] [--db 路径]
///   dart run bin/backtest.dart            # 不带规则 id 时列出全部规则
///
/// 每个持有期输出一节，表格并列各规则与基准（base rate）。
library;

// ignore_for_file: avoid_print

import 'dart:io';

import 'package:stock/config.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/bar_repository.dart';

const _defaultDays = [5, 10, 20];

Future<void> main(List<String> args) async {
  final ruleIds = <String>[];
  final days = <int>[];
  String? dbPath;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--help' || a == '-h') {
      _usage();
      return;
    } else if (a.startsWith('--days=')) {
      days.addAll(_parseDays(a.substring('--days='.length)));
    } else if (a == '--days' && i + 1 < args.length) {
      days.addAll(_parseDays(args[++i]));
    } else if (a.startsWith('--db=')) {
      dbPath = a.substring('--db='.length);
    } else if (a == '--db' && i + 1 < args.length) {
      dbPath = args[++i];
    } else {
      ruleIds.add(a);
    }
  }
  final horizons = days.isEmpty ? _defaultDays : days;

  if (ruleIds.isEmpty) {
    _usage();
    print('可用规则:');
    for (final r in builtInRules) {
      print('  ${r.id.padRight(24)} ${r.name}');
    }
    return;
  }

  final rules = [for (final id in ruleIds) ruleById(id)];
  final repo = BarRepository(dbPath ?? AppConfig.load().dbPath);
  final stocks = repo.loadAllStocks();
  repo.close();
  if (stocks.isEmpty) {
    print('数据库为空（0 只股票），先跑 dart run bin/sync.dart 同步数据');
    return;
  }

  final first = stocks.map((s) => s.bars.first.date).reduce((a, b) => a.isBefore(b) ? a : b);
  final last = stocks.map((s) => s.bars.last.date).reduce((a, b) => a.isAfter(b) ? a : b);
  final bars = stocks.map((s) => s.bars.length).reduce((a, b) => a > b ? a : b);

  print('股票 ${stocks.length} 只 · 每只最多 $bars 根 · 数据区间 $first ~ $last');
  print('⚠ 样本期短且只覆盖一段行情：只能看出「明显」差异，不能作为定论。');
  print('⚠ 同一只股票可能重复出信号，信号不独立；未计交易成本与涨跌停无法成交。');

  for (final h in horizons) {
    print('');
    // 每个持有期一遍扫描：单持有期调用下可评估日范围与逐规则路径一致，
    // 统计量逐位相同（test/backtest_test.dart 的等价性契约），但指标序列
    // 只构建一遍——逐规则 backtestRule 是规则数 × 持有期数遍全市场扫描。
    final report = backtestAll(stocks, rules, horizons: [h]);
    final base = report.baseline[h]!;
    print('══ 持有期 $h 日 · 基准样本 ${base.count} 个交易日 ══');
    if (base.count == 0) {
      print('  历史长度不足持有期 $h 日，跳过');
      continue;
    }
    final table = Table(const [
      '规则',
      '信号数',
      '胜率',
      '平均%',
      '中位%',
      '最好%',
      '最差%',
      '盈亏比',
      '超额胜率',
    ]);
    table.add(<String>[
      '（无条件基准）',
      '—',
      pct(base.winRate),
      num(base.avgReturn),
      num(base.medianReturn),
      '—',
      '—',
      '—',
      '—',
    ]);
    for (final r in rules) {
      final b = report.results[r.id]![h]!;
      // 7 个统计单元格；无信号时全部填 —（列数必须与表头一致，否则 Table.render 越界）
      final cells = b.count == 0
          ? const ['—', '—', '—', '—', '—', '—', '—']
          : [
              pct(b.winRate),
              num(b.avgReturn),
              num(b.medianReturn),
              num(b.bestReturn),
              num(b.worstReturn),
              num(b.profitFactor),
              pp((b.winRate - base.winRate) * 100),
            ];
      table.add([r.name, '${b.count}', ...cells]);
    }
    print(table.render());
  }
}

void _usage() {
  print('用法: dart run bin/backtest.dart <规则id...> [--days 5,10,20] [--db 路径]');
}
List<int> _parseDays(String s) {
  final out = <int>[];
  for (final part in s.split(',')) {
    final v = int.tryParse(part.trim());
    if (v == null || v <= 0) {
      stderr.writeln('非法持有期: $part（应为正整数）');
      exitCode = 1;
      continue;
    }
    out.add(v);
  }
  return out;
}

String pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
String num(double v) => v.toStringAsFixed(2);
String pp(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}pp';

/// 终端表格：按 East Asian 显示宽度对齐（中文/全角算 2 列）。
class Table {
  Table(this.columns);

  final List<String> columns;
  final List<List<String>> rows = [];

  void add(List<String> row) {
    assert(row.length == columns.length,
        '行 ${row.length} 列 != 表头 ${columns.length} 列');
    rows.add(row);
  }

  String render() {
    final widths = [
      for (var c = 0; c < columns.length; c++)
        [columns[c], for (final r in rows) r[c]]
            .map(_width)
            .reduce((a, b) => a > b ? a : b),
    ];
    final out = StringBuffer()
      ..writeln('  ${_line(columns, widths)}')
      ..writeln('  ${widths.map((w) => '-' * w).join('  ')}');
    for (final r in rows) {
      out.writeln('  ${_line(r, widths)}');
    }
    return out.toString().trimRight();
  }

  static String _line(List<String> cells, List<int> widths) =>
      [for (var c = 0; c < cells.length; c++) _pad(cells[c], widths[c])].join('  ');

  static int _width(String s) => s.runes.fold(0, (n, r) => n + (r > 0x2E80 ? 2 : 1));

  static String _pad(String s, int w) {
    final gap = w - _width(s);
    return gap <= 0 ? s : s + ' ' * gap;
  }
}
