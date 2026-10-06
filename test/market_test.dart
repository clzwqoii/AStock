import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/market.dart';
import 'package:stock/core/models.dart';

Bar bar({
  required String date,
  double open = 10,
  double high = 10,
  double low = 10,
  double close = 10,
}) =>
    Bar(
      date: DateTime.parse(date),
      open: open,
      high: high,
      low: low,
      close: close,
      volume: 1000,
    );

void main() {
  group('dailyLimitPct', () {
    test('主板 10%', () {
      for (final code in ['600000.SH', '601398.SH', '603507.SH', '000001.SZ', '002505.SZ']) {
        expect(dailyLimitPct(code), 10.0, reason: code);
      }
    });

    test('创业板/科创板 20%', () {
      for (final code in ['300980.SZ', '301575.SZ', '688981.SH']) {
        expect(dailyLimitPct(code), 20.0, reason: code);
      }
    });

    test('北交所 30%', () {
      expect(dailyLimitPct('920003.BJ'), 30.0);
    });
  });

  group('isCorporateActionGap', () {
    test('主板开盘跳空超过 10% = 除权/复牌', () {
      // 10 送 3：前收 10 → 除权参考价 7.69，开盘 7.7 属于正常除权日
      expect(
        isCorporateActionGap('600000.SH', bar(date: '2026-01-01', close: 10),
            bar(date: '2026-01-02', open: 7.7, high: 7.8, low: 7.6, close: 7.75)),
        isTrue,
      );
    });

    test('主板跌停开盘（-10%）是合法交易日，不是除权', () {
      expect(
        isCorporateActionGap('600000.SH', bar(date: '2026-01-01', close: 10),
            bar(date: '2026-01-02', open: 9, high: 9.2, low: 8.9, close: 9.1)),
        isFalse,
      );
    });

    test('创业板 10 转 4（祥源新材 2026-09-30 实例）被判为除权日', () {
      expect(
        isCorporateActionGap('300980.SZ', bar(date: '2026-09-29', close: 22.9),
            bar(date: '2026-09-30', open: 16.63, high: 16.69, low: 15.87, close: 15.98)),
        isTrue,
      );
    });

    test('创业板跌停开盘（-20%）是合法交易日，不是除权', () {
      expect(
        isCorporateActionGap('300980.SZ', bar(date: '2026-09-29', close: 20),
            bar(date: '2026-09-30', open: 16, high: 16.5, low: 15.8, close: 16.2)),
        isFalse,
      );
    });

    test('北交所 ±30% 内都算合法：-25% 不算除权，-31% 算', () {
      expect(
        isCorporateActionGap('920003.BJ', bar(date: '2026-01-01', close: 10),
            bar(date: '2026-01-02', open: 7.5, high: 7.6, low: 7.4, close: 7.55)),
        isFalse,
      );
      expect(
        isCorporateActionGap('920003.BJ', bar(date: '2026-01-01', close: 10),
            bar(date: '2026-01-02', open: 6.8, high: 6.9, low: 6.7, close: 6.85)),
        isTrue,
      );
    });

    test('向上跳空超过涨跌停同样是异常（长期停牌复牌）', () {
      expect(
        isCorporateActionGap('600000.SH', bar(date: '2026-01-01', close: 10),
            bar(date: '2026-06-01', open: 13, high: 13.5, low: 12.8, close: 13.2)),
        isTrue,
      );
    });

    test('前收盘非正数（脏数据）不判除权：宁可漏判也不要静默丢信号', () {
      expect(
        isCorporateActionGap('600000.SH', bar(date: '2026-01-01', close: 0),
            bar(date: '2026-01-02', open: 5, high: 5, low: 5, close: 5)),
        isFalse,
      );
    });

    test('容差让贴边的合法跳空不被误判', () {
      // 创业板 -20.5%：略超 20% 但仍在 1pp 容差内 → 合法
      expect(
        isCorporateActionGap('300980.SZ', bar(date: '2026-09-29', close: 20),
            bar(date: '2026-09-30', open: 15.9, high: 16, low: 15.8, close: 15.95)),
        isFalse,
      );
    });
  });

  group('barsSinceCorporateAction', () {
    test('除权日本身为 0，之后逐日 +1；没有除权时是大数', () {
      // 40 根 10.0，第 6 根（下标 5）开盘 7.7 = 主板除权
      // 前 5 根收 10，第 5 根除权（开盘 7.7），之后停在新价位 7.7 ——
      // 若除权后又跳回 10，等于第二天又除权一次，测的就不是同一件事。
      final bars = [
        for (var i = 0; i < 40; i++)
          i < 5
              ? bar(date: '2026-01-01', close: 10)
              : bar(date: '2026-01-05', open: 7.7, high: 7.8, low: 7.6, close: 7.75),
      ];
      final since = barsSinceCorporateAction('600000.SH', bars);
      expect(since[4], greaterThan(19)); // 除权前不认识
      expect(since[5], 0);
      expect(since[6], 1);
      expect(since[19], 14);
      expect(since[39], 34);
    });
  });

  group('isCleanSignalDay', () {
    // 40 根 10.0，下标 5 处主板除权（开盘 7.7）
    List<Bar> seriesWithGapAt5() => [
          for (var i = 0; i < 40; i++)
            i < 5
                ? bar(date: '2026-01-01', close: 10)
                : bar(date: '2026-01-05', open: 7.7, high: 7.8, low: 7.6, close: 7.75),
        ];

    test('信号当日就是除权日 → 不干净', () {
      expect(isCleanSignalDay('600000.SH', seriesWithGapAt5(), 5), isFalse);
    });

    test('除权后 19 根内（默认回溯 20 根）都不干净', () {
      for (var t = 6; t <= 24; t++) {
        expect(isCleanSignalDay('600000.SH', seriesWithGapAt5(), t), isFalse,
            reason: 't=$t');
      }
    });

    test('除权满 20 根后恢复干净', () {
      expect(isCleanSignalDay('600000.SH', seriesWithGapAt5(), 25), isTrue);
    });

    test('从未除权的序列全程干净', () {
      final bars = [for (var i = 0; i < 40; i++) bar(date: '2026-01-01', close: 10)];
      for (var t = 1; t < 40; t++) {
        expect(isCleanSignalDay('600000.SH', bars, t), isTrue);
      }
    });

    test('连续跌停（每天 -10%，主板）不会被误判成除权', () {
      final bars = <Bar>[];
      var close = 10.0;
      for (var i = 0; i < 40; i++) {
        final open = i == 0 ? close : close * 0.9;
        bars.add(bar(date: '2026-01-01', open: open, high: open, low: open, close: open));
        close = open;
      }
      for (var t = 1; t < 40; t++) {
        expect(isCleanSignalDay('600000.SH', bars, t), isTrue, reason: 't=$t');
      }
    });

    test('lookbackBars<=0 = 关护栏（复现旧口径用）', () {
      expect(isCleanSignalDay('600000.SH', seriesWithGapAt5(), 5, lookbackBars: 0),
          isTrue);
    });

    test('t<1（没有前一日）不判脏：宁可漏判也不静默丢信号', () {
      expect(isCleanSignalDay('600000.SH', seriesWithGapAt5(), 0), isTrue);
    });
  });

  group('tradingDaysSincePrevBar（停牌洞要用交易日历判）', () {
    // 仿 2024-01 的真实交易日：周二~周五 + 下周一、二（周末不在历里）
    final cal = {
      DateTime(2024, 1, 2), // 周二
      DateTime(2024, 1, 3),
      DateTime(2024, 1, 4),
      DateTime(2024, 1, 5), // 周五
      DateTime(2024, 1, 8), // 周一
      DateTime(2024, 1, 9),
    };

    test('相邻交易日 → 1；跨周末 → 1（周末不是交易日，不算洞）', () {
      // 连续 5 个交易日（周二~周五 + 周一），中间只跨了周末
      final bars = [
        for (final d in [
          DateTime(2024, 1, 2),
          DateTime(2024, 1, 3),
          DateTime(2024, 1, 4),
          DateTime(2024, 1, 5),
          DateTime(2024, 1, 8),
        ])
          Bar(date: d, open: 10, high: 10, low: 10, close: 10, volume: 1),
      ];
      expect(tradingDaysSincePrevBar(bars, cal), [1, 1, 1, 1, 1],
          reason: '周五→周一中间只有周末，不算停牌');
    });

    test('停牌 3 个交易日 → 4', () {
      final bars = [
        Bar(date: DateTime(2024, 1, 5), open: 10, high: 10, low: 10, close: 10, volume: 1),
        // 1/8、1/9 之后停牌到 1/16（不在历里的日期当作非交易日）
        Bar(date: DateTime(2024, 1, 16), open: 10, high: 10, low: 10, close: 10, volume: 1),
      ];
      final c2 = {...cal, DateTime(2024, 1, 15), DateTime(2024, 1, 16)};
      // 1/5 → 1/16 之间历上有 1/8,1/9,1/15,1/16 = 4 个交易日
      expect(tradingDaysSincePrevBar(bars, c2), [1, 4]);
    });



    test('日历为空 → 全部记 1（看不出洞，护栏失效但不误杀）', () {
      final bars = [
        Bar(date: DateTime(2024, 1, 2), open: 10, high: 10, low: 10, close: 10, volume: 1),
        Bar(date: DateTime(2024, 3, 2), open: 10, high: 10, low: 10, close: 10, volume: 1),
      ];
      expect(tradingDaysSincePrevBar(bars, const {}), [1, 1]);
    });

    test('首根记 1（没有前一根可比）', () {
      final one = [
        Bar(date: DateTime(2024, 1, 2), open: 10, high: 10, low: 10, close: 10, volume: 1),
      ];
      expect(tradingDaysSincePrevBar(one, cal), [1]);
    });
  });

  group('hasSuspensionGapNearby', () {
    // gapDays[i] = 第 i 根距上一根隔了几个交易日
    test('窗口内全是 1 → 干净', () {
      final g = List<int>.filled(40, 1);
      expect(hasSuspensionGapNearby(g, 39), isFalse);
    });

    test('窗口内出现 2 → 有洞', () {
      final g = List<int>.filled(40, 1)..[30] = 2;
      expect(hasSuspensionGapNearby(g, 39), isTrue);
    });

    test('窗口边界：只算 [t-lookback+1, t]，差一根就不算', () {
      final g = List<int>.filled(40, 1)..[19] = 45;
      // t=39、lookback=20 → 窗口 20..39，19 在窗外
      expect(hasSuspensionGapNearby(g, 39), isFalse);
      // t=38 → 窗口 19..38，19 在窗内
      expect(hasSuspensionGapNearby(g, 38), isTrue);
    });

    test('maxGapTradingDays 可调：只挡 >3 天的洞', () {
      final g = List<int>.filled(40, 1)..[30] = 3;
      expect(hasSuspensionGapNearby(g, 39, maxGapTradingDays: 3), isFalse);
      expect(hasSuspensionGapNearby(g, 39, maxGapTradingDays: 2), isTrue);
    });

    test('lookbackBars<=0 = 关护栏', () {
      final g = List<int>.filled(40, 1)..[39] = 45;
      expect(hasSuspensionGapNearby(g, 39, lookbackBars: 0), isFalse);
    });
  });
}
