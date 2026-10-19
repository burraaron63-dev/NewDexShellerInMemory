**English** | [中文](README_CN.md)

# dexshellerInMemory

A one-command DEX packer (shelling tool) for Android APKs that protects the
original `classes*.dex` by hiding them (encrypted) inside a *shell* DEX and
loading them back **in memory** at runtime — the original DEX is never written
to disk in plaintext.

It is the in-memory variant of
[dexsheller](https://github.com/yongyecc/dexsheller): same idea, plus an
in-memory DEX loading step so the original code is decrypted and loaded straight
from memory.

> ⚠️ For learning / security-research use. The payload is obfuscated with a
> single-byte XOR (`0xFF`), which is trivially reversible — treat it as tamper
> deterrence, not real cryptographic protection.

---

## How it works (v3: no-resource repackaging)

Earlier versions used `apktool` to decompile → edit the manifest → recompile,
which frequently failed at the `aapt2` resource-link stage on real-world APKs.
v3 drops that entirely:

1. **Read the original app name.** Parse the binary `AndroidManifest.xml`
   directly (`axml_editor.py`) and read `<application android:name>`; save it
   into the shell's `Config.java` so the shell can start the real `Application`
   later.
2. **Compile the shell DEX.** `javac` the shell sources under
   `shellApplicationSourceCode/`, then `dx` them into `shell.dex`.
3. **Hide the original DEX(es).** Collect every `classes*.dex` from the input
   APK, XOR-encrypt each, and append them to the tail of the shell DEX in this
   container format, then recompute the shell DEX header
   (`file_size` / `signature` / `checksum`) so the whole `classes.dex` stays a
   valid DEX:

   ```
   [magic "YYJG" (4, LE)] [count (4, LE)]
   repeat count times: [len_i (4, LE)] [XOR-encrypted original dex_i]
   [tailLen (4, LE)]   <- last 4 bytes of the file = bytes from magic to last dex
   ```

4. **Repackage the APK (no decompile, no resource recompile).** In-place edit
   the binary manifest (`android:name` → the shell `StubApp`), drop the original
   `classes*.dex`, write the shell `classes.dex`, append the per-ABI unpack
   `.so`, and strip the old signature. Everything else (`resources.arsc`,
   `res/`, `assets/`, original `lib/`, …) is copied byte-for-byte with its
   original compression preserved.
5. **Align & sign.** `zipalign -p 4` then `apksigner`.

At runtime `StubApp.attachBaseContext` reverses it: extract and decrypt the
payload DEXes (`FileUtils.extractPayloadDexes`), build an in-memory
`ClassLoader`, swap it into the current `LoadedApk.mClassLoader`, then start the
original `Application`.

---

## Compatibility

The in-memory loader is dispatched by API level (`StubApp.buildInMemoryClassLoader`):

| Android | API | Loading path | Needs native `.so` |
| --- | --- | --- | --- |
| 10 ~ 15+ | 29+ | `InMemoryDexClassLoader(ByteBuffer[], parent)` | No |
| 8.0 ~ 8.1 | 26~28 | `InMemoryDexClassLoader` (single buffer) with **merged `dexElements`** so multi-dex cross-references resolve | No |
| 6.0 ~ 7.1 | 23~25 | **Unsupported** — the native `vector + long` cookie and 5-arg `Object/DexFile` `defineClass` ABI are incompatible | - |
| 5.0 ~ 5.1 | 21~22 | Native `OpenMemory` fallback (`MyDexClassLoader` + `libdalvik_system_DexFile.so`) | Yes |
| < 5.0 | < 21 | Unsupported (Dalvik) | - |

Most in-the-field devices (Android 8+) use the official API and are stable;
native is only an old-device fallback.

---

## Requirements

- **JDK** (for `javac` / `apksigner`). On macOS make sure the real JDK `javac`
  is on `PATH`, not the Xcode stub (e.g. `export PATH="$(/usr/libexec/java_home)/bin:$PATH"`).
- **Android SDK** build-tools that still ship `dx` (removed in build-tools 31+),
  e.g. `sdkmanager "build-tools;30.0.3"`, plus `apksigner` and `zipalign` from
  any build-tools, and an `android.jar` platform.
- **Android NDK** — only if you need to rebuild the native `.so` for the
  5.0/5.1 fallback.

The Python side uses the standard library only (no third-party packages).

---

## Usage

```bash
python sheller.py -f app.apk      # -> result.apk
```

Tool paths can be overridden by environment variables (defaults point to Windows
SDK paths):

```bash
export ANDROID_JAR=.../platforms/android-33/android.jar
export DX_JAR=.../build-tools/30.0.3/lib/dx.jar
export APKSIGNER_JAR=.../build-tools/35.0.1/lib/apksigner.jar
export ZIPALIGN=.../build-tools/35.0.1/zipalign
python sheller.py -f app.apk
```

Or let the helper auto-detect the toolchain and run the whole flow:

```bash
./run_test.sh app.apk             # detects tools, (re)builds venv, produces result.apk
```

---

## Building the native fallback (`.so`)

Only needed to cover Android 5.0/5.1. Build all ABIs at once:

```bash
cd cpp
NDK=/path/to/android-ndk ./build.sh     # Windows: build.bat (set NDK first)
# outputs lib/<abi>/libdalvik_system_DexFile.so
```

`sheller.py` writes `lib/<abi>/libdalvik_system_DexFile.so` into the packed APK
when present. The native path depends on each ROM's `libart` symbols and is
best-effort — validate it on the target device.

---

## Demo & on-device testing

`demo/` contains a minimal **multi-dex** victim app (with a cross-dex call) plus
scripts to prove the whole pack → unpack flow on a real device/emulator.

```bash
./demo/device_test.sh              # build demo -> pack -> install -> launch -> verify
./demo/device_test.sh --baseline   # also verify the unpacked demo first
```

It checks three unique logcat markers: `APP_ONCREATE` (original `Application`
started), `ACTIVITY_ONCREATE` (original Activity loaded), and `SECONDARY_OK`
(cross-dex call into `classes2.dex` resolved). See `demo/README.md` for details.
Verified on a Galaxy S21 (Android 15 / API 35).

---

## Project layout

| Path | Purpose |
| --- | --- |
| `sheller.py` | The packer entry point (`-f <apk>` → `result.apk`) |
| `axml_editor.py` | Minimal binary `AndroidManifest.xml` reader/editor (no resource recompile) |
| `shellApplicationSourceCode/` | The shell app: `StubApp`, `FileUtils`, in-memory DEX loader |
| `cpp/` | Native `OpenMemory` fallback for Android 5.0/5.1 |
| `demo/` | Victim app + on-device test scripts |
| `run_test.sh` / `setup_test_env.sh` | Toolchain detection & one-command packing |

---

## References

1. [Android apk hardening — in-memory DEX loading principles](http://www.520monkey.com/archives/629)
2. [In-memory decrypt & load DEX (Bangcle)](https://github.com/woxihuannisja/Bangcle)
