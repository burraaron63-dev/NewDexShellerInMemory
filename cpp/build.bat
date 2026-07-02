@echo off
REM 一键编译全部 ABI 的脱壳 native 库，输出到 ..\lib\<abi>\
REM 用法： 先设置 NDK 环境变量指向 NDK 根目录，例如：
REM   set NDK=D:\Android\Sdk\ndk\21.4.7075529
REM 然后运行 build.bat

setlocal
cd /d %~dp0

if "%NDK%"=="" (
    echo 错误：请先设置环境变量 NDK 指向 NDK 根目录，例如 set NDK=D:\Android\Sdk\ndk\21.4.7075529
    exit /b 1
)

if exist libs rmdir /s /q libs
if exist obj rmdir /s /q obj

call "%NDK%\ndk-build.cmd" NDK_PROJECT_PATH=. APP_BUILD_SCRIPT=./Android.mk NDK_APPLICATION_MK=./Application.mk NDK_LIBS_OUT=./libs NDK_OUT=./obj
if errorlevel 1 exit /b 1

if not exist ..\lib mkdir ..\lib
xcopy /e /y /i libs\* ..\lib\

echo.
echo [*] 完成。各 ABI 的 libdalvik_system_DexFile.so 已复制到 ..\lib\^<abi^>\
endlocal
