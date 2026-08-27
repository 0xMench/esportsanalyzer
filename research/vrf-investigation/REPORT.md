# Valorant .vrf parsing — de-risking report

**Date:** 2026-08-27 · **Author:** investigation session · **Status:** desk research only.

> **Read this first.** This ran in a cloud Linux sandbox with **no access to your
> Windows machine or your ~20 replays**. Nothing here was tested against a real
> `.vrf`. Every claim is either (a) from the parsers' own source/docs and Riot's
> published policy — solid, or (b) marked **UNVERIFIED** — you confirm it by running
> `inventory.ps1`, `sniff_header.py`, and the `parse_one.md` runbook on your files.
> The blunt stuff you asked for is not softened.

---

## TASK 1 — Where files live (needs your confirmation)

- **Path:** `%LOCALAPPDATA%\VALORANT\Saved\Demos` → e.g.
  `C:\Users\<you>\AppData\Local\VALORANT\Saved\Demos`. AppData is hidden by
  default, which is why people think the folder is missing.
- **Naming:** each file is `<match-id>.vrf`, a GUID like
  `b9946017-117f-4a22-9d27-cbd17ab12a93.vrf`. **The filename is the Riot match id.**
  That single fact does a lot of work in Task 3.
- **Size:** ~40–70 MB each (consistent with your "files are large" note).
- **Retention:** Valorant keeps only your recent matches and **auto-deletes older
  ones**. Copy replays out before analyzing — this also means your "oldest files"
  for Task 5's old-patch test may already be gone. Check.
- `inventory.ps1` gives you reliable size/timestamp/match-id today. Map/patch/
  duration from the header is best-effort — see Task 5.

---

## TASK 3 — The identity problem (the important one)

**Anonymization is real and confirmed by multiple independent sources.** In
**competitive** matches the 10 players show as `Player N` / `Imported Crosshair …`.
Real Riot IDs only survive in **custom/scrim** replays. So for your actual use
case (ranked coaching), the names are gone. Verify on your own files with
`sniff_header.py` and the full parse, but do not expect this to change.

**The reframe that matters:** you don't need names. You need to know **which of
the 10 anonymized slots is the uploader**. And the replay *does* still expose each
player's **agent** and **team/side**. In any Valorant match, agents are unique per
team — no two players on the same side run the same agent. So `(agent, side)` is a
unique key for all 10 players. That collapses "who is the user" into "which agent
did the user play," which the user trivially knows.

### Options, ranked by reliability × cost

| Rank | Option | Reliability | Cost | Verdict |
|---|---|---|---|---|
| **1** | **Ask the user to pick their agent** (+ side if ever ambiguous) | **100%** | **~zero** | **Do this.** |
| 2 | Match-id → Riot match API, join anon slot ↔ real PUUID on `(agent, team)` | High *if* you get API access | High + ongoing + policy risk | Optional enrichment, not identity |
| 3 | Crosshair-profile / "Imported Crosshair" string as an identifier | ~0 in comp | low | Doesn't work — it's the anonymized label itself |
| 4 | A stable per-account ID inside the comp `.vrf` that maps to a Riot account | Unknown, likely absent | — | Don't count on it; comp is scrubbed by design |

**Blunt answer, as requested: the only clean, robust answer is to ask the user to
pick their agent.** It is free, instant, needs no Riot API, carries no policy risk,
and is unambiguous because agents are unique per team. Build identity on that.
Everything else is worse on at least one axis:

- **Option 2** is the *only* thing that gets you real gamertags and enriched stats,
  and it's genuinely reliable because `(agent, team)` is a clean join key and the
  match id is sitting in the filename — no fuzzy timestamp/score correlation needed.
  But: it requires a Riot **production API key** (approval is slow and discretionary),
  **RSO** so the user authorizes their own account, per-user API calls (so you're
  back to server + compute you wanted to avoid), and it plants you directly in the
  policy zone that got Recon Bolt a cease-and-desist (Task 5). Treat it as an
  *optional "link your Riot account for real names & stats"* feature layered on top
  of agent-pick — never as the primary identity mechanism.
- **Option 3** is a category error: "Imported Crosshair" *is* the anonymization, not
  a leak through it.
- **Option 4**: no evidence a resolvable account id survives comp anonymization;
  assume Riot removed it on purpose. Confirm with `sniff_header.py`, but don't
  design around finding one.

