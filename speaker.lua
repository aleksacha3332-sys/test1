-- Audioplayer Pro (Multi-Speaker, Selective Floppy Drives, Monitor UI, Remote Control)
-- Version 3.1

local dfpwm = require("cc.audio.dfpwm")

-- ===== CONFIGURATION =====
-- List the drive sides you want to use (e.g., "drive_1", "drive_2", ...).
-- Leave empty {} to use all detected disk drives (not recommended if you have many).
local ALLOWED_DRIVES = {
    "drive_0",
    "drive_1",
    "drive_2",
    "drive_3",
    "drive_4",
    "drive_5",
    "drive_6",
    "drive_7",
    "drive_8",
    "drive_9",
    "drive_10",
    "drive_11",
    "drive_12",
    "drive_13",
    "drive_14",
    "drive_15",
    "drive_16",
    "drive_17"
}

local BITRATE = 6000          -- bytes/sec for DFPWM (48 kbps)
local UPDATE_INTERVAL = 0.5   -- seconds between monitor updates

-- ===== PERIPHERALS =====
local speakers = {}           -- all connected speakers
local monitor = nil           -- first connected monitor
local diskDrives = {}         -- filtered list of drive sides (from ALLOWED_DRIVES)

-- ===== PLAYBACK STATE =====
local state = {
    playing = false,
    paused = false,
    currentFile = nil,
    currentName = nil,
    currentDrive = nil,
    loop = false,
    volume = 1.0,
    mode = "single",          -- "single" or "playlist"
    playlist = {},
    playlistIndex = 0,
    totalBytes = 0,
    readBytes = 0,
    progress = 0,
    isActive = false,
}

-- ===== HELPER FUNCTIONS =====

-- Find all speakers and the first monitor.
-- Disk drives are taken from ALLOWED_DRIVES (no auto‑detection).
function findPeripherals()
    speakers = {}
    for _, side in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(side)
        if p and p.playAudio then
            table.insert(speakers, p)
        end
        if p and p.getSize then  -- monitor
            monitor = p
        end
    end

    -- Use only explicitly allowed drives
    diskDrives = {}
    for _, side in ipairs(ALLOWED_DRIVES) do
        if peripheral.isPresent(side) and peripheral.getType(side) == "disk_drive" then
            table.insert(diskDrives, side)
        end
    end
    -- If ALLOWED_DRIVES is empty, fallback to all disk drives (legacy behaviour)
    if #diskDrives == 0 and #ALLOWED_DRIVES == 0 then
        for _, side in ipairs(peripheral.getNames()) do
            if peripheral.getType(side) == "disk_drive" then
                table.insert(diskDrives, side)
            end
        end
    end
end

-- Get list of files from the allowed disk drives
function getFileList()
    local files = {}
    for _, side in ipairs(diskDrives) do
        local drive = peripheral.wrap(side)
        if drive and drive.isDiskPresent and drive.isDiskPresent() then
            local mountPath = side
            if fs.exists(mountPath) and fs.isDir(mountPath) then
                for _, file in ipairs(fs.list(mountPath)) do
                    local fullPath = mountPath .. "/" .. file
                    if not fs.isDir(fullPath) then
                        table.insert(files, {
                            name = file,
                            path = fullPath,
                            drive = side,
                            size = fs.getSize(fullPath)
                        })
                    end
                end
            end
        end
    end
    return files
end

