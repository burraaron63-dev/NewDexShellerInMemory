LOCAL_PATH := $(call my-dir)

# 脱壳 native 库（仅 Android 5.0~5.1 / API 21~22 需要；6.0~7.1 无内存脱壳方案）。
# 8.0+ 由 Java 层 InMemoryDexClassLoader 处理，无需 native。
include $(CLEAR_VARS)
LOCAL_MODULE    := dalvik_system_DexFile
LOCAL_SRC_FILES := dalvik_system_DexFile.cpp
LOCAL_CPPFLAGS  := -std=c++11 -fexceptions -fno-rtti
LOCAL_LDLIBS    := -llog
include $(BUILD_SHARED_LIBRARY)
