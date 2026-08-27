# Valorant .vrf parsing — de-risking report

**Date:** 2026-08-27 · **Status:** desk research + partial verification against one real file.

> **What changed in this revision.** The first draft was pure desk research (no
> file access). We then ran `sniff_header.py` against a **real competitive replay**
> (match `67933ad4…`, map **Ascent**, build **release-13.04**). That verified some
> claims and **overturned two of them** — the header is plaintext (not encrypted),
> and competitive replays **retain all 10 players' PUUIDs** even though display
> names are stripped. Verified facts are tagged **[VERIFIED: 1 file]**; things still
> resting on one file or on docs are tagged **[UNVERIFIED]** / **[1 file only]**.

## VERIFIED against a real competitive `.vrf` (build release-13.04)

- **Container magic is `0x43F4EFDD`** (Riot's own), *not* vanilla Unreal's
  `0x1CA2E27F`. The first draft's sniffer looked for the wrong magic and wrongly
  concluded "encrypted." **The header is plaintext.**
- **Map and patch are in the clear:** `/Game/Maps/Ascent/Ascent` → Ascent;
  `++Ares-Core+release-13.04` → the build/patch. Readable with zero decompression.
- **A JSON player-loadout block is plaintext**, containing per player a
  `"subject"` (**Riot PUUID — a stable account id**) and a `"characterId"`
  (**agent UUID**; e.g. `1e58de9c-…` = Killjoy).
- **Competitive anonymization is display-name-only.** In the tested file:
  **10 unique PUUIDs**, 6 unique agents (agents overlap across the two teams),
  and **zero** `gameName`/`tagLine`/`displayName` fields. Riot strips the names
  you *see* but leaves the account ids that identify everyone.
- Only the per-tick **network stream after the header is Oodle-compressed** — that
  part still needs the full parser.

---

## TASK 1 — Where files live + inventory

- **Path:** `%LOCALAPPDATA%\VALORANT\Saved\Demos` → `C:\Users\<you>\AppData\Local\
  VALORANT\Saved\Demos` (AppData is hidden by default). **[VERIFIED: file was here]**
- **Naming:** `<match-id>.vrf` — the filename is the Riot match id. **[VERIFIED]**
- **Readable from the header with no parser: match-id, map, build/patch, and the
  10 player PUUIDs + agents.** `inventory.ps1` now pulls Map / Build / player-count
  for every file directly. **[VERIFIED: 1 file]**
- **Match duration:** a `uint32` in the fixed header (~offset 0x20) looks like
  `lengthInMs`, but I won't assert it off one file — the parser is the reliable
  source. **[UNVERIFIED]**
- **Size:** ~40–70 MB. **Retention:** Valorant auto-deletes old matches — copy
  replays out, and note your oldest ones may already be gone (matters for Task 5).

---

## TASK 3 — The identity problem (rewritten — the first draft was wrong here)

**First draft said:** competitive scrubs identity, no resolvable account id survives,
so "the only reliable path is to ask the user to pick their agent."
**The file says otherwise:** every player's **PUUID is in the replay, in plaintext.**
Identity is **solvable from the file itself.**

**The clean design now:**
1. User signs in with **Riot Sign-On (RSO)** → you learn *their own* PUUID.
2. Match that PUUID against the 10 `subject`s in the replay → you have their exact
   slot and agent. No guessing, no fuzzy correlation.
3. You never need to resolve the other 9 to coach the uploader.

### Options, re-ranked with the new evidence

| Rank | Option | Reliability | Cost | Verdict |
|---|---|---|---|---|
| **1** | **RSO login → match user's PUUID to one of the 10 `subject`s** | **Exact** | Low (RSO only; no match-API call needed for the join) | **Primary path.** The file already contains the answer. |
| 2 | **Ask the user to pick their agent** | 100% | ~zero | **Keep as the no-login fallback.** Works with no Riot integration at all. |
| 3 | Resolve all 10 PUUIDs → gamertags via Riot's name API | Exact | Riot production key + policy/privacy risk | Only if you truly need opponents' names. See the flag below. |
| 4 | Crosshair-profile / "Imported Crosshair" string | ~0 | — | Dead end — it's the anonymization label itself, not a leak. |

**Blunt guidance:** build identity on **RSO + PUUID match** (exact, minimal), with
**agent-pick as the offline fallback**. The old "just ask" answer isn't wrong as a
fallback — it's just no longer the *best* you can do.

**The sharpened risk (read this before you de-anonymize anyone):** Riot stripped
those names on purpose. Reading a PUUID offline is passive; **resolving other
players' PUUIDs to real gamertags — or displaying identities Riot deliberately
hid — is exactly the behavior that got Recon Bolt a cease-and-desist**, and it's a
real player-privacy problem, not just a ToS line. For the **uploader's own**
account it's fine (their data). For the **other nine**, don't — coach the uploader
against anonymized opponents.

---

## TASK 4 — Architecture: getting a .NET parser to the browser

*(Unchanged by the file evidence — the plaintext header doesn't help here, because
positions/kills/abilities live in the Oodle-compressed stream. One nuance added.)*

The reference parser is **C#/.NET 10**, event-driven (`IReplayEventSink`,
`FBinaryArchive`), and depends on **Oodle** decompression. Two hard constraints:

