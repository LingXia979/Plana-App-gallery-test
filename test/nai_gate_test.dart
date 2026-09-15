// 直连 NAI 的并发闸门。NAI 按账号限流 —— 同一把 Key 同时打两个请求,第二个
// 直接 429,而且这是条**静默错**:用户看到的只是「第二张失败了」。
//
// 闸门是全 app 共用的,吃这条限额的不止生成:图库 NAI 超分、灵感页标签预览打的
// 是同一个账号。所以这里既验「按可用 Key 放行」,也验「谁来都得排同一个队」,
// 外加每把自己的三个开关和「同时出几张」的设定。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plana_app/core/auth/nai_keys.dart';
import 'package:plana_app/core/net/gen_abort.dart';
import 'package:plana_app/core/net/nai_gate.dart';

/// 只读的 Key 列表 —— 闸门只 read,不需要真的存储。
class _FakeKeys extends NaiKeysNotifier {
  _FakeKeys(this._seed);
  final List<NaiKey> _seed;
  @override
  Future<List<NaiKey>> build() async => _seed;
}

NaiKey _k(
  String id, {
  bool gen = true,
  bool pts = true,
  bool primary = false,
}) => NaiKey(
  id: id,
  token: 'tok-$id',
  primary: primary,
  forGenerate: gen,
  usePoints: pts,
);

/// 主账号在前的一组全开 Key。
List<NaiKey> _plainN(int n) => [
  for (var i = 0; i < n; i++) _k('$i', primary: i == 0),
];

NaiGate _gate(List<NaiKey> keys) {
  final c = ProviderContainer(
    overrides: [naiKeysStoreProvider.overrideWith(() => _FakeKeys(keys))],
  );
  addTearDown(c.dispose);
  c.read(naiKeysStoreProvider); // 闸门读的是 .future,先预热到有值
  return c.read(naiGateProvider);
}

