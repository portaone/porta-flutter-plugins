import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_webrtc_noise_suppression/flutter_webrtc_noise_suppression.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(WebrtcNoiseSuppressionBridge.channelName);
  late List<MethodCall> calls;
  Object? answer;

  setUp(() {
    calls = [];
    answer = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('attach and detach reach the native side by name', () async {
    const bridge = WebrtcNoiseSuppressionBridge();

    expect(await bridge.attach(), isTrue);
    expect(await bridge.detach(), isTrue);
    expect(calls.map((c) => c.method), ['attach', 'detach']);
    expect(calls.first.arguments, {
      'engines': ['rnnoise'],
      'suppressionLevel': 1.0,
    });
  });

  test('attach sends a chain in its order', () async {
    const bridge = WebrtcNoiseSuppressionBridge();

    await bridge.attach(
      engines: const [WebrtcNoiseSuppressionEngine.rnnoise, WebrtcNoiseSuppressionEngine.testIdentity16k],
      dumpInputSeconds: 30,
    );
    expect(calls.single.arguments, {
      'engines': ['rnnoise', 'test-identity-16k'],
      'suppressionLevel': 1.0,
      'dumpInputSeconds': 30,
    });
  });

  test('registerTestEngines reaches the native side', () async {
    answer = null;
    const bridge = WebrtcNoiseSuppressionBridge();

    await bridge.registerTestEngines();
    expect(calls.single.method, 'registerTestEngines');
  });

  test('the suppression level reaches the native side', () async {
    answer = null;
    const bridge = WebrtcNoiseSuppressionBridge();

    await bridge.attach(suppressionLevel: 0.25);
    await bridge.setSuppressionLevel(0.75);
    expect(calls.first.arguments, containsPair('suppressionLevel', 0.25));
    expect(calls.last.method, 'setSuppressionLevel');
    expect(calls.last.arguments, {'level': 0.75});
  });

  test('vadStream reads the native events as doubles', () async {
    const vad = EventChannel(WebrtcNoiseSuppressionBridge.vadChannelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      vad,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          events.success(0.25);
          events.success(1);
          events.endOfStream();
        },
      ),
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(vad, null),
    );

    expect(await const WebrtcNoiseSuppressionBridge().vadStream.toList(), [0.25, 1.0]);
  });

  test('a level outside 0..1 is refused before the native side', () async {
    const bridge = WebrtcNoiseSuppressionBridge();

    expect(() => bridge.setSuppressionLevel(1.5), throwsRangeError);
    expect(() => bridge.setSuppressionLevel(double.nan), throwsRangeError);
    expect(() => bridge.attach(suppressionLevel: -0.1), throwsRangeError);
    expect(calls, isEmpty);
  });

  test('measure names the engine and reads the native answer', () async {
    answer = {'engine': 'rnnoise 0.1.1', 'meanUs': 331, 'p99Us': 465.5, 'attenuationDb': 15.1, 'latencyMs': 0};
    const bridge = WebrtcNoiseSuppressionBridge();

    final m = await bridge.measure(engine: WebrtcNoiseSuppressionEngine.rnnoise);
    expect(calls.single.method, 'measure');
    expect(calls.single.arguments, {'engine': 'rnnoise'});
    expect(m.engine, 'rnnoise 0.1.1');
    expect(m.meanUs, 331);
    expect(m.p99Us, 465.5);
    expect(m.attenuationDb, 15.1);
    expect(m.latencyMs, 0);
  });

  test('a native side that answers nothing counts as not attached', () async {
    answer = null;
    const bridge = WebrtcNoiseSuppressionBridge();

    expect(await bridge.attach(), isFalse);
  });
}
