-- ============================================
-- Advanced Music Player for ComputerCraft 1.21.1
-- Features:
--   - Multiple speakers support
--   - Multiple floppy disks library
--   - Multi-disk tracks (one song split across floppies)
--   - Touch monitor UI
--   - Rednet remote control
--   - Progress bar with seek
--   - Shuffle, sleep timer, visualizer
-- ============================================

local VERSION = "3.2"

-- ===== CONFIGURATION =====
local CONFIG = {
    rednetProtocol = "music_player",
    rednetHostName = "music_host",
    chunkSize = 16 * 1024 - 4,
    sampleRate = 48000,
    updateInterval = 0.5,
    maxQueueDisplay = 8,
    maxLibDisplay = 10,
    visualizerBars = 16,
    diskMusicPath = "music",
    metadataFile = "metadata.json",
    partPattern = "%.dfpwm%.part(%d+)$",
    metaPattern = "%.dfpwm%.meta$",
}

-- ===== STATE =====
local state = {
    playing = false,
    paused = false,
    queue = {},
    nowPlaying = nil,
    looping = 0,
    shuffle = false,
    volume = 1.5,
    sleepTimer = 0,
    sleepStart = nil,
    tab = 1,
    library = {},
    libraryScroll = 0,
    queueScroll = 0,
    searchQuery = "",
    filteredLibrary = {},
    progress = 0,
    trackPosition = 0,
    trackDuration = 0,
    isLoading = false,
    isError = false,
    errorMsg = "",
    visualizerData = {},
    needsRedraw = true,
    waitingInput = false,
    lastDiskCheck = 0,
    diskEjectWarning = false,
}

-- ===== PERIPHERALS =====
local speakers = {}
local monitors = {}
local driveNames = {}
local modem = nil
local mainMonitor = nil

-- ===== MULTI-DISK STREAM =====
-- Reads one logical track that may be spread over several floppy disks.
-- Parts are transparently chained: when a part ends, the next
-- mounted disk's part is opened and reading continues.
local stream = {
    files = {},    -- ordered list of part file paths (part0, part1, ...)
    index = 0,     -- index of the currently open part
    handle = nil,  -- open binary handle of the current part
}

local function streamClose()
    if stream.handle then stream.handle.close() end
    stream.handle = nil
    stream.index = 0
    stream.files = {}
end

local function streamOpen(files)
    streamClose()
    stream.files = files
    stream.index = 1
    stream.handle = fs.open(files[1], "rb")
    return stream.handle ~= nil
end

-- Reads up to count bytes across part boundaries.
-- Returns nil only when the whole stream is exhausted.
local function streamRead(count)
    local buffers = {}
    local total = 0
    while total < count do
        if not stream.handle then
            if total == 0 then return nil end
            break
        end
        local data = stream.handle.read(count - total)
        if data and #data > 0 then
            table.insert(buffers, data)
            total = total + #data
        else
            -- Current part is finished, move to the next disk's part
            stream.handle.close()
            stream.index = stream.index + 1
            local nextFile = stream.files[stream.index]
            if not nextFile then
                stream.handle = nil
                if total == 0 then return nil end
                break
            end
            stream.handle = fs.open(nextFile, "rb")
            if not stream.handle then return nil end
        end
    end
    return table.concat(buffers)
end

-- Seeks to an absolute byte offset within the whole logical stream.
local function streamSeek(offset)
    local remaining = offset
    local idx = 1
    while idx < #stream.files do
        local partSize = fs.getSize(stream.files[idx])
        if remaining < partSize then break end
        remaining = remaining - partSize
        idx = idx + 1
    end
    if stream.handle then stream.handle.close() end
    stream.index = idx
    stream.handle = fs.open(stream.files[idx], "rb")
    if not stream.handle then return false end
    if stream.handle.seek then
        stream.handle.seek("set", remaining)
    else
        while remaining > 0 do
            local r = math.min(remaining, 4096)
            stream.handle.read(r)
            remaining = remaining - r
            sleep(0)
        end
    end
    return true
end

-- ===== AUDIO =====
local decoder = require("cc.audio.dfpwm").make_decoder()
local audioStart = nil
local audioBytesRead = 0
local audioFileSize = 0
local audioNeedsChunk = false

-- ===== UTILITIES =====
local function formatTime(s)
    if not s or s < 0 then s = 0 end
    return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60))
end

local function clamp(v, a, b)
    return math.max(a, math.min(b, v))
end

-- Find peripheral NAMES (strings)
local function findNames(pType)
    local t = {}
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == pType then
            table.insert(t, n)
        end
    end
    return t
end

-- Find wrapped peripheral OBJECTS
local function wrapAll(pType)
    local t = {}
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == pType then
            table.insert(t, peripheral.wrap(n))
        end
    end
    return t
end

-- ===== DISK & LIBRARY =====
local function getDiskMountPaths()
    local paths = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" then
            local mountPath = disk.getMountPath(name)
            if mountPath then
                table.insert(paths, mountPath)
            end
        end
    end
    return paths
