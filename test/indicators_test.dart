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
