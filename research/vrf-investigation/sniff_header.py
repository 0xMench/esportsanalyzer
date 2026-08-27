#!/usr/bin/env python3
"""
sniff_header.py  —  inspect ONE .vrf and pull the plaintext fields Riot leaves
in the clear (match id, build/patch, map, and every player's PUUID + agent).

    python sniff_header.py path\\to\\<matchid>.vrf

VERIFIED against a real competitive replay (build release-13.04, 2026-08):
  * Container magic is Riot's 0x43F4EFDD (NOT vanilla Unreal 0x1CA2E27F).
  * The header + a JSON player-loadout block are PLAINTEXT (not encrypted).
    Only the per-tick network stream that follows is Oodle-compressed.
  * Competitive replays strip display NAMES but keep all 10 `subject` PUUIDs
    and each player's `characterId` (agent) in the clear. See REPORT.md Task 3.

This reads the whole file (it's tens of MB) to catch loadout data that sits
past the first few KB. It is reconnaissance, not a full parser — for positions/
kills/tick-rate you still need the C# parser (parse_one.md).
"""
import sys, re, struct

RIOT_MAGIC = 0x43F4EFDD   # observed at offset 0 in real .vrf files

def main(p):
    with open(p, "rb") as fh:
        data = fh.read()
    print(f"file: {p}\nsize: {len(data):,} bytes ({len(data)/1024/1024:.1f} MB)\n")

    # --- hex dump of first 128 bytes (the fixed header) ---
    print("--- first 128 bytes ---")
    for off in range(0, min(128, len(data)), 16):
        chunk = data[off:off+16]
        hexs = " ".join(f"{b:02x}" for b in chunk)
        asci = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"{off:04x}  {hexs:<47}  {asci}")

    # --- container magic ---
    magic = struct.unpack_from("<I", data, 0)[0] if len(data) >= 4 else 0
    print(f"\nmagic @0: 0x{magic:08X}  ->  " +
          ("Riot .vrf container (expected)" if magic == RIOT_MAGIC else
           "UNEXPECTED — format may have shifted; rest of this may be wrong"))

    # A few uint32s live between the magic and the match-id FString. One of them
    # is plausibly lengthInMs. Printed as candidates, not asserted.
    if len(data) >= 44:
        cands = struct.unpack_from("<III", data, 0x1c)  # 0x1c..0x28
        print("candidate uint32s @0x1c/0x20/0x24 (one may be duration-ms):",
              [f"{c} (~{c/1000:.0f}s)" for c in cands])

    # --- plaintext strings we care about (scan whole file) ---
    def uniq(pat, label, limit=64):
        vals = []
        for m in re.finditer(pat, data):
            v = m.group(0).decode("latin1")
            if v not in vals:
                vals.append(v)
        print(f"\n--- {label}: {len(vals)} unique ---")
        for v in vals[:limit]:
            print(f"  {v}")
        return vals

    uniq(rb"\+\+[A-Za-z0-9]+-Core\+release-[0-9.]+", "build / patch label")
    uniq(rb"/Game/Maps/[A-Za-z0-9_]+/[A-Za-z0-9_]+", "map path")
    subs  = uniq(rb'"subject":\s*"[0-9a-f-]{36}"', "player PUUIDs (subject)")
    chars = uniq(rb'"characterId":\s*"[0-9a-f-]{36}"', "agents (characterId)")

    # name fields — expected EMPTY in competitive (that's the anonymization)
    names = uniq(rb'"(?:gameName|tagLine|displayName|playerName)":\s*"[^"]*"',
                 "display-name fields (expect EMPTY in competitive)")

    print("\n=== READ-OUT ===")
    print(f"  players (unique PUUIDs): {len(subs)}   (10 => full lobby present)")
    print(f"  distinct agents:         {len(chars)} (may be <10; agents overlap across teams)")
    print(f"  leaked names:            {len(names)} "
          f"({'anonymized — names stripped, PUUIDs remain' if not names else 'NOT anonymized (custom/scrim?)'})")
    print("  NOTE: PUUIDs are stable Riot account ids. Resolving them to gamertags")
    print("        needs Riot's API and is the Recon-Bolt policy-risk zone (REPORT.md).")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__); sys.exit(1)
    main(sys.argv[1])
