#!/usr/bin/env python3
"""
Static patch for YTLite.dylib — patches _dvnCheck and _dvnLocked
to bypass the Patreon gate.

_dvnCheck:  patched to MOV W0, #1; RET  (returns 1 = patron active)
_dvnLocked: patched to MOV W0, #0; RET  (returns 0 = not locked)

This makes YTLite's OWN ad blocking, download, and all other
gated features work without a Patreon subscription.
"""
import lief
import struct
import sys
import os

def patch_dylib(dylib_path):
    fat = lief.MachO.parse(dylib_path)
    if fat is None:
        print(f"ERROR: Failed to parse {dylib_path}")
        return False

    # ARM64 instructions
    # MOV W0, #1; RET = return 1 (patron active)
    PATCH_RETURN_1 = struct.pack('<II', 0x52800020, 0xD65F03C0)
    # MOV W0, #0; RET = return 0 (not locked)
    PATCH_RETURN_0 = struct.pack('<II', 0x52800000, 0xD65F03C0)

    patched_total = 0

    for idx, macho in enumerate(fat):
        cpu = macho.header.cpu_type
        print(f"\nSlice {idx}: cpu_type={cpu}")

        # Find __TEXT segment for file offset calculation
        text_seg = None
        for seg in macho.segments:
            if seg.name == "__TEXT":
                text_seg = seg
                break

        if not text_seg:
            print("  WARNING: No __TEXT segment found")
            continue

        patched_slice = 0
        for sym in macho.symbols:
            if sym.name not in ("_dvnCheck", "_dvnLocked"):
                continue

            addr = sym.value
            if addr == 0:
                continue

            # Verify the symbol is in __TEXT
            in_text = False
            for seg in macho.segments:
                if seg.name == "__TEXT" and seg.virtual_address <= addr < seg.virtual_address + seg.virtual_size:
                    in_text = True
                    break

            if not in_text:
                print(f"  WARNING: {sym.name} @ 0x{addr:x} not in __TEXT, skipping")
                continue

            # Calculate file offset
            # For FAT binaries, LIEF handles the slice offset internally
            file_offset = addr - text_seg.virtual_address + text_seg.file_offset

            # Choose the right patch
            if sym.name == "_dvnCheck":
                patch = PATCH_RETURN_1  # return 1 = patron active
                desc = "MOV W0, #1; RET (patron active)"
            else:  # _dvnLocked
                patch = PATCH_RETURN_0  # return 0 = not locked
                desc = "MOV W0, #0; RET (not locked)"

            print(f"  {sym.name}: VA=0x{addr:x} file_offset=0x{file_offset:x}")

            # Read current bytes
            with open(dylib_path, 'rb') as f:
                f.seek(file_offset)
                original = f.read(8)
            print(f"    original: {original.hex()}")

            # Write patch
            with open(dylib_path, 'r+b') as f:
                f.seek(file_offset)
                f.write(patch)
            print(f"    patched:  {patch.hex()} ({desc})")
            patched_slice += 1

        patched_total += patched_slice
        print(f"  Patched {patched_slice} function(s) in this slice")

        # ── ALSO patch the lock variable in __DATA.__data ──
        # _dvnLocked reads from __DATA.__data + offset 0x5D81
        # But 3 OTHER code paths also read it directly (bypassing _dvnLocked)
        # They use: LDRB + EOR #1 + AND #1 → variable=0 means feature ACTIVE
        # So we need variable = 0 for the direct readers
        # (_dvnLocked is already patched to always return 0 regardless)
        for seg in macho.segments:
            if seg.name != "__DATA":
                continue
            for sec in seg.sections:
                if sec.name != "__data":
                    continue

                # The variable is at offset 0x5D81 from __DATA.__data start
                var_offset_in_section = 0x5D81
                if var_offset_in_section + 2 > sec.size:
                    print(f"  WARNING: lock variable offset 0x5D81 out of range")
                    break

                file_offset = sec.offset + var_offset_in_section
                print(f"  Lock variable: section={seg.name}.{sec.sectname} file_offset=0x{file_offset:x}")

                with open(dylib_path, 'rb') as f:
                    f.seek(file_offset)
                    original = f.read(2)
                print(f"    original: {original.hex()}")

                # Write 0x00 for both bytes (variable + adjacent flag)
                # variable=0 → direct readers: EOR(0,1)=1 AND 1=1 → feature ACTIVE
                with open(dylib_path, 'r+b') as f:
                    f.seek(file_offset)
                    f.write(b'\x00\x00')
                print(f"    patched:  0000 (features active for direct readers)")
                patched_total += 1
                break

    print(f"\nTotal patches applied: {patched_total}")
    return patched_total > 0

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 patch_dylib.py <path_to_YTLite.dylib>")
        sys.exit(1)

    path = sys.argv[1]
    if not os.path.exists(path):
        print(f"ERROR: File not found: {path}")
        sys.exit(1)

    success = patch_dylib(path)
    sys.exit(0 if success else 1)
