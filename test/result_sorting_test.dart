/// 选股结果排序与 CSV 导出：两者都是纯函数，先测再实现。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';

ScreenRow row(
  String symbol, {
  double close = 10,
  double changePct = 0,
  double volumeRatio = 1,
  double amountWan = 100,
  double ma20 = 9,
  String? name,
  List<String> matchedRules = const [],
}) =>
    ScreenRow(
      symbol: symbol,
      name: name ?? symbol,
      close: close,
      change: close - (close / (1 + changePct / 100)),
      changePct: changePct,
      volumeRatio: volumeRatio,
      amountWan: amountWan,
      ma20: ma20,
      matchedRules: matchedRules,
    );

void main() {
  group('sortRows', () {
    final rows = [
      row('A', close: 10, changePct: 1, volumeRatio: 2, ma20: 9.5),
      row('B', close: 30, changePct: -5, volumeRatio: 5, ma20: 28),
      row('C', close: 20, changePct: 3, volumeRatio: 1, ma20: 19),
    ];

    test('默认按涨跌幅降序', () {
      expect(sortRows(rows, SortField.changePct).map((r) => r.symbol).toList(), ['C', 'A', 'B']);
    });

    test('同一列重复点击切换升降序', () {
      final asc = sortRows(rows, SortField.changePct, ascending: true);
      expect(asc.map((r) => r.symbol).toList(), ['B', 'A', 'C']);
      expect(sortRows(rows, SortField.close).map((r) => r.symbol).toList(), ['B', 'C', 'A']);
    });

    test('各字段排序与表头一致', () {
      expect(sortRows(rows, SortField.volumeRatio).first.symbol, 'B');
      expect(sortRows(rows, SortField.amount).first.symbol, 'A'); // 默认全部 100，稳定序保持 A
      expect(sortRows(rows, SortField.ma20).first.symbol, 'B');
    });

    test('同值时稳定（保持原顺序，不抖动）', () {
      final tie = [row('X', close: 10), row('Y', close: 10), row('Z', close: 10)];
      expect(sortRows(tie, SortField.close, ascending: true).map((r) => r.symbol).toList(), ['X', 'Y', 'Z']);
    });

    test('返回新列表，不改动入参', () {
      final out = sortRows(rows, SortField.close);
      expect(identical(out, rows), false);
      expect(rows.first.symbol, 'A');
    });

    test('空列表安全', () {
      expect(sortRows(const [], SortField.close), isEmpty);
    });
  });

  group('rowsToCsv', () {
    test('说明行 + 表头 + 行内容，涨跌带正负号，列序与表头一致', () {
      final csv = rowsToCsv([
        row('600000.SH', close: 12.5, changePct: 3.5, volumeRatio: 2.4, amountWan: 8888, ma20: 11.2,
            name: '浦发银行',
            matchedRules: ['收盘价站上MA20', 'MA5上穿MA10']),
      ], dataDate: '20260930', combo: '收盘价站上MA20');
      final lines = csv.trim().split('\n');
      expect(lines[0], '# A股选股结果（不复权·手）  数据截至 20260930  规则：收盘价站上MA20');
      expect(lines[1], '代码,名称,收盘,涨跌,涨跌幅%,量比,成交额(万),MA20,数据截至,规则组合');
      expect(lines[2],
          '600000.SH,浦发银行,12.50,+0.42,+3.50,2.40,8888.00,11.20,20260930,收盘价站上MA20');
    });

    test('名称里的逗号与引号按 RFC4180 转义', () {
      final csv = rowsToCsv([row('A', name: '测,试"股')], dataDate: '20260930');
      expect(csv, contains('# A股选股结果（不复权·手）  数据截至 20260930'));
      expect(csv, contains('A,"测,试""股",'));
    });

    test('空结果只出说明行与表头', () {
      expect(rowsToCsv(const []).trim().split('\n').length, 2);
    });

    test('name 为 null 显示空字段而不是 null', () {
      final csv = rowsToCsv([ScreenRow(
        symbol: 'A',
        name: null,
        close: 1,
        change: 0,
        changePct: 0,
        volumeRatio: 0,
        amountWan: 0,
        ma20: 0,
      )]);
      expect(csv.trim().split('\n').last.split(',')[1], '');
    });
  });

  group('exportRowsCsv', () {
    test('写文件并返回路径；文件名带日期时间戳，内容带 BOM（Excel 中文不乱码）', () async {
      String? writtenPath;
      List<int>? writtenBytes;
      final path = await exportRowsCsv(
        [row('A')],
        dirPath: '/tmp/stock-test',
        dataDate: '20260930',
        write: (p, bytes) async {
          writtenPath = p;
          writtenBytes = bytes;
        },
      );
      expect(writtenPath, path);
      expect(path, startsWith('/tmp/stock-test/选股结果-'));
      expect(path, endsWith('.csv'));
      expect(writtenBytes!.take(3), [0xEF, 0xBB, 0xBF]); // UTF-8 BOM
      expect(utf8.decode(writtenBytes!.skip(3).toList()), contains('代码,名称,收盘'));
    });
  });
}
