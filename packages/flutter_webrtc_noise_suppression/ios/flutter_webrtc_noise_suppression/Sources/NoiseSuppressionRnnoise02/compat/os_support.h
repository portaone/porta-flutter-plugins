/* RNNoise v0.2's vec_neon.h includes os_support.h, which the v0.2 release does not ship (a header
 * of Opus); later RNNoise includes common.h instead. This plugin's stand-in gives the one macro
 * vec_neon.h takes from it. */
#ifndef NS_RNNOISE02_OS_SUPPORT_H
#define NS_RNNOISE02_OS_SUPPORT_H
#include <string.h>
#define OPUS_CLEAR(dst, n) (memset((dst), 0, (n) * sizeof(*(dst))))
#endif
