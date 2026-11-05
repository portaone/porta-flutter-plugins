# CocoaPods build of the add-on; Swift Package Manager builds it from
# flutter_webrtc_noise_suppression/Package.swift.
# RNNoise v0.2 adds about 5 MB, so it is built only when the app asks for it:
# FLUTTER_WEBRTC_NS_RNNOISE02=1 in the environment of `pod install` (`flutter build ios` runs it).
with_rnnoise02 = ENV['FLUTTER_WEBRTC_NS_RNNOISE02'] == '1'

Pod::Spec.new do |s|
  s.name             = 'flutter_webrtc_noise_suppression'
  s.version          = '0.0.1'
  s.summary          = 'flutter_webrtc add-on: noise suppression (RNNoise) of the captured voice.'
  s.homepage         = 'https://github.com/SERDUN/flutter_webrtc_noise_suppression'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Dmytro Serdun'
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_webrtc_noise_suppression/Sources/**/*.{h,m,c,swift}'
  # RNNoise v0.2 is compiled only through its units/, which rename its globals: its own sources and
  # headers stay out of the pod's file list (they share names with v0.1.1's) and are kept on disk
  # for the units to include by path.
  s.exclude_files    = with_rnnoise02 ?
    'flutter_webrtc_noise_suppression/Sources/NoiseSuppressionRnnoise02/rnnoise/**/*' :
    'flutter_webrtc_noise_suppression/Sources/NoiseSuppressionRnnoise02/**/*'
  s.preserve_paths   = 'flutter_webrtc_noise_suppression/Sources/NoiseSuppressionRnnoise02/rnnoise/**/*'
  s.public_header_files = [
    'flutter_webrtc_noise_suppression/Sources/NoiseSuppression/include/NoiseSuppression/*.h',
    'flutter_webrtc_noise_suppression/Sources/NoiseSuppressionCore/include/*.h',
  ]
  s.dependency 'Flutter'
  s.dependency 'flutter_webrtc'
  # flutter_webrtc is a static framework: a dynamic pod over it is refused by `pod install`.
  s.static_framework = true
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/flutter_webrtc_noise_suppression/Sources/NoiseSuppressionCore/include" "${PODS_TARGET_SRCROOT}/flutter_webrtc_noise_suppression/Sources/NoiseSuppressionCore/rnnoise/include" "${PODS_TARGET_SRCROOT}/flutter_webrtc_noise_suppression/Sources/NoiseSuppressionRnnoise02/include" "${PODS_TARGET_SRCROOT}/flutter_webrtc_noise_suppression/Sources/NoiseSuppressionRnnoise02/compat"',
    'GCC_PREPROCESSOR_DEFINITIONS' => 'common=ns_rnnoise_common' + (with_rnnoise02 ? ' NS_WITH_RNNOISE02' : ''),
    'WARNING_CFLAGS' => '-w',
  }
  s.resource_bundles = {
    'flutter_webrtc_noise_suppression_privacy' => ['flutter_webrtc_noise_suppression/Sources/flutter_webrtc_noise_suppression/PrivacyInfo.xcprivacy']
  }
end
