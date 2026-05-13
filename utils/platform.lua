-- utils/platform.lua
-- Cross-platform utilities for Windows, WSL, and native Linux

local M = {}

--------------------------------------------------------------------------------
-- Platform Detection
--------------------------------------------------------------------------------

-- Detect if running on Windows, WSL, or native Linux
-- Returns "windows", "wsl", or "linux"
function M.detect_platform()
    -- Check for Windows-specific environment variables
    local os_type = os.getenv("OS")
    if os_type and os_type:lower():find("windows") then
        return "windows"
    end

    -- Check for WSL (WSL2 always sets WSL_DISTRO_NAME)
    local wsl_distro = os.getenv("WSL_DISTRO_NAME")
    if wsl_distro then
        return "wsl"
    end

    -- Check path separator — Windows uses backslash
    if package.config:sub(1, 1) == "\\" then
        return "windows"
    end

    -- Native Linux (no APPDATA, no WSL_DISTRO_NAME, POSIX separator)
    local home = os.getenv("HOME")
    if home and home:sub(1, 1) == "/" then
        return "linux"
    end

    return "wsl"  -- Conservative fallback
end

-- Cache the platform detection result
M.platform = M.detect_platform()

--------------------------------------------------------------------------------
-- Script Directory Detection
--------------------------------------------------------------------------------

-- Get the directory containing this script
-- This uses debug.getinfo to find the script location
function M.get_script_dir()
    local info = debug.getinfo(2, "S")
    if info and info.source then
        local source = info.source
        -- Remove @ prefix if present
        if source:sub(1, 1) == "@" then
            source = source:sub(2)
        end
        -- Extract directory part
        local dir = source:match("(.*/)")
        if dir then
            return dir
        end
        -- Try Windows-style path
        dir = source:match("(.+\\)")
        if dir then
            return dir
        end
    end
    return "./"
end

-- Get the root effect_editor directory from a submodule
-- Works from anywhere within the effect_editor tree
function M.get_editor_root()
    local info = debug.getinfo(2, "S")
    if info and info.source then
        local source = info.source
        if source:sub(1, 1) == "@" then
            source = source:sub(2)
        end

        -- Look for effect_editor in the path
        local root = source:match("(.*/effect_editor/)")
        if root then
            return root
        end
        -- Try Windows-style path
        root = source:match("(.+\\effect_editor\\)")
        if root then
            return root
        end
    end
    return "./"
end

--------------------------------------------------------------------------------
-- Path Conversion
--------------------------------------------------------------------------------

-- Convert a path to Windows format (backslashes)
function M.to_win_path(path)
    if not path then return nil end
    return path:gsub("/", "\\")
end

-- Convert a path to POSIX format (forward slashes)
function M.to_posix_path(path)
    if not path then return nil end
    return path:gsub("\\", "/")
end

-- Convert a POSIX path to WSL UNC path for Windows access
-- /home/user/... -> \\wsl.localhost\Ubuntu\home\user\...
function M.posix_to_wsl_unc(posix_path, distro_name)
    if not posix_path then return nil end
    distro_name = distro_name or os.getenv("WSL_DISTRO_NAME") or "Ubuntu"
    local win_path = posix_path:gsub("/", "\\")
    return "\\\\wsl.localhost\\" .. distro_name .. win_path
end

-- Normalize path for current platform file operations
function M.normalize_path(path)
    if not path then return nil end
    if M.platform == "linux" then
        return M.to_posix_path(path)
    end
    -- Windows / WSL: PCSX-Redux file I/O needs backslashes
    return M.to_win_path(path)
end

--------------------------------------------------------------------------------
-- Directory Operations
--------------------------------------------------------------------------------

