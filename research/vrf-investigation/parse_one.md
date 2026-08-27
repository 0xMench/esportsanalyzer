# TASK 2 — Parse one .vrf into JSON (runbook you execute on Windows)

I can't run this for you: there is no .vrf in the cloud sandbox, and the parser
is Windows/.NET with an Oodle dependency. This is the exact reproducible path.
Everything below is derived from the parser's README/structure, not from a run I
did — so the *shape* is right; exact field names may drift because the parser is
pre-1.0 and says "API behaviour is likely to change."

## Which parser
Use **michel-giehl/ValorantReplayParser** (C#/.NET 10, actively maintained).
NOT `ValorantReplayParserPlayground` — it was archived July 2026 and points here.
`talhakoek/ValorantWebReplayer` is just a viewer wrapping the *playground* parser
as a compiled .exe; its server-side pipeline (`.exe` -> positions.json/events.json/
abilities.json) is a good reference for the JSON you want, but the parser proper
is the michel-giehl repo.

## Steps
```powershell
# 1. Prereqs: install .NET 10 SDK. Oodle: Unreal replays are Oodle-compressed.
#    The parser bundles/looks for oo2core (Oodle) — if it errors on a missing
#    oo2core_*.dll, copy one from a UE install or the Valorant install next to
#    the built exe. This is the #1 thing that will block a first run.

git clone https://github.com/michel-giehl/ValorantReplayParser
cd ValorantReplayParser
dotnet build -c Release

# 2. The repo ships a CLI demo (CliReader) with `log` and `export` commands.
#    Point it at ONE copied-out replay (copy it first — Valorant deletes old ones).
dotnet run --project src/CliReader -c Release -- export `
    --input "D:\vrf_backup\<matchid>.vrf" `
    --output ".\out\<matchid>.json"

# If the arg names differ, run with `--help`; the two verbs are log (stream
# decoded events to stdout) and export (write structured output).
```

## What you can expect in the JSON, mapped to your Task-2 asks
Confidence is mine, from the parser's stated progress table:

| You asked for                    | Reachable? | Where / caveat                                              |
|----------------------------------|-----------|-------------------------------------------------------------|
| tick rate                        | likely    | from replay header/network settings; verify the value       |
| match duration                   | yes       | header lengthInMs                                           |
| 10 players: team + agent         | yes       | "agent selections" is implemented                          |
| player identity fields           | PARTIAL   | competitive = "Player N" only (see REPORT.md, Task 3)      |
| positions over time              | yes       | `RemoteCharacterMovementReceived` movement events           |
| view angles                      | likely    | rotation rides with movement events; confirm it's populated |
| kill/death events + timestamps   | yes       | "gunplay/combat events" implemented                        |
| kill/death POSITIONS             | likely    | join kill event tick -> nearest movement sample per actor   |
| ability usage events             | FLAKY     | "in development" upstream; the web-replayer patch pulls     |
|                                  |           | ability locations out of ActorSpawned/channel-open events   |

## The self-check when it runs
Dump the summary and sanity-check against a match you remember:
- 10 players, 5v5, agents you recognize.
- duration within ~a minute of the real match.
- kill count roughly matches the scoreboard.
If those three line up, the parse is trustworthy enough to build on. If agents
are blank or you get 9 or 11 players, stop — the format shifted under the parser.

## Heads-up on the intermediate size
The web-replayer notes a raw decode of ~1 GB per replay before it's reduced to
JSON. Parse in a temp dir and delete the intermediate. This is also the core
reason browser-side parsing is hard (see REPORT.md Task 4).
