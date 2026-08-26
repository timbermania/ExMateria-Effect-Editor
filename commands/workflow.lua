-- commands/workflow.lua
-- Quick test cycle and apply commands

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (will be injected)
--------------------------------------------------------------------------------

local config = nil
local logging = nil
local MemUtils = nil
local apply_all_edits_fn = nil
local ee_reload_fn = nil
local texture_ops = nil
local audio_record = nil
local parser = nil

function M.set_dependencies(cfg, log_module, mem_utils, apply_all_edits, reload_fn, tex_ops, audio_rec, parser_module)
    config = cfg
    logging = log_module
    MemUtils = mem_utils
    apply_all_edits_fn = apply_all_edits
    ee_reload_fn = reload_fn
    texture_ops = tex_ops
    audio_record = audio_rec
    parser = parser_module
end

--------------------------------------------------------------------------------
-- ee_test: Quick test cycle - reload savestate, apply changes, resume
--
-- opts.install_mute_hook: if true, install audio_record.mute_music() in the
--   nextTick callback (after savestate reload). Off by default because the
--   typical iteration loop uses a no-music-patched ISO; the music-mute hook
--   has a hardcoded blacklist (resource_id ∈ {0, 283}) that silences valid
--   effect sounds. Audio capture (ee_capture_audio_start) opts in.
-- opts.skip_patching: if true, skip apply_all_edits_fn and the texture
--   reload entirely. Just reload the savestate and resume. Useful for
--   confirming what the unmodified ROM does (baseline / sanity check).
-- opts.dry_writes: if true, still call apply_all_edits_fn but in
--   dry-write mode (pauses + refreshes + returns without writing). Lets
--   us A/B the pause/resume choreography against the actual writes when
--   the writes produce byte-identical bytes (apply yields a bin that
--   already matches the ROM) yet audio still breaks.
--------------------------------------------------------------------------------

