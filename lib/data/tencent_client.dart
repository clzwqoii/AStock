/// 腾讯日K公开接口（无需 token）。
/// 作为 tushare daily 限频/不可用时的逐股备源：一次拉一只股票的最近 N 根日线。
library;

import 'dart:async';
import 'dart:convert';

import 'package:gbk_codec/gbk_codec.dart';
import 'package:http/http.dart' as h;

import 'tushare_client.dart';

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

  /// 某只股票最近 [count] 根日K（前复权）。北交所不支持。
  Future<List<DailyRow>> dailyBars(String tsCode, {int count = 400}) async {
    if (tsCode.endsWith('.BJ')) {
      throw ArgumentError('腾讯日K暂不支持北交所: $tsCode');
    }
    final parts = tsCode.split('.');
    final symbol = '${parts[1].toLowerCase()}${parts[0]}';
    // 直接拼查询串：Uri.queryParameters 会丢弃空参数位（param 里的 ,,, 是占位语法）。
    // param 格式：符号,day,开始日,结束日,根数,qfq —— 起止留空即三个连续逗号。
    final uri = Uri.parse(
        '$apiBase/appstock/app/fqkline/get?param=${Uri.encodeQueryComponent('$symbol,day,,,$count,qfq')}');
    final res = await _http.get(uri);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final data = body['data'] as Map<String, dynamic>?;
    final node = data?[symbol] as Map<String, dynamic>?;
    // 前复权接口返回 qfqday，无复权数据时退回 day；数组顺序：日期/开/收/高/低/量(手)。
    final klines = ((node?['qfqday'] ?? node?['day']) as List?)?.cast<List>() ?? const [];
    return [
      for (final k in klines)
        DailyRow(
          tsCode: tsCode,
          tradeDate: (k[0] as String).replaceAll('-', ''),
          open: _d(k[1]),
          close: _d(k[2]),
          high: _d(k[3]),
          low: _d(k[4]),
          vol: _d(k[5]),
          amount: 0,
        ),
    ];
  }

  static double _d(Object? v) => double.parse(v as String);

  /// 批量拿股票名称（行情接口第 2 个字段），每批 60 只，GBK 解码。
  /// 代码来源是本地 daily_bars 已有的代码清单，无需额外配额。
  Future<Map<String, String>> stockNames(List<String> tsCodes) async {
    final symbols = [
      for (final ts in tsCodes)
        if (ts.endsWith('.SH') || ts.endsWith('.SZ'))
          '${ts.split('.')[1].toLowerCase()}${ts.split('.')[0]}',
    ];
    final names = <String, String>{};
    for (var i = 0; i < symbols.length; i += 60) {
      final batch = symbols.skip(i).take(60).join(',');
      final res =
          await _http.get(Uri.parse('https://qt.gtimg.cn/q=$batch')).timeout(timeout);
      final text = gbk_bytes.decoder.convert(res.bodyBytes);
      for (final m in RegExp(r'v_(\w+)="([^"]*)"').allMatches(text)) {
        final fields = m.group(2)!.split('~');
        if (fields.length > 2) {
          final code = fields[2];
          names['$code${code.startsWith('6') ? '.SH' : '.SZ'}'] = fields[1];
        }
      }
    }
    return names;
  }


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