List<NaiKey> _plain(int n) => _plainN(n);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('按 Key 数放行', () {
    test('一把 Key:第二个必须等第一个放槽', () async {
      final gate = _gate(_plain(1));

      final a = await gate.acquire();
      expect(a.token, 'tok-0');

      var bDone = false;
      final b = gate.acquire().then((p) {
        bDone = true;
        return p;
      });

      // 放槽之前 b 只能挂着 —— 挂不住就是 429 的来路
      await Future<void>.delayed(Duration.zero);
      expect(bDone, isFalse);
      expect(gate.busyCount, 1);

      gate.release(a.slot);
      expect((await b).token, 'tok-0');
    });

    test('三把 Key:三条同时放行且各用各的,第四条才排队', () async {
      final gate = _gate(_plain(3));

      final got = [
        await gate.acquire(),
        await gate.acquire(),
        await gate.acquire(),
      ];
      // 同一把 Key 不能发两张通行证,否则等于自己打自己
      expect({for (final p in got) p.token}, {'tok-0', 'tok-1', 'tok-2'});

      var fourth = false;
      unawaited(gate.acquire().then((_) => fourth = true));
      await Future<void>.delayed(Duration.zero);
      expect(fourth, isFalse);

      gate.release(got[1].slot);
      await Future<void>.delayed(Duration.zero);
      expect(fourth, isTrue);
    });

    // 一把都没存时不能把人卡死在等位里 —— 那种卡法在界面上就是「点了没反应」。
    // 给一张空通行证,让调用方去报「没有令牌」。
    test('一把都没存:立刻返回空通行证,不排队', () async {
      final gate = _gate(const []);
      final p = await gate.acquire();
      expect(p.token, isNull);
      expect(p.slot, -1);
    });
  });

  group('副账号自己的开关', () {
    test('取消了并发生成的不参与', () async {
      final gate = _gate([
        _k('0', primary: true),
        _k('1', gen: false),
        _k('2'),
      ]);
      expect(await gate.limit(), 2);
      expect((await gate.acquire()).token, 'tok-0');
      expect((await gate.acquire()).token, 'tok-2');
    });

    // 白嫖号的点数不该被偷偷花掉:免费单照用,付费单跳过。
    test('取消了花点数的副账号只接免费单', () async {
      final gate = _gate([_k('0', primary: true), _k('1', pts: false)]);

      // 免费单:两把都能用,主账号先出
      final a = await gate.acquire();
      final b = await gate.acquire();
      expect({a.token, b.token}, {'tok-0', 'tok-1'});
      gate.release(a.slot);
      gate.release(b.slot);

      // 付费单:1 号被跳过,只剩主账号
      final p1 = await gate.acquire(paid: true);
      expect(p1.token, 'tok-0');
      var second = false;
      unawaited(gate.acquire(paid: true).then((_) => second = true));
      await Future<void>.delayed(Duration.zero);
      expect(second, isFalse);
    });

    // 槽位记的是**全局下标**。若按「可用集合内的序号」记账,免费单占了第 0 把、
    // 付费单看到的可用集合首位是第 1 把也叫序号 0 —— 两条会认成同一个槽,
    // 于是要么误放行、要么误排队。
    test('免费单与付费单的槽位不串台', () async {
      final gate = _gate([_k('0', primary: true), _k('1', pts: false)]);

      final free = await gate.acquire(paid: true); // 付费只能用主账号,占住第 0 把
      expect(free.token, 'tok-0');

      final other = await gate.acquire(); // 免费单:第 1 把仍空着,应当放行
      expect(other.token, 'tok-1');
      expect(gate.busyCount, 2);
    });

    // 主账号的两个开关由存储层强制为真,所以「一把可用的都没有」只可能是
    // 一把都没存。副账号全关掉,主账号照样能出图。
    test('副账号全关掉:主账号照样出图', () async {
      final gate = _gate([
        _k('0', primary: true),
        _k('1', gen: false),
        _k('2', gen: false),
      ]);
      expect(await gate.limit(), 1);
      expect((await gate.acquire()).token, 'tok-0');
    });
  });

  // 并发上限没有单独设置:就是主账号 + 勾了并发生成的副账号的个数。
  group('并发上限 = 能出图的把数', () {
    test('四把全开 → 4', () async {
      expect(await _gate(_plain(4)).limit(), 4);
    });

    test('关掉两把副账号 → 2', () async {
      final gate = _gate([
        _k('0', primary: true),
        _k('1', gen: false),
        _k('2'),
        _k('3', gen: false),
      ]);
      expect(await gate.limit(), 2);
    });

    test('一把都没存 → 给 1,不把人卡死在等位里', () async {
      expect(await _gate(const []).limit(), 1);
    });
  });

  group('取消与成对释放', () {
    test('等位期间被取消:返回 -1,不占槽', () async {
      final gate = _gate(_plain(1));
      final held = await gate.acquire();

      final abort = GenAbort();
      final waiting = gate.acquire(abort: abort);
      await Future<void>.delayed(Duration.zero);

      abort.abort();
      expect((await waiting).slot, -1);

      gate.release(held.slot);
      expect(gate.busyCount, 0);
    });

    // 取消留下的空壳 completer 不能把唤醒吞掉:release 要一路跳到真正在等的那个。
    test('取消者留下的空壳不吞唤醒', () async {
      final gate = _gate(_plain(1));
      final held = await gate.acquire();

      final abort = GenAbort();
      unawaited(gate.acquire(abort: abort));
      await Future<void>.delayed(Duration.zero);
      abort.abort(); // 空壳留在等位队列里

      var live = false;
      unawaited(gate.acquire().then((_) => live = true));
      await Future<void>.delayed(Duration.zero);

      gate.release(held.slot);
      await Future<void>.delayed(Duration.zero);
      expect(live, isTrue);
    });

    // run() 是超分 / 标签预览用的成对包装:body 抛了也必须把槽还回来,
    // 漏还一次闸门就永久焊死,之后所有生成都卡在等位。
    test('run():body 抛异常也把槽还回来', () async {
      final gate = _gate(_plain(1));

      await expectLater(
        gate.run((_, _) async => throw StateError('boom')),
        throwsStateError,
      );
      expect(gate.busyCount, 0);

      expect(await gate.run((t, _) async => t), 'tok-0');
      expect(gate.busyCount, 0);
    });

    test('run() 与生成排同一个队', () async {
      final gate = _gate(_plain(1));
      final gen = await gate.acquire(); // 假装一条生成正在跑

      var upscaled = false;
      unawaited(gate.run((_, _) async => upscaled = true));
      await Future<void>.delayed(Duration.zero);
      expect(upscaled, isFalse); // 超分得等生成让位,不能自己开一路打过去

      gate.release(gen.slot);
      await Future<void>.delayed(Duration.zero);
      expect(upscaled, isTrue);
    });
  });
}
