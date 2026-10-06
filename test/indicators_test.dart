import 'package:flutter_test/flutter_test.dart';
import 'package:stock/core/indicators.dart';

import 'fixtures.dart';

void main() {
  group('sma', () {
    test('最后 n 个收盘价的简单平均', () {
      expect(sma([1.0, 2.0, 3.0, 4.0, 5.0], 3), 4.0);
      expect(sma([10.0, 10.0, 10.0], 3), 10.0);
    });

    test('数据不足 n 个时抛 ArgumentError', () {
      expect(() => sma([1.0, 2.0], 3), throwsArgumentError);
    });
  });

  group('smaSeries', () {
    // 锁定现有行为：逐日窗口均值，与逐窗口直接求和/sma() 标量同口径。
    // 前缀和重构（性能）不得改变这套语义。
    test('逐日窗口均值与逐窗口 sublist 求和一致，前 n-1 位为 null', () {
      final closes = closesVRecovery(); // 40 根非平凡序列
      for (final n in [1, 5, 10, 20, 39, 40]) {
        final r = smaSeries(closes, n);
        expect(r.length, closes.length, reason: 'n=$n');
        for (var i = 0; i < closes.length; i++) {
          if (i < n - 1) {
            expect(r[i], isNull, reason: 'n=$n i=$i 应为 null');
          } else {
            final w = closes.sublist(i - n + 1, i + 1);
            expect(r[i], closeTo(w.reduce((a, b) => a + b) / n, 1e-9),
                reason: 'n=$n i=$i');
          }
        }
        expect(r.last, closeTo(sma(closes, n), 1e-12), reason: 'n=$n 末值应与 sma() 标量一致');
      }
    });

    // smaSeries 的契约是「前 n-1 天不足窗口返回 null」，不像标量版 sma() 那样抛异常——
    // 选股要在历史不足时安静跳过，而不是炸掉。
    test('历史不足 n 根时返回 null 而不抛异常', () {
      final short = smaSeries([1.0, 2.0], 3);
      expect(short, everyElement(isNull));
      // n<=0 仍是编程错误，必须抛
      expect(() => smaSeries([1.0, 2.0, 3.0], 0), throwsArgumentError);
    });
  });
  group('macd', () {
    test('V 型反转序列与独立基准一致', () {
      final r = macd(closesVRecovery());
      expect(r.dif[38], closeTo(1.5654038808830428, 1e-9));
      expect(r.dif[39], closeTo(1.694253775402938, 1e-9));
      expect(r.dea[38], closeTo(0.9521737450143762, 1e-9));
      expect(r.dea[39], closeTo(1.1005897510920888, 1e-9));
      expect(r.hist[39], closeTo(1.1873280486216986, 1e-9));
    });

    test('单边下跌时 dif 为负', () {
      final r = macd(closesCrash());
      expect(r.dif[39], lessThan(0));
    });
  });
  group('rsi', () {
    test('V 型反转尾段超买，与独立基准一致', () {
      expect(rsi(closesVRecovery(), 14), closeTo(85.00915283788616, 1e-9));
    });

    test('单边下跌时为 0', () {
      expect(rsi(closesCrash(), 14), 0.0);
    });

    test('全部横盘时为中性 50', () {
      expect(rsi(List.filled(20, 10.0), 14), 50.0);
    });
  });
  group('kdj', () {
    test('V 型反转与独立基准一致，金叉在下标 20', () {
      final r = kdj(barsWithBand());
      expect(r.k[8], closeTo(36.66666666666668, 1e-9));
      expect(r.d[8], closeTo(45.555555555555564, 1e-9));
      expect(r.j[8], closeTo(18.8888888888889, 1e-9));
      expect(r.k[19], closeTo(10.308293865170379, 1e-9));
      expect(r.d[19], closeTo(11.541469325851809, 1e-9));
      expect(r.k[20], closeTo(16.748739119990137, 1e-9));
      expect(r.d[20], closeTo(13.277225923897918, 1e-9));
      expect(r.j[39], closeTo(94.05729128305899, 1e-9));
      expect(r.k[19]! < r.d[19]!, isTrue); // 金叉前 K 在 D 下方
      expect(r.k[20]! > r.d[20]!, isTrue); // 金叉日 K 上穿 D
    });

    test('前 n-1 根无值，不足 n 根抛 ArgumentError', () {
      final bars = barsWithBand();
      expect(kdj(bars).k.take(8), everyElement(isNull));
      expect(() => kdj(bars.take(8).toList()), throwsArgumentError);
    });

    test('连续一字板（高低相等）RSV 取 50，K/D/J 恒为 50', () {
      final r = kdj([for (var i = 0; i < 12; i++) bar()]);
      expect(r.k.last, closeTo(50.0, 1e-9));
      expect(r.d.last, closeTo(50.0, 1e-9));
      expect(r.j.last, closeTo(50.0, 1e-9));
    });
  });

  group('volumeRatio 量比', () {
    test('当日成交量除以前 5 日均量', () {
      final bars = [for (var i = 0; i < 5; i++) bar(), bar(volume: 300)];
      expect(volumeRatio(bars), 3.0);
    });

    test('不足 6 根抛 ArgumentError', () {
      expect(() => volumeRatio([for (var i = 0; i < 5; i++) bar()]), throwsArgumentError);
    });
  });

  group('pctChange 涨跌幅', () {
    test('当日相对前一日的百分比', () {
      expect(pctChange([bar(close: 10.0), bar(close: 11.0)]), closeTo(10.0, 1e-9));
    });

    test('不足 2 根抛 ArgumentError', () {
      expect(() => pctChange([bar(close: 10.0)]), throwsArgumentError);
    });
  });

  group('smaTrend MA 变动', () {
    test('MA(n) 最近 days 日的变化，与独立基准一致', () {
      final cl = [10.0, 10.5, 11.0, 11.5, 12.0, 12.5, 13.0, 13.5];
      expect(smaTrend(cl, 3, days: 2), closeTo(1.0, 1e-9));
      expect(smaTrend(cl, 3, days: 5), closeTo(2.5, 1e-9));
    });

    test('首值或末值所在窗口不足时返回 null', () {
      expect(smaTrend(List.filled(6, 1.0), 8, days: 2), isNull);
      expect(smaTrend([1.0, 2.0, 3.0, 4.0], 5, days: 3), isNull);
      expect(smaTrend([1.0, 2.0], 2, days: 5), isNull); // 回溯越过序列起点
    });

    test('n<=0 或 days<=0 抛 ArgumentError', () {
      expect(() => smaTrend([1.0, 2.0, 3.0], 0), throwsArgumentError);
      expect(() => smaTrend([1.0, 2.0, 3.0], -2), throwsArgumentError);
      expect(() => smaTrend([1.0, 2.0, 3.0], 2, days: 0), throwsArgumentError);
      expect(() => smaTrend([1.0, 2.0, 3.0], 2, days: -1), throwsArgumentError);
    });
  });

  group('biasPct 乖离率', () {
    test('收盘价相对 MA(n) 的乖离百分比，与独立基准一致', () {
      final cl = [10.0, 10.5, 11.0, 11.5, 12.0, 12.5, 13.0, 13.5];
      expect(biasPct(cl, 3), closeTo(3.8461538461538547, 1e-9));
      expect(biasPct(cl, 8), closeTo(14.893617021276606, 1e-9));
    });

    test('MA 无值（历史不足 n 根）时返回 null', () {
      expect(biasPct([1.0, 2.0, 3.0], 8), isNull);
    });

    test('n<=0 抛 ArgumentError', () {
      expect(() => biasPct([1.0, 2.0], 0), throwsArgumentError);
    });
  });

  group('amountRatio 成交额比', () {
    test('当日成交额除以前 5 日均额（与量比同构）', () {
      final bars = [for (var i = 0; i < 5; i++) kbar(close: 10), kbar(close: 10, volume: 300)];
      expect(amountRatio(bars), 3.0);
    });

    test('任一日 amount<=0（旧数据缺失）返回 0，不抛异常', () {
      final zero = [for (var i = 0; i < 5; i++) bar(close: 10), bar(close: 10, volume: 300)];
      expect(amountRatio(zero), 0.0);
    });

    test('前 5 日均额为 0（分母为 0）返回 0，不抛异常', () {
      final bars = [
        for (var i = 0; i < 5; i++) kbar(close: 10, volume: 0),
        kbar(close: 10, volume: 300)
      ];
      expect(amountRatio(bars), 0.0);
    });

    test('不足 6 根抛 ArgumentError', () {
      expect(() => amountRatio([for (var i = 0; i < 5; i++) kbar(close: 10)]), throwsArgumentError);
    });
  });

  group('closePos 收盘位置', () {
    test('收盘价在当日振幅中的位置，与独立基准一致', () {
      expect(closePos(kbar(close: 10, high: 10, low: 9)), 1.0);
      expect(closePos(kbar(close: 8.5, high: 10, low: 8)), closeTo(0.25, 1e-9));
      expect(closePos(kbar(close: 9.5, high: 10, low: 9)), closeTo(0.5, 1e-9));
      expect(closePos(kbar(close: 10, high: 11, low: 10)), 0.0);
    });

    test('一字板（高低相等）取中性 0.5', () {
      expect(closePos(kbar(close: 10, high: 10, low: 10)), 0.5);
    });
  });

  group('rsiSeries 逐日 RSI', () {
    test('V 型反转与 python 独立基准一致', () {
      final r = rsiSeries(closesVRecovery(), 14);
      expect(r[13], isNull); // 前 n 日无值
      expect(r[14], closeTo(0.0, 1e-9));
      expect(r[38], closeTo(83.73094050006465, 1e-9));
      expect(r[39], closeTo(85.00915283788616, 1e-9));
    });

    test('单边下跌整段为 0', () {
      final r = rsiSeries(closesCrash(), 14);
      expect(r[39], 0.0);
      expect(r[20], 0.0);
    });

    test('全部横盘为中性 50', () {
      final r = rsiSeries(List.filled(25, 10.0), 14);
      expect(r[14], closeTo(50.0, 1e-9));
      expect(r[24], closeTo(50.0, 1e-9));
    });

    test('与 rsi() 末值逐位一致（rsi 委托 rsiSeries）', () {
      for (final cl in [closesVRecovery(), closesCrash(), List.filled(25, 10.0)]) {
        expect(rsi(cl, 14), closeTo(rsiSeries(cl, 14).last!, 1e-12));
      }
    });

    test('历史不足 n+1 根抛 ArgumentError', () {
      expect(() => rsiSeries(List.filled(14, 10.0), 14), throwsArgumentError);
      expect(() => rsiSeries(List.filled(20, 10.0), 0), throwsArgumentError);
    });
  });

  group('maBullAlignment 多头排列', () {
    double? lastOf(List<double> closes, int n) => smaSeries(closes, n).last;

    test('形态 A 末日多头排列成立，形态 B 回踩后不成立', () {
      final a = closesMa60Breakout();
      expect(
        maBullAlignment(lastOf(a, 5), lastOf(a, 10), lastOf(a, 20), lastOf(a, 60)),
        isTrue,
      );
      final b = closesMa60Pullback();
      expect(
        maBullAlignment(lastOf(b, 5), lastOf(b, 10), lastOf(b, 20), lastOf(b, 60)),
        isFalse, // MA5(20.82) < MA10(20.92)：真回踩必然搅乱短期均线
      );
    });

    test('任一为 null（历史不足 60 根）返回 false', () {
      final short = List.filled(30, 10.0);
      expect(
        maBullAlignment(lastOf(short, 5), lastOf(short, 10), lastOf(short, 20), lastOf(short, 60)),
        isFalse,
      );
      expect(maBullAlignment(1.0, 2.0, 3.0, null), isFalse);
    });

    test('全程平盘时四线相等，不满足严序', () {
      expect(maBullAlignment(10.0, 10.0, 10.0, 10.0), isFalse);
    });

    test('严序必须完整成立，缺一不可', () {
      expect(maBullAlignment(5.0, 4.0, 3.0, 2.0), isTrue);
      expect(maBullAlignment(5.0, 5.0, 3.0, 2.0), isFalse);
      expect(maBullAlignment(5.0, 4.0, 4.0, 2.0), isFalse);
      expect(maBullAlignment(5.0, 4.0, 3.0, 3.0), isFalse);
    });
  });
}
