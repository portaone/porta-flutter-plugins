# PortaOne Flutter plugins

PortaOne's open-source Flutter and Dart packages, published to [pub.dev](https://pub.dev) under PortaOne's verified publisher. Each package lives in its own folder under `packages/`, has its own version, changelog and license, and is released on its own.

## Packages

| Package | pub.dev | Platforms | Description |
|---|---|---|---|
| [flutter_webrtc_noise_suppression](packages/flutter_webrtc_noise_suppression) | [![pub package](https://img.shields.io/pub/v/flutter_webrtc_noise_suppression.svg)](https://pub.dev/packages/flutter_webrtc_noise_suppression) | Android, iOS | Noise suppression (RNNoise) of the voice an app sends through [flutter_webrtc](https://pub.dev/packages/flutter_webrtc) |
| [device_auto_rotate](packages/device_auto_rotate) | not published yet | Android | Reads and watches the Android system auto-rotate setting; `true` on other platforms |

## Repository layout

```
.github/            CI, release and repository settings
packages/<name>/    one package each: everything that ships to pub.dev stays inside its folder
pubspec.yaml        the pub workspace and the melos scripts; never published
analysis_options.yaml  the lints every package includes
```

## Requirements

Working in this repository needs Flutter 3.35 or newer (Dart 3.9): the packages are one [pub workspace](https://dart.dev/tools/pub/workspaces) (Dart 3.6 and newer), and [melos](https://melos.invertase.dev) 8, which runs the scripts below, needs Dart 3.9. What an app needs to use a package is in that package's README and pubspec.

```sh
flutter pub get          # resolves every package of the workspace at once
dart run melos analyze   # flutter analyze in every package
dart run melos format    # fails when a Dart file is not formatted
dart run melos test      # flutter test in every package that has tests
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): the setup, the commit convention, adding a package and how releases are cut.

## License

Each package carries its own license, in its folder. The repository's own files are under the BSD 3-Clause license, see [LICENSE](LICENSE).