end

-- Registry of multi-disk track parts found across all mounts.
-- partsRegistry["Song.dfpwm"][0] = "disk/music/Song.dfpwm.part0"
local partsRegistry = {}
local partsMeta = {}

local function scanDiskMount(mountPath)
    local mpath = fs.combine(mountPath, CONFIG.diskMusicPath)
    if not fs.isDir(mpath) then return {} end

    local meta = {}
    local mfile = fs.combine(mountPath, CONFIG.metadataFile)
    if fs.exists(mfile) then
        local f = fs.open(mfile, "r")
        if f then
            local ok, d = pcall(textutils.unserializeJSON, f.readAll())
            if ok and type(d) == "table" then meta = d end
            f.close()
        end
    end
    local byFile = {}
    for _, e in ipairs(meta) do
        if e.file then byFile[e.file] = e end
    end

    local tracks = {}
    for _, fn in ipairs(fs.list(mpath)) do
        local fp = fs.combine(mpath, fn)
        if fn:match("%.dfpwm$") then
            -- Regular single-disk track
            local sz = fs.getSize(fp)
            local m = byFile[fn] or {}
            local dur = m.duration or math.floor(sz * 8 / CONFIG.sampleRate)
            table.insert(tracks, {
                id = mountPath .. "/" .. fn:gsub("%.dfpwm$", ""),
                file = fp,
                files = {fp},
                name = m.name or fn:gsub("%.dfpwm$", ""),
                artist = m.artist or "Unknown",
                duration = dur,
                size = sz,
                disk = mountPath,
            })
        else
            -- Multi-disk part: "Song.dfpwm.part3"
            local partIdx = fn:match(CONFIG.partPattern)
            if partIdx then
                local base = fn:gsub("%.part%d+$", "")
                partsRegistry[base] = partsRegistry[base] or {}
                partsRegistry[base][tonumber(partIdx)] = fp
            elseif fn:match(CONFIG.metaPattern) then
                -- Part metadata: "Song.dfpwm.meta"
                local base = fn:gsub("%.meta$", "")
                local f = fs.open(fp, "r")
                if f then
                    local ok, d = pcall(textutils.unserializeJSON, f.readAll())
                    if ok and type(d) == "table" then partsMeta[base] = d end
                    f.close()
                end
            end
        end
    end
    return tracks
end