-- Play audio buffer on all speakers synchronously
function playAudioOnAllSpeakers(buffer)
    if #speakers == 0 then
        print("No speakers found!")
        return false
    end
    local pending = {}
    for _, sp in ipairs(speakers) do
        pending[#pending + 1] = sp
    end
    while #pending > 0 do
        for i = #pending, 1, -1 do
            local sp = pending[i]
            if sp.playAudio(buffer, state.volume) then
                table.remove(pending, i)
            end
        end
        if #pending > 0 then
            os.pullEvent("speaker_audio_empty")
        end
    end
    return true
end

-- Update information on the monitor
function updateMonitor()
    if not monitor then return end
    local w, h = monitor.getSize()
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextColor(colors.white)
    monitor.write("=== AUDIOPLAYER PRO ===")
    monitor.setCursorPos(1, 2)
    monitor.write("Status: ")
    if state.playing then
        if state.paused then
            monitor.setTextColor(colors.yellow)
            monitor.write("PAUSED")
        else
            monitor.setTextColor(colors.green)
            monitor.write("PLAYING")
        end
    else
        monitor.setTextColor(colors.red)
        monitor.write("STOPPED")
    end
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, 4)
    monitor.write("File: " .. (state.currentName or "-"))
    monitor.setCursorPos(1, 5)
    monitor.write("Drive: " .. (state.currentDrive or "-"))
    monitor.setCursorPos(1, 6)
    if state.playing and state.totalBytes > 0 then
        local elapsed = state.readBytes / BITRATE
        local total = state.totalBytes / BITRATE
        local remain = total - elapsed
        monitor.write(string.format("Time: %02d:%02d / %02d:%02d",
            math.floor(elapsed / 60), math.floor(elapsed % 60),
            math.floor(total / 60), math.floor(total % 60)))
        monitor.setCursorPos(1, 7)
        local barWidth = math.min(w - 1, 40)
        local filled = math.floor(state.progress * barWidth)
        local bar = string.rep("#", filled) .. string.rep("-", barWidth - filled)
        monitor.write("Progress: " .. bar)
        monitor.setCursorPos(1, 8)
        monitor.write(string.format("  %3.0f%%", state.progress * 100))
    else
        monitor.write("Time: --:-- / --:--")
    end
    monitor.setCursorPos(1, 9)
    monitor.write("Mode: " .. (state.mode == "single" and "Single" or "Playlist"))
    if state.loop then
        monitor.setTextColor(colors.cyan)
        monitor.write(" (Loop)")
        monitor.setTextColor(colors.white)
    end
    monitor.setCursorPos(1, h)
    monitor.write("Remote via rednet")
end

-- Core playback routine (runs in a coroutine)
function playFileCoroutine(filePath, loop, volume)
    if state.isActive then
        return
    end
    state.isActive = true
    state.playing = true
    state.paused = false
    state.loop = loop
    state.volume = volume or 1.0
    state.currentFile = filePath
    state.currentName = fs.getName(filePath)
    -- Determine drive side from path
    for _, side in ipairs(diskDrives) do
        if string.find(filePath, "^" .. side .. "/") then
            state.currentDrive = side
            break
        end
    end
    if not state.currentDrive then state.currentDrive = "?" end

    state.totalBytes = fs.getSize(filePath)
    state.readBytes = 0
    state.progress = 0

    local decoder = dfpwm.make_decoder()
    local ok, err = pcall(function()
        local file = io.open(filePath, "rb")
        if not file then error("Failed to open file") end

        while true do
            if state.paused then
                while state.paused and state.playing do
                    os.pullEvent("timer")
                end
                if not state.playing then break end
            end

            local chunk = file:read(16 * 1024)
            if not chunk then break end

            local buffer = decoder(chunk)
            if not playAudioOnAllSpeakers(buffer) then
                error("Playback error on speakers")
            end

            state.readBytes = state.readBytes + #chunk
            state.progress = math.min(state.readBytes / state.totalBytes, 1)
            updateMonitor()
            os.sleep(0.02)
        end
        file:close()
    end)

    state.playing = false
    state.isActive = false
    state.paused = false
    if not ok then
        print("Error: " .. tostring(err))
    end

    -- Playlist handling
    if state.mode == "playlist" and #state.playlist > 0 then
        if loop then
            state.playlistIndex = state.playlistIndex + 1
            if state.playlistIndex > #state.playlist then
                state.playlistIndex = 1
            end
            local nextFile = state.playlist[state.playlistIndex]
            if nextFile then
                startPlayback(nextFile, loop, volume)
            end
        else
            state.playlistIndex = state.playlistIndex + 1
            if state.playlistIndex <= #state.playlist then
                local nextFile = state.playlist[state.playlistIndex]
                if nextFile then
                    startPlayback(nextFile, loop, volume)
                end
            else
                state.playing = false
                state.playlist = {}
                state.playlistIndex = 0
            end
        end
    else
        if not loop then
            state.playing = false
        else
            if state.loop and state.currentFile then
                startPlayback(state.currentFile, true, state.volume)
            else
                state.playing = false
            end
        end
    end
    updateMonitor()
