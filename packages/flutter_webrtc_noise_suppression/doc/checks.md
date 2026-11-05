# Checks

```sh
make test                 # the C core on the host: white noise attenuated by more than 10 dB, bad frames untouched
flutter analyze && flutter test
cd example/android && ./gradlew :flutter_webrtc_noise_suppression:testDebugUnitTest   # the format adapter and the registry on the JVM (JDK 17-21)
cd example && FLUTTER_WEBRTC_NS_RNNOISE02=1 flutter test integration_test   # on a device (the example's Android build enables RNNoise v0.2 in its gradle.properties; iOS needs the variable): attach and detach, a chain with the test engine, an unknown engine, an attach overtaken, measure of both
cd example && flutter build ios --config-only --debug && cd ios && xcodebuild test -workspace Runner.xcworkspace \
  -scheme Runner -destination id=<iPhone udid> -only-testing:RunnerTests DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates
# the format adapter in Swift and the suppressor on an iPhone
```