local function scanLibrary()
    state.library = {}
    partsRegistry = {}
    partsMeta = {}
    driveNames = getDiskMountPaths()
    for _, mp in ipairs(driveNames) do
        for _, tr in ipairs(scanDiskMount(mp)) do
            table.insert(state.library, tr)
        end
    end

    -- Assemble multi-disk tracks: a track appears in the library
    -- only when every one of its parts is present on a mounted disk.
    for base, parts in pairs(partsRegistry) do
        local lastIdx = -1
        for i in pairs(parts) do
            if i > lastIdx then lastIdx = i end
        end
        local files = {}
        local totalSize = 0
        local complete = true
        for i = 0, lastIdx do
            local p = parts[i]
            if not p then
                complete = false
                break
            end
            table.insert(files, p)
            totalSize = totalSize + fs.getSize(p)
        end
        if complete and #files > 0 then
            local m = partsMeta[base] or {}
            table.insert(state.library, {
                id = "multi/" .. base:gsub("%.dfpwm$", ""),
                files = files,
                name = m.name or base:gsub("%.dfpwm$", ""),
                artist = m.artist or "Unknown",
                duration = m.duration or math.floor(totalSize * 8 / CONFIG.sampleRate),
                size = totalSize,
                disk = nil,
                parts = #files,
            })
        end
    end

    table.sort(state.library, function(a, b) return a.name:lower() < b.name:lower() end)

    if state.searchQuery ~= "" then
        state.filteredLibrary = {}
        local q = state.searchQuery:lower()
        for _, tr in ipairs(state.library) do
            if tr.name:lower():find(q, 1, true) or tr.artist:lower():find(q, 1, true) then
                table.insert(state.filteredLibrary, tr)
            end
        end
    else
        state.filteredLibrary = state.library
    end
    if not state.filteredLibrary then
        state.filteredLibrary = {}
    end
    state.libraryScroll = clamp(state.libraryScroll, 0, math.max(0, #state.filteredLibrary - CONFIG.maxLibDisplay))
end

local function closeTrack()
    streamClose()
    audioNeedsChunk = false
end

local function checkDiskChanges()
    local curPaths = getDiskMountPaths()
    local changed = #curPaths ~= #driveNames
    if not changed then
        for i, p in ipairs(curPaths) do
            if driveNames[i] ~= p then
                changed = true
                break
            end
        end
    end
    if changed then
        scanLibrary()
        state.diskEjectWarning = true
        state.needsRedraw = true
        if state.nowPlaying then
            -- For multi-disk tracks every part's disk must stay mounted
            local ok = true
            for _, f in ipairs(state.nowPlaying.files) do
                local found = false
                for _, p in ipairs(curPaths) do
                    if f:find(p, 1, true) then
                        found = true
                        break
                    end
                end
                if not found then
                    ok = false
                    break
                end
            end
            if not ok then
                state.isError = true
                state.errorMsg = "Disk ejected!"
                for _, sp in ipairs(speakers) do sp.stop() end
                state.playing = false
                state.nowPlaying = nil
                closeTrack()
            end
        end
    end
end

-- ===== AUDIO ENGINE =====
local function openTrack(track)
    closeTrack()
    if not track then return false end
    -- All parts of a multi-disk track must be available
    for _, f in ipairs(track.files) do
        if not fs.exists(f) then return false end
    end
    if not streamOpen(track.files) then return false end
    audioStart = streamRead(4)
    audioFileSize = track.size
    audioBytesRead = 4
    state.trackDuration = track.duration
    state.trackPosition = 0
    state.progress = 0
    audioNeedsChunk = true
    return true
end

local function readChunk()
    local chunk = streamRead(CONFIG.chunkSize)
    if not chunk then return nil end
    if audioStart then
        chunk = audioStart .. chunk
        audioStart = nil
    end
    audioBytesRead = audioBytesRead + #chunk
    state.trackPosition = (audioBytesRead * 8) / CONFIG.sampleRate
    state.progress = clamp(audioBytesRead / audioFileSize, 0, 1)

    local bars = {}
    local step = math.floor(#chunk / CONFIG.visualizerBars)
    for i = 1, CONFIG.visualizerBars do
        local sum = 0
        local idx0 = (i - 1) * step + 1
        for j = 0, math.min(step - 1, 10) do
            local idx = idx0 + j * math.floor(step / 10)
            if idx <= #chunk then sum = sum + string.byte(chunk, idx) end
        end
        bars[i] = math.floor((sum / 11) / 25.5)
    end
    state.visualizerData = bars
    return chunk
end

local function seekTrack(pos)
    if not state.nowPlaying then return end
    local target = math.floor(pos * audioFileSize)
    target = target - (target % 4)
    target = clamp(target, 4, audioFileSize - 4)

    if not streamSeek(target) then return end

    audioStart = streamRead(4)
    audioBytesRead = target + 4
    state.trackPosition = (audioBytesRead * 8) / CONFIG.sampleRate
    state.progress = pos
    audioNeedsChunk = true
end

local function playOnSpeakers(buffer, vol)
    local fns = {}
    for _, sp in ipairs(speakers) do
        table.insert(fns, function()
            local nm = peripheral.getName(sp)
            while state.playing and not state.paused do
                if sp.playAudio(buffer, vol) then
                    while true do
                        local ev, p1 = os.pullEvent()
                        if ev == "speaker_audio_empty" and p1 == nm then break end
                        if ev == "playback_stopped" then return end
                    end
                    break
                else
                    os.pullEvent("speaker_audio_empty")
                end
            end
        end)
    end
    pcall(parallel.waitForAll, table.unpack(fns))
end

local function stopPlayback()
    state.playing = false
    state.paused = false
    for _, sp in ipairs(speakers) do sp.stop() end
    os.queueEvent("playback_stopped")
    closeTrack()
    state.progress = 0
    state.trackPosition = 0
    state.visualizerData = {}
end

local function skipTrack()
    if state.looping == 2 and state.nowPlaying then
        if openTrack(state.nowPlaying) then
            state.playing = true
            state.paused = false
            audioNeedsChunk = true
            return
        end
    end
    if #state.queue > 0 then
        if state.looping == 1 and state.nowPlaying then
            table.insert(state.queue, state.nowPlaying)
        end
        state.nowPlaying = state.queue[1]
        table.remove(state.queue, 1)
        if openTrack(state.nowPlaying) then
            state.playing = true
            state.paused = false
            audioNeedsChunk = true
            state.isError = false
            state.errorMsg = ""
        else
            state.isError = true
            state.errorMsg = "Cannot open"
            state.nowPlaying = nil
        end
    else
        if state.looping == 1 and state.nowPlaying then
            if openTrack(state.nowPlaying) then
                state.playing = true
                state.paused = false
                audioNeedsChunk = true
                return
            end
        end
        state.nowPlaying = nil
        state.playing = false
        closeTrack()
    end
end

local function prevTrack()
    if state.nowPlaying then
        seekTrack(0)
        state.paused = false
        state.playing = true
        audioNeedsChunk = true
    end
end

local function audioLoop()
    while true do
        if state.playing and not state.paused and state.nowPlaying then
            if audioNeedsChunk then
                local chunk = readChunk()
                if chunk then
                    audioNeedsChunk = false
                    local buf = decoder(chunk)
                    playOnSpeakers(buf, state.volume)
                    audioNeedsChunk = true
                    state.needsRedraw = true
                else
                    skipTrack()
                    state.needsRedraw = true
                end
            else
                sleep(0.05)
            end
        else
            sleep(0.1)
        end
        if state.sleepTimer > 0 and state.sleepStart then
            if (os.clock() - state.sleepStart) / 60 >= state.sleepTimer then
                stopPlayback()
                state.sleepTimer = 0
                state.sleepStart = nil
            end
        end
        if os.clock() - state.lastDiskCheck > 2 then
            state.lastDiskCheck = os.clock()
            checkDiskChanges()
        end
        os.queueEvent("audio_tick")
        os.pullEvent("audio_tick")
    end
end

-- ===== REDNET =====
local rednetEnabled = false

local function initRednet()
    local names = findNames("modem")
    if #names > 0 then
        for _, n in ipairs(names) do
            rednet.open(n)
        end
        rednet.host(CONFIG.rednetProtocol, CONFIG.rednetHostName)
        rednetEnabled = true
        return true
    end
    return false
end

local function broadcastStatus()
    if not rednetEnabled then return end
    local st = {
        type = "status",
        playing = state.playing,
        paused = state.paused,
        nowPlaying = state.nowPlaying,
        progress = state.progress,
        position = state.trackPosition,
        duration = state.trackDuration,
        volume = state.volume,
        looping = state.looping,
        shuffle = state.shuffle,
        queueSize = #state.queue,
        queue = {},
        error = state.isError,
        errorMsg = state.errorMsg,
    }
    for i = 1, math.min(5, #state.queue) do
        table.insert(st.queue, {
            name = state.queue[i].name,
            artist = state.queue[i].artist,
            duration = state.queue[i].duration,
        })
    end
    rednet.broadcast(textutils.serializeJSON(st), CONFIG.rednetProtocol)
end

local function sendLibrary(id)
    if not rednetEnabled then return end
    local lib = {}
    for _, tr in ipairs(state.library) do
        table.insert(lib, {
            id = tr.id,
            name = tr.name,
            artist = tr.artist,
            duration = tr.duration,
        })
    end
    local chunkSize = 50
    for i = 1, #lib, chunkSize do
        local c = {}
        for j = i, math.min(i + chunkSize - 1, #lib) do
            table.insert(c, lib[j])
        end
        rednet.send(id, textutils.serializeJSON({
            type = "library_chunk",
            chunk = c,
            index = i,
            total = #lib,
        }), CONFIG.rednetProtocol)
        sleep(0.1)
    end
    rednet.send(id, textutils.serializeJSON({
        type = "library_end",
        total = #lib,
    }), CONFIG.rednetProtocol)
end

local function rednetLoop()
    if not rednetEnabled then return end
    while true do
        local sid, msg = rednet.receive(CONFIG.rednetProtocol)
        local ok, cmd = pcall(textutils.unserializeJSON, msg)
        if not ok or type(cmd) ~= "table" then cmd = {cmd = msg} end

        if cmd.cmd == "play" then
            if cmd.track_id then
                for _, tr in ipairs(state.library) do
                    if tr.id == cmd.track_id then
                        stopPlayback()
                        state.nowPlaying = tr
                        if openTrack(tr) then
                            state.playing = true
                            state.paused = false
                            audioNeedsChunk = true
                            if cmd.clear_queue then state.queue = {} end
                        end
                        break
                    end
                end
            elseif state.nowPlaying then
                state.paused = false
                state.playing = true
                audioNeedsChunk = true
            elseif #state.queue > 0 then
                skipTrack()
            end
            state.needsRedraw = true

        elseif cmd.cmd == "pause" then
            state.paused = true
            for _, sp in ipairs(speakers) do sp.stop() end
            os.queueEvent("playback_stopped")
            state.needsRedraw = true

        elseif cmd.cmd == "resume" then
            state.paused = false
            state.playing = true
            audioNeedsChunk = true
            state.needsRedraw = true

        elseif cmd.cmd == "stop" then
            stopPlayback()
            state.needsRedraw = true

        elseif cmd.cmd == "skip" then
            skipTrack()
            state.needsRedraw = true

        elseif cmd.cmd == "prev" then
            prevTrack()
            state.needsRedraw = true

        elseif cmd.cmd == "queue_add" and cmd.track_id then
            for _, tr in ipairs(state.library) do
                if tr.id == cmd.track_id then
                    if cmd.position == "next" then
                        table.insert(state.queue, 1, tr)
                    else
                        table.insert(state.queue, tr)
                    end
                    break
                end
            end
            state.needsRedraw = true

        elseif cmd.cmd == "queue_remove" and cmd.index then
            if cmd.index >= 1 and cmd.index <= #state.queue then
                table.remove(state.queue, cmd.index)
            end
            state.needsRedraw = true

        elseif cmd.cmd == "set_volume" and cmd.volume then
            state.volume = clamp(cmd.volume, 0, 3)
            state.needsRedraw = true

        elseif cmd.cmd == "set_loop" and cmd.mode ~= nil then
            state.looping = cmd.mode % 3
            state.needsRedraw = true

        elseif cmd.cmd == "set_shuffle" and cmd.shuffle ~= nil then
            state.shuffle = cmd.shuffle
            state.needsRedraw = true

        elseif cmd.cmd == "seek" and cmd.position then
            seekTrack(clamp(cmd.position, 0, 1))
            state.needsRedraw = true

        elseif cmd.cmd == "get_status" then
            broadcastStatus()

        elseif cmd.cmd == "get_library" then
            sendLibrary(sid)

        elseif cmd.cmd == "set_sleep" and cmd.minutes then
            state.sleepTimer = cmd.minutes
            state.sleepStart = (cmd.minutes > 0) and os.clock() or nil
            state.needsRedraw = true
        end

        rednet.send(sid, textutils.serializeJSON({
            type = "ack",
            cmd = cmd.cmd,
            success = true,
        }), CONFIG.rednetProtocol)
        broadcastStatus()
    end
end

-- ===== UI =====
local function getTarget()
    return mainMonitor or term
end

local function getW()
    return (mainMonitor or term).getSize()
end

local function getH()
    return select(2, (mainMonitor or term).getSize())
end

local function setC(fg, bg)
    local t = getTarget()
    if fg then t.setTextColor(fg) end
    if bg then t.setBackgroundColor(bg) end
end

local function drawT(x, y, txt, fg, bg)
    setC(fg, bg)
    getTarget().setCursorPos(x, y)
    getTarget().write(txt)
end

local function clearSc()
    local t = getTarget()
    t.setBackgroundColor(colors.black)
    t.clear()
end

local function drawTabs()
    local w = getW()
    getTarget().setCursorPos(1, 1)
    getTarget().setBackgroundColor(colors.gray)
    getTarget().clearLine()
    local tabs = {" Library ", " Queue ", " Player "}
    local tw = math.floor(w / #tabs)
    for i, tn in ipairs(tabs) do
        if state.tab == i then
            setC(colors.black, colors.white)
        else
            setC(colors.white, colors.gray)
        end
        local x = (i - 1) * tw + math.floor((tw - #tn) / 2) + 1
        getTarget().setCursorPos(x, 1)
        getTarget().write(tn)
    end
end

local function drawProg(x, y, w, p)
    local f = math.floor(w * p)
    setC(colors.white, colors.gray)
    getTarget().setCursorPos(x, y)
    getTarget().write(string.rep(" ", w))
    if f > 0 then
        setC(colors.black, colors.lime)
        getTarget().setCursorPos(x, y)
        getTarget().write(string.rep(" ", f))
    end
    setC(colors.white, colors.black)
    getTarget().setCursorPos(x + w + 1, y)
    getTarget().write(formatTime(state.trackPosition) .. " / " .. formatTime(state.trackDuration))
end

local function drawVol(x, y, w)
    local f = math.floor(w * (state.volume / 3))
    setC(colors.white, colors.gray)
    getTarget().setCursorPos(x, y)
    getTarget().write(string.rep(" ", w))
    if f > 0 then
        setC(colors.black, colors.orange)
        getTarget().setCursorPos(x, y)
        getTarget().write(string.rep(" ", f))
    end
    setC(colors.white, colors.black)
    getTarget().setCursorPos(x + w + 1, y)
    getTarget().write(math.floor((state.volume / 3) * 100) .. "%")
end

local function drawVis(x, y, w)
    if #state.visualizerData == 0 then
        setC(colors.gray, colors.black)
        for i = 1, w do
            getTarget().setCursorPos(x + i - 1, y)
            getTarget().write("-")
        end
        return
    end
    local bw = math.floor(w / CONFIG.visualizerBars)
    for i = 1, CONFIG.visualizerBars do
        local h = math.min(state.visualizerData[i] or 0, 2)
        local c = colors.lime
        if state.visualizerData[i] > 7 then c = colors.yellow end
        if state.visualizerData[i] > 9 then c = colors.red end
        for hh = 0, h do
            if y - hh >= 1 then
                setC(c, colors.black)
                getTarget().setCursorPos(x + (i - 1) * bw, y - hh)
                getTarget().write(string.rep("|", bw))
            end
        end
    end
end

local function drawLibrary()
    local w, h = getW(), getH()
    local sbg = state.waitingInput and state.tab == 1 and colors.white or colors.lightGray
    setC(colors.black, sbg)
    paintutils.drawFilledBox(2, 3, w - 1, 5, sbg)
    getTarget().setCursorPos(3, 4)
    getTarget().write((state.searchQuery == "" and "Search..." or state.searchQuery):sub(1, w - 5))

    setC(colors.lightGray, colors.black)
    getTarget().setCursorPos(2, 6)
    getTarget().write(#state.filteredLibrary .. " tracks")

    if #state.filteredLibrary == 0 then
        setC(colors.gray, colors.black)
        getTarget().setCursorPos(2, 8)
        getTarget().write("No tracks. Insert floppy disks")
        getTarget().setCursorPos(2, 9)
        getTarget().write("with .dfpwm files in /music/")
    else
        for i = 1, CONFIG.maxLibDisplay do
            local idx = state.libraryScroll + i
            if idx > #state.filteredLibrary then break end
            local tr = state.filteredLibrary[idx]
            local yy = 7 + (i - 1) * 2
            if yy > h - 2 then break end
            if state.nowPlaying and state.nowPlaying.id == tr.id then
                setC(colors.lime, colors.black)
            else
                setC(colors.white, colors.black)
            end
            getTarget().setCursorPos(2, yy)
            getTarget().write(tr.name:sub(1, w - 4))
            local info = tr.artist .. " | " .. formatTime(tr.duration)
            if tr.parts then
                info = info .. " | " .. tr.parts .. " disks"
            end
            setC(colors.lightGray, colors.black)
            getTarget().setCursorPos(2, yy + 1)
            getTarget().write(info:sub(1, w - 4))
        end
        if state.libraryScroll > 0 then
            setC(colors.white, colors.black)
            getTarget().setCursorPos(w, 7)
            getTarget().write("^")
        end
        if state.libraryScroll + CONFIG.maxLibDisplay < #state.filteredLibrary then
            setC(colors.white, colors.black)
            getTarget().setCursorPos(w, h - 1)
            getTarget().write("v")
        end
    end
end

local function drawQueue()
    local w, h = getW(), getH()
    setC(colors.lightGray, colors.black)
    getTarget().setCursorPos(2, 3)
    getTarget().write("Queue (" .. #state.queue .. " tracks)")
    if #state.queue == 0 then
        setC(colors.gray, colors.black)
        getTarget().setCursorPos(2, 5)
        getTarget().write("Queue is empty")
    else
        for i = 1, CONFIG.maxQueueDisplay do
            local idx = state.queueScroll + i
            if idx > #state.queue then break end
            local tr = state.queue[idx]
            local yy = 5 + (i - 1) * 2
            if yy > h - 2 then break end
            setC(colors.white, colors.black)
            getTarget().setCursorPos(2, yy)
            getTarget().write(idx .. ". " .. tr.name:sub(1, w - 6))
            setC(colors.lightGray, colors.black)
            getTarget().setCursorPos(4, yy + 1)
            getTarget().write(tr.artist .. " | " .. formatTime(tr.duration))
        end
        if state.queueScroll > 0 then
            setC(colors.white, colors.black)
            getTarget().setCursorPos(w, 5)
            getTarget().write("^")
        end
        if state.queueScroll + CONFIG.maxQueueDisplay < #state.queue then
            setC(colors.white, colors.black)
            getTarget().setCursorPos(w, h - 1)
            getTarget().write("v")
        end
    end
end

local function drawPlayer()
    local w, h = getW(), getH()
    if state.nowPlaying then
        setC(colors.lime, colors.black)
        getTarget().setCursorPos(2, 3)
        getTarget().write(state.nowPlaying.name:sub(1, w - 3))
        setC(colors.lightGray, colors.black)
        getTarget().setCursorPos(2, 4)
        getTarget().write(state.nowPlaying.artist:sub(1, w - 3))
    else
        setC(colors.gray, colors.black)
        getTarget().setCursorPos(2, 3)
        getTarget().write("Not playing")
    end

    local sy = 5
    if state.isLoading then
        setC(colors.yellow, colors.black)
        getTarget().setCursorPos(2, sy)
        getTarget().write("Loading...")
    elseif state.isError then
        setC(colors.red, colors.black)
        getTarget().setCursorPos(2, sy)
        getTarget().write("Error: " .. state.errorMsg)
    elseif state.paused then
        setC(colors.yellow, colors.black)
        getTarget().setCursorPos(2, sy)
        getTarget().write("PAUSED")
    elseif state.playing then
        setC(colors.lime, colors.black)
        getTarget().setCursorPos(2, sy)
        getTarget().write("PLAYING")
    end

    if h > 12 then
        drawVis(2, 8, w - 4)
    end

    local py = h - 6
    setC(colors.white, colors.black)
    getTarget().setCursorPos(2, py - 1)
    getTarget().write("Progress:")
    drawProg(2, py, w - 16, state.progress)

    local vy = h - 4
    setC(colors.white, colors.black)
    getTarget().setCursorPos(2, vy - 1)
    getTarget().write("Volume:")
    drawVol(2, vy, w - 12)

    local by = h - 2
    local canP = state.nowPlaying ~= nil
    setC(canP and colors.white or colors.lightGray, colors.gray)
    getTarget().setCursorPos(2, by)
    getTarget().write(" << ")
    setC(canP and colors.white or colors.lightGray, colors.gray)
    getTarget().setCursorPos(7, by)
    if state.playing and not state.paused then
        getTarget().write(" || ")
    else
        getTarget().write(" > ")
    end
    setC(state.playing and colors.white or colors.lightGray, colors.gray)
    getTarget().setCursorPos(12, by)
    getTarget().write(" [] ")
    setC(canP and colors.white or colors.lightGray, colors.gray)
    getTarget().setCursorPos(17, by)
    getTarget().write(" >> ")

    local lt = state.looping == 0 and " Loop " or (state.looping == 1 and " LoopQ " or " Loop1 ")
    setC(state.looping ~= 0 and colors.white or colors.lightGray, state.looping ~= 0 and colors.blue or colors.gray)
    getTarget().setCursorPos(22, by)
    getTarget().write(lt)

    setC(state.shuffle and colors.white or colors.lightGray, state.shuffle and colors.purple or colors.gray)
    getTarget().setCursorPos(29, by)
    getTarget().write(" Rnd ")

    if state.sleepTimer > 0 then
        setC(colors.orange, colors.black)
        getTarget().setCursorPos(w - 10, by)
        local rem = math.max(0, state.sleepTimer - math.floor((os.clock() - (state.sleepStart or os.clock())) / 60))
        getTarget().write("Zzz " .. rem .. "m")
    end
    if state.diskEjectWarning then
        setC(colors.red, colors.black)
        getTarget().setCursorPos(w - 8, 3)
        getTarget().write("[DISK!]")
    end
end

local function drawScreen()
    if state.waitingInput then return end
    clearSc()
    drawTabs()
    if state.tab == 1 then
        drawLibrary()
    elseif state.tab == 2 then
        drawQueue()
    else
        drawPlayer()
    end
    if rednetEnabled then
        setC(colors.lime, colors.black)
        getTarget().setCursorPos(getW() - 3, 1)
        getTarget().write("NET")
    end
    state.needsRedraw = false
end

-- ===== INPUT =====
local function handleTabClick(x, y)
    if y ~= 1 then return false end
    local w = getW()
    local tw = math.floor(w / 3)
    for i = 1, 3 do
        if x >= (i - 1) * tw + 1 and x <= i * tw then
            state.tab = i
            state.needsRedraw = true
            return true
        end
    end
    return false
end

local function handleLibClick(x, y)
    local w, h = getW(), getH()
    if y >= 3 and y <= 5 and x >= 2 and x <= w - 1 then
        state.waitingInput = true
        state.needsRedraw = true
        return true
    end
    for i = 1, CONFIG.maxLibDisplay do
        local idx = state.libraryScroll + i
        if idx > #state.filteredLibrary then break end
        local ty = 7 + (i - 1) * 2
        if y == ty or y == ty + 1 then
            table.insert(state.queue, state.filteredLibrary[idx])
            state.needsRedraw = true
            return true
        end
    end
    if x == w and y == 7 and state.libraryScroll > 0 then
        state.libraryScroll = state.libraryScroll - 1
        state.needsRedraw = true
        return true
    end
    if x == w and y == h - 1 and state.libraryScroll + CONFIG.maxLibDisplay < #state.filteredLibrary then
        state.libraryScroll = state.libraryScroll + 1
        state.needsRedraw = true
        return true
    end
    return false
end

local function handleQueueClick(x, y)
    local w, h = getW(), getH()
    for i = 1, CONFIG.maxQueueDisplay do
        local idx = state.queueScroll + i
        if idx > #state.queue then break end
        local ty = 5 + (i - 1) * 2
        if y == ty or y == ty + 1 then
            table.remove(state.queue, idx)
            state.needsRedraw = true
            return true
        end
    end
    if x == w and y == 5 and state.queueScroll > 0 then
        state.queueScroll = state.queueScroll - 1
        state.needsRedraw = true
        return true
    end
    if x == w and y == h - 1 and state.queueScroll + CONFIG.maxQueueDisplay < #state.queue then
        state.queueScroll = state.queueScroll + 1
        state.needsRedraw = true
        return true
    end
    return false
end

local function handlePlayerClick(x, y)
    local w, h = getW(), getH()
    local by = h - 2
    if y == by then
        if x >= 2 and x <= 5 then
            prevTrack()
            state.needsRedraw = true
            return true
        end
        if x >= 7 and x <= 10 then
            if state.playing and not state.paused then
                state.paused = true
                for _, sp in ipairs(speakers) do sp.stop() end
                os.queueEvent("playback_stopped")
            else
                state.paused = false
                state.playing = true
                audioNeedsChunk = true
                if not state.nowPlaying and #state.queue > 0 then
                    skipTrack()
                end
            end
            state.needsRedraw = true
            return true
        end
        if x >= 12 and x <= 15 then
            stopPlayback()
            state.needsRedraw = true
            return true
        end
        if x >= 17 and x <= 20 then
            skipTrack()
            state.needsRedraw = true
            return true
        end
        if x >= 22 and x <= 27 then
            state.looping = (state.looping + 1) % 3
            state.needsRedraw = true
            return true
        end
        if x >= 29 and x <= 33 then
            state.shuffle = not state.shuffle
            if state.shuffle then
                for i = #state.queue, 2, -1 do
                    local j = math.random(i)
                    state.queue[i], state.queue[j] = state.queue[j], state.queue[i]
                end
            end
            state.needsRedraw = true
            return true
        end
    end
    if y == h - 6 and x >= 2 and x <= w - 15 then
        seekTrack((x - 2) / (w - 16))
        state.needsRedraw = true
        return true
    end
    if y == h - 4 and x >= 2 and x <= w - 11 then
        state.volume = ((x - 2) / (w - 12)) * 3
        state.volume = clamp(state.volume, 0, 3)
        state.needsRedraw = true
        return true
    end
    return false
end

local function handleMouse(event, btn, x, y)
    if handleTabClick(x, y) then return end
    if state.tab == 1 then
        handleLibClick(x, y)
    elseif state.tab == 2 then
        handleQueueClick(x, y)
    else
        handlePlayerClick(x, y)
    end
end

local function handleInput()
    local t = getTarget()
    local w = getW()
    setC(colors.black, colors.white)
    paintutils.drawFilledBox(2, 3, w - 1, 5, colors.white)
    t.setCursorPos(3, 4)
    t.setCursorBlink(true)

    local input = ""
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "key" then
            if p1 == keys.enter then
                state.searchQuery = input
                state.waitingInput = false
                scanLibrary()
                state.needsRedraw = true
                t.setCursorBlink(false)
                return
            elseif p1 == keys.escape then
                state.waitingInput = false
                state.needsRedraw = true
                t.setCursorBlink(false)
                return
            elseif p1 == keys.backspace and #input > 0 then
                input = input:sub(1, -2)
            end
        elseif ev == "char" then
            input = input .. p1
        elseif ev == "mouse_click" then
            state.waitingInput = false
            state.needsRedraw = true
            t.setCursorBlink(false)
            return
        end

        setC(colors.black, colors.white)
        paintutils.drawFilledBox(2, 3, w - 1, 5, colors.white)
        t.setCursorPos(3, 4)
        t.write(input)
        t.setCursorPos(3 + #input, 4)
    end
end

local function uiLoop()
    drawScreen()
    while true do
        if state.waitingInput then
            handleInput()
            if state.needsRedraw then drawScreen() end
        else
            parallel.waitForAny(
                function()
                    local _, b, x, y = os.pullEvent("mouse_click")
                    handleMouse("mouse_click", b, x, y)
                end,
                function()
                    local _, d, x, y = os.pullEvent("mouse_scroll")
                    if state.tab == 1 then
                        state.libraryScroll = clamp(state.libraryScroll + d, 0, math.max(0, #state.filteredLibrary - CONFIG.maxLibDisplay))
                    elseif state.tab == 2 then
                        state.queueScroll = clamp(state.queueScroll + d, 0, math.max(0, #state.queue - CONFIG.maxQueueDisplay))
                    end
                    state.needsRedraw = true
                end,
                function()
                    local _, s, x, y = os.pullEvent("monitor_touch")
                    if mainMonitor then
                        handleMouse("monitor_touch", 1, x, y)
                    end
                end,
                function()
                    local _, k = os.pullEvent("key")
                    -- R: force library rescan (useful after swapping floppies)
                    if k == keys.r then
                        scanLibrary()
                        state.needsRedraw = true
                    end
                end,
                function()
                    while true do
                        os.pullEvent("redraw_screen")
                        state.needsRedraw = true
                    end
                end,
                function()
                    while true do
                        sleep(CONFIG.updateInterval)
                        if state.playing then state.needsRedraw = true end
                        if rednetEnabled then broadcastStatus() end
                    end
                end
            )
            if state.needsRedraw then drawScreen() end
        end
    end
end

-- ===== INIT =====
local function init()
    speakers = wrapAll("speaker")
    if #speakers == 0 then
        error("No speakers found! Attach at least one speaker.", 0)
    end

    monitors = wrapAll("monitor")
    if #monitors > 0 then
        mainMonitor = monitors[1]
        mainMonitor.setTextScale(0.5)
        term.redirect(mainMonitor)
    end

    initRednet()
    scanLibrary()

    local t = getTarget()
    clearSc()
    setC(colors.lime, colors.black)
    t.setCursorPos(2, 2)
    t.write("Advanced Music Player v" .. VERSION)
    setC(colors.white, colors.black)
    t.setCursorPos(2, 4)
    t.write("Speakers: " .. #speakers)
    t.setCursorPos(2, 5)
    t.write("Disks: " .. #driveNames)
    t.setCursorPos(2, 6)
    t.write("Tracks: " .. #state.library)
    t.setCursorPos(2, 7)
    t.write("Rednet: " .. (rednetEnabled and "Enabled" or "Disabled"))
    t.setCursorPos(2, 9)
    t.write("Starting in 2 seconds...")
    sleep(2)
    state.lastDiskCheck = os.clock()
end

init()
parallel.waitForAny(uiLoop, audioLoop, rednetLoop)
