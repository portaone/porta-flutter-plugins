import 'package:flutter/material.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_webrtc_noise_suppression/flutter_webrtc_noise_suppression.dart';

void main() => runApp(const ExampleApp());

/// Puts the suppressor into flutter_webrtc's capture slot and takes it out again.
///
/// A peer connection is created first: flutter_webrtc builds its factory, and with it the slot, on
/// its first use. Speech is not processed here - no call is made - the example shows the add-on
/// reaches the slot on a device.
class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  final _bridge = const WebrtcNoiseSuppressionBridge();
  final _lines = <String>[];

  Future<void> _run() async {
    final pc = await createPeerConnection({'iceServers': []});
    final attached = await _bridge.attach();
    final detached = await _bridge.detach();
    await pc.close();
    setState(() => _lines.add('attach: $attached, detach: $detached'));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('flutter_webrtc_noise_suppression')),
        body: ListView(
          children: [for (final line in _lines) ListTile(title: Text(line))],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _run,
          child: const Icon(Icons.play_arrow),
        ),
      ),
    );
  }
}
