#!/usr/bin/env python3
"""
inject_dylib.py — 将 AMProjExport.dylib 注入 AlightMotion IPA

用法:
    python inject_dylib.py <输入.ipa> <AMProjExport.dylib> [输出.ipa]
    python inject_dylib.py AlightMotion_v27b.ipa AMProjExport.dylib AMProjExport_v27b.ipa

流程:
    1. 解压 IPA
    2. 复制 dylib 到 Frameworks/
    3. 修改主二进制, 插入 LC_LOAD_DYLIB load command
    4. 重签 (需要有效证书或使用 ldid 伪签)
    5. 重新打包 IPA
"""

import sys, os, shutil, tempfile, struct, plistlib, subprocess
from pathlib import Path

def parse_macho(path):
    """Parse Mach-O 64-bit header and load commands"""
    with open(path, 'rb') as f:
        magic = struct.unpack('<I', f.read(4))[0]
        assert magic == 0xfeedfacf, f"Not arm64: 0x{magic:x}"

        hdr = f.read(28)  # remaining after magic: 32 - 4 = 28 bytes
        cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = \
            struct.unpack('<IIIIIII', hdr)  # 7 fields = 28 bytes

        return {
            'path': path,
            'ncmds': ncmds,
            'sizeofcmds': sizeofcmds,
            'filetype': filetype,
        }

def insert_load_dylib(macho_path, dylib_path):
    """Insert LC_LOAD_DYLIB command into Mach-O"""
    info = parse_macho(macho_path)

    with open(macho_path, 'rb') as f:
        data = bytearray(f.read())

    # Check if already injected
    if dylib_path.encode() in data:
        print(f"[!] {dylib_path} already injected, skipping")
        return False

    # Build the new LC_LOAD_DYLIB command
    dylib_name = f"@executable_path/Frameworks/{os.path.basename(dylib_path)}"
    name_bytes = dylib_name.encode('utf-8') + b'\x00'

    # LC_DYLIB = 0x0c
    # struct dylib_command { cmd, cmdsize, dylib.name offset, timestamp, current_version, compatibility_version }
    # The name is a lc_str: { offset (relative to dylib_command start) }

    name_offset = 24  # offset of name within dylib_command
    cmd_size = 24 + len(name_bytes)
    # Pad to 8-byte alignment
    if cmd_size % 8:
        cmd_size += 8 - (cmd_size % 8)
        name_bytes += b'\x00' * (8 - (len(name_bytes) % 8) if len(name_bytes) % 8 else 0)

    # Actually, let's be more precise:
    cmd_size = 24 + len(name_bytes)
    align_to = 8
    if cmd_size % align_to:
        pad = align_to - (cmd_size % align_to)
        cmd_size += pad
        name_bytes += b'\x00' * pad

    dylib_cmd = struct.pack('<II', 0x0c, cmd_size)  # cmd, cmdsize
    dylib_cmd += struct.pack('<I', name_offset)       # name offset
    dylib_cmd += struct.pack('<I', 2)                  # timestamp
    dylib_cmd += struct.pack('<I', 0x10000)            # current version
    dylib_cmd += struct.pack('<I', 0x10000)            # compat version
    dylib_cmd += name_bytes

    print(f"[+] New LC_LOAD_DYLIB: {dylib_name}")
    print(f"[+] Command size: {cmd_size} bytes")

    # Insert after the last LC_LOAD_DYLIB or at the end of load commands
    # Find the last LC_LOAD_DYLIB (0x0c)
    insert_offset = None
    offset = 32  # start of load commands (mach_header_64 = 32 bytes)
    for i in range(info['ncmds']):
        cmd, cmdsize = struct.unpack_from('<II', data, offset)
        if cmd == 0x0c:  # LC_LOAD_DYLIB
            insert_offset = offset + cmdsize
        offset += cmdsize

    if insert_offset is None:
        # No existing LC_LOAD_DYLIB? Insert after LC_SEGMENT_64 for __LINKEDIT
        offset = 32
        for i in range(info['ncmds']):
            cmd, cmdsize = struct.unpack_from('<II', data, offset)
            if cmd == 0x19:  # LC_SEGMENT_64
                segname = data[offset+8:offset+24].rstrip(b'\x00')
                if segname == b'__LINKEDIT':
                    insert_offset = offset  # Insert before LINKEDIT
                    break
            offset += cmdsize

    if insert_offset is None:
        insert_offset = 32 + info['sizeofcmds']

    # Insert the new command
    new_data = bytearray(data[:insert_offset])
    new_data += dylib_cmd
    new_data += data[insert_offset:]

    # Update ncmds and sizeofcmds
    new_ncmds = info['ncmds'] + 1
    new_sizeofcmds = info['sizeofcmds'] + cmd_size
    struct.pack_into('<I', new_data, 16, new_ncmds)
    struct.pack_into('<I', new_data, 20, new_sizeofcmds)

    # Update __LINKEDIT segment fileoff + filesize (and any following segments)
    offset = 32
    for i in range(info['ncmds']):
        cmd, cmdsize = struct.unpack_from('<II', new_data, offset)
        if cmd == 0x19:
            segname = new_data[offset+8:offset+24].rstrip(b'\x00')
            if segname == b'__LINKEDIT':
                fileoff = struct.unpack_from('<Q', new_data, offset+40)[0]
                struct.pack_into('<Q', new_data, offset+40, fileoff + cmd_size)
                # Also need to update Code Signature if it references LINKEDIT
        offset += cmdsize

    with open(macho_path, 'wb') as f:
        f.write(new_data)

    print(f"[+] Patched {macho_path}: ncmds {info['ncmds']} -> {new_ncmds}")
    return True