---

## TASK 4 — Architecture: getting a .NET parser to the browser

The reference parser is **C#/.NET 10**, event-driven (`IReplayEventSink`,
`FBinaryArchive`), and depends on **Oodle** decompression. Two hard constraints
drive everything:

1. **Oodle.** Valorant replays are Unreal network replays; the stream chunks are
   **Oodle (Kraken)**-compressed. Oodle is proprietary (RAD/Epic) with **no
   browser build and a license you can't ship to a web client.** A community
   reverse-engineered *decompressor* exists and can be compiled to WASM, but that
   adds its own legal/maintenance risk. **Oodle is the gate on every client-side
   path**, not the parser logic.
2. **Size/CPU.** ~40–70 MB compressed on disk; the web-replayer reports a **~1 GB**
   fully-decoded intermediate per replay. Decode + walk-the-stream is seconds of
   CPU and hundreds of MB of RAM. In a browser tab that is **exactly the 5-second
   freeze you said kills the product** — unless it runs off the main thread.

| Path | What it really costs | Parse-time / freeze risk | Verdict |
|---|---|---|---|
| **Port to Rust → WASM** | Rewrite the whole parser (it's C#, not Rust — this is a *rewrite*, not a recompile) **and** solve Oodle-in-WASM. Months. | Good *if* run in a **Web Worker** (no UI freeze) — but big transient RAM (~hundreds MB) can still OOM mobile tabs | Best *eventual* client-side story; **do not start here** |
| **.NET → WASM (Blazor WASM)** | Ship the C# nearly as-is. But Blazor WASM runtime download is heavy, it's slower than native, **Oodle native .dll won't load in the WASM sandbox** (you'd still need a WASM Oodle), and 1 GB working set in the .NET/WASM heap is brutal | High freeze/OOM risk unless workerized; runtime cold-start is its own UX cost | Tempting (reuses C#) but the Oodle + memory wall makes it fragile |
| **Server-side parse on upload** | A box with .NET + Oodle. Per-user compute (the thing you wanted to avoid) + 40–70 MB uploads + ~1 GB transient disk/RAM per job | **Zero** browser freeze — nothing heavy runs client-side | **Start here.** It's literally what ValorantWebReplayer already does. |

**Recommendation — blunt:** start **server-side**. It's the only path where the
parser already runs today, it sidesteps Oodle-in-the-browser entirely, and it
removes the freeze risk by construction. Yes, it's the per-user compute you didn't
want — but a `.vrf` decode is a batch job (seconds, then cache the JSON forever),
not a live per-frame cost. Parse once on upload, store the compact JSON, and every
later view/coaching pass is cheap. Revisit Rust→WASM only if server compute
becomes a real cost problem at scale, and only after someone has a shippable WASM
Oodle decompressor. **Blazor WASM is the trap option**: it looks like a free reuse
of the C# code but you still hit the Oodle wall and the memory wall, just with a
heavier runtime.

**Numbers to confirm on your machine (I could not):** wall-clock parse time for one
replay, peak RAM, and the compact-JSON output size (positions dominate — sampling
rate is your main lever to shrink it).

---

## TASK 5 — Constraints report

### Definitely available (from the parser's implemented feature set)
- Match duration; player list with **team + agent**; **positions over time**;
  **kill/death combat events** with timestamps; movement/rotation (**view angles**
  UNVERIFIED-but-likely, they ride the movement events).
- Match id (filename) and on-disk timestamp — free, no parsing.

### Available but flaky / in-progress
- **Ability usage:** upstream marks it "in development." The web-replayer only gets
  ability *locations* via a **manual patch** that reads channel-open/`ActorSpawned`
  events. Assume abilities need extra work and may break patch-to-patch.
- **Tick rate:** almost certainly derivable from the header/network settings, but
  confirm the exact number rather than trusting a constant.
- **Game state / world state / economy:** upstream says **"not started."** Don't
  promise round economy, spike state beyond timing, etc., without building it.

### Definitely NOT available
- **Real player names in competitive** — anonymized by design (`Player N`).
- **A resolvable Riot account id inside comp replays** — assume absent.
- Anything requiring Riot's servers while staying "offline" — mutually exclusive.

### Old-patch replays / format fragility
- **UNVERIFIED — test on your oldest files.** The runbook's self-check (10 players,
  right agents, sane duration) is your pass/fail. My honest expectation: replays
  from a meaningfully older patch **will parse partially or fail**, because the
  parser is reverse-engineered field-by-field against *current* matches.
