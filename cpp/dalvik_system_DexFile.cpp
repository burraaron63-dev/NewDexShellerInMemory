#include <jni.h>
#include <string>
#include <dlfcn.h>
#include <android/log.h>
#include <iostream>
#include <stdio.h>
#include <sys/mman.h>
#include <elf.h>
#include <asm/fcntl.h>
#include <fcntl.h>
#include <unistd.h>
#include <vector>
#include <sys/system_properties.h>
#include "dalvik_system_DexFile.h"


#define TAG "yongye"

#define log_info(fmt, args...) __android_log_print(ANDROID_LOG_INFO, TAG, (const char *) fmt, ##args)
#define log_err(fmt, args...)  __android_log_print(ANDROID_LOG_ERROR, TAG, (const char *) fmt, ##args)

#ifdef LOG_DBG
#define log_dbg log_info
#else
#define log_dbg(...)
#endif

/*
 * 按编译目标位宽选择 ELF 结构与系统库路径，解决 64 位机型（arm64-v8a / x86_64）
 * 直接崩溃的问题。旧版写死 Elf32 + /system/lib，只能在 32 位进程里工作。
 */
#if defined(__LP64__)
#define Elf_Ehdr Elf64_Ehdr
#define Elf_Shdr Elf64_Shdr
#define Elf_Sym  Elf64_Sym
static const char *kArtLibPath = "/system/lib64/libart.so";
#else
#define Elf_Ehdr Elf32_Ehdr
#define Elf_Shdr Elf32_Shdr
#define Elf_Sym  Elf32_Sym
static const char *kArtLibPath = "/system/lib/libart.so";
#endif

struct ctx {
    void *load_addr;
    void *dynstr;
    void *dynsym;
    int nsyms;
    off_t bias;
};

void *fake_dlopen(const char *libpath, int flags);
void *fake_dlsym(void *handle, const char *name);

/*
 * art::DexFile::OpenMemory 在不同 Android 版本上返回 DexFile*，参数细节略有差异，
 * 但前 7 个参数的 ABI 布局一致，可用同一函数指针类型调用。
 */
typedef void *(*org_artDexFileOpenMemory)(const uint8_t *base, size_t size,
                                          const std::string &location, uint32_t location_checksum,
                                          void *mem_map, const void *oat_file, std::string *error_msg);

/*
 * 各版本 OpenMemory 的 mangled 符号候选表。运行时逐个尝试 dlsym，命中即用，
 * 从而在 Android 5.0~7.1 之间自适应，而不是写死单一版本。
 */
static const char *kOpenMemorySymbols[] = {
        // Android 5.0 / 5.1 / 6.0 : ...MemMap...OatFile...
        "_ZN3art7DexFile10OpenMemoryEPKhjRKNSt3__112basic_stringIcNS3_11char_traitsIcEENS3_9allocatorIcEEEEjPNS_6MemMapEPKNS_7OatFileEPS9_",
        // Android 7.0 / 7.1 : ...MemMap...OatDexFile...
        "_ZN3art7DexFile10OpenMemoryEPKhjRKNSt3__112basic_stringIcNS3_11char_traitsIcEENS3_9allocatorIcEEEEjPNS_6MemMapEPKNS_10OatDexFileEPS9_",
        // 少数 6.0 ROM 变体
        "_ZN3art7DexFile10OpenMemoryEPKhmRKNSt3__112basic_stringIcNS3_11char_traitsIcEENS3_9allocatorIcEEEEjPNS_6MemMapEPKNS_7OatFileEPS9_",
};

static int getDeviceSdkInt() {
    char prop[PROP_VALUE_MAX] = {0};
    int len = __system_property_get("ro.build.version.sdk", prop);
    if (len <= 0) return 0;
    return atoi(prop);
}

jlong replace_cookie(JNIEnv *env, void *c_dex_cookie, int sdk_int);

// 前向声明：createCookieWithDirectBuffer 复用 array 版本的实现
extern "C" JNIEXPORT jlong JNICALL
Java_cn_yongye_nativeshell_inmemoryloaddex_DexFile_createCookieWithArray(JNIEnv *env, jclass clazz,
                                                                         jbyteArray buf, jint start,
                                                                         jint end);

