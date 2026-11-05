# device_auto_rotate

Reads and watches the Android system auto-rotate setting, so an app can check it before it forces an orientation: on Android `SystemChrome.setPreferredOrientations` overrides the system rotation lock. Android only; every other platform answers `true`.

Not published to pub.dev yet.

## Use

```dart
import 'package:device_auto_rotate/device_auto_rotate.dart';

final enabled = await DeviceAutoRotate.isEnabled; // one query
DeviceAutoRotate.stream.listen((enabled) { ... }); // the current value, then every change
```

- `static Future<bool> get DeviceAutoRotate.isEnabled` - one query over a MethodChannel; `true` on any error or a `null` answer.
- `static Stream<bool> get DeviceAutoRotate.stream` - an EventChannel backed by a ContentObserver. It emits the current value as soon as it is listened to, then on every change of the setting.
- Errors on the stream are swallowed without a value: `handleError((_) => true)` drops the error and emits nothing, so a listener keeps the last value it had.

| Platform | Returns | Reason |
|---|---|---|
| Android | `Settings.System.ACCELEROMETER_ROTATION == 1` (`false` if locked or unset, `true` if unreadable) | the app's orientation request would bypass the lock |
| iOS | always `true` | iOS enforces the orientation lock itself and ignores a landscape request while it is on |
| Others | always `true` (`stream` is a single `true`) | fallback for web, desktop and tests |

## Architecture

```
DeviceAutoRotate (lib/device_auto_rotate.dart)
  +-- MethodChannel "device_auto_rotate"          one query
  +-- EventChannel  "device_auto_rotate_stream"   stream
        |
DeviceAutoRotatePlugin.kt (android/)
  +-- onMethodCall()  reads Settings.System.ACCELEROMETER_ROTATION
  +-- onListen()      registers the ContentObserver and sends the current value
  +-- onCancel()      unregisters it
```

The ContentObserver is registered in `onListen()` and unregistered in `onCancel()`. There is no iOS native code: the Dart layer answers there.

## Checks

```sh
flutter test                                                        # the Dart API against a mocked channel
cd example && flutter test integration_test/plugin_integration_test.dart   # on an Android device
```

## License

BSD 3-Clause, see [LICENSE](LICENSE).