def patch_info_plist(app_dir):
    """Add .amproj UTI registration to Info.plist so QQ/WeChat downloads can open directly in AM"""
    info_path = os.path.join(app_dir, 'Info.plist')
    if not os.path.exists(info_path):
        print("[!] Info.plist not found")
        return False

    with open(info_path, 'rb') as f:
        plist = plistlib.load(f)

    uti_id = 'com.alightcreative.motion.amproj'

    # Check if already patched
    if 'CFBundleDocumentTypes' in plist:
        for dt in plist['CFBundleDocumentTypes']:
            if 'LSItemContentTypes' in dt and uti_id in dt['LSItemContentTypes']:
                print("[*] Info.plist already has .amproj registration, skipping")
                return False

    # Add UTI declaration
    amproj_uti = {
        'UTTypeIdentifier': uti_id,
        'UTTypeDescription': 'Alight Motion Project',
        'UTTypeConformsTo': ['public.data', 'public.archive'],
        'UTTypeTagSpecification': {
            'public.filename-extension': ['amproj'],
            'public.mime-type': ['application/x-amproj'],
        }
    }

    if 'UTExportedTypeDeclarations' not in plist:
        plist['UTExportedTypeDeclarations'] = []
    plist['UTExportedTypeDeclarations'].append(amproj_uti)

    # Add document type
    doc_type = {
        'CFBundleTypeName': 'Alight Motion Project',
        'CFBundleTypeRole': 'Editor',
        'LSHandlerRank': 'Owner',
        'LSItemContentTypes': [uti_id],
    }

    if 'CFBundleDocumentTypes' not in plist:
        plist['CFBundleDocumentTypes'] = []
    plist['CFBundleDocumentTypes'].append(doc_type)

    # Also add to LSApplicationQueriesSchemes or similar for "Open In" support
    # Add the UTI to the app's supported document types for iOS share sheet
    if 'UISupportsDocumentBrowser' not in plist:
        plist['UISupportsDocumentBrowser'] = False  # We use UIDocumentPicker instead

    with open(info_path, 'wb') as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_BINARY)

    print(f"[+] Patched Info.plist: added .amproj UTI registration")
    return True


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.ipa> <dylib> [output.ipa]")
        sys.exit(1)

    ipa_path = sys.argv[1]
    dylib_path = sys.argv[2]
    output_path = sys.argv[3] if len(sys.argv) > 3 else ipa_path.replace('.ipa', '_amproj.ipa')

    if not os.path.exists(dylib_path):
        print(f"[!] Dylib not found: {dylib_path}")
        sys.exit(1)

    # Create temp dir
    tmpdir = tempfile.mkdtemp(prefix='amproj_inject_')
    print(f"[*] Temp dir: {tmpdir}")

    # Unzip IPA
    print(f"[*] Extracting {ipa_path}...")
    shutil.unpack_archive(ipa_path, tmpdir, 'zip')
    # Find .app
    payload = os.path.join(tmpdir, 'Payload')
    app_dir = None
    for f in os.listdir(payload):
        if f.endswith('.app'):
            app_dir = os.path.join(payload, f)
            break

    if not app_dir:
        print("[!] No .app found in IPA")
        sys.exit(1)

    app_name = os.path.basename(app_dir).replace('.app', '')

    # Copy dylib to Frameworks
    frameworks = os.path.join(app_dir, 'Frameworks')
    os.makedirs(frameworks, exist_ok=True)
    dylib_dest = os.path.join(frameworks, os.path.basename(dylib_path))
    shutil.copy2(dylib_path, dylib_dest)
    print(f"[+] Copied dylib to {dylib_dest}")

    # Patch main binary
    binary_path = os.path.join(app_dir, app_name)
    if not os.path.exists(binary_path):
        print(f"[!] Binary not found: {binary_path}")
        sys.exit(1)

    patched = insert_load_dylib(binary_path, dylib_dest)
    if not patched:
        print("[*] Binary already patched, continuing...")

    # Patch Info.plist — add .amproj file type registration
    patch_info_plist(app_dir)

    # Remove code signature (we'll re-sign)
    sig_dir = os.path.join(app_dir, '_CodeSignature')
    if os.path.exists(sig_dir):
        shutil.rmtree(sig_dir)
    print("[+] Removed old code signature")

    # Try to re-sign with ldid if available
    try:
        subprocess.run(['ldid', '-S', app_dir], check=True, capture_output=True)
        print("[+] Resigned with ldid")
    except (subprocess.CalledProcessError, FileNotFoundError):
        print("[!] ldid not found or failed — need to re-sign manually")
        print(f"    Run: ldid -S {app_dir}")

    # Repack IPA
    print(f"[*] Repacking to {output_path}...")
    # Remove existing output
    if os.path.exists(output_path):
        os.remove(output_path)
    shutil.make_archive(output_path.replace('.ipa', ''), 'zip', tmpdir)
    os.rename(output_path.replace('.ipa', '.zip'), output_path)
    print(f"[+] Done: {output_path}")

    # Cleanup
    shutil.rmtree(tmpdir)

if __name__ == '__main__':
    main()
