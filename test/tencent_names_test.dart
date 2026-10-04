
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stock/data/tencent_client.dart';

void main() {
  test('stockNames 批量 60 只/请求，GBK 解码名称', () async {
    // 130 只股票 → 3 次请求（60+60+10）。
    final codes = [
      for (var i = 0; i < 130; i++) '${(600000 + i).toString()}.SH',
    ];
    final requested = <String>[];
    final client = TencentClient(
      http: MockClient((req) async {
        // qt.gtimg.cn 的 q= 在路径里（无 ?），形如 /q=sh600000,sz000581
        final q = req.url.path.substring('/q='.length);
        requested.add(q);
        // 每只返回 GBK 编码的行情串：1~名称~代码~...（逐段编码后拼字节流）
        final bodyBytes = <int>[];
        for (final sym in q.split(',')) {
          bodyBytes.addAll(gbk_bytes.encode(
              'v_$sym="1~测试股票~${sym.substring(2)}~9.48~9.18~9.22~100~100~100~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~0~~20260930161454~0.3~3.2~9.4~9.1~0~0~0~0.4~6.1~~9.4~9.1~3.5~3000~3000~0.4~10.1~8.2~2~0~9.4~5.1~6.3~~~0~138620~42~445~   A~GP-A~0~4~4~6~0~13~8~3~1~11~333~333~0~";'));
        }
        return http.Response.bytes(bodyBytes, 200,
            headers: {'content-type': 'text/html; charset=GBK'});
      }),
    );

    final names = await client.stockNames(codes);

    expect(requested, hasLength(3));
    expect(requested.first.split(','), hasLength(60));
    expect(names['600000.SH'], '测试股票');
    expect(names, hasLength(130));
  });
}