-- Ensure a directory exists (cross-platform)
function M.ensure_dir(path)
    if not path then return false end

    if M.platform == "linux" then
        local posix_path = M.to_posix_path(path)
        -- Check existence first
        local test_path = posix_path .. "/.dir_check_" .. tostring(os.time())
        local f = io.open(test_path, "w")
        if f then
            f:close()
            os.remove(test_path)
            return true
        end
        os.execute('mkdir -p "' .. posix_path .. '"')
        return true
    end

    local win_path = M.to_win_path(path)

    -- First try to detect if directory already exists
    local test_path = win_path .. "\\.dir_check_" .. tostring(os.time())
    local f = io.open(test_path, "w")
    if f then
        f:close()
        os.remove(test_path)
        return true
    end

    if M.platform == "windows" then
        os.execute('mkdir "' .. win_path .. '" 2>nul')
    else
        -- WSL: use cmd.exe to create Windows directory
        os.execute('cmd.exe /c mkdir "' .. win_path .. '" 2>nul')
    end
    return true
end

--------------------------------------------------------------------------------
-- File Listing
--------------------------------------------------------------------------------

-- List files matching a pattern in a directory (cross-platform)
-- Returns a table of filenames (without path)
function M.list_files(dir, extension)
    local files = {}

    if M.platform == "linux" then
        local posix_path = M.to_posix_path(dir)
        local temp_file = "/tmp/pcsx_ee_list_" .. tostring(os.time()) .. ".txt"
        local glob = extension and (posix_path .. extension) or (posix_path .. "*")
        os.execute('ls -1 "' .. posix_path .. '" 2>/dev/null > "' .. temp_file .. '"')
        local handle = io.open(temp_file, "r")
        if handle then
            for line in handle:lines() do
                if line and #line > 0 then
                    -- Filter by extension if provided (strip leading * from "*.json")
                    if extension then
                        local ext = extension:match("%*(.+)$") or extension
                        if line:sub(-#ext) == ext then
                            table.insert(files, line)
                        end
                    else
                        table.insert(files, line)
                    end
                end
            end
            handle:close()
            os.remove(temp_file)
        end
        return files
    end

    local win_path = M.to_win_path(dir)
    local pattern = extension or "*"

    -- Use temp file to avoid console window flash
    local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
    local temp_file = temp_dir .. "\\pcsx_ee_list.txt"

    local cmd
    if M.platform == "windows" then
        cmd = string.format('cmd /c dir /b "%s%s" > "%s" 2>nul', win_path, pattern, temp_file)
    else
        -- WSL: use cmd.exe for Windows filesystem access
        cmd = string.format('cmd.exe /c dir /b "%s%s" > "%s" 2>nul', win_path, pattern, temp_file)
    end

    os.execute(cmd)

    local handle = io.open(temp_file, "r")
    if handle then
        for line in handle:lines() do
            if line and #line > 0 then
                table.insert(files, line)
            end
        end
        handle:close()
        os.remove(temp_file)
    end

    return files
end

--------------------------------------------------------------------------------
-- Home/Config Directory Detection
--------------------------------------------------------------------------------

-- Get the user's home directory
function M.get_home_dir()
    -- Try Windows first (PCSX-Redux runs on Windows)
    local userprofile = os.getenv("USERPROFILE")
    if userprofile then
        return M.to_posix_path(userprofile)
    end

    -- Fall back to POSIX
    local home = os.getenv("HOME")
    if home then
        return home
    end

    -- Last resort fallback - use temp directory
    local temp = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
    return M.to_posix_path(temp)
end

-- Get the application data directory
function M.get_appdata_dir()
    -- Native Linux: use XDG config dir (~/.config)
    if M.platform == "linux" then
        local xdg = os.getenv("XDG_CONFIG_HOME")
        if xdg then return xdg end
        return M.get_home_dir() .. "/.config"
    end

    -- Windows / WSL: use APPDATA (e.g. C:\Users\...\AppData\Roaming)
    local appdata = os.getenv("APPDATA")
    if appdata then
        return M.to_posix_path(appdata)
    end

    return M.get_home_dir() .. "/AppData/Roaming"
end

return M
