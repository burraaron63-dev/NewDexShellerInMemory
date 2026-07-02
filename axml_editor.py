# -*- coding: UTF-8 -*-
"""
最小可用的二进制 AndroidManifest.xml (AXML) 编辑器。

只做加固所需的两件事：
  1. 读取 <application> 的 android:name（用于保存原 Application 名到壳 Config）
  2. 设置 <application> 的 android:name 为壳 StubApp（已有则改值，没有则插入属性）

不重编资源，因此不受 aapt2 严格校验（如 gravity="0x0"）影响，可处理各类真实 APK。

设计要点（保证安全）：
  - 新的取值字符串「追加」到字符串池末尾，已有字符串索引保持不变，
    因此除字符串池本身外，其余所有 chunk 的字符串索引引用都无需改动。
  - 插入属性时只在对应 START_ELEMENT chunk 内做局部字节插入并更新其 size。
"""

import struct

RES_XML_TYPE = 0x0003
RES_STRING_POOL_TYPE = 0x0001
RES_XML_RESOURCE_MAP_TYPE = 0x0180
RES_XML_START_ELEMENT_TYPE = 0x0102

UTF8_FLAG = 0x0100
ANDROID_URI = "http://schemas.android.com/apk/res/android"
ATTR_NAME_RESID = 0x01010003  # android:name


class AXMLError(Exception):
    pass


def _dec_len_utf16(data, off):
    u = struct.unpack_from('<H', data, off)[0]
    off += 2
    if u & 0x8000:
        u2 = struct.unpack_from('<H', data, off)[0]
        off += 2
        u = ((u & 0x7fff) << 16) | u2
    return u, off


def _dec_len_utf8(data, off):
    b = data[off]; off += 1
    if b & 0x80:
        b2 = data[off]; off += 1
        b = ((b & 0x7f) << 8) | b2
    return b, off


def _parse_string_pool(data, base):
    t, hs, size = struct.unpack_from('<HHI', data, base)
    if t != RES_STRING_POOL_TYPE:
        raise AXMLError("第一个 chunk 不是字符串池")
    scount, stycount, flags, strStart, styStart = struct.unpack_from('<IIIII', data, base + 8)
    utf8 = bool(flags & UTF8_FLAG)
    offsets = [struct.unpack_from('<I', data, base + 28 + i * 4)[0] for i in range(scount)]
    strings = []
    data_base = base + strStart
    for o in offsets:
        p = data_base + o
        if utf8:
            _clen, p = _dec_len_utf8(data, p)
            blen, p = _dec_len_utf8(data, p)
            s = data[p:p + blen].decode('utf-8', 'replace')
        else:
            clen, p = _dec_len_utf16(data, p)
            s = data[p:p + clen * 2].decode('utf-16-le', 'replace')
        strings.append(s)
    return {'flags': flags, 'utf8': utf8, 'strings': strings,
            'styleCount': stycount, 'size': size, 'base': base}


def _enc_string_utf16(s):
    b = s.encode('utf-16-le')
    clen = len(s)
    out = bytearray()
    if clen > 0x7fff:
        out += struct.pack('<H', 0x8000 | (clen >> 16))
        out += struct.pack('<H', clen & 0xffff)
    else:
        out += struct.pack('<H', clen)
    out += b
    out += b'\x00\x00'
    return bytes(out)


def _enc_string_utf8(s):
    b = s.encode('utf-8')
    clen = len(s.encode('utf-16-le')) // 2  # UTF-16 code units
    blen = len(b)
    out = bytearray()
    for n in (clen, blen):
        if n > 0x7f:
            out.append(0x80 | (n >> 8))
            out.append(n & 0xff)
        else:
            out.append(n)
    out += b
    out.append(0)
    return bytes(out)