1. **Oodle.** The stream chunks are **Oodle (Kraken)**-compressed. Oodle is
   proprietary (RAD/Epic), with no browser build and a license you can't ship to a
   web client. A reverse-engineered *decompressor* exists and can be WASM-compiled,
   but adds legal/maintenance risk. **This gates every client-side path.**
2. **Size/CPU.** ~40–70 MB on disk; the web-replayer reports a **~1 GB** decoded
   intermediate. Decode + walk is seconds of CPU and hundreds of MB of RAM — the
   **5-second tab-freeze you said kills the product**, unless it runs off-thread.

| Path | What it really costs | Freeze risk | Verdict |
|---|---|---|---|
| **Rust → WASM** | Full rewrite (C#→Rust) **and** solve Oodle-in-WASM. Months. | Low *in a Web Worker*; big transient RAM can OOM mobile | Best *eventual* client path; not first |
| **.NET → WASM (Blazor)** | Reuse the C#, but Oodle native `.dll` won't load in the WASM sandbox, heavy runtime, 1 GB heap is brutal | High unless workerized | **Trap** — looks free, hits both walls |
| **Server-side parse on upload** | Box with .NET + Oodle; per-user compute + uploads + ~1 GB transient/job | **Zero** client freeze | **Start here** — what ValorantWebReplayer already does |

**Recommendation:** **parse server-side on upload, cache the compact JSON.** A `.vrf`
decode is a one-time batch job (seconds, then cached forever), not a per-frame cost —
so the "no per-user compute" goal is mostly preserved. **Nuance from Task 3:** the
identity/map/patch metadata is cheap plaintext, so you *could* read *that* in the
browser to show a match-picker instantly, and only send the file to the server for
the heavy positional parse. Revisit Rust→WASM only when a shippable WASM Oodle
exists and server cost actually bites.

**Numbers to measure on your machine:** wall-clock parse time, peak RAM, compact-JSON
size (positions dominate; sampling rate is your shrink lever). **[UNVERIFIED]**

---

## TASK 5 — Constraints report

### Definitely available
- **No parser needed (plaintext header):** match-id, **map**, **build/patch**, and
  **all 10 players' PUUIDs + agents**. **[VERIFIED: 1 file]**
- **Needs the parser (implemented upstream):** player list with team+agent,
  **positions over time**, **kill/death events with timestamps**, movement/rotation
  (view angles ride movement — **[UNVERIFIED]** they're populated).
- Match-id + on-disk timestamp — free.

### Available but flaky / in-progress
- **Ability usage:** upstream "in development"; web-replayer gets ability *locations*
  only via a hand-written patch reading channel-open/`ActorSpawned`. Expect work +
  patch-to-patch breakage.
- **Tick rate & exact duration:** derivable from header/stream; confirm the numbers.
- **Game/world state, economy:** upstream "not started." Don't promise it.

### Corrected from the first draft
- ~~"Real player names in competitive — gone."~~ → Display **names** are stripped,
  but **PUUIDs are retained** in plaintext. You *can* identify players (via the API);
  the question is whether you *should* (policy/privacy — see Task 3).
- ~~"A resolvable Riot account id inside comp replays — assume absent."~~ →
  **Present.** 10 PUUIDs, in the clear. **[VERIFIED: 1 file]**

### Old-patch replays / format fragility
- **Test it with `inventory.ps1`:** sort by Build; any older file where **Players<10**
  or **Magic=`??`** is a file the current format assumptions don't fit. That's your
  concrete old-patch fragility signal. **[UNVERIFIED — run across your 20 files]**
- **Fragility is real regardless:** the original parser playground was **archived
  (July 2026)** and superseded; the successor is **pre-1.0** ("API behaviour is
  likely to change"); the web-replayer needed a manual patch for abilities. No public
  spec, Oodle-compressed, **Riot can change it any patch**. Plan for a parser that
  breaks periodically and needs a maintainer — ongoing cost, not one-time.
- The magic and JSON-loadout layout could themselves shift between patches; treat the
  `0x43F4EFDD` / field names as current-patch facts, not permanent ones.

### Riot third-party policy (a live risk, not a footnote)
- Riot's terms **prohibit reverse-engineering the game/API.** Parsing an undocumented
  `.vrf` sits against the letter of that even offline.
- **Precedent:** Riot **cease-and-desist'd Recon Bolt** offline. The community lives
  in a gray zone Riot has shown it will act on.
- **Offline reading of your own replays** is the lowest-exposure posture. It escalates
  fast when you (a) call Riot's API to resolve PUUIDs→names, or (b) surface the other
  players' identities Riot anonymized. (a) needs a production key + RSO + Riot's data
  rules; (b) is a privacy problem on top of a policy one.
- **Don't build a business assuming Riot's blessing.** Assume a possible C&D and keep
  a fallback. Get real legal advice before monetizing — this flags risk, not clears it.

---

## Bottom line
1. **Identity is solved by the file.** RSO → match the user's PUUID to one of the 10
   `subject`s → exact slot/agent. Agent-pick is the no-login fallback. (First draft's
   "you can only ask" was wrong.)
2. **Do NOT de-anonymize opponents.** Names are stripped on purpose; resolving their
   PUUIDs is the Recon-Bolt risk zone plus a privacy problem. Coach the uploader
   against anonymized opponents.
3. **Cheap metadata is plaintext:** map, patch, match-id, PUUIDs, agents — readable
   with no Oodle, even in the browser. Heavy positional data needs the parser.
4. **Architecture: parse server-side on upload, cache JSON.** Client-side is gated by
   proprietary Oodle + a ~1 GB working set. Rust→WASM later; Blazor WASM is a trap.
5. **The parser is your fragile dependency.** No spec, Oodle, Riot-can-break-it,
   abilities/state incomplete, superseded once. Budget a maintainer.
6. **Still to verify on your machine:** run `inventory.ps1` across all 20 files
   (old-patch fragility, player-count spread), confirm view-angle/tick-rate via the
   full parse, and measure parse-time/RAM/JSON-size.

## Sources
- michel-giehl/ValorantReplayParser (maintained C#/.NET parser) — https://github.com/michel-giehl/ValorantReplayParser
- michel-giehl/ValorantReplayParserPlayground (archived predecessor) — https://github.com/michel-giehl/ValorantReplayParserPlayground
- talhakoek/ValorantWebReplayer (server-parse viewer) — https://github.com/talhakoek/ValorantWebReplayer
- Agent/object UUID list (characterId → agent) — https://gist.github.com/NotOfficer/8da2e088a596bc6acc1b46b4c2d0c64b
- Riot "Replays: Everything You Need to Know" — https://playvalorant.com/en-us/news/dev/replays-everything-you-need-to-know/
- Riot General Policies (reverse-engineering prohibition) — https://support-developer.riotgames.com/hc/en-us/articles/22698591841939-General-Policies
- Riot Developer Terms — https://developer.riotgames.com/terms
- Riot vs the Valorant third-party dev community (Recon Bolt C&D) — https://gist.github.com/giorgi-o/e0fc2f6160a5fd43f05be8567ad6fdd7
- Oodle Data (Unreal) — https://dev.epicgames.com/documentation/en-us/unreal-engine/oodle-data
