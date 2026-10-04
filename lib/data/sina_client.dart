/// 新浪财经日K公开接口（无需 token，scale=240 即日K）。
/// 日线降级链第 2 顺位（tushare → 腾讯 → 新浪 → 网易）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as h;

import 'tushare_client.dart';

class SinaClient {
  SinaClient({
    h.Client? http,
    this.apiBase = 'https://quotes.sina.cn',
    this.timeout = const Duration(seconds: 15),
  }) : _http = http ?? h.Client();

  final h.Client _http;
  final String apiBase;

  /// 单请求超时：网络异常时快速失败并降级。
  final Duration timeout;

  /// 某只股票最近 [count] 根日K。北交所不支持。
  Future<List<DailyRow>> dailyBars(String tsCode, {int count = 400}) async {
    if (tsCode.endsWith('.BJ')) {
      throw ArgumentError('新浪日K暂不支持北交所: $tsCode');
    }
    final parts = tsCode.split('.');
    final symbol = '${parts[1].toLowerCase()}${parts[0]}';
    final uri = Uri.parse(
            '$apiBase/cn/api/json_v2.php/CN_MarketDataService.getKLineData')
        .replace(queryParameters: {
      'symbol': symbol,
      'scale': '240',
      'ma': 'no',
      'datalen': '$count',
    });
    final res = await _http
        .get(uri, headers: const {'Referer': 'https://finance.sina.com.cn'})
        .timeout(timeout);
    final arr = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    return [
      for (final k in arr.cast<Map<String, dynamic>>())
        DailyRow(
          tsCode: tsCode,
          tradeDate: (k['day'] as String).replaceAll('-', ''),
          open: _d(k['open']),
          high: _d(k['high']),
          low: _d(k['low']),
          close: _d(k['close']),
          vol: _d(k['volume']),
          amount: 0,
        ),
    ];
  }

  static double _d(Object? v) => double.parse(v as String);
}