- **Fragility signal from the repos themselves:** the original playground was
  **archived (July 2026)** and superseded; the successor is **pre-1.0 and states
  "API behaviour is likely to change."** The web-replayer needed a **hand-written
  patch** just to get ability locations. This is a format with **no public spec,
  Oodle-compressed, that Riot can change any patch** with zero notice. Plan for a
  parser that breaks periodically and needs a maintainer — this is an ongoing cost,
  not a one-time integration. (Note: the exact 11.06 date is muddy in public
  sources — some point to a later regional rollout than May 2025 — worth you
  pinning down, but it doesn't change the fragility conclusion.)

### Riot third-party policy (this is a real risk, not a footnote)
- Riot's terms **prohibit reverse-engineering the game/API**. Parsing an
  undocumented `.vrf` by reverse-engineering its format sits **against the letter**
  of that, even done offline.
- **Precedent:** Riot issued a **cease-and-desist that took Recon Bolt offline**
  (a popular third-party Valorant app). The third-party dev community operates in a
  gray zone Riot has shown it will act on.
- **Reading files offline** (no Riot servers touched) is the *least* exposed posture
  — but "offline" ends the moment you add Option-2 match-API enrichment, which
  requires a **production API key + RSO** and Riot's data rules (opt-in data
  sharing, the disclaimer that account-linking makes data public). That upgrade is
  where policy risk becomes concrete.
- **Practical stance:** an offline `.vrf` coaching tool is *lower* risk than an app
  hitting Riot's private API, but it is **not zero**, and it depends on a format
  Riot can break or explicitly disallow. Don't build a business assuming Riot's
  blessing; assume you may get a C&D and have a fallback. Get real legal advice
  before monetizing — I'm flagging risk, not clearing you.

---

## Bottom line
1. **Identity: just ask the user their agent.** Reliable, free, no API, no policy
   risk. Offer Riot-account linking later as optional enrichment, not as identity.
2. **Architecture: parse server-side on upload, cache JSON.** It's the only path
   the parser runs on today and it kills the browser-freeze problem outright.
   Rust→WASM is a real-but-later option gated on a shippable WASM Oodle; Blazor WASM
   is a trap (Oodle + memory wall, heavier runtime).
3. **The parser is the fragile part of your whole product.** No spec, Oodle,
   Riot-can-break-it-any-patch, abilities/game-state incomplete, superseded once
   already. Budget for a maintainer, not a one-off.
4. **Policy is a live risk.** Offline reading is the safer posture; the moment you
   touch Riot's API you inherit the Recon-Bolt exposure. Get legal advice before you
   monetize.
5. **What still needs your machine:** run the three scripts against real files to
   confirm the header fields, the anonymization, view-angle population, tick rate,
   old-patch parse success, and real parse-time/RAM/JSON-size numbers.

## Sources
- michel-giehl/ValorantReplayParser (maintained C#/.NET parser) — https://github.com/michel-giehl/ValorantReplayParser
- michel-giehl/ValorantReplayParserPlayground (archived predecessor) — https://github.com/michel-giehl/ValorantReplayParserPlayground
- talhakoek/ValorantWebReplayer (server-parse viewer, anonymization notes) — https://github.com/talhakoek/ValorantWebReplayer
- Riot "Replays: Everything You Need to Know" — https://playvalorant.com/en-us/news/dev/replays-everything-you-need-to-know/
- Riot General Policies (reverse-engineering prohibition) — https://support-developer.riotgames.com/hc/en-us/articles/22698591841939-General-Policies
- Riot Developer Terms — https://developer.riotgames.com/terms
- Writeup: Riot vs the Valorant third-party dev community (Recon Bolt C&D) — https://gist.github.com/giorgi-o/e0fc2f6160a5fd43f05be8567ad6fdd7
- Oodle Data (Unreal) — https://dev.epicgames.com/documentation/en-us/unreal-engine/oodle-data
- FortniteReplayDecompressor (the lineage the parser forks from) — https://fortnitereplaydecompressor.readthedocs.io/en/stable/overview/
