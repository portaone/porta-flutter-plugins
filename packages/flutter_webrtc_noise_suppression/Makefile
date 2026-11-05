# Host checks of the C core. `make test` needs a C compiler only.
SRC_DIR := ios/flutter_webrtc_noise_suppression/Sources
CORE := $(SRC_DIR)/NoiseSuppressionCore
RNN := $(CORE)/rnnoise/src
R02 := $(SRC_DIR)/NoiseSuppressionRnnoise02
R02_SRC := $(R02)/ns_rnnoise02.c $(wildcard $(R02)/units/*.c)
CORE_SRC := $(CORE)/noise_suppressor.c $(RNN)/celt_lpc.c $(RNN)/denoise.c $(RNN)/kiss_fft.c \
            $(RNN)/pitch.c $(RNN)/rnn.c $(RNN)/rnn_data.c
CFLAGS ?= -O2
BUILD := build/native

.PHONY: test clean
# Both builds: with RNNoise v0.2 (an app that asks for it) and without (the default).
test: $(BUILD)/noise_suppressor_test $(BUILD)/noise_suppressor_test_v01
	$(BUILD)/noise_suppressor_test
	$(BUILD)/noise_suppressor_test_v01

# RNNoise v0.2 is compiled apart, with its own include paths (both versions ship an rnnoise.h), and
# only through its units/, which rename its globals; see rnnoise02_prefix.h.
$(BUILD)/rnnoise02.a: $(R02_SRC) $(R02)/rnnoise02_prefix.h
	mkdir -p $(BUILD)/r02
	cd $(BUILD)/r02 && for f in $(abspath $(R02_SRC)); do \
	  $(CC) $(CFLAGS) -c -I$(abspath $(R02)/rnnoise/include) -I$(abspath $(R02)/rnnoise/src) -I$(abspath $(R02)/compat) -I$(abspath $(R02)/include) -w $$f || exit 1; done
	ar rcs $@ $(BUILD)/r02/*.o

$(BUILD)/noise_suppressor_test: test/native/noise_suppressor_test.c $(CORE_SRC) $(CORE)/include/noise_suppressor.h $(BUILD)/rnnoise02.a
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I$(CORE)/include -I$(CORE)/rnnoise/include -I$(R02)/include -DNS_WITH_RNNOISE02 -Dcommon=ns_rnnoise_common \
	  -w test/native/noise_suppressor_test.c $(CORE_SRC) $(BUILD)/rnnoise02.a -lm -o $@

$(BUILD)/noise_suppressor_test_v01: test/native/noise_suppressor_test.c $(CORE_SRC) $(CORE)/include/noise_suppressor.h
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -I$(CORE)/include -I$(CORE)/rnnoise/include -Dcommon=ns_rnnoise_common \
	  -w test/native/noise_suppressor_test.c $(CORE_SRC) -lm -o $@

clean:
	rm -rf build
