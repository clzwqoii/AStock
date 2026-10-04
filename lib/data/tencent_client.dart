/// 腾讯日K公开接口（无需 token）。
/// 作为 tushare daily 限频/不可用时的逐股备源：一次拉一只股票的最近 N 根日线。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as h;


class TencentClient {
  TencentClient({
    h.Client? http,
    this.apiBase = 'https://web.ifzq.gtimg.cn',
    this.timeout = const Duration(seconds: 15),
  }) : _http = http ?? h.Client();

  final h.Client _http;
  final String apiBase;

  /// 单请求超时：网络异常时快速失败并降级。
  final Duration timeout;

  /// 单只股票名称（fqkline 响应自带 qt 实时行情块，UTF-8，第 2 字段是名称）。北交所不支持。
  Future<String?> stockName(String tsCode) async {
    if (tsCode.endsWith('.BJ')) {
      throw ArgumentError('腾讯日K暂不支持北交所: $tsCode');
    }
    final parts = tsCode.split('.');
    final symbol = '${parts[1].toLowerCase()}${parts[0]}';
    final uri = Uri.parse(
        '$apiBase/appstock/app/fqkline/get?param=${Uri.encodeQueryComponent('$symbol,day,,,1,qfq')}');
    final res = await _http.get(uri).timeout(timeout);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final node = (body['data'] as Map<String, dynamic>?)?[symbol] as Map<String, dynamic>?;
    final qt = node?['qt'] as Map<String, dynamic>?;
    final quote = qt?[symbol] as List?;
    if (quote == null || quote.length < 2) return null;
    return quote[1] as String?;
  }
}