end

-- Safe start of playback
function startPlayback(filePath, loop, volume)
    if state.isActive then
        print("Playback already active")
        return
    end
    if not fs.exists(filePath) or fs.isDir(filePath) then
        print("File not found: " .. filePath)
        return
    end
    local co = coroutine.create(function()
        playFileCoroutine(filePath, loop, volume)
    end)
    coroutine.resume(co)
end

-- Stop playback
function stopPlayback()
    state.playing = false
    state.paused = false
    state.isActive = false
    state.currentFile = nil
    state.currentName = nil
    state.currentDrive = nil
    state.progress = 0
    state.readBytes = 0
    state.totalBytes = 0
    updateMonitor()
end

-- Pause / Resume toggle
function togglePause()
    if state.playing then
        state.paused = not state.paused
        updateMonitor()
    end
end

-- Set volume (0..1)
function setVolume(vol)
    state.volume = math.max(0, math.min(1, vol))
    updateMonitor()
end

-- ===== REDNET COMMANDS =====

function handleRednetMessage(sender, message, protocol)
    if protocol ~= "audio_control" then return end
    if type(message) ~= "table" then return end

    local cmd = message.command
    if cmd == "play" then
        local file = message.file
        local loop = message.loop or false
        local volume = message.volume or 1.0
        if file then
            local fileList = getFileList()
            local found = nil
            for _, f in ipairs(fileList) do
                if f.name == file then
                    found = f.path
                    break
                end
            end
            if found then
                state.mode = "single"
                state.playlist = {}
                state.playlistIndex = 0
                startPlayback(found, loop, volume)
            else
                print("File not found: " .. file)
            end
        end
    elseif cmd == "playlist" then
        local files = message.files or {}
        local loop = message.loop or false
        local volume = message.volume or 1.0
        if #files > 0 then
            local validPaths = {}
            local fileList = getFileList()
            for _, fname in ipairs(files) do
                for _, f in ipairs(fileList) do
                    if f.name == fname then
                        table.insert(validPaths, f.path)
                        break
                    end
                end
            end
            if #validPaths > 0 then
                state.mode = "playlist"
                state.playlist = validPaths
                state.playlistIndex = 1
                state.loop = loop
                state.volume = volume
                startPlayback(validPaths[1], loop, volume)
            else
                print("No valid files found in playlist")
            end
        end
    elseif cmd == "stop" then
        stopPlayback()
    elseif cmd == "pause" then
        togglePause()
    elseif cmd == "resume" then
        if state.paused then
            state.paused = false
            updateMonitor()
        end
    elseif cmd == "volume" then
        local vol = message.volume
        if vol then
            setVolume(vol)
        end
    end
end

-- ===== LOCAL CONSOLE INTERFACE =====

function printHelp()
    print("Available commands:")
    print("  list                - show all files on allowed drives")
    print("  play <number>       - play file by number (from list)")
    print("  play <name>         - play file by name")
    print("  playlist <numbers>  - play a playlist (space-separated)")
    print("  loop <number/name>  - loop a file")
    print("  stop                - stop playback")
    print("  pause               - pause/resume")
    print("  volume <0..1>       - set volume")
    print("  help                - this help")
    print("  exit                - exit program")
