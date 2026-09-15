// 直连 Key 的多把存储。两处最容易出静默错:
//
//  1. **老用户迁移** —— 旧的单把存法(`nai_access_token` + `nai_login_access_key`)
//     要搬进列表。搬错了用户的令牌就没了,而界面只会显示「未设置」。
//  2. **续期凭证跟着谁** —— 凭证以前是全局一份。多把 Key 下若还是全局一份,
//     续期会拿 A 账号的凭证把 B 那把的令牌换成 A 的,用户毫无察觉。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/auth/token_store.dart';
import 'package:plana_app/core/net/nai_endpoint.dart';

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

Future<NaiKeysNotifier> _store(ProviderContainer c) async {
  await c.read(naiKeysStoreProvider.future);
  return c.read(naiKeysStoreProvider.notifier);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('老用户迁移', () {
    test('旧的单把令牌 + 续期凭证搬进列表,旧键删掉', () async {
      FlutterSecureStorage.setMockInitialValues({
        'nai_access_token': 'pst-abc123456',
        'nai_login_access_key': 'derived-key',
      });
      final c = _container();
      final keys = await c.read(naiKeysStoreProvider.future);

      expect(keys.length, 1);
      expect(keys.first.token, 'pst-abc123456');
      // 凭证跟着这把走,不再是全局一份
      expect(keys.first.accessKey, 'derived-key');

      // 旧键已清:留着的话下次还会再搬一遍,搬出第二把重复的
      const s = FlutterSecureStorage();
      expect(await s.read(key: 'nai_access_token'), isNull);
      expect(await s.read(key: 'nai_login_access_key'), isNull);
      expect(await s.read(key: 'nai_access_keys'), isNotNull);
    });

    test('手贴令牌没有续期凭证:搬过去也是 null,不瞎编', () async {
      FlutterSecureStorage.setMockInitialValues({
        'nai_access_token': 'pst-only',
      });
      final keys = await _container().read(naiKeysStoreProvider.future);
      expect(keys.single.accessKey, isNull);
    });

    test('全新用户:空列表,不写任何东西', () async {
      final keys = await _container().read(naiKeysStoreProvider.future);
      expect(keys, isEmpty);
      expect(
        await const FlutterSecureStorage().read(key: 'nai_access_keys'),
        isNull,
      );
    });

    test('迁移落盘后重开:读新键,内容一致', () async {
      FlutterSecureStorage.setMockInitialValues({
        'nai_access_token': 'pst-abc123456',
      });
      await _container().read(naiKeysStoreProvider.future); // 第一次:迁移
      final again = await _container().read(naiKeysStoreProvider.future);
      expect(again.single.token, 'pst-abc123456');
    });
  });

  group('接口地址跟着每把走', () {
    test('同一串 key 填两个地址 = 两把:那是两台机器上的两个账号', () async {
      final s = await _store(_container());
      final a = await s.add('same-key', endpoint: 'https://relay.a.com');
      final b = await s.add('same-key', endpoint: 'https://relay.b.com/');
      expect(a!.id, isNot(b!.id));
      expect(b.endpoint, 'https://relay.b.com', reason: '尾斜杠要归一掉');

      // 同地址再加一次才是同一把
      final again = await s.add('same-key', endpoint: 'https://relay.a.com');
      expect(again!.id, a.id);
      expect((await s.future).length, 2);
    });

    test('官方那把不落地址字段,落盘再读回来还是官方', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('pst-official');
      await s.add('third-key', endpoint: 'https://relay.example.com');
      final raw = await const FlutterSecureStorage().read(
        key: 'nai_access_keys',
      );
      expect(raw, isNot(contains('"ep":"https://image.novelai.net"')));

      final back = await _container().read(naiKeysStoreProvider.future);
      expect(back[0].endpoint, '');
      expect(back[0].isThirdParty, isFalse);
      expect(back[1].endpoint, 'https://relay.example.com');
      expect(back[1].isThirdParty, isTrue);
    });

    test('填成官方地址本身 = 官方,不算第三方', () async {
      final s = await _store(_container());
      final k = await s.add('tok', endpoint: '$kNaiOfficialBase/');
      expect(k!.endpoint, '');
      expect(k.isThirdParty, isFalse);
    });
  });

  group('增删改', () {
    test('add 追加;第一把自动成为主账号', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('tok-a');
      await s.add('tok-b');

      final now = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in now) k.token], ['tok-a', 'tok-b']);
      expect([for (final k in now) k.primary], [true, false]);
    });

    // 同一把存两遍会被当成两个账号放行两条并发 —— 正是 429 的成因。
    test('同一个令牌不重复添加,只并进已有那把', () async {
      final c = _container();
      final s = await _store(c);
      final first = await s.add('tok-a');
      final again = await s.add('tok-a', accessKey: 'ak');

      expect(c.read(naiKeysStoreProvider).value!.length, 1);
      expect(again!.id, first!.id); // id 不变,重命名/主 Key 不会错位
      expect(again.accessKey, 'ak'); // 补上了凭证
    });

    test('存满之后加不进去(返回 null)', () async {
      final c = _container();
      final s = await _store(c);
      for (var i = 0; i < kMaxNaiKeys; i++) {
        expect(await s.add('tok-$i'), isNotNull);
      }
      expect(await s.add('tok-overflow'), isNull);
      expect(c.read(naiKeysStoreProvider).value!.length, kMaxNaiKeys);
    });

    // 换主账号**不动顺序** —— 早先是挪到首位,于是在列表里选中一行它就窜到
    // 顶上去,跟单选钮的行为完全不搭(单选钮从不让选项换位置)。
    test('makePrimary 只挪标记,列表顺序不动', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      await s.add('c');
      final third = c.read(naiKeysStoreProvider).value![2];

      await s.makePrimary(third.id);
      final now = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in now) k.token], ['a', 'b', 'c']);
      expect([for (final k in now) k.primary], [false, false, true]);
      expect(naiPrimaryKey(now)!.token, 'c');
    });

    // 拖动排序改的是列表顺序,主账号标记跟着那把 Key 走 —— 拖动不该换人。
    test('reorder 挪位置,主账号跟着那把 Key 走', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      await s.add('c');
      await s.makePrimary(c.read(naiKeysStoreProvider).value![2].id);

      await s.reorder(2, 0); // c 拖到首位
      final now = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in now) k.token], ['c', 'a', 'b']);
      expect(naiPrimaryKey(now)!.token, 'c');

      await s.reorder(0, 2); // 再拖回末位
      final back = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in back) k.token], ['a', 'b', 'c']);
      expect(naiPrimaryKey(back)!.token, 'c');
    });

    // 越界/原地不动的下标不该把列表搅乱,更不该抛。
    test('reorder 下标越界或原地不动:列表不变', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');

      for (final (from, to) in const [(0, 0), (-1, 1), (0, 5), (9, 0)]) {
        await s.reorder(from, to);
        expect(
          [for (final k in c.read(naiKeysStoreProvider).value!) k.token],
          ['a', 'b'],
        );
      }
    });

    // 顺序落盘了才算数:重启回来还得是拖好的那个顺序。
    test('reorder 的顺序会落盘', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      await s.add('c');
      await s.reorder(0, 2);

      final again = await _container().read(naiKeysStoreProvider.future);
      expect([for (final k in again) k.token], ['b', 'c', 'a']);
    });

    // 出图顺序才认主账号:它排头,其余按列表顺序。
    test('出图取 Key:主账号排头,其余保持列表顺序', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      await s.add('c');
      await s.makePrimary(c.read(naiKeysStoreProvider).value![2].id);

      final order = naiKeysForGenerate(
        c.read(naiKeysStoreProvider).value!,
        paid: false,
      );
      expect([for (final k in order) k.token], ['c', 'a', 'b']);
    });

    // 续期换的是令牌本身,id / 名字 / 凭证都得留着,否则续一次就「换了个人」。
    test('replaceToken:换令牌不动 id、名字、凭证', () async {
      final c = _container();
      final s = await _store(c);
      final k = (await s.add('old-jwt', label: '主号', accessKey: 'ak'))!;

      await s.replaceToken(k.id, 'new-jwt');
      final after = c.read(naiKeysStoreProvider).value!.single;
      expect(after.token, 'new-jwt');
      expect(after.id, k.id);
      expect(after.label, '主号');
      expect(after.accessKey, 'ak');
    });

    test('rename / remove / clearAll', () async {
      final c = _container();
      final s = await _store(c);
      final a = (await s.add('a'))!;
      await s.add('b');

      await s.rename(a.id, '  小号  '); // 顺手 trim
      expect(c.read(naiKeysStoreProvider).value!.first.label, '小号');

      await s.remove(a.id);
      expect(c.read(naiKeysStoreProvider).value!.single.token, 'b');

      await s.clearAll();
      expect(c.read(naiKeysStoreProvider).value, isEmpty);
    });
  });

  group('对老接口的兼容', () {
    test('tokenProvider = 主账号;naiKeysProvider = 全部', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');

      expect(await c.read(tokenProvider.future), 'a');
      expect(await c.read(naiKeysProvider.future), ['a', 'b']);
    });

    test('一把都没存:主账号为 null,列表为空', () async {
      final c = _container();
      expect(await c.read(tokenProvider.future), isNull);
      expect(await c.read(naiKeysProvider.future), isEmpty);
    });

    // 引导页/邮箱登录都走 save():它的语义是「把这把加进来」,不是「顶掉原来那把」。
    test('save() 是追加,不顶掉已有的', () async {
      final c = _container();
      await c.read(tokenProvider.future);
      await c.read(tokenProvider.notifier).save('first');
      await c.read(tokenProvider.notifier).save('second', accessKey: 'ak2');

      final keys = c.read(naiKeysStoreProvider).value!;
      expect([for (final k in keys) k.token], ['first', 'second']);
      expect(keys[1].accessKey, 'ak2');
      expect(await c.read(tokenProvider.future), 'first'); // 主账号还是头一把
    });

    test('save(空串) 等同清空', () async {
      final c = _container();
      await c.read(tokenProvider.future);
      await c.read(tokenProvider.notifier).save('a');
      await c.read(tokenProvider.notifier).save('   ');
      expect(c.read(naiKeysStoreProvider).value, isEmpty);
    });
  });

  // 主账号(首位)是「一定会被用到」的那个:出图必参与、点数必可花。
  // 这条不变式收在存储层,换主账号/删主账号/首次添加都由它兜住。
  group('主账号强制全开', () {
    test('主账号那把的两个开关被拨回真', () async {
      final c = _container();
      final s = await _store(c);
      await s.add('a');
      await s.add('b');
      final second = c.read(naiKeysStoreProvider).value![1];

      // 副账号可以关
      await s.setFlags(second.id, forGenerate: false, usePoints: false);
      expect(c.read(naiKeysStoreProvider).value![1].forGenerate, isFalse);

      // 提成主账号 → 立刻全开(位置不动,还在第二个)
      await s.makePrimary(second.id);
      final now = c.read(naiKeysStoreProvider).value![1];
      expect(now.id, second.id);
      expect(now.primary, isTrue);
      expect(now.forGenerate, isTrue);
      expect(now.usePoints, isTrue);
    });

    test('关不掉主账号自己的开关', () async {
      final c = _container();
      final s = await _store(c);
      final a = (await s.add('a'))!;

      await s.setFlags(a.id, forGenerate: false, usePoints: false);
      final now = c.read(naiKeysStoreProvider).value!.single;
      expect(now.forGenerate, isTrue);
      expect(now.usePoints, isTrue);
    });

    // 删掉主账号 → 下一把顶上来,它的开关也得跟着全开。
    test('删掉主账号:接班的那把自动全开', () async {
      final c = _container();
      final s = await _store(c);
      final a = (await s.add('a'))!;
      final b = (await s.add('b'))!;
      await s.setFlags(b.id, forGenerate: false);

      await s.remove(a.id);
      final now = c.read(naiKeysStoreProvider).value!.single;
      expect(now.id, b.id);
      expect(now.forGenerate, isTrue);
    });

    // 上一版的总开关 `off` 并进了 forGenerate:那时「停用」就是「完全不用」。
    test('老数据里的 off 读成不参与出图', () async {
      FlutterSecureStorage.setMockInitialValues({
        'nai_access_keys':
            '[{"id":"k0","token":"a"},{"id":"k1","token":"b","off":true}]',
      });
      final keys = await _container().read(naiKeysStoreProvider.future);
      expect(keys.first.forGenerate, isTrue);
      expect(keys[1].forGenerate, isFalse);
    });
  });

  test('naiKeyTitle:起过名用名字,没起过用尾号', () {
    const a = NaiKey(id: '1', token: 'pst-verylongtoken123456', label: '主号');
    const b = NaiKey(id: '2', token: 'pst-verylongtoken123456');
    expect(naiKeyTitle(a), '主号');
    expect(naiKeyTitle(b), '…123456');
  });
}
