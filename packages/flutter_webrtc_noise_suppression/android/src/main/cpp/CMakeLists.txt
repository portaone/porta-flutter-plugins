cmake_minimum_required(VERSION 3.18.1)
project(flutter_webrtc_noise_suppression C)

# The C sources are one copy, inside the iOS Swift package (SwiftPM cannot reach
# sources outside its package directory); Android builds the same files.
set(SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/../../../../ios/flutter_webrtc_noise_suppression/Sources")
set(CORE "${SOURCES}/NoiseSuppressionCore")
set(RNN "${CORE}/rnnoise/src")
set(R02 "${SOURCES}/NoiseSuppressionRnnoise02")

# RNNoise v0.2 only when the app asks for it: gradle property flutter_webrtc_noise_suppression.rnnoise02.
option(NS_WITH_RNNOISE02 "Build RNNoise v0.2 with its standard model (about 5 MB per ABI)" OFF)
if(NS_WITH_RNNOISE02)

# RNNoise v0.2 is compiled apart, with its own include paths (both versions ship an rnnoise.h),
# and only through its units/, which rename its globals (rnnoise02_prefix.h), so both versions
# link into one library.
add_library(ns_rnnoise02 OBJECT
  "${R02}/ns_rnnoise02.c"
  "${R02}/units/ns02_celt_lpc.c"
  "${R02}/units/ns02_denoise.c"
  "${R02}/units/ns02_kiss_fft.c"
  "${R02}/units/ns02_nnet.c"
  "${R02}/units/ns02_nnet_default.c"
  "${R02}/units/ns02_parse_lpcnet_weights.c"
  "${R02}/units/ns02_pitch.c"
  "${R02}/units/ns02_rnn.c"
  "${R02}/units/ns02_rnnoise_data.c"
  "${R02}/units/ns02_rnnoise_tables.c"
)
target_include_directories(ns_rnnoise02 PRIVATE "${R02}/include" "${R02}/rnnoise/include" "${R02}/rnnoise/src" "${R02}/compat")
target_compile_options(ns_rnnoise02 PRIVATE -O3 -fvisibility=hidden -w)
endif()

add_library(flutter_webrtc_noise_suppression SHARED
  noise_suppressor_jni.c
  "${CORE}/noise_suppressor.c"
  "${RNN}/celt_lpc.c"
  "${RNN}/denoise.c"
  "${RNN}/kiss_fft.c"
  "${RNN}/pitch.c"
  "${RNN}/rnn.c"
  "${RNN}/rnn_data.c"
)

target_include_directories(flutter_webrtc_noise_suppression PRIVATE "${CORE}/include" "${CORE}/rnnoise/include" "${R02}/include")

# RNNoise v0.1.1 keeps its FFT state in a global called `common`; give it a name
# no other library in the process can collide with.
target_compile_definitions(flutter_webrtc_noise_suppression PRIVATE common=ns_rnnoise_common)

# The engine is optimized in debug builds too; only the JNI entry points are
# exported; the vendored RNNoise sources are compiled as they are.
target_compile_options(flutter_webrtc_noise_suppression PRIVATE -O3 -fvisibility=hidden -w)

target_link_libraries(flutter_webrtc_noise_suppression m)

if(NS_WITH_RNNOISE02)
  target_sources(flutter_webrtc_noise_suppression PRIVATE $<TARGET_OBJECTS:ns_rnnoise02>)
  target_compile_definitions(flutter_webrtc_noise_suppression PRIVATE NS_WITH_RNNOISE02)
endif()
