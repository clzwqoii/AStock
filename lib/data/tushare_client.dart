/// tushare pro HTTP 客户端。只负责协议：请求构造、翻页、错误翻译。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as h;

/// tushare 返回非 0 错误码（如权限不足、限频）。
class TushareException implements Exception {
  TushareException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'TushareException($code): $message';
}

/// 单根日行情行。
class DailyRow {
  const DailyRow({
    required this.tsCode,
    required this.tradeDate,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.vol,
    required this.amount,
  });

  final String tsCode;
  final String tradeDate; // YYYYMMDD
  final double open;
  final double high;
  final double low;
  final double close;

  /// 成交量（手）。
  final double vol;

  /// 成交额（千元）。
  final double amount;
}

/// tushare pro 接口封装。
class TushareClient {
  TushareClient({
    required this.token,
    h.Client? http,
    this.pageSize = 6000,
    this.apiBase = 'https://api.tushare.pro',
    this.timeout = const Duration(seconds: 15),
  }) : _http = http ?? h.Client();

  final String token;
  final h.Client _http;

  /// 单页行数上限：必须恰好等于服务端上限 6000，不可更大——超限的 limit 不报错
  /// 而是被静默截断到 6000，`_callPaged` 的「不满一页即终止」会因此提前 break 丢
  /// 数据（真机实测：limit=6000 返回满 6000 行，limit=100000 也只回 6000 行）。
  /// 测试注入小值驱动翻页。
  final int pageSize;
  final String apiBase;

  /// 单请求超时：网络异常时快速失败并提示，避免界面长时间「同步中」。
  final Duration timeout;

  Future<dynamic> _call(String apiName, Map<String, dynamic> params, String fields) async {
    final res = await _http
        .post(
      Uri.parse(apiBase),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'api_name': apiName,
        'token': token,
        'params': params,
        'fields': fields,
      }),
    )
        .timeout(timeout,
            onTimeout: () =>
                throw TushareException(408, '请求超时（${timeout.inSeconds}秒）：$apiName'));
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final code = body['code'];
    if (code != 0) {
      throw TushareException(code as int, (body['msg'] ?? '') as String);
    }
    return body['data'];
  }

  /// 通用翻页：按 offset 拉取直到不足一页。
  Future<List<List<dynamic>>> _callPaged(String apiName, Map<String, dynamic> params, String fields) async {
    final items = <List<dynamic>>[];
    var offset = 0;
    while (true) {
      final data = await _call(apiName, {...params, 'offset': offset, 'limit': pageSize}, fields);
      final page = (data['items'] as List).cast<List<dynamic>>();
      items.addAll(page);
      if (page.length < pageSize) break;
      offset += pageSize;
    }
    return items;
  }

  static const _dailyFields = 'ts_code,trade_date,open,high,low,close,vol,amount';

  /// 交易日历（含开市标记），按日期升序。
  Future<List<({String date, bool isOpen})>> tradeCal(String startDate, String endDate) async {
    final items = await _callPaged(
        'trade_cal', {'exchange': 'SSE', 'start_date': startDate, 'end_date': endDate, 'is_open': '0'},
        'cal_date,is_open');
    final out = [
      for (final it in items) (date: it[0] as String, isOpen: it[1] == '1'),
    ]..sort((a, b) => a.date.compareTo(b.date));
    return out;
  }

  /// 全部上市股票列表。
  Future<List<({String tsCode, String name})>> stockBasic() async {
    final items = await _callPaged(
        'stock_basic', {'list_status': 'L'}, 'ts_code,name');
    return [for (final it in items) (tsCode: it[0] as String, name: it[1] as String)];
  }

  /// 某个交易日的全市场日线。
  Future<List<DailyRow>> daily({required String tradeDate}) async {
    final items = await _callPaged('daily', {'trade_date': tradeDate}, _dailyFields);
    return [
      for (final it in items)
        DailyRow(
          tsCode: it[0] as String,
          tradeDate: it[1] as String,
          open: (it[2] as num).toDouble(),
          high: (it[3] as num).toDouble(),
          low: (it[4] as num).toDouble(),
          close: (it[5] as num).toDouble(),
          vol: (it[6] as num).toDouble(),
          amount: (it[7] as num).toDouble(),
        ),
    ];
  }
}
