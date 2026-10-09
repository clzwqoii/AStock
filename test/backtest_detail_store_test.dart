import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/backtest.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/market_state.dart';
import 'package:stock/core/models.dart';
import 'package:stock/core/rules.dart';
import 'package:stock/data/backtest_detail_store.dart';

final _day0 = DateTime(2024, 1, 1);

StockData stockOfCloses(List<double> closes, {String symbol = 'T'}) => StockData(
      symbol: symbol,
      bars: [
        for (var i = 0; i < closes.length; i++)
          Bar(
            date: _day0.add(Duration(days: i)),
            open: closes[i],
            high: closes[i],
            low: closes[i],
            close: closes[i],
            volume: 100,
          ),
      ],
    );

final _upCloses = <double>[
  ...List.filled(40, 10.0),
  11.0, 11.5, 12.0, 12.5, 13.0, 13.5,
  ...List.filled(104, 14.0),
];

final _downCloses = <double>[
  ...List.filled(40, 10.0),
  11.0, 10.5, 10.0, 9.5, 9.0, 8.5,
  ...List.filled(104, 8.0),
];

final _rules = [
  ruleById('pct_change_up'),
  ruleById('ma5_golden_ma10'),
];
const _hs = [5, 10];
const _recentWindow = 30;
const _fp = 'fp-v1|pct_change_up|ma5_golden_ma10|5|10|30';

void main() {
  late Directory tmp;
  late String path;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('backtest-detail-store-test');
    path = '${tmp.path}${Platform.pathSeparator}detail.bin';
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  (BacktestReport, ShardDetail) buildMerged() {
    final stocks = [
      stockOfCloses(_upCloses, symbol: 'U1'),
      stockOfCloses(_downCloses, symbol: 'D1'),
      stockOfCloses(List<double>.filled(150, 10.0), symbol: 'F1'),
    ];
    final calendar = tradingCalendar(stocks);
    final cutoff = recentCutoffDate(calendar, _recentWindow)!;
    final msCtx = MarketStateCtx.fromCalendar(calendar,
        maPeriod: 120,
        recentDays: 130,
        statWindow: 20,
        maxLastBarLagTradingDays: 20,
        corporateActionLookbackBars: kCorporateActionLookbackBars);
    return mergeAndAggregate([
      scanStocksShard(
          stocks: stocks.sublist(0, 2),
          rules: _rules,
          hs: _hs,
          calendar: calendar,
          recentCutoffDate: cutoff,
          msCtx: msCtx),
      scanStocksShard(
          stocks: stocks.sublist(2),
          rules: _rules,
          hs: _hs,
          calendar: calendar,
          recentCutoffDate: cutoff,
          msCtx: msCtx),
    ],
        ruleIds: [for (final r in _rules) r.id],
        hs: _hs,
        recentCutoffDate: cutoff,
        msCtx: msCtx);
  }

  void expectSameDetail(ShardDetail a, ShardDetail b) {
    expect(a.stockCount, b.stockCount);
    expect(a.stockLens, b.stockLens);
    expect(a.sigTapes.keys, b.sigTapes.keys);
    for (final id in b.sigTapes.keys) {
      for (final h in _hs) {
        final x = a.sigTapes[id]![h]!, y = b.sigTapes[id]![h]!;
        expect(x.count, y.count, reason: '$id h=$h count');
        expect(x.sum, y.sum, reason: '$id h=$h sum');
        expect(x.gain, y.gain, reason: '$id h=$h gain');
        expect(x.loss, y.loss, reason: '$id h=$h loss');
        expect(x.wins, y.wins, reason: '$id h=$h wins');
        expect(x.best, y.best, reason: '$id h=$h best');
        expect(x.worst, y.worst, reason: '$id h=$h worst');
        expect(x.byMonth, y.byMonth, reason: '$id h=$h byMonth');
        for (final year in y.byYear.keys) {
          expect(x.byYear[year], y.byYear[year], reason: '$id h=$h y=$year');
        }
      }
    }
    for (final h in _hs) {
      final x = a.baseTapes[h]!, y = b.baseTapes[h]!;
      expect(x.count, y.count, reason: 'base h=$h count');
      expect(x.sum, y.sum, reason: 'base h=$h sum');
      expect(x.byYear.keys, y.byYear.keys, reason: 'base h=$h years');
      for (final year in y.byYear.keys) {
        expect(x.byYear[year], y.byYear[year], reason: 'base h=$h y=$year');
      }
    }
    for (final id in b.recentSigDays!.keys) {
      for (final h in _hs) {
        expect(a.recentSigDays![id]![h], b.recentSigDays![id]![h],
            reason: 'recentSigDays $id h=$h');
      }
    }
    for (final h in _hs) {
      expect(a.recentBaseDays![h], b.recentBaseDays![h],
          reason: 'recentBaseDays h=$h');
    }
  }

  test('save → load roundtrip：明细与水位逐位一致，聚合报告等价', () {
    final (report, merged) = buildMerged();
    saveBacktestDetail(path, merged,
        fingerprint: _fp, maxRowid: 12345, rowCount: 6789);

    final loaded = loadBacktestDetail(path, fingerprint: _fp)!;
    expect(loaded.maxRowid, 12345);
    expect(loaded.rowCount, 6789);
    expect(loaded.fingerprint, _fp);
    expectSameDetail(loaded.detail, merged);

    // 聚合等价：加载态与原态走同一 aggregateDetail，报告逐位一致
    final calendar = tradingCalendar([
      stockOfCloses(_upCloses, symbol: 'U1'),
      stockOfCloses(_downCloses, symbol: 'D1'),
    ]);
    final cutoff = recentCutoffDate(calendar, _recentWindow)!;
    final r2 = aggregateDetail(loaded.detail,
        ruleIds: [for (final r in _rules) r.id],
        hs: _hs,
        recentCutoffDate: cutoff,
        msCtx: null);
    for (final h in _hs) {
      expect(r2.baseline[h]!.stats.count, report.baseline[h]!.stats.count);
      expect(r2.baseline[h]!.stats.avgReturn, report.baseline[h]!.stats.avgReturn);
      expect(r2.baseline[h]!.stats.medianReturn,
          report.baseline[h]!.stats.medianReturn);
    }
  });

  test('指纹不匹配返回 null', () {
    final (_, merged) = buildMerged();
    saveBacktestDetail(path, merged, fingerprint: _fp, maxRowid: 1, rowCount: 2);
    expect(loadBacktestDetail(path, fingerprint: 'other-fp'), isNull);
  });

  test('文件损坏返回 null（截断）', () {
    final (_, merged) = buildMerged();
    saveBacktestDetail(path, merged, fingerprint: _fp, maxRowid: 1, rowCount: 2);
    final bytes = File(path).readAsBytesSync();
    File(path).writeAsBytesSync(bytes.sublist(0, bytes.length - 40));
    expect(loadBacktestDetail(path, fingerprint: _fp), isNull);
  });

  test('文件不存在返回 null', () {
    expect(loadBacktestDetail(path, fingerprint: _fp), isNull);
  });

  test('backtestDetailPathFor：stock.db → 同目录 stock-backtest-detail.bin', () {
    expect(
        backtestDetailPathFor('/tmp/x/stock.db'),
        '/tmp/x${Platform.pathSeparator}stock-backtest-detail.bin');
    expect(
        backtestDetailPathFor('/tmp/x/custom.db3'),
        '/tmp/x${Platform.pathSeparator}custom.db3-backtest-detail.bin');
  });
}
