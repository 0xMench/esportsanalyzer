#!/usr/bin/env python3
"""
sniff_header.py  —  poke at the first bytes of ONE .vrf to see how much of the
header is plaintext before the Oodle-compressed stream begins.

    python sniff_header.py path\to\<matchid>.vrf

I could not run this against a real file (no .vrf in the cloud sandbox), so the
field offsets below are the STANDARD Unreal local-file replay layout, not a
Riot-confirmed layout. Use the hexdump + strings output to judge whether Riot's
container matches it or has a custom/encrypted prefix. This is a reconnaissance
tool, not a parser.
"""
import sys, struct

UNREAL_MAGIC = 0x1CA2E27F  # FLocalFileReplayCustomVersion magic

def main(p):
    with open(p, "rb") as fh:
        data = fh.read(8192)
    print(f"file: {p}\nread: {len(data)} bytes (first 8 KB)\n")

    # hex + ascii dump of first 256 bytes
    print("--- first 256 bytes ---")
    for off in range(0, min(256, len(data)), 16):
        chunk = data[off:off+16]
        hexs = " ".join(f"{b:02x}" for b in chunk)
        asci = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"{off:04x}  {hexs:<47}  {asci}")

    # find Unreal magic
    idx = data.find(struct.pack("<I", UNREAL_MAGIC))
    print("\n--- unreal replay magic (0x1CA2E27F) ---")
    if idx == -1:
        print("NOT FOUND in first 8 KB -> Riot prefix is custom/encrypted, or magic sits deeper.")
    else:
        print(f"found at offset {idx}. Standard header follows: magic,uint32 fileVersion,")
        print("int32 lengthInMs, uint32 networkVersion, uint32 changelist, FString friendlyName,")
        print("then timestamp/bCompressed/... Try reading fileVersion/lengthInMs right after it:")
        try:
            fv, length_ms, netv, changelist = struct.unpack_from("<IiII", data, idx+4)
            print(f"  fileVersion={fv}  lengthInMs={length_ms} ({length_ms/1000:.1f}s)"
                  f"  networkVersion={netv}  changelist={changelist}")
            print("  ^ if lengthInMs looks like a plausible match length, the layout matches.")
        except struct.error:
            print("  (couldn't unpack — not enough bytes)")

    # printable strings >= 4 chars (map names, agent ids, 'Player N', etc. often leak here)
    print("\n--- printable strings (len>=4) in first 8 KB ---")
    cur, out = [], []
    for b in data:
        if 32 <= b < 127:
            cur.append(chr(b))
        else:
            if len(cur) >= 4: out.append("".join(cur))
            cur = []
    if len(cur) >= 4: out.append("".join(cur))
    for s in out[:60]:
        print(f"  {s}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(1)
    main(sys.argv[1])