def _build_string_pool(flags, strings, style_count_zero=True):
    utf8 = bool(flags & UTF8_FLAG)
    enc = _enc_string_utf8 if utf8 else _enc_string_utf16
    blob = bytearray()
    offsets = []
    for s in strings:
        offsets.append(len(blob))
        blob += enc(s)
    # 4 字节对齐
    while len(blob) % 4 != 0:
        blob.append(0)
    header_size = 28
    str_start = header_size + len(offsets) * 4
    total = str_start + len(blob)
    out = bytearray()
    out += struct.pack('<HHI', RES_STRING_POOL_TYPE, header_size, total)
    out += struct.pack('<IIIII', len(strings), 0, flags, str_start, 0)
    for o in offsets:
        out += struct.pack('<I', o)
    out += blob
    return bytes(out)


class AXML:
    def __init__(self, data):
        self.data = bytearray(data)
        t, hs, size = struct.unpack_from('<HHI', self.data, 0)
        if t != RES_XML_TYPE:
            raise AXMLError("不是 AXML 文件")
        self.pool = _parse_string_pool(self.data, 8)
        self.strings = self.pool['strings']
        self.pool_size = self.pool['size']
        self.tail = bytes(self.data[8 + self.pool_size:size])  # 资源映射 + XML 事件

    # -------- 字符串工具 --------
    def _find_string(self, s):
        try:
            return self.strings.index(s)
        except ValueError:
            return -1

    def _get_or_append_string(self, s):
        i = self._find_string(s)
        if i >= 0:
            return i, False
        self.strings.append(s)
        return len(self.strings) - 1, True

    # -------- 遍历 START_ELEMENT --------
    def _iter_start_elements(self):
        off = 0
        n = len(self.tail)
        while off + 8 <= n:
            t, hs, size = struct.unpack_from('<HHI', self.tail, off)
            if size <= 0:
                break
            if t == RES_XML_START_ELEMENT_TYPE:
                yield off, hs, size
            off += size

    def _element_name(self, off, hs):
        ns, name = struct.unpack_from('<II', self.tail, off + hs)
        return name

    def _attrs(self, off, hs):
        # attrExt 紧跟 header；attributeStart 相对 attrExt
        ext = off + hs
        attrStart, attrSize, attrCount = struct.unpack_from('<HHH', self.tail, ext + 8)
        base = ext + attrStart
        res = []
        for i in range(attrCount):
            a = base + i * 20
            ns, name, raw = struct.unpack_from('<III', self.tail, a)
            tsize, res0, dtype, ddata = struct.unpack_from('<HBBI', self.tail, a + 12)
            res.append({'pos': a, 'ns': ns, 'name': name, 'raw': raw,
                        'dtype': dtype, 'data': ddata})
        return ext, attrStart, attrCount, base, res

    def _find_application(self):
        app_idx = self._find_string('application')
        if app_idx < 0:
            return None
        for off, hs, size in self._iter_start_elements():
            if self._element_name(off, hs) == app_idx:
                return (off, hs, size)
        return None

    # -------- 对外 API --------
    def get_application_name(self):
        """返回 <application android:name> 的字符串；无则 None"""
        app = self._find_application()
        if not app:
            return None
        off, hs, size = app
        android_uri = self._find_string(ANDROID_URI)
        _ext, _as, _ac, _base, attrs = self._attrs(off, hs)
        for a in attrs:
            if self.strings[a['name']] == 'name' and (android_uri < 0 or a['ns'] == android_uri):
                if 0 <= a['data'] < len(self.strings):
                    return self.strings[a['data']]
        return None

    def set_application_name(self, new_name):
        """设置 <application android:name>，返回原名（无则 None）"""
        app = self._find_application()
        if not app:
            raise AXMLError("manifest 中未找到 <application>")
        off, hs, size = app
        android_uri = self._find_string(ANDROID_URI)
        ext, attrStart, attrCount, abase, attrs = self._attrs(off, hs)

        old_name = None
        target = None
        for a in attrs:
            if self.strings[a['name']] == 'name' and (android_uri < 0 or a['ns'] == android_uri):
                target = a
                if 0 <= a['data'] < len(self.strings):
                    old_name = self.strings[a['data']]
                break

        new_idx, _appended = self._get_or_append_string(new_name)

        if target is not None:
            # 改值：rawValue 与 typed data 都指向新字符串，类型=STRING
            a = target['pos']
            struct.pack_into('<I', self.tail_ba(), a + 8, new_idx)       # rawValue
            struct.pack_into('<HBBI', self.tail_ba(), a + 12, 8, 0, 0x03, new_idx)
        else:
            # 插入属性：需要 android uri 与 name(0x01010003) 属性名字符串
            if android_uri < 0:
                raise AXMLError("manifest 未声明 android 命名空间，无法插入 android:name")
            name_attr_idx = self._find_name_attr_index()
            if name_attr_idx < 0:
                raise AXMLError("未找到可用的 name 属性名(0x01010003)，无法插入")
            new_attr = struct.pack('<IIIHBBI', android_uri, name_attr_idx, new_idx,
                                   8, 0, 0x03, new_idx)
            tb = bytearray(self.tail)
            insert_at = abase + attrCount * 20
            tb[insert_at:insert_at] = new_attr
            # attributeCount +1
            struct.pack_into('<H', tb, ext + 8 + 4, attrCount + 1)
            # 该 START_ELEMENT chunk size +20
            struct.pack_into('<I', tb, off + 4, size + 20)
            self.tail = bytes(tb)

        return old_name

    def _tail_ba_cache(self):
        return None

    def tail_ba(self):
        if not isinstance(self.tail, bytearray):
            self.tail = bytearray(self.tail)
        return self.tail

    def _resource_map(self):
        """返回 (base_off_in_tail, [resIds]) 或 (None, [])"""
        off = 0
        while off + 8 <= len(self.tail):
            t, hs, size = struct.unpack_from('<HHI', self.tail, off)
            if t == RES_XML_RESOURCE_MAP_TYPE:
                cnt = (size - hs) // 4
                ids = [struct.unpack_from('<I', self.tail, off + hs + i * 4)[0] for i in range(cnt)]
                return off, ids
            if t == RES_XML_START_ELEMENT_TYPE:
                break
            off += size
        return None, []

    def _find_name_attr_index(self):
        _base, ids = self._resource_map()
        for i, rid in enumerate(ids):
            if rid == ATTR_NAME_RESID and i < len(self.strings) and self.strings[i] == 'name':
                return i
        return -1

    def to_bytes(self):
        pool = _build_string_pool(self.pool['flags'], self.strings)
        tail = bytes(self.tail)
        body = pool + tail
        total = 8 + len(body)
        out = bytearray()
        out += struct.pack('<HHI', RES_XML_TYPE, 8, total)
        out += body
        return bytes(out)


# ---------------- 自测 ----------------
if __name__ == '__main__':
    import sys
    data = open(sys.argv[1], 'rb').read()
    ax = AXML(data)
    print("字符串数:", len(ax.strings))
    print("原 application name:", ax.get_application_name())
    old = ax.set_application_name('cn.yongye.nativeshell.StubApp')
    print("set 返回原名:", old)
    out = ax.to_bytes()
    open('/tmp/axtest/out.xml', 'wb').write(out)
    # round-trip 校验：重新解析，确认 application name 已改
    ax2 = AXML(out)
    got = ax2.get_application_name()
    print("改后再解析 application name:", got)
    assert got == 'cn.yongye.nativeshell.StubApp', "改名失败"
    # 结构校验：能完整遍历所有 START_ELEMENT 且 size 合法
    cnt = sum(1 for _ in ax2._iter_start_elements())
    print("START_ELEMENT 数:", cnt)
    print("OK: round-trip 通过, 输出 %d 字节" % len(out))