function M.ee_test(opts)
    opts = opts or {}
    -- Check quiet mode - only log if not quiet
    local quiet = EFFECT_EDITOR.test_quiet

    if not quiet then
        logging.log("========================================")
        logging.log("=== EE_TEST (TEST CYCLE) ===")
        logging.log("========================================")
    end

    -- Check prerequisites - need a selected session name
    local has_session_name = EFFECT_EDITOR.session_name and EFFECT_EDITOR.session_name ~= ""
    if not quiet then
        logging.log(string.format("  session_name: '%s'", EFFECT_EDITOR.session_name or "nil"))
        logging.log(string.format("  memory_base: 0x%08X", EFFECT_EDITOR.memory_base or 0))
        logging.log(string.format("  effect_id: %d", EFFECT_EDITOR.effect_id or 0))
    end

    if not has_session_name then
        logging.log_error("No session selected! Click a session in the list first.")
        return false
    end

    if EFFECT_EDITOR.memory_base < 0x80000000 then
        logging.log_error("No memory target! Capture an effect first.")
        return false
    end

    -- Check savestate file exists before trying to reload.
    -- Pattern used elsewhere in this codebase: APPDATA env var is
    -- only set on Windows; backslash-path on Windows, forward on
    -- Linux (config.SAVESTATE_PATH already uses /).
    local ss_path = config.SAVESTATE_PATH .. EFFECT_EDITOR.session_name .. ".sstate"
    local ss_win_path = ss_path:gsub("/", "\\")
    local ss_io_path = os.getenv("APPDATA") and ss_win_path or ss_path
    local ss_file = io.open(ss_io_path, "rb")
    if ss_file then
        local ss_size = ss_file:seek("end")
        ss_file:close()
        if not quiet then
            logging.log(string.format("  Savestate file: %d bytes", ss_size or 0))
        end
    else
        logging.log_error(string.format("  Savestate file NOT FOUND: %s", ss_io_path))
        return false
    end

    -- Step 1: Reload savestate (this also pauses)
    if not quiet then logging.log("Step 1: Reloading savestate...") end
    if not ee_reload_fn(nil, quiet) then
        logging.log_error("Failed to reload savestate")
        return false
    end
    if not quiet then logging.log("Step 1 complete: ee_reload returned true") end

    -- Step 2: Apply all edits to memory
    -- Need to wait a tick for savestate to fully load before writing
    if not quiet then logging.log("Scheduling Step 2 on nextTick...") end
    PCSX.nextTick(function()
        if not quiet then
            if opts.skip_patching then
                logging.log("Step 2: SKIPPING patching (baseline test, no apply_all_edits)")
            else
                logging.log("Step 2: Applying all edits to memory...")
            end
        end

        -- Verify effect is in memory after reload
        MemUtils.refresh_mem()
        local lookup_base = MemUtils.read32(config.EFFECT_BASE_LOOKUP_TABLE + EFFECT_EDITOR.effect_id * 4)
        if not quiet then
            logging.log(string.format("  Post-reload lookup_table[%d]: 0x%08X", EFFECT_EDITOR.effect_id, lookup_base or 0))
        end

        if not opts.skip_patching then
            -- Apply structure changes FIRST (this may shift memory addresses)
            if apply_all_edits_fn then
                apply_all_edits_fn(true, {dry_writes = opts.dry_writes})  -- silent
            end

            -- Check for modified texture BMP and reload if needed
            -- IMPORTANT: Must happen AFTER structure changes, otherwise memory shift overwrites texture!
            if not quiet then logging.log("  Checking for texture changes...") end
            if texture_ops then
                local reloaded = texture_ops.maybe_reload_texture_before_test()
                if reloaded and not quiet then
                    logging.log("  Reloaded modified texture from BMP")
                end
            else
                if not quiet then logging.log("  texture_ops module not available") end
            end

            if not quiet then logging.log("Step 2 complete: all edits applied") end
        end

        -- Mute background music (must be AFTER savestate load)
        -- Savestate restores game state, so we install mute hook here.
        -- Opt-in only: the hook blacklists resource_id ∈ {0, 283} and will
        -- silence valid effect sounds on a no-music-patched ISO.
        if opts.install_mute_hook and audio_record then
            audio_record.mute_music()
            if not quiet then logging.log("  Music mute hook installed (effects preserved)") end
        end

        -- Prime SFX-voice "previous-voice residue" so the runtime gate at
        -- RAM 0x80150AB0 doesn't mute voices whose predecessor happens to
        -- be cold in this savestate.
        --
        -- Background: that gate reads `lhu chan_prev+0x08` and clears the
        -- current voice's chan+0x92 (the vol-formula multiplier) iff the
        -- value is 0 or 0x011B. silenceAllVoices() resets SPU envelopes
        -- but not WRAM channel structs, so chan+0x08 enters the test cycle
        -- at whatever the savestate captured — typically 0 for SFX slot
        -- pairs that hadn't been exercised. Real PSX gameplay reaches each
        -- effect from arbitrary prior states; the residue is rarely 0.
        --
        -- We patch only voices marked SFX (chan+0x0B == 0x20) and only
        -- when the residue is currently 0 — leaves music voices and
        -- voices with genuine residue alone. Value 0x010E mirrors the
        -- runtime-observed residue on voices 16/17 in our captures.
        --
        -- See research/effect_sound/working_documents/VOICE_19_CHAN_08_SAVESTATE_RESIDUE.md.
        local prime_enabled = opts.prime_sfx_residue
        if prime_enabled == nil then
            prime_enabled = EFFECT_EDITOR.test_prime_sfx_residue
            if prime_enabled == nil then prime_enabled = true end
        end
        if prime_enabled then
            -- Cover every voice whose chan+0x08 could be read as a
            -- "predecessor" by the gate when an SFX-pool voice plays.
            -- The predecessor relationship is fixed by RAM layout: voice
            -- N's gate reads voice N-1's chan+0x08. So if any SFX effect
            -- plays on voice K (K∈[16,21]), voice K-1's chan+0x08 matters.
            -- That extends the prime range down to v15 (predecessor of
            -- v16, which lives outside the labeled SFX pool — marker
            -- byte = 0x00 in our captures).
            --
            -- Accept marker 0x20 (labeled SFX) or 0x00 (uninitialized /
            -- pool-boundary voice 15). Skip 0x80 (MUSIC) to avoid
            -- perturbing music voices.
            local PRIME_TARGETS = {
                {voice = 15, base = 0x8003703A},  -- predecessor of v16; marker may be 0x00
                {voice = 16, base = 0x8003719A},
                {voice = 17, base = 0x800372FA},
                {voice = 18, base = 0x8003745A},
                {voice = 19, base = 0x800375BA},
                {voice = 20, base = 0x8003771A},
                {voice = 21, base = 0x8003787A},
                -- voices 22, 23 are MUSIC (marker = 0x80); skip
            }
            local PRIME_LO, PRIME_HI = 0x0E, 0x01  -- composite halfword 0x010E
            local SENTINEL_011B = 0x011B          -- second value the gate clears on
            MemUtils.refresh_mem()
            local patched, skipped_music, skipped_residue = 0, 0, 0
            for _, entry in ipairs(PRIME_TARGETS) do
                local marker = MemUtils.read8(entry.base + 0x0B) or 0
                local lo = MemUtils.read8(entry.base + 0x08) or 0
                local hi = MemUtils.read8(entry.base + 0x09) or 0
                local halfword = lo + hi * 0x100
                local would_trigger_gate = (halfword == 0) or (halfword == SENTINEL_011B)
                if marker == 0x80 then
                    skipped_music = skipped_music + 1
                elseif not would_trigger_gate then
                    -- Genuine non-zero, non-0x011B residue — preserve it.
                    skipped_residue = skipped_residue + 1
                elseif marker == 0x20 or marker == 0x00 then
                    MemUtils.write8(entry.base + 0x08, PRIME_LO)
                    MemUtils.write8(entry.base + 0x09, PRIME_HI)
                    patched = patched + 1
                    if not quiet then
                        local why = (halfword == 0) and "was 0x0000" or "was 0x011B"
                        local mlabel = (marker == 0x20) and "SFX" or "uninit"
                        logging.log(string.format(
                            "  Primed v%d chan+0x08 = 0x010E  (base 0x%08X, %s, marker %s)",
                            entry.voice, entry.base, why, mlabel))
                    end
                end
            end
            if not quiet then
                logging.log(string.format(
                    "  Prime SFX residue: %d patched, %d preserved (genuine residue), %d skipped (music)",
                    patched, skipped_residue, skipped_music))
            end
        end

        -- Step 3: Resume emulator
        if not quiet then logging.log("Step 3: Resuming emulator...") end
        PCSX.resumeEmulator()

        if not quiet then
            logging.log("========================================")
            logging.log("=== TEST CYCLE COMPLETE ===")
            logging.log("========================================")
        end
        EFFECT_EDITOR.status_msg = "Test cycle complete!"
    end)

    return true
end

--------------------------------------------------------------------------------
-- ee_apply: Apply all edits to memory (emitters + curves)
--------------------------------------------------------------------------------

function M.ee_apply()
    if apply_all_edits_fn then
        apply_all_edits_fn()
    end
end

--------------------------------------------------------------------------------
-- ee_verify_feds_roundtrip: Prove parse→serialize of the feds section is a
-- byte-identical no-op against the live memory bytes the SPU is reading.
--
-- Reads ground-truth bytes from base + header.sound_def_ptr (the same bytes
-- a naked savestate replay sees), runs them through the parser and serializer
-- used by ee_test, and reports any divergence (byte-level + structural).
--------------------------------------------------------------------------------

