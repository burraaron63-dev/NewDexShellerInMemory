# For more information about using CMake with Android Studio, read the
# documentation: https://d.android.com/studio/projects/add-native-code.html

# Sets the minimum version of CMake required to build the native library.

cmake_minimum_required(VERSION 3.4.1)

# Creates and names a library, sets it as either STATIC
# or SHARED, and provides the relative paths to its source code.
# You can define multiple libraries, and CMake builds them for you.
# Gradle automatically packages shared libraries with your APK.

# 仅在 Android 5.0~7.1 (API 21~25) 需要该 native 库；8.0+ 走 Java InMemoryDexClassLoader。
# yongyejiagu.cpp 已废弃（编排迁至 Java StubApp），不再编译。
add_library( # Sets the name of the library.
        dalvik_system_DexFile

             # Sets the library as a shared library.
             SHARED

             # Provides a relative path to your source file(s).
        dalvik_system_DexFile.cpp)


# Searches for a specified prebuilt library and stores the path as a
# variable. Because CMake includes system libraries in the search path by
# default, you only need to specify the name of the public NDK library
# you want to add. CMake verifies that the library exists before
# completing its build.

find_library( # Sets the name of the path variable.
              log-lib

              # Specifies the name of the NDK library that
              # you want CMake to locate.
              log )

# Specifies libraries CMake should link to your target library. You
# can link multiple libraries, such as libraries you define in this
# build script, prebuilt third-party libraries, or system libraries.

target_link_libraries( # Specifies the target library.
                        dalvik_system_DexFile

                       # Links the target library to the log library
                       # included in the NDK.
                       ${log-lib} )