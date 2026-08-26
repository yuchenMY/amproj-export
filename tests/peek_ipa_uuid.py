# -*- coding: utf-8 -*-
"""提取 IPA 主程序 Mach-O 的 LC_UUID（校验输入 IPA 用）。"""
import struct
import sys
import zipfile


def find_uuid(ipa_path):
    z = zipfile.ZipFile(ipa_path)
    for n in z.namelist():
        if n.endswith("/AlightMotion"):
            data = z.read(n)
            if len(data) < 32:
                return None
            magic = struct.unpack_from("<I", data, 0)[0]
            if magic == 0xfeedfacf:  # MH_MAGIC_64 (little-endian)
                ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
                off = 32
                for _ in range(ncmds):
                    cmd, cmdsize = struct.unpack_from("<II", data, off)
                    if cmd == 0x1B:  # LC_UUID
                        return data[off + 8:off + 24].hex()
                    off += cmdsize
                return None
            # fat binary
            if magic == 0xcafebabe or magic == 0xbebafeca:
                return "fat-binary(需进一步解析)"
    return None


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print("%s  ->  %s" % (p, find_uuid(p)))
