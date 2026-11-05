#include <jni.h>
#include <stdint.h>

#include "noise_suppressor.h"

#define JNI_FN(name) Java_com_portaone_flutter_1webrtc_1noise_1suppression_RnnoiseSuppressor_##name

JNIEXPORT jlong JNICALL JNI_FN(nativeCreate)(JNIEnv* env, jclass cls, jint engine) {
  return (jlong)(intptr_t)ns_create_engine((NsEngine)engine);
}

JNIEXPORT void JNICALL JNI_FN(nativeDestroy)(JNIEnv* env, jclass cls, jlong handle) {
  ns_destroy((NsSuppressor*)(intptr_t)handle);
}

JNIEXPORT void JNICALL JNI_FN(nativeReset)(JNIEnv* env, jclass cls, jlong handle) {
  ns_reset((NsSuppressor*)(intptr_t)handle);
}

JNIEXPORT jint JNICALL JNI_FN(nativeProcess)(JNIEnv* env, jclass cls, jlong handle, jint rate,
                                             jint num_samples, jobject frame, jint byte_offset) {
  uint8_t* base = (uint8_t*)(*env)->GetDirectBufferAddress(env, frame);
  if (base == NULL) return NS_INVALID;
  return (jint)ns_process((NsSuppressor*)(intptr_t)handle, rate, num_samples,
                          (float*)(base + byte_offset), NULL);
}

JNIEXPORT void JNICALL JNI_FN(nativeSetSuppressionLevel)(JNIEnv* env, jclass cls, jlong handle,
                                                         jfloat level) {
  ns_set_suppression_level((NsSuppressor*)(intptr_t)handle, level);
}

JNIEXPORT jfloat JNICALL JNI_FN(nativeTakeVoiceProbability)(JNIEnv* env, jclass cls, jlong handle) {
  return ns_take_voice_probability((NsSuppressor*)(intptr_t)handle);
}

JNIEXPORT jstring JNICALL JNI_FN(nativeEngine)(JNIEnv* env, jclass cls, jint engine) {
  const char* name = ns_engine_name((NsEngine)engine);
  return name == NULL ? NULL : (*env)->NewStringUTF(env, name);
}

JNIEXPORT jint JNICALL JNI_FN(nativeFrameSize)(JNIEnv* env, jclass cls) { return ns_frame_size(); }

JNIEXPORT jint JNICALL JNI_FN(nativeSampleRate)(JNIEnv* env, jclass cls) { return ns_sample_rate(); }