JNICALL extern "C"
JNIEXPORT jlong JNICALL
Java_cn_yongye_nativeshell_inmemoryloaddex_DexFile_createCookieWithDirectBuffer(JNIEnv *env,
                                                                                jclass clazz,
                                                                                jobject buf, jint start,
                                                                                jint end) {
    // DirectBuffer 场景：取出底层地址并复用数组路径逻辑。当前 Java 层只走 array 路径，
    // 这里做一个安全实现以防外部直接调用。
    if (buf == nullptr) return 0;
    void *addr = env->GetDirectBufferAddress(buf);
    jlong cap = env->GetDirectBufferCapacity(buf);
    if (addr == nullptr || cap <= 0) {
        log_err("createCookieWithDirectBuffer: 无法获取直接缓冲区地址");
        return 0;
    }
    // 转成 byte[] 复用主实现
    jbyteArray arr = env->NewByteArray((jsize) cap);
    env->SetByteArrayRegion(arr, 0, (jsize) cap, (const jbyte *) addr);
    return Java_cn_yongye_nativeshell_inmemoryloaddex_DexFile_createCookieWithArray(env, clazz, arr,
                                                                                    start, end);
}


JNICALL extern "C"
JNIEXPORT jlong JNICALL
Java_cn_yongye_nativeshell_inmemoryloaddex_DexFile_createCookieWithArray(JNIEnv *env, jclass clazz,
                                                                         jbyteArray buf, jint start,
                                                                         jint end) {
    void *artlib = fake_dlopen(kArtLibPath, RTLD_LAZY);
    if (!artlib) {
        log_err("无法打开 %s", kArtLibPath);
        return 0;  // 优雅失败，交回 Java 层处理，而不是 exit(0) 杀进程
    }

    org_artDexFileOpenMemory openMemory = nullptr;
    for (const char *sym : kOpenMemorySymbols) {
        openMemory = (org_artDexFileOpenMemory) fake_dlsym(artlib, sym);
        if (openMemory) {
            log_info("命中 OpenMemory 符号");
            break;
        }
    }
    if (!openMemory) {
        log_err("未在 libart 中找到匹配的 OpenMemory 符号，当前系统可能不受 native 路径支持");
        return 0;
    }

    jbyte *bytes = env->GetByteArrayElements(buf, nullptr);
    int inDexLen = env->GetArrayLength(buf);
    char *pDex = new char[inDexLen + 1];
    memset(pDex, 0, inDexLen + 1);
    memcpy(pDex, bytes, inDexLen);
    pDex[inDexLen] = 0;
    env->ReleaseByteArrayElements(buf, bytes, 0);

    std::string location = "";
    std::string err_msg;
    const Header *dex_header = reinterpret_cast<const Header *>(pDex);
    void *value = openMemory((const unsigned char *) pDex, inDexLen, location,
                             dex_header->checksum_, nullptr, nullptr, &err_msg);
    if (!value) {
        log_err("OpenMemory 返回空: %s", err_msg.c_str());
        delete[] pDex;
        return 0;
    }

    int sdk = getDeviceSdkInt();
    jlong cookie = replace_cookie(env, value, sdk);
    if (cookie == 0) {
        log_err("当前 SDK=%d 暂不支持 native cookie 组装", sdk);
    }
    // 注意：pDex 内存需在 DexFile 生命周期内保持有效，故此处不释放
    return cookie;
}


void *fake_dlsym(void *handle, const char *name) {
    struct ctx *ctx = (struct ctx *) handle;
    if (!ctx) return nullptr;

    Elf_Sym *sym = (Elf_Sym *) ctx->dynsym;
    char *strings = (char *) ctx->dynstr;

    for (int k = 0; k < ctx->nsyms; k++, sym++) {
        if (strcmp(strings + sym->st_name, name) == 0) {
            return (char *) ctx->load_addr + sym->st_value - ctx->bias;
        }
    }
    return nullptr;
}

