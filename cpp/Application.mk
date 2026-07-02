# 一次编译全部主流 ABI，解决只出 x86 导致真机崩溃的问题。
APP_ABI      := armeabi-v7a arm64-v8a x86 x86_64
# native 回退路径面向 Android 5.0~7.1
APP_PLATFORM := android-21
APP_STL      := c++_static
APP_CPPFLAGS := -std=c++11 -fexceptions
