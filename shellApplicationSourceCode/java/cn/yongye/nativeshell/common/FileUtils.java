package cn.yongye.nativeshell.common;

import android.content.Context;
import android.util.Log;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

public class FileUtils {

    /** 隐藏 payload 容器魔数 "YYJG"（小端），与 sheller.py 保持一致 */
    public static final int PAYLOAD_MAGIC = 0x474A5959;
    /** 异或加密密钥，与 sheller.py 的 inKey 保持一致 */
    private static final int XOR_KEY = 0xFF;

    /**
     * 获取父目录的绝对路径
     * @param f 文件对象
     * @return 父目录对象
     */
    public static File getParent(File f) {
        String path = f.getAbsolutePath();
        int separator = path.lastIndexOf(File.separator);
        return separator == -1 ? new File(path) : new File(path.substring(0, separator));
    }

    /**
     * 获取应用classes.dex字节数据
     * @param context
     * @return
     * @throws IOException
     */
    public static byte[] readDexFileFromApk(Context context) throws IOException {
        ByteArrayOutputStream dexByteArrayOutputStream = new ByteArrayOutputStream();
        ZipInputStream localZipInputStream = new ZipInputStream(
                new BufferedInputStream(new FileInputStream(
                        context.getApplicationInfo().sourceDir)));
        while (true) {
            ZipEntry localZipEntry = localZipInputStream.getNextEntry();
            if (localZipEntry == null) {
                localZipInputStream.close();
                break;
            }
            if (localZipEntry.getName().equals("classes.dex")) {
                byte[] arrayOfByte = new byte[1024];
                while (true) {
                    int i = localZipInputStream.read(arrayOfByte);
                    if (i == -1)
                        break;
                    dexByteArrayOutputStream.write(arrayOfByte, 0, i);
                }
            }
            localZipInputStream.closeEntry();
        }
        localZipInputStream.close();
        return dexByteArrayOutputStream.toByteArray();
    }

    private static byte[] decrypt(byte[] baEncryted){
        byte[] baRes = new byte[baEncryted.length];
        for(int i=0; i<baEncryted.length; i++){
            baRes[i] = (byte) (baEncryted[i] ^ XOR_KEY);
        }
        return baRes;
    }

    private static int readLE(byte[] b, int off) {
        return (b[off] & 0xff)
                | ((b[off + 1] & 0xff) << 8)
                | ((b[off + 2] & 0xff) << 16)
                | ((b[off + 3] & 0xff) << 24);
    }

    /**
     * 从壳 classes.dex 尾部解析并解密出全部原始 dex（支持多 dex）。
     *
     * 容器格式（追加在壳 dex 之后）：
     *   [magic(4, LE)] [count(4, LE)]
     *   repeat count 次: [len_i(4, LE)] [异或加密的原始 dex_i]
     *   [tailLen(4, LE)]  <- 文件最后 4 字节，= 从 magic 到最后一个 dex 的字节数
     *
     * 通过文件末尾的 tailLen 定位容器起点，避免依赖 dex 头长度字段。
     *
     * @return 解密后的原始 dex 字节数组列表；若无有效容器返回空列表。
     */
    public static List<byte[]> extractPayloadDexes(Context context) throws IOException {
        List<byte[]> result = new ArrayList<>();
        byte[] all = readDexFileFromApk(context);
        if (all == null || all.length < 12) {
            return result;
        }
        int fileLen = all.length;
        int tailLen = readLE(all, fileLen - 4);
        if (tailLen <= 8 || tailLen > fileLen - 4) {
            return result; // 非本壳生成，或格式不符
        }
        int off = fileLen - 4 - tailLen;
        if (off < 0 || readLE(all, off) != PAYLOAD_MAGIC) {
            return result;
        }
        off += 4;
        int count = readLE(all, off);
        off += 4;
        if (count <= 0 || count > 4096) {
            return result;
        }
        for (int i = 0; i < count; i++) {
            if (off + 4 > fileLen - 4) {
                break;
            }
            int len = readLE(all, off);
            off += 4;
            if (len <= 0 || off + len > fileLen - 4) {
                break;
            }
            byte[] enc = new byte[len];
            System.arraycopy(all, off, enc, 0, len);
            off += len;
            result.add(decrypt(enc));
        }
        return result;
    }
}
