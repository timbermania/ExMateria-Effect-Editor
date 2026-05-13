# ExMateria Effect Editor

Live editor for *Final Fantasy Tactics* (PSX) effect files (`E###.BIN`)
— particles, animations, color tracks, sounds. Loads as a Lua script
inside [PCSX-Redux](https://github.com/grumpycoders/pcsx-redux), reads
and patches game memory in real time, and exposes a tabbed UI for
inspecting and editing the structures behind every spell, attack, and
ability animation.

> **Status:** experimental. The data formats are still being mapped;
> features land as the reverse-engineering work catches up. Most useful
> right now for *exploring* effect data and capturing reference traces;
> editing surface is partial.

Part of the [ExMateria family](https://github.com/timbermania):

- **[ExMateria-Effect-Editor](https://github.com/timbermania/ExMateria-Effect-Editor)** — this repo.
- **[ExMateria-ISO-Patcher](https://github.com/timbermania/ExMateria-ISO-Patcher)** — patch FFT discs (replace music slots, etc.) and extract the disc tree for the rest of the family.
- **[ExMateria-DAW-Plugin](https://github.com/timbermania/ExMateria-DAW-Plugin)** — VST3 plugin that plays / edits FFT music in your DAW.
- **[ExMateria-SPU-Core](https://github.com/timbermania/ExMateria-SPU-Core)** — portable C++ implementation of FFT's PSX SPU emulation, shared between the audio tools.

## Prerequisites

- **[PCSX-Redux](https://github.com/grumpycoders/pcsx-redux)** running
  *Final Fantasy Tactics* (SCUS-942.21, NTSC-U).
- An extracted `EFFECT/` directory from the disc — easiest way is to
  run [ExMateria-ISO-Patcher's `fft-iso-patcher extract`](https://github.com/timbermania/ExMateria-ISO-Patcher),
  which dumps `E###.BIN` files to the standard ExMateria assets path.

## Setup

1. **Clone or download** this repo somewhere PCSX-Redux can read. Any
   local filesystem works — Linux, macOS, or Windows. (On WSL, UNC paths
   like `\\wsl$\Ubuntu\home\you\effect-editor` also work from a Windows
   PCSX-Redux build.)
2. **Copy `config_user.lua.example` → `config_user.lua`** and edit:
   - `DATA_PATH`: where the editor stores its captures, savestates, and
     edits (default suggestion: `~/.local/share/pcsx-effect-editor/` on
     Linux, `%APPDATA%\pcsx-effect-editor\` on Windows).
   - `EFFECT_FILES_PATH`: where your extracted `E###.BIN` files live
     (e.g. `~/.local/share/exmateria/assets/EFFECT/` on Linux,
     `%APPDATA%\exmateria\assets\EFFECT\` on Windows).
3. **Launch PCSX-Redux**, load FFT, open the Lua console
   (`Tools → Show Lua Console`), and `dofile()` `main.lua` from wherever
   you cloned the repo. Forward slashes work on every platform, e.g.:
   ```lua
   -- Linux / macOS:
   dofile("/home/you/effect-editor/main.lua")
   -- Windows:
   dofile("C:/path/to/effect-editor/main.lua")
   ```
   The editor's main window should appear as an Imgui panel. Click
   around the tabs.

To reload after editing the Lua source, just `dofile()` `main.lua`
again.

## What's where

```
.
├── main.lua              — entry point; sets up paths and registers UI
├── config.lua            — paths + global constants (overridable via config_user.lua)
├── config_user.lua.example
├── capture.lua           — top-level capture orchestration
├── capture/              — per-aspect capture modules
│   ├── audio_record.lua  — pcsx-redux SPU capture bridge
│   ├── instrument_snapshot.lua
│   ├── note_capture.lua
│   ├── opcode_capture.lua
│   └── spu_voice_trace.lua
├── commands/             — slash-command handlers (debug, file, savestate, …)
├── core/
│   ├── field_schema.lua  — typed schemas for E###.BIN structures
│   ├── memory_utils.lua  — read/write helpers over PCSX-Redux's memory API
│   ├── parser.lua        — binary → in-memory model
│   ├── particle_reader.lua
│   └── structure_manager.lua
├── mips/                 — small MIPS disassembler used for callsite analysis
├── ui/                   — 23 Imgui tabs / panels (frames, particles, curves,
│                            color tracks, time scale, sound timeline, …)
├── utils/
│   ├── bmp.lua           — texture export
│   └── platform.lua      — APPDATA / HOME resolution
└── analysis/             — offline post-processing
    ├── godot_visualizer/ — Godot 4 project for viewing captured trajectories
    ├── generate_godot.py
    └── regress_trajectories.py
```

## Capturing reference data

Several `capture/*.lua` modules hook into PCSX-Redux's memory and audio
events to record what the game *actually* does. The captures land under
`DATA_PATH` (default `%APPDATA%\pcsx-effect-editor\`) and feed both the
editor's UI (for compare-against-reference workflows) and the offline
`analysis/` scripts.

Audio capture uses a small bridge file at
`%APPDATA%\pcsx-redux\bridge_response.txt`; the path resolves at
runtime from `$APPDATA` / `$HOME` so it works on any Windows / WSL /
Linux PCSX-Redux install.

## Source

This repo is published from the
[fft-project monorepo](https://github.com/timbermania/fft-monorepo)
under `effect-editor/`. Edits land there and propagate out via the
publish pipeline.

## License

[MIT](LICENSE). Use however you want; just keep the copyright notice
when you redistribute.