function M.ee_verify_feds_roundtrip()
    if not parser then
        print("[Verify] ERROR: parser module not injected")
        return false
    end
    if not MemUtils then
        print("[Verify] ERROR: MemUtils not injected")
        return false
    end
    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        print("[Verify] ERROR: no memory_base set. Capture an effect first.")
        return false
    end
    local hdr = EFFECT_EDITOR.header
    if not hdr then
        print("[Verify] ERROR: no header loaded. Capture an effect first.")
        return false
    end

    MemUtils.refresh_mem()
    local base = EFFECT_EDITOR.memory_base
    local size = hdr.texture_ptr - hdr.sound_def_ptr
    local addr = base + hdr.sound_def_ptr

    print(string.format("[Verify] feds region @ 0x%08X, size=%d bytes (texture_ptr - sound_def_ptr)",
        addr, size))

    -- 1. Snapshot ground-truth bytes from memory.
    local orig_chars = {}
    for i = 0, size - 1 do
        orig_chars[i + 1] = string.char(MemUtils.read8(addr + i))
    end
    local orig = table.concat(orig_chars)

    -- 2. Parse, then re-serialize using the same code path ee_test invokes.
    local def = parser.parse_sound_definition_from_memory(base, hdr.sound_def_ptr, size)
    if not def then
        print("[Verify] ERROR: parse_sound_definition_from_memory returned nil")
        return false
    end
    local new_bytes, new_data_size = parser.serialize_sound_definition(def)
    if not new_bytes then
        print("[Verify] ERROR: serialize_sound_definition returned nil")
        return false
    end

    print(string.format("[Verify] parsed: num_channels=%d resource_id=%d data_offset=0x%X declared_data_size=%d",
        def.num_channels, def.resource_id, def.data_offset, def.data_size))

    local channel_sizes = {}
    for i = 1, def.num_channels do
        channel_sizes[i] = string.format("ch%d=%d", i - 1, def.channels[i] and def.channels[i].size or -1)
    end
    print("[Verify] channel sizes: " .. table.concat(channel_sizes, ", "))

    -- 3. Length check. 'size' is the in-memory section span; new_data_size is
    --    what the serializer wrote (declared data_size in the new header).
    if #orig ~= #new_bytes then
        print(string.format("[Verify] LENGTH MISMATCH: original=%d, serialized=%d (delta=%+d)",
            #orig, #new_bytes, #new_bytes - #orig))
    else
        print(string.format("[Verify] length identical: %d bytes", #orig))
    end

    -- 4. Byte diff with hex window.
    local max_diffs = 16
    local diffs = 0
    local lim = math.min(#orig, #new_bytes)
    for i = 1, lim do
        if orig:byte(i) ~= new_bytes:byte(i) then
            diffs = diffs + 1
            if diffs <= max_diffs then
                local lo = math.max(1, i - 4)
                local hi = math.min(lim, i + 4)
                local o_hex, n_hex = {}, {}
                for j = lo, hi do
                    o_hex[#o_hex + 1] = string.format("%02X", orig:byte(j))
                    n_hex[#n_hex + 1] = string.format("%02X", new_bytes:byte(j))
                end
                print(string.format("[Verify] DIFF @ 0x%04X: orig=0x%02X new=0x%02X  | orig[%s] new[%s]",
                    i - 1, orig:byte(i), new_bytes:byte(i),
                    table.concat(o_hex, " "), table.concat(n_hex, " ")))
            end
        end
    end

    -- 5. Structural re-parse: ensure serialized bytes re-parse identically.
    local def2 = parser.parse_sound_definition_from_data(new_bytes, 0, #new_bytes)
    if not def2 then
        print("[Verify] WARN: re-parse of serialized bytes returned nil")
    else
        local mismatches = {}
        if def2.num_channels ~= def.num_channels then
            table.insert(mismatches,
                string.format("num_channels %d->%d", def.num_channels, def2.num_channels))
        end
        if def2.data_size ~= new_data_size then
            table.insert(mismatches,
                string.format("data_size_written=%d  reparsed=%d", new_data_size, def2.data_size))
        end
        if def2.data_offset ~= def.data_offset then
            table.insert(mismatches,
                string.format("data_offset 0x%X->0x%X", def.data_offset, def2.data_offset))
        end
        for i = 1, def.num_channels do
            local a = def.channels[i] and def.channels[i].size or -1
            local b = def2.channels[i] and def2.channels[i].size or -1
            if a ~= b then
                table.insert(mismatches, string.format("ch%d.size %d->%d", i - 1, a, b))
            end
        end
        if #mismatches == 0 then
            print("[Verify] structural re-parse identical")
        else
            print("[Verify] structural drift: " .. table.concat(mismatches, ", "))
        end
    end

    local ok = (diffs == 0) and (#orig == #new_bytes)
    if ok then
        print("[Verify] RESULT: BYTE-IDENTICAL round-trip (parser/serializer is innocent)")
    else
        print(string.format("[Verify] RESULT: %d byte differences, length delta %d (parser/serializer IS modifying bytes)",
            diffs, #new_bytes - #orig))
    end
    return ok
end

--------------------------------------------------------------------------------
-- ee_dump_audio_globals: Print the global pointers the SPU/sequencer reads
-- to find the loaded effect's sound data. Useful for snapshotting before vs
-- after a patch cycle to detect stale/clobbered globals outside the per-effect
-- memory region (the .bin save only covers [base..base+EFFECT_MAX_SIZE]).
--
-- Addresses verified in research/effect_sound/working_documents and
-- capture/opcode_capture.lua:55.
--------------------------------------------------------------------------------

local AUDIO_GLOBALS = {
    {addr = 0x801BBF74, name = "g_sound_section_ptr (feds ptr)"},
    {addr = 0x801BBF78, name = "sprite_def_table_ptr (frames+4)"},
    {addr = 0x801BC0C8, name = "g_timeline_ptr"},
    {addr = 0x801BC0DC, name = "g_sound_data_base (SPU bank)"},
    {addr = 0x801BACC8, name = "g_effect_flags_ptr"},
    {addr = 0x801B9250, name = "sound_call_count"},
}

function M.ee_dump_audio_globals()
    if not MemUtils then
        print("[Globals] ERROR: MemUtils not injected")
        return nil
    end
    MemUtils.refresh_mem()
    print("[Globals] === audio-related global pointers ===")
    local snapshot = {}
    for _, g in ipairs(AUDIO_GLOBALS) do
        local v = MemUtils.read32(g.addr)
        snapshot[g.addr] = v
        print(string.format("  0x%08X  %-36s = 0x%08X", g.addr, g.name, v))
    end
    return snapshot
end

-- Snapshot globals, run a single apply pass, snapshot again, diff.
-- Run *after* a freshly reloaded savestate so we're comparing
-- "clean state" → "post-apply state".
function M.ee_diff_globals_around_apply()
    if not MemUtils or not apply_all_edits_fn then
        print("[GlobalsDiff] ERROR: dependencies not ready")
        return false
    end
    print("[GlobalsDiff] === BEFORE apply ===")
    local before = M.ee_dump_audio_globals()

    apply_all_edits_fn(true)  -- silent

    MemUtils.refresh_mem()
    print("[GlobalsDiff] === AFTER apply ===")
    local after = M.ee_dump_audio_globals()

    local changed = 0
    for _, g in ipairs(AUDIO_GLOBALS) do
        if before[g.addr] ~= after[g.addr] then
            changed = changed + 1
            print(string.format("[GlobalsDiff] CHANGED 0x%08X %s: 0x%08X -> 0x%08X",
                g.addr, g.name, before[g.addr], after[g.addr]))
        end
    end
    if changed == 0 then
        print("[GlobalsDiff] no audio-related globals changed by apply")
    else
        print(string.format("[GlobalsDiff] %d global(s) changed by apply", changed))
    end
    return changed == 0
end

--------------------------------------------------------------------------------
-- Audio Capture (for bridge-based recording)
-- Two-call pattern: ee_capture_audio_start() then ee_capture_audio_read()
--------------------------------------------------------------------------------

-- Timeline frame counter address (written each frame during effect)
local TIMELINE_FRAME_ADDR = 0x801BF14C

-- Memory addresses for phase boundary calculation (from trace_phases_v2.lua)
local G_TIMELINE_PTR = 0x801bc0c8
local G_EFFECT_CONTEXT = 0x801bad0c

-- Try to get precise system time via LuaJIT FFI (Windows)
local ffi_available, ffi = pcall(require, "ffi")
local get_precise_time = nil

if ffi_available then
    -- Define Windows FILETIME structure and GetSystemTimeAsFileTime
    pcall(function()
        ffi.cdef[[
            typedef struct { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } FILETIME;
            void GetSystemTimeAsFileTime(FILETIME* lpSystemTimeAsFileTime);
        ]]
        get_precise_time = function()
            local ft = ffi.new("FILETIME")
            ffi.C.GetSystemTimeAsFileTime(ft)
            -- Convert FILETIME (100-nanosecond intervals since 1601) to Unix epoch
            local ticks = ft.dwLowDateTime + ft.dwHighDateTime * 4294967296ULL
            return tonumber((ticks - 116444736000000000ULL) / 10000000ULL) +
                   tonumber((ticks - 116444736000000000ULL) % 10000000ULL) / 10000000
        end
        print("[AudioCapture] Using FFI for precise Windows time")
    end)
end

-- SPU registers for audio marker (fallback sync method)
local SPU_MAIN_VOL_L = 0x1F801D80
local SPU_MAIN_VOL_R = 0x1F801D82

-- Play a sync click by briefly muting SPU (creates audible marker)
local function play_sync_click()
    -- Write to SPU registers via hardware memory region
    -- SPU is at 0x1F801C00-0x1F801FFF, need to use PCSX SPU access
    print("[AudioCapture] SYNC CLICK")
    -- TODO: Implement actual SPU mute/unmute if FFI time doesn't work
end

-- Get system time with sub-second precision (UNIX epoch timestamp)
-- This matches Python's time.time() for cross-process timestamp correlation
local function get_system_time()
    -- Always use os.time() for Unix epoch (integer seconds)
    -- This is the most reliable cross-platform approach
    local unix_time = os.time()

    -- Try to get sub-second precision from FFI
    if get_precise_time then
        local precise = get_precise_time()
        -- Sanity check: precise time should be close to os.time()
        if math.abs(precise - unix_time) < 2 then
            return precise
        else
            print(string.format("[AudioCapture] WARNING: FFI time drift! os.time=%d, ffi=%.3f", unix_time, precise))
        end
    end

    -- Fallback: just use os.time() (integer seconds, no sub-second precision)
    return unix_time
end

-- Get phase boundaries by reading from memory (like trace_phases_v2.lua)
-- This reads the ACTUAL runtime values, not just the parsed timeline_header
local function get_phase_boundaries()
    MemUtils.refresh_mem()
    local ptr = MemUtils.read32(G_TIMELINE_PTR)
    if ptr == 0 or ptr < 0x80000000 then
        -- Fallback to timeline_header if pointer not set
        local th = EFFECT_EDITOR.timeline_header or {}
        local phase1_end = th.phase1_duration or 60
        local spawn_delay = th.spawn_delay or 0
        local phase2_delay = th.phase2_delay or 60
        return {
            phase1_end = phase1_end,
            spawn_delay = spawn_delay,
            phase2_delay = phase2_delay,
            target_count = 1,
            foreach_end = phase1_end,  -- No spawns for single target
            phase2_start = phase1_end + phase2_delay,
        }
    end

    -- Read from memory (timeline header offsets: +4=phase1_end, +6=spawn_delay, +10=phase2_delay)
    local phase1_end = MemUtils.read16(ptr + 4)
    local spawn_delay = MemUtils.read16(ptr + 6)
    local phase2_delay = MemUtils.read16(ptr + 10)
    local target_count = MemUtils.read16(G_EFFECT_CONTEXT)

    if target_count < 1 then target_count = 1 end

    -- foreach_end = when last child spawns
    local foreach_end = phase1_end + (target_count - 1) * spawn_delay
    -- phase2_start = after phase2_delay
    local phase2_start = foreach_end + phase2_delay

    return {
        phase1_end = phase1_end,
        spawn_delay = spawn_delay,
        phase2_delay = phase2_delay,
        target_count = target_count,
        foreach_end = foreach_end,
        phase2_start = phase2_start,
    }
end

-- Start audio capture: mute music, setup breakpoints, run test cycle
function M.ee_capture_audio_start()
    -- Check prerequisites
    local has_session = EFFECT_EDITOR.session_name and EFFECT_EDITOR.session_name ~= ""
    if not has_session then
        print("ERROR: No session loaded. Use ee_load_session() first.")
        return false
    end

    if EFFECT_EDITOR.memory_base < 0x80000000 then
        print("ERROR: No memory target. Load a session with captured effect data.")
        return false
    end

    -- Initialize capture state with all phase timestamps
    EFFECT_EDITOR.audio_capture_timestamps = {
        effect_start = nil,      -- Frame 1 (system time)
        phase1_end = nil,        -- Frame == phase1_end (for-each START)
        foreach_end = nil,       -- Frame == foreach_end (last child spawned)
        phase2_start = nil,      -- Frame == phase2_start
        effect_end = nil,        -- Set by ee_capture_audio_read()
        -- Frame numbers for reference
        phase1_end_frame = nil,
        foreach_end_frame = nil,
        phase2_start_frame = nil,
    }
    EFFECT_EDITOR.audio_capture_active = true

    -- Phase boundaries - read when effect starts (not before, as effect isn't loaded yet)
    local bounds = nil

    -- Setup frame tracking breakpoint
    if AUDIO_CAPTURE_BP then
        pcall(function() AUDIO_CAPTURE_BP:disable() end)
        AUDIO_CAPTURE_BP = nil
    end

    AUDIO_CAPTURE_BP = PCSX.addBreakpoint(
        TIMELINE_FRAME_ADDR, "Write", 2, "AudioCapture",
        function()
            if not EFFECT_EDITOR.audio_capture_active then return true end

            MemUtils.refresh_mem()
            local frame = MemUtils.read16(TIMELINE_FRAME_ADDR)
            local now = get_system_time()  -- UNIX epoch timestamp
            local ts = EFFECT_EDITOR.audio_capture_timestamps

            -- Effect starts at frame 0 (when timeline counter resets)
            -- Read phase boundaries NOW when effect is actually loaded
            if frame == 0 and not ts.effect_start then
                ts.effect_start = now
                bounds = get_phase_boundaries()
                print(string.format("[AudioCapture] Effect started at frame %d, unix_time=%.6f", frame, now))
                print(string.format("[AudioCapture] Phase boundaries: phase1_end=%d, foreach_end=%d, phase2_start=%d",
                    bounds.phase1_end, bounds.foreach_end, bounds.phase2_start))
                print(string.format("[AudioCapture] DEBUG: os.time()=%d", os.time()))
            end

            -- Only track phase boundaries AFTER effect has started and bounds are loaded
            if ts.effect_start and bounds then
                -- Capture phase1_end (when for-each spawning starts)
                if frame == bounds.phase1_end and not ts.phase1_end then
                    ts.phase1_end = now
                    ts.phase1_end_frame = frame
                    if frame == 0 then
                        print(string.format("[AudioCapture] Phase 1 ended at frame 0 (no phase 1), unix_time=%.6f", now))
                    else
                        print(string.format("[AudioCapture] Phase 1 ended at frame %d, unix_time=%.6f", frame, now))
                    end
                end

            end

            -- Capture phase2_start and calculate foreach_end
            if ts.effect_start and bounds and frame == bounds.phase2_start and not ts.phase2_start then
                ts.phase2_start = now
                ts.phase2_start_frame = frame
                -- For-each audio = spawn_delay frames after phase1_end
                -- Back out: foreach_end = phase1_end + (spawn_delay / 30fps)
                ts.foreach_end = ts.phase1_end + (bounds.spawn_delay / 30)
                ts.foreach_end_frame = bounds.phase1_end + bounds.spawn_delay
                print(string.format("[AudioCapture] Phase 2 started at frame %d, foreach_end backed out to frame %d (spawn_delay=%d)",
                    frame, ts.foreach_end_frame, bounds.spawn_delay))
            end

            return true  -- Continue execution
        end
    )

    print("[AudioCapture] Breakpoint armed, running test cycle...")

    -- Run test cycle (async - uses nextTick).
    -- Capture mode opts in to the music-mute MIPS hook so the WAV doesn't
    -- contain music bleed; ee_test does not install it by default anymore.
    M.ee_test({install_mute_hook = true})

    print("[AudioCapture] Test cycle started. Call ee_capture_audio_read() after effect completes.")
    return true
end

-- Response file for bridge communication (Windows path for io.open)
local BRIDGE_RESPONSE_FILE = (os.getenv("APPDATA") or os.getenv("HOME") or ".") .. "/pcsx-redux/bridge_response.txt"

-- Write response to file for bridge
local function write_bridge_response(text)
    local f = io.open(BRIDGE_RESPONSE_FILE, "w")
    if f then
        f:write(text)
        f:close()
    end
end

-- Read capture results: get timestamps, cleanup, unmute
function M.ee_capture_audio_read()
    if not EFFECT_EDITOR.audio_capture_active then
        local err = "ERROR: No active capture. Call ee_capture_audio_start() first."
        print(err)
        write_bridge_response(err)
        return nil
    end

    -- Record end time (system time)
    local ts = EFFECT_EDITOR.audio_capture_timestamps
    ts.effect_end = get_system_time()

    -- Mark capture complete
    EFFECT_EDITOR.audio_capture_active = false

    -- Cleanup breakpoint
    if AUDIO_CAPTURE_BP then
        pcall(function() AUDIO_CAPTURE_BP:disable() end)
        AUDIO_CAPTURE_BP = nil
    end

    -- Output ABSOLUTE timestamps (UNIX epoch) for Python correlation
    -- Python will use these with its own record_start_time to calculate WAV positions
    -- Using %.6f for microsecond precision (needed for accurate WAV slicing)
    local json = string.format(
        'TIMESTAMPS:{"effect_start":%.6f,"phase1_end":%.6f,"foreach_end":%.6f,"phase2_start":%.6f,"effect_end":%.6f,"phase1_end_frame":%s,"foreach_end_frame":%s,"phase2_start_frame":%s}',
        ts.effect_start or 0,
        ts.phase1_end or 0,
        ts.foreach_end or 0,
        ts.phase2_start or 0,
        ts.effect_end,
        ts.phase1_end_frame or "null",
        ts.foreach_end_frame or "null",
        ts.phase2_start_frame or "null"
    )
    print(json)

    -- Write to response file for bridge
    write_bridge_response(json)

    return ts
end

--------------------------------------------------------------------------------
-- Phase Sound Isolation (bridge commands for isolated audio capture)
--------------------------------------------------------------------------------

-- Bridge command: isolate a single phase's sounds (mute other phases)
-- phase: "phase1", "foreach", or "phase2"
function M.ee_isolate_phase(phase)
    if not parser then
        print("[Workflow] ERROR: parser module not available")
        write_bridge_response("ERROR:parser_not_available")
        return false
    end

    local success = parser.isolate_sound_phase(phase)
    if success then
        write_bridge_response("OK:isolated_" .. phase)
    else
        write_bridge_response("ERROR:isolate_failed")
    end
    return success
end

-- Bridge command: restore all sounds to original state
function M.ee_restore_sounds()
    if not parser then
        print("[Workflow] ERROR: parser module not available")
        write_bridge_response("ERROR:parser_not_available")
        return false
    end

    local success = parser.restore_sound_timelines()
    if success then
        write_bridge_response("OK:restored")
    else
        write_bridge_response("ERROR:restore_failed")
    end
    return success
end

--------------------------------------------------------------------------------
-- Load sound data from a different BIN file
-- This allows reusing the same session savestate but with sounds from another effect
--------------------------------------------------------------------------------

-- Find embedded DATA header in CODE (MIPS) format files
-- Returns offset where the 40-byte header begins, or 0 for DATA format
local function find_embedded_header_offset(data)
    local mem = require("memory_utils")

    -- Check if this is a CODE format file (MIPS prologue: addiu sp, sp, -X = 0x27BDXXXX)
    local first_word = mem.buf_read32(data, 0)
    if first_word < 0x27BD0000 or first_word >= 0x27BE0000 then
        -- Not MIPS format, header is at offset 0
        return 0
    end

    print("[Workflow]   Detected MIPS format, searching for embedded header...")

    -- Search for embedded header by looking for the 0x28 pattern
    -- (first pointer = 0x28 = size of header, typical for DATA format)
    for i = 0, #data - 0x28, 4 do
        local ptr00 = mem.buf_read32(data, i)
        if ptr00 == 0x28 then
            -- Validate header structure: pointers should be ascending and reasonable
            local ptr08 = mem.buf_read32(data, i + 0x08)
            local ptr0C = mem.buf_read32(data, i + 0x0C)
            local ptr10 = mem.buf_read32(data, i + 0x10)

            if ptr08 > 0x28 and ptr08 < ptr0C and ptr0C < ptr10 and ptr10 < 0x8000 then
                print(string.format("[Workflow]   Found embedded header at offset 0x%X", i))
                return i
            end
        end
    end

    print("[Workflow]   WARNING: Could not find embedded header, using offset 0")
    return 0
end

function M.ee_load_sound_from_bin(bin_path)
    if not parser then
        print("[Workflow] ERROR: parser module not available")
        write_bridge_response("ERROR:parser_not_available")
        return false
    end

    local mem = require("memory_utils")

    -- 1. Read the BIN file
    print("[Workflow] Loading sound data from: " .. bin_path)
    local file = io.open(bin_path, "rb")
    if not file then
        print("[Workflow] ERROR: Cannot open " .. bin_path)
        write_bridge_response("ERROR:cannot_open_file")
        return false
    end
    local data = file:read("*all")
    file:close()
    print("[Workflow]   Read " .. #data .. " bytes")

    -- 2. Find base offset for MIPS files
    local base_offset = find_embedded_header_offset(data)

    -- 3. Parse header to get section pointers (adjusted for base_offset)
    -- Create adjusted data view for parsing
    local header = {
        frames_ptr = mem.buf_read32(data, base_offset + 0x00),
        animation_ptr = mem.buf_read32(data, base_offset + 0x04),
        script_data_ptr = mem.buf_read32(data, base_offset + 0x08),
        effect_data_ptr = mem.buf_read32(data, base_offset + 0x0C),
        anim_table_ptr = mem.buf_read32(data, base_offset + 0x10),
        time_scale_ptr = mem.buf_read32(data, base_offset + 0x14),
        effect_flags_ptr = mem.buf_read32(data, base_offset + 0x18),
        timeline_section_ptr = mem.buf_read32(data, base_offset + 0x1C),
        sound_def_ptr = mem.buf_read32(data, base_offset + 0x20),
        texture_ptr = mem.buf_read32(data, base_offset + 0x24),
    }

    -- All pointers are relative to the header location, so add base_offset
    local timeline_ptr = base_offset + header.timeline_section_ptr
    local effect_flags_ptr = base_offset + header.effect_flags_ptr
    local sound_def_ptr = base_offset + header.sound_def_ptr
    local texture_ptr = base_offset + header.texture_ptr

    print(string.format("[Workflow]   Header at 0x%X: effect_flags=0x%X, timeline=0x%X, sound_def=0x%X",
        base_offset, effect_flags_ptr, timeline_ptr, sound_def_ptr))

    -- 4. Parse sound-related sections from the BIN (using absolute offsets)

    -- TIER 1: Sound timelines
    local source_sound_timelines = parser.parse_all_sound_timelines(data, timeline_ptr)
    if source_sound_timelines then
        EFFECT_EDITOR.sound_timelines = source_sound_timelines
        print("[Workflow]   Loaded 9 sound timeline tracks")
    end

    -- TIER 2: Sound config channels (effect_flags bytes 0x08-0x17)
    local source_sound_flags = parser.parse_sound_flags_from_data(data, effect_flags_ptr)
    if source_sound_flags then
        EFFECT_EDITOR.sound_flags = source_sound_flags
        print("[Workflow]   Loaded 4 sound config channels")
    end

    -- TIER 3: Sound definition (feds section)
    local sound_section_size = texture_ptr - sound_def_ptr
    if sound_section_size > 0 then
        local source_sound_def = parser.parse_sound_definition_from_data(data, sound_def_ptr, sound_section_size)
        if source_sound_def then
            EFFECT_EDITOR.sound_definition = source_sound_def
            print(string.format("[Workflow]   Loaded feds section: %d channels", source_sound_def.num_channels))
        end
    end

    -- TIER 3.5: Effect script bytecode (script_data section), raw byte
    -- copy. Parse→serialize round-trip via the script parser is not
    -- byte-identical for all bins, which corrupts the host's RAM and
    -- stalls the runtime. Raw byte copy preserves source exactly.
    -- Writes happen immediately (no go-through ee_apply) so the
    -- already-parsed EFFECT_EDITOR.script_instructions (host's parse)
    -- isn't touched — apply_all_edits_to_memory will re-serialize and
    -- write the HOST's script (round-trip safe because it matches what
    -- was just loaded from memory), and then we OVERWRITE that with
    -- the source's raw bytes right after via ee_apply_script_raw.
    local script_size = header.effect_data_ptr - header.script_data_ptr
    if script_size > 0 then
        local script_offset = base_offset + header.script_data_ptr
        local script_bytes = data:sub(script_offset + 1, script_offset + script_size)
        EFFECT_EDITOR._pending_script_raw = {
            bytes = script_bytes,
            size = script_size,
            -- Target offset in host memory is the HOST's script_data_ptr
            -- (read from EFFECT_EDITOR.header at apply time). Don't pin
            -- it here in case the apply phase shifts sections first.
        }
        print(string.format(
            "[Workflow]   Pending raw script copy: %d bytes (call ee_apply_script_raw after ee_apply)",
            script_size))
    end

    -- Phase timing from timeline header
    local source_timeline_header = parser.parse_timeline_header_from_data(data, timeline_ptr)
    if source_timeline_header and EFFECT_EDITOR.timeline_header then
        EFFECT_EDITOR.timeline_header.phase1_duration = source_timeline_header.phase1_duration
        EFFECT_EDITOR.timeline_header.spawn_delay = source_timeline_header.spawn_delay
        EFFECT_EDITOR.timeline_header.phase2_delay = source_timeline_header.phase2_delay
        print(string.format("[Workflow]   Loaded phase timing: phase1=%d, spawn_delay=%d, phase2_delay=%d",
            source_timeline_header.phase1_duration,
            source_timeline_header.spawn_delay,
            source_timeline_header.phase2_delay))
    end

    print("[Workflow] Sound data loaded successfully")
    write_bridge_response("OK:loaded_sound")
    return true
end

--------------------------------------------------------------------------------
-- Force-single-target patch — clamp the for-each spawn loop to 1 instance.
--
-- effect_context_value @ 0x801BAD0C is the global target count the FFT
-- effect runtime uses as the upper bound for the for-each spawn loop
-- (see research/wiki_articles/effect_state.txt §"3-PHASE LAYOUT" and
-- research/context_restore/CAMERA_DEBUG_9_EMITTERS.md). When an AoE
-- ability like Disillusion is captured mid-cast, the savestate has
-- this set to N (one per hit target), and the runtime will spawn N
-- per-target for-each EffectState instances on resume.
--
-- For audio-parity captures we don't want that — extra for-each spawns
-- produce overlapping play_sound calls that drift between PCSX and
-- Godot (Godot's spawn handling diverges; see
-- research/effect_sound/working_documents/PROBE_FORMULA_STAGES_PRE_ANCHOR_GATE_DEFICIT.md
-- and related deficit docs). Writing 1 here BEFORE the runtime reads
-- it clamps spawning to a single instance, giving a clean single-target
-- audio capture that is easy to A/B against any host savestate.
--
-- The runtime reads this at the start of the spawn loop in
-- outer_phases_timeline_tick. Patching while the emulator is paused
-- post-savestate-load (i.e. before resume) takes effect immediately
-- on the next IRQ.
--
-- Usage:
--   ee_force_single_target()             -- clamps to 1 (default)
--   ee_force_single_target(N)            -- clamps to N
-- Returns true on success, false on failure.
--------------------------------------------------------------------------------
-- Apply pending raw script bytes from ee_load_sound_from_bin into PSX
-- memory. Separate from ee_apply because the script-parser
-- round-trip is not byte-identical for all bins, so we keep
-- EFFECT_EDITOR.script_instructions = host's (matches what
-- ee_apply serializes back unchanged) and overwrite the script
-- section with the source's RAW bytes right after.
--
-- Caller pattern (orchestrator-side):
--   ee_load_sound_from_bin(src)
--   ee_apply()              -- writes host's data back (no-op for sound; the sound bytes
--                              come from EFFECT_EDITOR.sound_definition which IS source's)
--   ee_apply_script_raw()   -- raw-copy source's script bytes over host's script slot
function M.ee_apply_script_raw()
    local pending = EFFECT_EDITOR._pending_script_raw
    if not pending or not pending.bytes then
        return true  -- nothing to do
    end
    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        print("[Workflow] ee_apply_script_raw: no valid memory_base")
        return false
    end
    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.script_data_ptr then
        print("[Workflow] ee_apply_script_raw: no script_data_ptr in EFFECT_EDITOR.header")
        return false
    end
    -- Re-read header from memory to pick up any post-apply section shifts.
    MemUtils.refresh_mem()
    local mem_header = parser.parse_header_from_memory(EFFECT_EDITOR.memory_base)
    local script_data_ptr = mem_header and mem_header.script_data_ptr
                            or EFFECT_EDITOR.header.script_data_ptr
    local effect_data_ptr = mem_header and mem_header.effect_data_ptr
                            or EFFECT_EDITOR.header.effect_data_ptr
    local dst_capacity = effect_data_ptr - script_data_ptr
    if pending.size > dst_capacity then
        print(string.format(
            "[Workflow] ee_apply_script_raw: source script %d bytes won't fit host slot %d (would overflow into effect_data); skipping",
            pending.size, dst_capacity))
        EFFECT_EDITOR._pending_script_raw = nil
        return false
    end
    local addr = EFFECT_EDITOR.memory_base + script_data_ptr
    for i = 1, pending.size do
        MemUtils.write8(addr + i - 1, pending.bytes:byte(i))
    end
    -- Zero-pad the remainder to avoid leftover host bytecode tail
    -- decoding as opcodes.
    for i = pending.size, dst_capacity - 1 do
        MemUtils.write8(addr + i, 0)
    end
    print(string.format(
        "[Workflow] ee_apply_script_raw: wrote %d source bytes at 0x%08X (slot %d, padded with %d zeros)",
        pending.size, addr, dst_capacity, dst_capacity - pending.size))
    EFFECT_EDITOR._pending_script_raw = nil
    return true
end

--------------------------------------------------------------------------------
-- Extend phase2_delay — push the post-spawn tail of an effect so the
-- for-each instances have time to finish playing audibly before the
-- effect terminates. Useful for swap captures where the host's
-- phase2_delay was tuned for a fast effect and would cut off a longer
-- swapped-in spell.
--
-- phase2_delay lives in the timeline_section header at +0x0A (int16).
-- Address = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.timeline_section_ptr + 0x0A.
-- Writing here directly takes effect on the next outer_phases_timeline_tick
-- read (the runtime re-reads this field each frame). See
-- research/wiki_articles/timeline_section.txt lines 274/997.
--
-- Usage:
--   ee_extend_phase2()          -- default 300 frames (~10s @ 30fps)
--   ee_extend_phase2(600)       -- 600 frames (~20s)
-- Also mirrors the value into EFFECT_EDITOR.timeline_header so any
-- subsequent ee_apply doesn't overwrite it.
function M.ee_extend_phase2(frames)
    frames = frames or 300
    if frames < 0 or frames > 0x7FFF then
        print(string.format(
            "[Workflow] ee_extend_phase2: frames %d out of range (0..32767)",
            frames))
        return false
    end
    if not EFFECT_EDITOR.memory_base or EFFECT_EDITOR.memory_base < 0x80000000 then
        print("[Workflow] ee_extend_phase2: no valid memory_base — load a session first")
        return false
    end
    if not EFFECT_EDITOR.header or not EFFECT_EDITOR.header.timeline_section_ptr then
        print("[Workflow] ee_extend_phase2: no timeline_section_ptr in EFFECT_EDITOR.header")
        return false
    end
    local addr = EFFECT_EDITOR.memory_base + EFFECT_EDITOR.header.timeline_section_ptr + 0x0A
    local ok, err = pcall(function()
        MemUtils.refresh_mem()
        local prev = MemUtils.read16(addr)
        MemUtils.write16(addr, frames)
        if EFFECT_EDITOR.timeline_header then
            EFFECT_EDITOR.timeline_header.phase2_delay = frames
        end
        print(string.format(
            "[Workflow] phase2_delay @ 0x%08X: %d -> %d (extend_phase2)",
            addr, prev, frames))
    end)
    if not ok then
        print("[Workflow] ee_extend_phase2 failed: " .. tostring(err))
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- Reset script_position on every active EffectState slot.
-- Needed when overlaying a different effect's bytecode (raw script
-- swap) so the runtime re-enters the new script from offset 0
-- instead of mid-stream where the frozen savestate PC happens to be.
-- EffectState +0x06 = script_position (int16), per
-- research/wiki_articles/effect_state.txt §"SECTION 8: MEMORY LAYOUT".
function M.ee_reset_script_position()
    local EFFECT_STATE_BASE   = 0x801BF02C
    local EFFECT_STATE_STRIDE = 0xF8
    local ACTIVE_HEAD_ADDR    = 0x801BBF90
    local SLOT_LIMIT          = 32
    local ok, err = pcall(function()
        MemUtils.refresh_mem()
        local idx = MemUtils.read16(ACTIVE_HEAD_ADDR)
        local visited = 0
        while idx ~= 0 and idx ~= 0xFFFF and visited < SLOT_LIMIT do
            local addr = EFFECT_STATE_BASE + idx * EFFECT_STATE_STRIDE
            local prev = MemUtils.read16(addr + 0x06)
            MemUtils.write16(addr + 0x06, 0)
            print(string.format(
                "[Workflow]   EffectState[%d] @ 0x%08X: script_position %d -> 0",
                idx, addr, prev))
            local next_idx = MemUtils.read16(addr + 0x00)
            if next_idx == idx then break end
            idx = next_idx
            visited = visited + 1
        end
        print(string.format("[Workflow] script_position reset on %d slots", visited))
    end)
    if not ok then
        print("[Workflow] ee_reset_script_position failed: " .. tostring(err))
        return false
    end
    return true
end

function M.ee_force_single_target(target_count)
    target_count = target_count or 1
    if target_count < 1 or target_count > 0xFFFF then
        print(string.format(
            "[Workflow] ee_force_single_target: target_count %d out of range (1..65535)",
            target_count))
        return false
    end
    -- The for-each spawn loop in outer_phases_timeline_tick (opcode 41)
    -- runs IFF `spawned_target_count < total_targets`. Two patches needed:
    --   1. effect_context_value @ 0x801BAD0C = N     (the total_targets ref)
    --   2. For every active EffectState slot, zero:
    --        +0x2A for_each_spawn_delay   (countdown — 0 means spawn now)
    --        +0x2C spawned_target_count   (already-spawned counter)
    -- Without (2), savestates captured mid-effect (with spawn already in
    -- progress) have spawned_target_count >= 1 — patching total_targets
    -- to 1 alone makes the condition false and no spawn fires. See
    -- research/wiki_articles/effect_state.txt §"3-PHASE LAYOUT" + §9.
    local ADDR_CONTEXT = 0x801BAD0C
    local EFFECT_STATE_BASE   = 0x801BF02C   -- effect_state_array_base
    local EFFECT_STATE_STRIDE = 0xF8          -- per slot
    local ACTIVE_HEAD_ADDR    = 0x801BBF90    -- active_effect_list_head
    local SLOT_LIMIT          = 32            -- safety bound on linked-list walk
    local ok, err = pcall(function()
        MemUtils.refresh_mem()

        local prev_ctx = MemUtils.read16(ADDR_CONTEXT)
        MemUtils.write16(ADDR_CONTEXT, target_count)
        print(string.format(
            "[Workflow] effect_context_value @ 0x%08X: %d -> %d",
            ADDR_CONTEXT, prev_ctx, target_count))

        -- Walk the active EffectState list and zero the spawn counters.
        local idx = MemUtils.read16(ACTIVE_HEAD_ADDR)
        local visited = 0
        while idx ~= 0 and idx ~= 0xFFFF and visited < SLOT_LIMIT do
            local addr = EFFECT_STATE_BASE + idx * EFFECT_STATE_STRIDE
            local prev_delay = MemUtils.read16(addr + 0x2A)
            local prev_count = MemUtils.read16(addr + 0x2C)
            MemUtils.write16(addr + 0x2A, 0)
            MemUtils.write16(addr + 0x2C, 0)
            print(string.format(
                "[Workflow]   EffectState[%d] @ 0x%08X: for_each_spawn_delay %d -> 0, spawned_target_count %d -> 0",
                idx, addr, prev_delay, prev_count))
            local next_idx = MemUtils.read16(addr + 0x00)
            if next_idx == idx then break end  -- self-loop guard
            idx = next_idx
            visited = visited + 1
        end
        print(string.format(
            "[Workflow] active effect slots patched: %d", visited))
    end)
    if not ok then
        print("[Workflow] ee_force_single_target failed: " .. tostring(err))
        return false
    end
    return true
end

return M
