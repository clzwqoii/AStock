/// 东方财富公开行情接口（无需 token）。
/// 当前只承担一件事：全市场股票代码+名称名单，作为 tushare stock_basic 限频时的降级源。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as h;

class EastmoneyClient {
  EastmoneyClient({
    h.Client? http,
    this.pageSize = 100,
    this.apiBase = 'https://push2.eastmoney.com',
    this.timeout = const Duration(seconds: 15),
  }) : _http = http ?? h.Client();

  final h.Client _http;
  final int pageSize;
  final String apiBase;

  /// 单请求超时：网络异常时快速失败并降级。
  final Duration timeout;

  /// 全部 A 股（沪深主板/创业板/科创板/北交所）名单。
  Future<List<({String tsCode, String name})>> stockList() async {
    const fields = 'f12,f13,f14';
    final fs = 'm:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048';
    final out = <({String tsCode, String name})>[];
    var pn = 1;
    var total = 1 << 30;
    while (out.length < total) {
      final uri = Uri.parse('$apiBase/api/qt/clist/get').replace(queryParameters: {
        'pn': '$pn',
        'pz': '$pageSize',
        'po': '1',
        'np': '1',
        'fltt': '2',
        'invt': '2',
        'fid': 'f12',
        'fs': fs,
        'fields': fields,
      });
      final res = await _http.get(uri, headers: _ua).timeout(timeout);
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final data = body['data'] as Map<String, dynamic>?;
      if (data == null) break;
      total = (data['total'] as num?)?.toInt() ?? 0;
      final diff = (data['diff'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      if (diff.isEmpty) break;
      for (final d in diff) {
        final code = d['f12'] as String;
        out.add((tsCode: '$code${_marketSuffix(code)}', name: d['f14'] as String));
      }
      pn++;
    }
    return out;
  }

  /// 单只股票名称（走 push2his K线接口，响应自带 name）。
  /// clist 域名在部分网络被拦时，名称回填可用此方法逐股获取。北交所不支持。
  Future<String?> stockName(String tsCode) async {
    if (tsCode.endsWith('.BJ')) {
      throw ArgumentError('东财日K暂不支持北交所: $tsCode');
    }
    final parts = tsCode.split('.');
    final secid = '${parts[1] == 'SH' ? '1' : '0'}.${parts[0]}';
    final uri = Uri.parse(
        '$_hisBase/api/qt/stock/kline/get').replace(queryParameters: {
      'secid': secid,
      'klt': '101',
      'fqt': '1',
      'lmt': '1',
      'end': '20500101',
      'fields1': 'f1,f2,f3,f4,f5,f6',
      'fields2': 'f51,f52,f53,f54,f55,f56',
    });
    final res = await _http.get(uri, headers: _ua).timeout(timeout);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>?;
    return data?['name'] as String?;
  }

  /// 6 位代码前缀定市场：6→SH，0/3→SZ，4/8/9→BJ。
  static String _marketSuffix(String code) {
    final c = code[0];
    if (c == '6') return '.SH';
    if (c == '0' || c == '3') return '.SZ';
    return '.BJ';
  }

  static const _ua = {'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'};
  static const _hisBase = 'https://push2his.eastmoney.com';
}