void *fake_dlopen(const char *libpath, int flags) {
    FILE *maps;
    char buff[256];
    struct ctx *ctx = nullptr;
    off_t load_addr = 0, size = 0;
    int fd = -1, found = 0;
    char *shoff;
    Elf_Ehdr *elf = (Elf_Ehdr *) MAP_FAILED;

#define fail(fmt, args...) do { log_dbg(fmt, ##args); goto err_exit; } while(0)

    maps = fopen("/proc/self/maps", "r");
    if (!maps) fail("failed to open maps");

    while (fgets(buff, sizeof(buff), maps)) {
        if ((strstr(buff, "r-xp") || strstr(buff, "r--p")) && strstr(buff, libpath)) {
            found = 1;
            break;
        }
    }
    fclose(maps);
    if (!found) fail("%s not found in maps", libpath);

    if (sscanf(buff, "%lx", (unsigned long *) &load_addr) != 1)
        fail("failed to read load address for %s", libpath);

    fd = open(libpath, O_RDONLY);
    if (fd < 0) fail("failed to open %s", libpath);

    size = lseek(fd, 0, SEEK_END);
    if (size <= 0) fail("lseek() failed for %s", libpath);

    elf = (Elf_Ehdr *) mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    fd = -1;
    if (elf == MAP_FAILED) fail("mmap() failed for %s", libpath);

    ctx = (struct ctx *) calloc(1, sizeof(struct ctx));
    if (!ctx) fail("no memory for %s", libpath);

    ctx->load_addr = (void *) load_addr;
    shoff = ((char *) elf) + elf->e_shoff;

    for (int k = 0; k < elf->e_shnum; k++, shoff += elf->e_shentsize) {
        Elf_Shdr *sh = (Elf_Shdr *) shoff;
        switch (sh->sh_type) {
            case SHT_DYNSYM:
                if (ctx->dynsym) fail("%s: duplicate DYNSYM", libpath);
                ctx->dynsym = malloc(sh->sh_size);
                if (!ctx->dynsym) fail("no memory for .dynsym");
                memcpy(ctx->dynsym, ((char *) elf) + sh->sh_offset, sh->sh_size);
                ctx->nsyms = (sh->sh_size / sizeof(Elf_Sym));
                break;
            case SHT_STRTAB:
                if (ctx->dynstr) break;
                ctx->dynstr = malloc(sh->sh_size);
                if (!ctx->dynstr) fail("no memory for .dynstr");
                memcpy(ctx->dynstr, ((char *) elf) + sh->sh_offset, sh->sh_size);
                break;
            case SHT_PROGBITS:
                if (!ctx->dynstr || !ctx->dynsym) break;
                ctx->bias = (off_t) sh->sh_addr - (off_t) sh->sh_offset;
                k = elf->e_shnum;  // 提前结束循环
                break;
        }
    }

    munmap(elf, size);
    elf = (Elf_Ehdr *) MAP_FAILED;

    if (!ctx->dynstr || !ctx->dynsym) fail("dynamic sections not found in %s", libpath);
#undef fail

    return ctx;

    err_exit:
    if (fd >= 0) close(fd);
    if (elf != MAP_FAILED) munmap(elf, size);
    if (ctx) {
        free(ctx->dynsym);
        free(ctx->dynstr);
        free(ctx);
    }
    return nullptr;
}

/*
 * 把 native DexFile* 组装成 Java 层 DexFile.mCookie 所需的表示。
 * Android 5.0~7.1 均使用 std::vector<const DexFile*>* 作为 cookie；不同小版本
 * 的 defineClass 反射签名（long cookie）与此一致。更高版本已走 InMemoryDexClassLoader，
 * 不会进入本函数。
 */
jlong replace_cookie(JNIEnv *env, void *c_dex_cookie, int sdk_int) {
    if (sdk_int >= 21 && sdk_int <= 25) {
        auto *dex_files = new std::vector<const void *>();
        dex_files->push_back(c_dex_cookie);
        return static_cast<jlong>(reinterpret_cast<uintptr_t>(dex_files));
    }
    // 21 以下（Dalvik）与 26+（应走 Java InMemoryDexClassLoader）不在此处理
    return 0;
}
