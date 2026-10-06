/// 更新完成提示的状态机（纯 Dart，无原生依赖）。
///
/// 为什么用「版本号对比」而不是监听安装广播：Android 11+ 的
/// REPLACE_EXISTING_PACKAGES 会在替换安装时**由系统结束旧进程**，
/// app 根本收不到 PACKAGE_REPLACED / PackageInstaller 回调
/// （见 test/ 注释与 docs）。所以唯一可靠的观察点是**下次冷启动**。
///
/// 判定逻辑：上次启动时记住 build 号，本次启动发现 build 号变了
/// → 说明中间装过更新 → 提示一次，然后立刻把新号写回去（只提示一次）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:stock/update_notice.dart';

void main() {
  group('shouldShowUpdateNotice', () {
    test('build 号变了 → 需要提示', () {
      expect(shouldShowUpdateNotice(lastSeen: '10', current: '11'), isTrue);
    });

    test('build 号相同 → 不提示（普通冷启动）', () {
      expect(shouldShowUpdateNotice(lastSeen: '11', current: '11'), isFalse);
    });

    test('首次启动（无记录）→ 不提示', () {
      expect(shouldShowUpdateNotice(lastSeen: null, current: '11'), isFalse);
    });

    test('记录是空串 → 视为首次，不提示', () {
      expect(shouldShowUpdateNotice(lastSeen: '', current: '11'), isFalse);
    });

    test('build 号变小（降级安装）→ 也提示：用户确实换了版本', () {
      expect(shouldShowUpdateNotice(lastSeen: '11', current: '10'), isTrue);
    });

    test('两侧都空 → 不提示', () {
      expect(shouldShowUpdateNotice(lastSeen: '', current: ''), isFalse);
    });
  });

  group('UpdateNoticeStore：只提示一次的记账', () {
    test('首次记录当前号，不提示', () {
      final store = _FakeStore(null);
      expect(UpdateNoticeStore(store).consume(current: '10'), isFalse);
      expect(store.value, '10', reason: '首次启动要把当前号记下来，供下次对比');
    });

    test('检测到变化：提示一次并写回新号', () {
      final store = _FakeStore('10');
      final s = UpdateNoticeStore(store);
      expect(s.consume(current: '11'), isTrue);
      expect(store.value, '11', reason: '必须立刻写回，否则下次启动会重复提示');
      expect(s.consume(current: '11'), isFalse, reason: '同一次更新只提示一次');
    });

    test('普通重启：不提示且不重复写', () {
      final store = _FakeStore('11');
      final s = UpdateNoticeStore(store);
      expect(s.consume(current: '11'), isFalse);
      expect(s.consume(current: '11'), isFalse);
    });

    test('连续两次更新：各提示一次', () {
      final store = _FakeStore('10');
      final s = UpdateNoticeStore(store);
      expect(s.consume(current: '11'), isTrue);
      expect(s.consume(current: '12'), isTrue);
      expect(s.consume(current: '12'), isFalse);
    });
  });
}

/// 内存版持久化：生产接 .env 文件，测试用它避免真实 IO。
class _FakeStore implements LastSeenStore {
  _FakeStore(this._v);
  String? _v;
  @override
  String? get value => _v;
  @override
  void write(String v) => _v = v;
}
