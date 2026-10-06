/// 选股结果排序与 CSV 导出：两者都是纯函数，先测再实现。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/app_logic.dart';
import 'package:stock/core/score.dart';

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


  group('按评分/盈亏比排序', () {
    ScreenRow r(String s, double score) {
      final f = score < 0
          ? null
          : PriceForecast(
              entry: 10,
              target: 12,
              stop: 9,
              optimistic: null,
              riskReward: score > 100 ? null : score / 20,
              lowConfidence: false,
              reason: '',
            );
      return ScreenRow(
        symbol: s,
        name: s,
        close: 10,
        change: 0,
        changePct: 0,
        volumeRatio: 1,
        amountWan: 1,
        ma20: 9,
        score: StockScore(
          score: score < 0 ? 0 : score,
          rawWinRate: 0.5,
          baselineWinRate: 0.5,
          sampleCount: 100,
          hitRuleIds: const ['x'],
          lowConfidence: false,
          reason: '',
        ),
        forecast: f,
      );
    }

    // 辅助：给 scoreOf 造一个带分位数的最小报告
    test('评分降序', () {
      final rows = [r('低', 40), r('高', 92), r('中', 75)];
      expect(sortRows(rows, SortField.score).map((e) => e.symbol).toList(), ['高', '中', '低']);
      expect(sortRows(rows, SortField.score, ascending: true).map((e) => e.symbol).toList(),
          ['低', '中', '高']);
    });

    test('起伏序时空值（无盈亏比）恒沉底，不随升降序翻到顶部', () {
      final rows = [r('无', -1), r('低', 40), r('高', 92)];
      expect(sortRows(rows, SortField.riskReward).map((e) => e.symbol).toList(),
          ['高', '低', '无']);
      expect(sortRows(rows, SortField.riskReward, ascending: true).map((e) => e.symbol).toList(),
          ['低', '高', '无'],
          reason: '升序就是数值小的在前，但空值仍必须在底部——'
              '一行“暂无数据”浮到第一名比不显示更糟');
    });

    test('无评分的行（score=null）在评分排序里沉底', () {
      final bare = ScreenRow(
        symbol: '裸',
        name: '裸',
        close: 10,
        change: 0,
        changePct: 0,
        volumeRatio: 1,
        amountWan: 1,
        ma20: 9,
      );
      final rows = [bare, r('高', 92)];
      expect(sortRows(rows, SortField.score).map((e) => e.symbol).toList(), ['高', '裸']);
      expect(sortRows(rows, SortField.score, ascending: true).map((e) => e.symbol).toList(),
          ['高', '裸']);
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


    test('withScore: true 追加评分与预测价列，且默认关闭', () {
      final r = row('600000.SH', close: 10, name: '浦发银行');
      // 默认：列序与旧版逐字节一致（下游解析脚本不能错位）
      final plain = rowsToCsv([r], dataDate: '20260930');
      expect(plain.trim().split('\n')[1],
          '代码,名称,收盘,涨跌,涨跌幅%,量比,成交额(万),MA20,数据截至,规则组合');

      final withScore = rowsToCsv([r], dataDate: '20260930', withScore: true);
      final ls = withScore.trim().split('\n');
      expect(ls[1],
          '代码,名称,收盘,涨跌,涨跌幅%,量比,成交额(万),MA20,数据截至,规则组合,'
          '评分,档位,目标价,止损价,盈亏比,样本数');
    });

    test('withScore: true 时无评分/预测价写空串而不是 null 或 0', () {
      final csv = rowsToCsv([row('A', close: 10)], withScore: true);
      final cells = csv.trim().split('\n').last.split(',');
      // 原 10 列 + 6 列新列 = 16
      expect(cells.length, 16);
      expect(cells[10], '', reason: '无报告时评分必须留空，不能写 0 分');
      expect(cells[12], '', reason: '无目标价时留空');
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
