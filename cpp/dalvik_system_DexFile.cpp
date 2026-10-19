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

    int arrLen = env->GetArrayLength(buf);
    // 按调用方传入的 [start, end) 区间取 dex，而不是整只数组（ByteBuffer 可能带偏移/上限）
    if (start < 0 || end < start || end > arrLen) {
        log_err("createCookieWithArray: 非法区间 start=%d end=%d len=%d", start, end, arrLen);
        return 0;
    }
    int inDexLen = end - start;
    jbyte *bytes = env->GetByteArrayElements(buf, nullptr);
    char *pDex = new char[inDexLen + 1];
    memset(pDex, 0, inDexLen + 1);
    memcpy(pDex, bytes + start, inDexLen);
    pDex[inDexLen] = 0;
    env->ReleaseByteArrayElements(buf, bytes, JNI_ABORT);  // 只读，无需拷回

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

    // 按 section header 索引精确定位：先找 .dynsym，再按它的 sh_link 取对应的 .dynstr，
    // 而不是"第一个 SHT_STRTAB 当 dynstr"——后者在 .dynstr 之前还有别的字符串表
    // （如部分 ROM 的 .strtab）时会取错表，导致符号名解析全部错位。
#define SHDR(i) ((Elf_Shdr *) (((char *) elf) + elf->e_shoff + (size_t)(i) * elf->e_shentsize))
    int shnum = elf->e_shnum;
    int dynsym_idx = -1;
    for (int k = 0; k < shnum; k++) {
        if (SHDR(k)->sh_type == SHT_DYNSYM) { dynsym_idx = k; break; }
    }
    if (dynsym_idx < 0) fail("%s: 未找到 .dynsym", libpath);

    Elf_Shdr *dynsym_sh = SHDR(dynsym_idx);
    int dynstr_idx = (int) dynsym_sh->sh_link;   // .dynsym 关联的字符串表（即 .dynstr）
    if (dynstr_idx <= 0 || dynstr_idx >= shnum || SHDR(dynstr_idx)->sh_type != SHT_STRTAB)
        fail("%s: .dynsym 的 sh_link 非法 (%d)", libpath, dynstr_idx);
    Elf_Shdr *dynstr_sh = SHDR(dynstr_idx);

    ctx->dynsym = malloc(dynsym_sh->sh_size);
    if (!ctx->dynsym) fail("no memory for .dynsym");
    memcpy(ctx->dynsym, ((char *) elf) + dynsym_sh->sh_offset, dynsym_sh->sh_size);
    ctx->nsyms = (int) (dynsym_sh->sh_size / sizeof(Elf_Sym));

    ctx->dynstr = malloc(dynstr_sh->sh_size);
    if (!ctx->dynstr) fail("no memory for .dynstr");
    memcpy(ctx->dynstr, ((char *) elf) + dynstr_sh->sh_offset, dynstr_sh->sh_size);

    // bias：取 .dynsym/.dynstr 之后第一个 PROGBITS 段的 (sh_addr - sh_offset)，
    // 用于把符号虚拟地址换算成相对 load_addr 的运行时地址（沿用原实现语义）。
    int hi = dynsym_idx > dynstr_idx ? dynsym_idx : dynstr_idx;
    for (int k = hi + 1; k < shnum; k++) {
        if (SHDR(k)->sh_type == SHT_PROGBITS) {
            ctx->bias = (off_t) SHDR(k)->sh_addr - (off_t) SHDR(k)->sh_offset;
            break;
        }
    }
#undef SHDR

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
    // 仅 Android 5.0 / 5.1 (API 21~22)：DexFile.mCookie 是 long，其值为
    // std::vector<const DexFile*>*，defineClass 签名为 (String,ClassLoader,long,List)，
    // 与本壳 Java 层的反射完全一致。
    // Android 6.0+ (API 23+)：mCookie 变为 Object(long[]{oatPtr, dexPtr...})，defineClass
    // 多了 Object/DexFile 参数，与此 vector+long 方案不兼容——此处直接失败，避免把一个
    // 运行时无法消费的 cookie 交回去造成误导/内存泄漏。该区间请用 8.0+ 的
    // InMemoryDexClassLoader 方案，或走落盘 DexClassLoader（本壳未实现）。
    if (sdk_int >= 21 && sdk_int <= 22) {
        auto *dex_files = new std::vector<const void *>();
        dex_files->push_back(c_dex_cookie);
        return static_cast<jlong>(reinterpret_cast<uintptr_t>(dex_files));
    }
    log_err("SDK=%d 不支持 native 内存脱壳（仅 Android 5.0/5.1）", sdk_int);
    return 0;
}