end

function localCommandHandler(input)
    local parts = {}
    for part in string.gmatch(input, "%S+") do
        table.insert(parts, part)
    end
    if #parts == 0 then return end
    local cmd = parts[1]

    if cmd == "list" then
        local files = getFileList()
        if #files == 0 then
            print("No files found on allowed drives.")
        else
            print("Available files:")
            for i, f in ipairs(files) do
                print(string.format("%d. %s (on %s, %d bytes)", i, f.name, f.drive, f.size))
            end
        end
    elseif cmd == "play" then
        if #parts < 2 then
            print("Specify a number or file name.")
            return
        end
        local arg = parts[2]
        local files = getFileList()
        local found = nil
        if tonumber(arg) then
            local idx = tonumber(arg)
            if files[idx] then
                found = files[idx].path
            end
        else
            for _, f in ipairs(files) do
                if f.name == arg then
                    found = f.path
                    break
                end
            end
        end
        if found then
            state.mode = "single"
            state.playlist = {}
            state.playlistIndex = 0
            startPlayback(found, false, state.volume)
        else
            print("File not found.")
        end
    elseif cmd == "loop" then
        if #parts < 2 then
            print("Specify a number or file name.")
            return
        end
        local arg = parts[2]
        local files = getFileList()
        local found = nil
        if tonumber(arg) then
            local idx = tonumber(arg)
            if files[idx] then
                found = files[idx].path
            end
        else
            for _, f in ipairs(files) do
                if f.name == arg then
                    found = f.path
                    break
                end
            end
        end
        if found then
            state.mode = "single"
            state.playlist = {}
            state.playlistIndex = 0
            startPlayback(found, true, state.volume)
        else
            print("File not found.")
        end
    elseif cmd == "playlist" then
        if #parts < 2 then
            print("Specify file numbers separated by space.")
            return
        end
        local files = getFileList()
        local indices = {}
        for i = 2, #parts do
            local idx = tonumber(parts[i])
            if idx and files[idx] then
                table.insert(indices, files[idx].path)
            end
        end
        if #indices == 0 then
            print("No valid numbers.")
            return
        end
        state.mode = "playlist"
        state.playlist = indices
        state.playlistIndex = 1
        state.loop = false
        startPlayback(indices[1], false, state.volume)
    elseif cmd == "stop" then
        stopPlayback()
    elseif cmd == "pause" then
        togglePause()
    elseif cmd == "volume" then
        if #parts < 2 then
            print("Current volume: " .. state.volume)
        else
            local vol = tonumber(parts[2])
            if vol then
                setVolume(vol)
                print("Volume set to: " .. state.volume)
            end
        end
    elseif cmd == "help" then
        printHelp()
    elseif cmd == "exit" then
        os.exit()
    else
        print("Unknown command. Type 'help'.")
    end
end

-- ===== MAIN LOOP =====

function main()
    findPeripherals()
    print("Speakers found: " .. #speakers)
    print("Allowed drives: " .. #diskDrives)
    if monitor then
        print("Monitor found")
        monitor.setTextScale(0.5)
    else
        print("No monitor found")
    end

    if rednet then
        rednet.open("back")   -- adjust side if needed
        print("Rednet opened on back")
    else
        print("Rednet not available")
    end

    print("Program started. Type 'help' for commands.")
    updateMonitor()

    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        if event == "rednet_message" then
            local sender, message, protocol = p1, p2, p3
            handleRednetMessage(sender, message, protocol)
        elseif event == "disk" or event == "disk_eject" then
            updateMonitor()
            print("Disk changed, file list refreshed.")
        elseif event == "timer" then
            updateMonitor()
        end
    end
end

-- Run main with a parallel console input loop
local function consoleLoop()
    while true do
        print("> ")
        local input = read()
        localCommandHandler(input)
    end
end

parallel.waitForAny(
    function() main() end,
    function() consoleLoop() end
)
