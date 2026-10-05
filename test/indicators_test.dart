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
}
