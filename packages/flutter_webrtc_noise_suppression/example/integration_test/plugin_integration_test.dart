import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc_noise_suppression/flutter_webrtc_noise_suppression.dart';
import 'package:integration_test/integration_test.dart';

/// The plugin's test engine: 16 kHz frames left as they are, so what comes back is the adapter's.
const identity16k = WebrtcNoiseSuppressionEngine.testIdentity16k;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const bridge = WebrtcNoiseSuppressionBridge();
  setUpAll(bridge.registerTestEngines);

  testWidgets('the suppressor goes into the capture slot and comes out again', (tester) async {
    // flutter_webrtc builds its factory, and the slot with it, on its first use.
    final pc = await createPeerConnection({'iceServers': []});

    expect(await bridge.attach(), isTrue);
    expect(await bridge.attach(), isTrue, reason: 'a second attach keeps the one in the slot');
    expect(await bridge.detach(), isTrue);
    expect(await bridge.detach(), isFalse, reason: 'nothing left to take out');

    await pc.close();
  });

  testWidgets('a chain of two engines goes into the slot', (tester) async {
    final pc = await createPeerConnection({'iceServers': []});

    expect(await bridge.attach(engines: const [WebrtcNoiseSuppressionEngine.rnnoise, identity16k]), isTrue);
    expect(await bridge.attach(engines: const [identity16k]), isTrue, reason: 'another chain replaces it');
    expect(await bridge.detach(), isTrue);

    await expectLater(
      bridge.attach(engines: const [WebrtcNoiseSuppressionEngine.testUnknown]),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'unknown_engine')),
    );

    await pc.close();
  });

  testWidgets('RNNoise v0.2 goes into the slot beside v0.1.1', (tester) async {
    final pc = await createPeerConnection({'iceServers': []});

    expect(await bridge.attach(engines: const [WebrtcNoiseSuppressionEngine.rnnoise02]), isTrue);
    expect(await bridge.detach(), isTrue);

    await pc.close();
  });

  testWidgets('the suppression level is taken by the slot', (tester) async {
    final pc = await createPeerConnection({'iceServers': []});

    expect(await bridge.attach(suppressionLevel: 0.5), isTrue);
    await bridge.setSuppressionLevel(0.25);
    expect(await bridge.attach(suppressionLevel: 1.0), isTrue, reason: 'the same chain takes the level');
    expect(await bridge.detach(), isTrue);
    await bridge.setSuppressionLevel(1.0);

    await pc.close();
  });

  testWidgets('an attach overtaken while it creates answers false', (tester) async {
    final pc = await createPeerConnection({'iceServers': []});

    final first = bridge.attach();
    final second = bridge.attach(engines: const [identity16k]);
    expect(await first, isFalse, reason: 'the later attach wins');
    expect(await second, isTrue);

    final third = bridge.attach();
    expect(await bridge.detach(), isTrue, reason: 'the identity chain was still there');
    expect(await third, isFalse, reason: 'the detach came while it was created');
    expect(await bridge.detach(), isFalse);

    // The chain in the slot asked again while another one is created: the one in the slot stays.
    expect(await bridge.attach(), isTrue);
    final other = bridge.attach(engines: const [identity16k]);
    expect(await bridge.attach(), isTrue);
    expect(await other, isFalse, reason: 'the attach of the chain already there came later');
    expect(await bridge.attach(engines: const [identity16k]), isTrue, reason: 'another chain goes in as usual');
    expect(await bridge.detach(), isTrue);

    await pc.close();
  });

  testWidgets('every engine runs on this device within the frame budget', (tester) async {
    for (final engine in const [WebrtcNoiseSuppressionEngine.rnnoise, WebrtcNoiseSuppressionEngine.rnnoise02]) {
      final m = await bridge.measure(engine: engine);
      // The lines a device run is read for: the time per frame on this phone.
      debugPrint('measure: $m');
      expect(m.attenuationDb, greaterThan(10), reason: '$m');
      expect(m.p99Us, lessThan(10000), reason: 'a 10 ms frame must take less than 10 ms: $m');
      expect(m.latencyMs, 0);
    }

    // White noise through a 16 kHz engine that changes nothing: the band above 7.2 kHz is filtered
    // out (about 5 dB of white noise), the rest comes back, one engine frame and the filters later.
    final adapted = await bridge.measure(engine: identity16k);
    debugPrint('measure: $adapted');
    expect(adapted.attenuationDb, inInclusiveRange(3, 8), reason: '$adapted');
    expect(adapted.p99Us, lessThan(10000), reason: '$adapted');
    expect(adapted.latencyMs, inInclusiveRange(10, 15), reason: '$adapted');
  });
}
