/// 网易财经历史日线 CSV（无需 token）。
/// 日线降级链第 3 顺位（tushare → 腾讯 → 新浪 → 网易）。
/// 头部为 GB2312（utf8 解码会乱码），但数据行是 ASCII，按列位解析不受影响。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as h;

import 'tushare_client.dart';

class NeteaseClient {
  NeteaseClient({
    h.Client? http,
    this.apiBase = 'https://quotes.money.163.com',
    this.timeout = const Duration(seconds: 15),
  }) : _http = http ?? h.Client();

  final h.Client _http;
  final String apiBase;

  /// 单请求超时：网络异常时快速失败并降级。
  final Duration timeout;

  /// [start]/[end] 形如 YYYYMMDD； CSV 列序固定：
  /// 日期, 代码, 名称, 开盘, 最高, 最低, 收盘, 成交量(股), 成交金额(元)。
  Future<List<DailyRow>> dailyBars(String tsCode, {String? start, String? end}) async {
    if (tsCode.endsWith('.BJ')) {
      throw ArgumentError('网易日K暂不支持北交所: $tsCode');
    }
    final parts = tsCode.split('.');
    // 网易代码前缀：沪 0、深 1。
    final code = parts[1] == 'SH' ? '0${parts[0]}' : '1${parts[0]}';
    final params = {'code': code, 'start': ?start, 'end': ?end};
    final uri = Uri.parse('$apiBase/service/chddata.html')
        .replace(queryParameters: params);
    final res = await _http.get(uri).timeout(timeout);
    final lines = utf8.decode(res.bodyBytes, allowMalformed: true).split('\n');

    final out = <DailyRow>[];
    for (final line in lines.skip(1)) {
      final cols = line.trim().split(',');
      if (cols.length < 9) continue;
      out.add(DailyRow(
        tsCode: tsCode,
        tradeDate: cols[0].replaceAll('-', ''),
        open: _d(cols[3]),
        high: _d(cols[4]),
        low: _d(cols[5]),
        close: _d(cols[6]),
        vol: _d(cols[7]),
        amount: _d(cols[8]) / 1000, // 元 → 千元
      ));
    }
    // 网易按日期倒序返回，统一成升序。
    out.sort((a, b) => a.tradeDate.compareTo(b.tradeDate));
    return out;
  }

  static double _d(Object? v) => double.tryParse((v as String).trim()) ?? 0;
}
