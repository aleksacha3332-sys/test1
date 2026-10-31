-- ============================================
-- CC Music Player (enhanced)
-- Features:
--   - Multi-disk tracks: one song split across floppy disks
--   - Built-in splitter: import a URL or local file straight to floppies
--   - URL streaming: play .dfpwm directly from a web link
--   - Albums, search, speaker selection, rednet control
-- Made by Mstr_Max
-- ============================================

local dfpwm = require("cc.audio.dfpwm")

local CONFIG = {
    partSize = 120 * 1024,    -- bytes per floppy part (floppy = 128 KiB)
    ioBuffer = 16 * 1024,     -- read/write block size
    reserveSpace = 4 * 1024,  -- keep free on each disk for meta files
    bytesPerSec = 6000,       -- dfpwm @ 48 kHz = 48000 bits/s
}

local modem = peripheral.find("modem")
if modem then
    rednet.open(peripheral.getName(modem))
    rednet.host("music_player", "main")
end

local function getAdjacentMonitor()
    for _, side in ipairs({"top", "bottom", "left", "right", "front", "back"}) do
        if peripheral.getType(side) == "monitor" then
            return peripheral.wrap(side)
        end
    end
    return nil
end

local monitor = getAdjacentMonitor()
if not monitor then
    print("Waiting for an adjacent monitor...")
end

math.randomseed(os.time())

local global_playlist = {}
local active_playlist = {}
local url_playlist = {}
local track_registry = {}
local current_song_idx = 1
local is_playing = false
local volume_level = 10
local skip_request = false
local seek_request = nil

local state = {
    tab = "all",
    album_view = nil,
    page_all = 1,
    page_alb_l = 1,
    page_alb_r = 1,
    mode = 1, -- LOP
    search = "",
    is_searching = false,
    is_adding_album = false,
    album_input = "",
    is_adding_url = false,
    url_input = "",
    is_splitting = false,
    split_input = "",
    edit_mode = false,
    selected_songs = {},
    selected_albums = {},
    albums = {},
    speakers = {}
}
local modes = {"SEQ", "LOP", "REP", "RND"}
local buttons = {}

local total_time_sec = 0
local current_time_sec = 0

local function getAlbumCount()
    local c = 0
    for _ in pairs(state.albums) do c = c + 1 end
    return c
end

local function loadSettings()
    if fs.exists("albums.dat") then
        local f = io.open("albums.dat", "r")
        if f then state.albums = textutils.unserialize(f:read("*a")) or {}; f:close() end
    end
    if fs.exists("speakers.dat") then
        local f = io.open("speakers.dat", "r")
        if f then state.speakers = textutils.unserialize(f:read("*a")) or {}; f:close() end
    end
    if fs.exists("urls.dat") then
        local f = io.open("urls.dat", "r")
        if f then url_playlist = textutils.unserialize(f:read("*a")) or {}; f:close() end
    end
end

local function saveAlbums()
    local f = io.open("albums.dat", "w")
    if f then f:write(textutils.serialize(state.albums)); f:close() end
end

local function saveSpeakers()
    local f = io.open("speakers.dat", "w")
    if f then f:write(textutils.serialize(state.speakers)); f:close() end
end

local function saveUrls()
    local f = io.open("urls.dat", "w")
    if f then f:write(textutils.serialize(url_playlist)); f:close() end
end

local function scanSpeakers()
    local current_spks = {peripheral.find("speaker")}
    local valid = {}
    for _, spk in ipairs(current_spks) do
        local name = peripheral.getName(spk)
        valid[name] = true
        if state.speakers[name] == nil then
            state.speakers[name] = true
        end
    end
    for name in pairs(state.speakers) do
        if not valid[name] then state.speakers[name] = nil end
    end
    saveSpeakers()
end

local function getActiveSpeakers()
    local spks = {}
    for name, enabled in pairs(state.speakers) do
        if enabled then
            local p = peripheral.wrap(name)
            if p then table.insert(spks, p) end
        end
    end
    return spks
end

-- ===== TRACK REGISTRY =====
-- Maps a track id (file path, "multi:Name" or a URL) to its source:
--   {files = {...}}        one or more local files (multi-disk parts)
--   {source = "url", url}  a web stream
local function getTrackName(id)
    local t = track_registry[id]
    if t and t.name then return t.name end
    local ok, nm = pcall(fs.getName, id)
    if ok and nm then return nm:gsub("%.dfpwm$", "") end
    return tostring(id)
end

local function scanDisks()
    global_playlist = {}
    track_registry = {}
    local partsReg = {}
    local partsMeta = {}

    for _, dir in ipairs(fs.list("/")) do
        if dir:match("^disk") and fs.isDir(dir) then
            for _, file in ipairs(fs.list(dir)) do
                local fp = fs.combine(dir, file)
                if file:match("%.dfpwm$") then
                    -- Regular single-disk track
                    track_registry[fp] = {files = {fp}, name = file:gsub("%.dfpwm$", "")}
                    table.insert(global_playlist, fp)
                else
                    -- Multi-disk part: "Song.dfpwm.part3"
                    local partIdx = file:match("%.dfpwm%.part(%d+)$")
                    if partIdx then
                        local base = file:gsub("%.part%d+$", "")
                        partsReg[base] = partsReg[base] or {}
                        partsReg[base][tonumber(partIdx)] = fp
                    elseif file:match("%.dfpwm%.meta$") then
                        -- Part metadata written by the built-in splitter
                        local base = file:gsub("%.meta$", "")
                        local f = io.open(fp, "r")
                        if f then
                            local okm, d = pcall(function() return textutils.unserializeJSON(f:read("*a")) end)
                            if okm and type(d) == "table" then partsMeta[base] = d end
                            f:close()
                        end
                    end
                end
            end
        end
    end

    -- Reassemble multi-disk tracks: visible only with ALL parts mounted
    for base, parts in pairs(partsReg) do
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
            local okz, sz = pcall(fs.getSize, p)
            totalSize = totalSize + ((okz and sz) or 0)
        end
        if complete and #files > 0 then
            local m = partsMeta[base] or {}
            local nm = m.name or base:gsub("%.dfpwm$", "")
            local id = "multi:" .. nm
            track_registry[id] = {files = files, name = nm, size = totalSize, parts = #files}
            table.insert(global_playlist, id)
        end
    end

    -- Web streams added by the user (persisted in urls.dat)
    for _, u in ipairs(url_playlist) do
        if not track_registry[u.url] then
            track_registry[u.url] = {source = "url", url = u.url, name = u.name}
            table.insert(global_playlist, u.url)
        end
    end

    if #active_playlist == 0 then
        for _, p in ipairs(global_playlist) do table.insert(active_playlist, p) end
    end
end

local function addUrlTrack(url)
    for _, u in ipairs(url_playlist) do
        if u.url == url then return end
    end
    local nm = url:match("([^/]+)%.dfpwm") or url:match("([^/]+)$") or "stream"
    nm = nm .. " (web)"
    table.insert(url_playlist, {url = url, name = nm})
    saveUrls()
    scanDisks()
end

-- ===== TRACK SOURCES =====
-- Every source exposes: read(n), seek(pos), close(), and maybe size.

local function makeFileSource(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local ok, sz = pcall(fs.getSize, path)
    return {
        size = (ok and sz) or 0,
        read = function(n) return h:read(n) end,
        seek = function(pos) h:seek("set", pos); return true end,
        close = function() h:close() end,
    }
end

-- Chains several part files on different disks into one logical stream
local function makeMultiSource(files)
    local st = {files = files, idx = 1, h = nil, sizes = {}, size = 0}
    for i, f in ipairs(files) do
        local ok, sz = pcall(fs.getSize, f)
        st.sizes[i] = (ok and sz) or 0
        st.size = st.size + st.sizes[i]
    end

    local function openPart(i)
        if st.h then pcall(function() st.h:close() end) end
        st.idx = i
        if not files[i] then st.h = nil return false end
        st.h = io.open(files[i], "rb")
        return st.h ~= nil
    end

    if not openPart(1) then return nil end

    st.read = function(n)
        local bufs = {}
        local total = 0
        while total < n do
            if not st.h then
                if total == 0 then return nil end
                break
            end
            local data = st.h:read(n - total)
            if data and #data > 0 then
                table.insert(bufs, data)
                total = total + #data
            else
                if not openPart(st.idx + 1) then
                    if total == 0 then return nil end
                    break
                end
            end
        end
        return table.concat(bufs)
    end

    st.seek = function(pos)
        local remaining = pos
        local i = 1
        while i < #files do
            if remaining < st.sizes[i] then break end
            remaining = remaining - st.sizes[i]
            i = i + 1
        end
        if not openPart(i) then return false end
        while remaining > 0 do
            local r = math.min(remaining, 4096)
            st.h:read(r)
            remaining = remaining - r
        end
        return true
    end

    st.close = function()
        if st.h then pcall(function() st.h:close() end) end
        st.h = nil
    end

    return st
end

-- Streams a URL over HTTP; seek uses Range requests when supported
local function makeHttpSource(url)
    if not http then return nil end
    local body = nil
    local size = nil

    local function openAt(pos)
        if body then pcall(function() body.close() end) end
        local headers = nil
        if pos > 0 then headers = {["Range"] = "bytes=" .. pos .. "-"} end
        local ok, resp = pcall(http.get, url, headers, true)
        if not ok or not resp then return false end
        local code = resp.getResponseCode()
        if pos == 0 then
            if code ~= 200 then resp.close() return false end
            local hdrs = resp.getResponseHeaders and resp.getResponseHeaders() or {}
            size = tonumber(hdrs["Content-Length"] or hdrs["content-length"]) or nil
            body = resp
            return true
        end
        if code == 206 then
            body = resp
            return true
        elseif code == 200 then
            -- Server ignored Range: drain the skipped prefix instead
            local remaining = pos
            while remaining > 0 do
                local data = resp.read(math.min(remaining, 4096))
                if not data then resp.close() return false end
                remaining = remaining - #data
            end
            body = resp
            return true
        end
        resp.close()
        return false
    end

    if not openAt(0) then return nil end

    return {
        size = size,
        read = function(n)
            if not body then return nil end
            return body.read(n)
        end,
        seek = function(pos) return openAt(pos) end,
        close = function()
            if body then pcall(function() body.close() end) end
            body = nil
        end,
    }
end

local function openTrackSource(track_id)
    local t = track_registry[track_id]
    if not t then
        if fs.exists(track_id) then
            t = {files = {track_id}}
        else
            return nil
        end
    end
    if t.source == "url" then
        return makeHttpSource(t.url)
    end
    if t.files and #t.files == 1 then
        return makeFileSource(t.files[1])
    end
    if t.files then
        return makeMultiSource(t.files)
    end
    return nil
end

local function formatTime(sec)
    return string.format("%02d:%02d", math.floor((sec or 0) / 60), (sec or 0) % 60)
end

local function addBtn(id, x, y, width, text, bg, fg)
    table.insert(buttons, {id=id, x1=x, x2=x+width-1, y=y, text=text, bg=bg, fg=fg})
end

local function drawProgressBar(w, y_pos)
    if not monitor then return end
    local bar_len = math.floor(w * 0.6)
    local time_str = formatTime(current_time_sec) .. "  "
    local total_str = "  " .. formatTime(total_time_sec)
    
    local total_width = #time_str + bar_len + #total_str
    local start_x = math.floor((w - total_width) / 2) + 1
    
    monitor.setCursorPos(start_x, y_pos)
    monitor.setTextColor(colors.white)
    monitor.setBackgroundColor(colors.black)
    monitor.write(time_str)
    
    local bar_start_x = start_x + #time_str
    addBtn("progress_bar", bar_start_x, y_pos, bar_len, "", colors.black, colors.white)
    
    local progress = 0
    if total_time_sec > 0 then progress = current_time_sec / total_time_sec end
    if progress > 1 then progress = 1 end
    local filled = math.floor(progress * bar_len)
    
    monitor.setCursorPos(bar_start_x, y_pos)
    monitor.setBackgroundColor(colors.lime)
    monitor.write(string.rep(" ", filled))
    monitor.setBackgroundColor(colors.gray)
    monitor.write(string.rep(" ", bar_len - filled))
    
    monitor.setBackgroundColor(colors.black)
    monitor.write(total_str)
end

local function getFilteredSongs()
    local list = {}
    local source = global_playlist
    if state.tab == "albums" then
        source = state.album_view and (state.albums[state.album_view] or {}) or {}
    end
    for _, p in ipairs(source) do
        local name = getTrackName(p)
        if track_registry[p] and track_registry[p].parts then
            name = name .. " [" .. track_registry[p].parts .. " disks]"
        end
        if state.search == "" or name:lower():find(state.search:lower(), 1, true) then
            table.insert(list, {path=p, name=name})
        end
    end
    return list
end

local function getAlbumList()
    local list = {}
    for k, _ in pairs(state.albums) do
        if state.search == "" or k:lower():find(state.search:lower(), 1, true) then
            table.insert(list, k)
        end
    end
    table.sort(list)
    return list
end

local function drawUI()
    if not monitor then return end
    monitor.setTextScale(0.5)
    local w, h = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    buttons = {}

    local sep_color = state.edit_mode and colors.yellow or colors.lime

    -- 1. Header
    local title = "=== CC Music Player ==="
    monitor.setCursorPos(math.floor((w - #title) / 2) + 1, 1)
    monitor.setTextColor(colors.cyan)
    monitor.write(title)
    local author = "Made by Mstr_Max"
    monitor.setCursorPos(w - #author, 1)
    monitor.setTextColor(colors.lightGray)
    monitor.write(author)

    -- 2. Stats
    local stats = "Tracks: " .. #global_playlist .. " | Albums: " .. getAlbumCount() .. " | Web: " .. #url_playlist
    monitor.setCursorPos(math.floor((w - #stats) / 2) + 1, 3)
    monitor.setTextColor(colors.yellow)
    monitor.write(stats)

    -- 3. Tabs
    local tabs = {
        {id="all", text=" ALL SONGS "},
        {id="albums", text=" ALBUMS "},
        {id="settings", text=" SETTINGS "}
    }
    local tabs_w = #tabs[1].text + 2 + #tabs[2].text + 2 + #tabs[3].text
    local tab_x = math.floor((w - tabs_w) / 2) + 1
    
    monitor.setCursorPos(1, 4)
    monitor.setTextColor(colors.gray)
    monitor.write(string.rep("-", w))
    
    monitor.setCursorPos(1, 6)
    monitor.write(string.rep("-", w))

    local current_x = tab_x
    for _, t in ipairs(tabs) do
        local is_active = (state.tab == t.id)
        local fg = is_active and colors.white or colors.gray
        addBtn("tab_"..t.id, current_x, 5, #t.text, t.text, colors.black, fg)
        
        if is_active then
            monitor.setCursorPos(current_x, 6)
            monitor.setTextColor(sep_color)
            monitor.write(string.rep("-", #t.text))
        end
        current_x = current_x + #t.text + 2
    end

    -- 4. Status and track name
    local status_color = is_playing and colors.lime or colors.yellow
    if not is_playing and total_time_sec == 0 then status_color = colors.red end
    local status_text = is_playing and "PLAYING" or (total_time_sec == 0 and "STOPPED" or "PAUSED")
    
    local song_name = "None"
    if #active_playlist > 0 and current_song_idx <= #active_playlist then
        song_name = getTrackName(active_playlist[current_song_idx])
    end
    
    local info_str = "Status: " .. status_text .. "   |   Track: " .. song_name
    local info_x = math.floor((w - #info_str) / 2) + 1
    monitor.setCursorPos(info_x, 8)
    monitor.setTextColor(colors.lightGray)
    monitor.write("Status: ")
    monitor.setTextColor(status_color)
    monitor.write(status_text)
    monitor.setTextColor(colors.lightGray)
    monitor.write("   |   Track: ")
    monitor.setTextColor(colors.white)
    monitor.write(song_name)

    -- 5. Progress bar
    drawProgressBar(w, 10)

    -- 6. Controls
    local play_bg = is_playing and colors.lime or colors.yellow
    local ctrl_1 = "[ << ]  [ >/|| ]  [ [] ]  [ >> ]    [ MODE: " .. modes[state.mode+1] .. " ]    "
    local ctrl_2 = "[-] " .. (volume_level * 10) .. "% [+]    "
    local ctrl_w = #ctrl_1 + #ctrl_2 - 4
    local cx = math.floor((w - ctrl_w) / 2) + 1

    addBtn("prev", cx, 12, 6, "[ << ]", colors.gray, colors.white); cx = cx + 8
    addBtn("play", cx, 12, 8, "[ >/|| ]", play_bg, colors.black); cx = cx + 10
    addBtn("stop", cx, 12, 6, "[ [] ]", colors.red, colors.white); cx = cx + 8
    addBtn("next", cx, 12, 6, "[ >> ]", colors.gray, colors.white); cx = cx + 10
    addBtn("mode", cx, 12, 13, "[ MODE: " .. modes[state.mode+1] .. " ]", colors.blue, colors.white); cx = cx + 17
    addBtn("vol_down", cx, 12, 3, "[-]", colors.orange, colors.white); cx = cx + 4
    
    monitor.setCursorPos(cx, 12)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.write((volume_level * 10) .. "%")
    cx = cx + #(tostring(volume_level * 10) .. "%") + 1
    addBtn("vol_up", cx, 12, 3, "[+]", colors.orange, colors.white)

    -- 7. Search and edit
    local s_text = "Search: "
    monitor.setCursorPos(2, 14)
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.lightGray)
    monitor.write(s_text)
    
    local sb_x = 2 + #s_text
    local sb_w = math.floor(w * 0.3)
    local disp = state.search
    if state.is_searching then disp = disp .. "_" end
    
    monitor.setBackgroundColor(colors.gray)
    monitor.setTextColor(state.is_searching and colors.lime or colors.white)
    monitor.setCursorPos(sb_x, 14)
    
    local d_text = " " .. disp
    d_text = d_text .. string.rep(" ", math.max(0, sb_w - #d_text))
    monitor.write(d_text)
    addBtn("search_box", sb_x, 14, sb_w, "", colors.gray, colors.white)
    
    monitor.setBackgroundColor(colors.black)
    addBtn("search_clear", sb_x + sb_w + 1, 14, 5, " [X] ", colors.red, colors.white)

    if state.tab ~= "settings" then
        local edit_text = state.edit_mode and "[ CANCEL EDIT ]" or "[ EDIT: OFF ]"
        local ex = w - #edit_text - 1
        local edit_bg = state.edit_mode and colors.yellow or colors.gray
        local edit_fg = state.edit_mode and colors.black or colors.white
        addBtn("edit", ex, 14, #edit_text, edit_text, edit_bg, edit_fg)

        if state.edit_mode then
            if state.tab == "all" and #state.selected_songs > 0 then
                local add_text = "[ ADD TO ALBUM (" .. #state.selected_songs .. ") ]"
                local ax = ex - #add_text - 2
                addBtn("add_to_alb", ax, 14, #add_text, add_text, colors.lime, colors.black)
            elseif state.tab == "albums" then
                if not state.album_view and #state.selected_albums > 0 then
                    local del_text = "[ DELETE ALBUMS (" .. #state.selected_albums .. ") ]"
                    local ax = ex - #del_text - 2
                    addBtn("del_alb", ax, 14, #del_text, del_text, colors.red, colors.white)
                elseif state.album_view and #state.selected_songs > 0 then
                    local rem_text = "[ REMOVE TRACKS (" .. #state.selected_songs .. ") ]"
                    local ax = ex - #rem_text - 2
                    addBtn("rem_tracks", ax, 14, #rem_text, rem_text, colors.red, colors.white)
                end
            end
        end
    end

    -- Separator line 15
    monitor.setCursorPos(1, 15)
    monitor.setTextColor(sep_color)
    monitor.write(string.rep("-", w))

    for _, b in ipairs(buttons) do
        if b.id ~= "progress_bar" and b.id ~= "search_box" then
            monitor.setCursorPos(b.x1, b.y)
            monitor.setBackgroundColor(b.bg)
            monitor.setTextColor(b.fg)
            monitor.write(b.text)
        end
    end

    if state.tab == "settings" then
        addBtn("rescan", 2, 17, 18, " [ RESCAN DISKS ] ", colors.blue, colors.white)
        addBtn("clear_alb", 2, 19, 22, " [ CLEAR ALL ALBUMS ] ", colors.red, colors.white)
        addBtn("split_disks", 2, 21, 24, " [ SPLIT TO DISKS ] ", colors.purple, colors.white)
        addBtn("add_url", 2, 23, 24, " [ ADD URL STREAM ] ", colors.lime, colors.black)
        
        local spk_x = math.floor(w * 0.4)
        monitor.setCursorPos(spk_x, 17)
        monitor.setTextColor(colors.yellow)
        monitor.write("--- ACTIVE SPEAKERS ---")
        
        local spk_names = {}
        for name in pairs(state.speakers) do table.insert(spk_names, name) end
        table.sort(spk_names)
        
        local row = 18
        for _, name in ipairs(spk_names) do
            local enabled = state.speakers[name]
            local text = (enabled and "[X] " or "[ ] ") .. name
            local fg = enabled and colors.lime or colors.gray
            addBtn("spk_" .. name, spk_x, row, #text, text, colors.black, fg)
            row = row + 1
        end

        for _, b in ipairs(buttons) do
            if b.id == "rescan" or b.id == "clear_alb" or b.id == "split_disks"
               or b.id == "add_url" or b.id:match("^spk_") then
                monitor.setCursorPos(b.x1, b.y)
                monitor.setBackgroundColor(b.bg)
                monitor.setTextColor(b.fg)
                monitor.write(b.text)
            end
        end
        return
    end

    -- 8. Lists
    local list_start_y = 16
    local items_per_col = h - list_start_y - 1

    if state.tab == "albums" then
        local left_w = math.floor(w * 0.35)
        local right_w = w - left_w - 1
        
        for y = list_start_y, h - 1 do
            monitor.setCursorPos(left_w + 1, y)
            monitor.setTextColor(sep_color)
            monitor.write("|")
        end
        
        -- Left window
        local album_list = getAlbumList()
        local max_p_l = math.ceil(#album_list / items_per_col)
        if max_p_l < 1 then max_p_l = 1 end
        if state.page_alb_l > max_p_l then state.page_alb_l = max_p_l end
        
        local start_idx_l = (state.page_alb_l - 1) * items_per_col
        for i = 1, items_per_col do
            local idx = start_idx_l + i
            if idx > #album_list then break end
            local a_name = album_list[idx]
            
            monitor.setCursorPos(2, list_start_y + i - 1)
            local is_curr = (state.album_view == a_name)
            local is_sel = false
            for _, a in ipairs(state.selected_albums) do if a == a_name then is_sel = true break end end

            if state.edit_mode and not state.album_view then
                monitor.setBackgroundColor(colors.black)
                monitor.setTextColor(is_sel and colors.red or colors.white)
            else
                monitor.setBackgroundColor(is_curr and colors.gray or colors.black)
                monitor.setTextColor(is_curr and colors.white or colors.lightGray)
            end
            
            local text = (state.edit_mode and not state.album_view) and ((is_sel and "[X] " or "[ ] ") .. a_name) or a_name
            local max_len = left_w - 2
            if #text > max_len then text = text:sub(1, max_len - 2)..".." end
            text = text .. string.rep(" ", max_len - #text)
            monitor.write(text)
            addBtn("sel_alb_" .. idx, 2, list_start_y + i - 1, #text, "", colors.black, colors.white)
        end

        local pag_l = state.page_alb_l .. "/" .. max_p_l
        local px_l = math.floor(left_w / 2) - 1
        addBtn("palb_prev", 2, h, 3, "[<]", colors.gray, colors.white)
        monitor.setCursorPos(px_l, h)
        monitor.setTextColor(colors.yellow)
        monitor.write(pag_l)
        addBtn("palb_next", left_w - 3, h, 3, "[>]", colors.gray, colors.white)

        -- Right window
        local song_list = getFilteredSongs()
        local max_p_r = math.ceil(#song_list / items_per_col)
        if max_p_r < 1 then max_p_r = 1 end
        if state.page_alb_r > max_p_r then state.page_alb_r = max_p_r end

        local start_idx_r = (state.page_alb_r - 1) * items_per_col
        for i = 1, items_per_col do
            local idx = start_idx_r + i
            if idx > #song_list then break end
            local item = song_list[idx]
            local row_y = list_start_y + i - 1
            local list_x = left_w + 3
            
            monitor.setCursorPos(list_x, row_y)
            local is_curr = (active_playlist[current_song_idx] == item.path)
            local is_sel = false
            for _, p in ipairs(state.selected_songs) do if p == item.path then is_sel = true break end end

            if state.edit_mode and state.album_view then
                monitor.setBackgroundColor(colors.black)
                monitor.setTextColor(is_sel and colors.orange or colors.white)
            else
                monitor.setBackgroundColor(is_curr and colors.gray or colors.black)
                monitor.setTextColor(is_curr and colors.lime or colors.white)
            end
            
            local text = (state.edit_mode and state.album_view) and ((is_sel and "[X] " or "[ ] ") .. item.name) or (string.format("%02d. ", idx) .. item.name)
            local max_len = right_w - 4
            if #text > max_len then text = text:sub(1, max_len - 2)..".." end
            text = text .. string.rep(" ", max_len - #text)
            monitor.write(text)
            addBtn("play_song_" .. idx, list_x, row_y, #text, "", colors.black, colors.white)
        end

        if state.album_view then
            local pag_r = "PAGE " .. state.page_alb_r .. " / " .. max_p_r
            local px_r = left_w + 2 + math.floor((right_w - #pag_r) / 2)
            addBtn("ptrack_prev", left_w + 3, h, 3, "[<]", colors.gray, colors.white)
            monitor.setCursorPos(px_r, h)
            monitor.setTextColor(colors.yellow)
            monitor.write(pag_r)
            addBtn("ptrack_next", w - 4, h, 3, "[>]", colors.gray, colors.white)
        end

        for _, b in ipairs(buttons) do
            if b.id:match("^palb_") or b.id:match("^ptrack_") then
                monitor.setCursorPos(b.x1, b.y)
                monitor.setBackgroundColor(b.bg)
                monitor.setTextColor(b.fg)
                monitor.write(b.text)
            end
        end

    else
        -- ALL SONGS tab
        local song_list = getFilteredSongs()
        local items_per_page = items_per_col * 2
        local max_page = math.ceil(#song_list / items_per_page)
        if max_page < 1 then max_page = 1 end
        if state.page_all > max_page then state.page_all = max_page end
        
        local mid_x = math.floor(w/2) + 1
        for y = list_start_y, h - 1 do
            monitor.setCursorPos(mid_x, y)
            monitor.setTextColor(sep_color)
            monitor.write("|")
        end

        local start_idx = (state.page_all - 1) * items_per_page
        for i = 1, items_per_page do
            local idx = start_idx + i
            if idx > #song_list then break end
            local item = song_list[idx]
            
            local col = (i - 1) >= items_per_col and 1 or 0
            local row = (i - 1) % items_per_col
            local col_x = col == 0 and 2 or (mid_x + 2)
            local row_y = list_start_y + row
            local col_w = col == 0 and (mid_x - 3) or (w - mid_x - 2)
            
            monitor.setCursorPos(col_x, row_y)
            
            local is_curr = (active_playlist[current_song_idx] == item.path)
            local is_sel = false
            for _, p in ipairs(state.selected_songs) do if p == item.path then is_sel = true break end end

            if state.edit_mode then
                monitor.setBackgroundColor(colors.black)
                monitor.setTextColor(is_sel and colors.cyan or colors.white)
            else
                monitor.setBackgroundColor(is_curr and colors.gray or colors.black)
                monitor.setTextColor(is_curr and colors.lime or colors.white)
            end
            
            local text = state.edit_mode and ((is_sel and "[X] " or "[ ] ") .. item.name) or (string.format("%02d. ", idx) .. item.name)
            if #text > col_w then text = text:sub(1, col_w - 2)..".." end
            text = text .. string.rep(" ", col_w - #text)
            monitor.write(text)
            addBtn("play_song_" .. idx, col_x, row_y, #text, "", colors.black, colors.white)
        end

        local pag_text = "PAGE " .. state.page_all .. " / " .. max_page
        local pag_x = math.floor((w - #pag_text) / 2) + 1
        addBtn("pall_prev", pag_x - 5, h, 3, "[<]", colors.gray, colors.white)
        monitor.setCursorPos(pag_x, h)
        monitor.setTextColor(colors.yellow)
        monitor.write(pag_text)
        addBtn("pall_next", pag_x + #pag_text + 2, h, 3, "[>]", colors.gray, colors.white)

        for _, b in ipairs(buttons) do
            if b.id:match("^pall_") then
                monitor.setCursorPos(b.x1, b.y)
                monitor.setBackgroundColor(b.bg)
                monitor.setTextColor(b.fg)
                monitor.write(b.text)
            end
        end
    end
    monitor.setBackgroundColor(colors.black)
end

local function stopSpeakers()
    for _, spk in ipairs(getActiveSpeakers()) do
        pcall(function() spk.stop() end)
    end
    os.queueEvent("speaker_audio_empty")
end

local function playChunk(buffer)
    local cc_vol = (volume_level / 10) * 3.0 
    local to_play = getActiveSpeakers()

    if #to_play == 0 then
        local t_id = os.startTimer(4096 / 6000)
        while true do
            if not is_playing or skip_request or seek_request then
                os.cancelTimer(t_id)
                return
            end
            local ev, p1 = os.pullEvent()
            if ev == "timer" and p1 == t_id then break end
            if ev == "play_status_changed" or ev == "speaker_audio_empty" then
                os.cancelTimer(t_id)
                return
            end
        end
        return
    end

    while #to_play > 0 do
        if not is_playing or skip_request or seek_request then return end
        local remaining = {}
        for _, spk in ipairs(to_play) do
            local success, accepted = pcall(function() return spk.playAudio(buffer, cc_vol) end)
            if not success or not accepted then table.insert(remaining, spk) end
        end
        to_play = remaining
        if #to_play > 0 then os.pullEvent("speaker_audio_empty") end
    end
end

local function audioLoop()
    while true do
        if #active_playlist > 0 then
            local track_id = active_playlist[current_song_idx]
            local decoder = dfpwm.make_decoder()
            local src = openTrackSource(track_id)
            
            if src then
                local total_bytes = src.size or 0
                total_time_sec = math.floor(total_bytes / CONFIG.bytesPerSec)
                current_time_sec = 0
                local bytes_read = 0
                local header_offset = 0
                
                -- Skip WAV/MP3 style headers if present
                local success_hdr, header = pcall(function() return src.read(100) end)
                if success_hdr and header and #header >= 12 then
                    if header:sub(1,4) == "RIFF" and header:sub(9,12) == "WAVE" then
                        local data_idx = header:find("data")
                        header_offset = data_idx and (data_idx + 7) or 44
                    elseif header:sub(1,3) == "ID3" then
                        local b1, b2, b3, b4 = header:byte(7, 10)
                        local sz = (b1 * 2097152) + (b2 * 16384) + (b3 * 128) + b4
                        header_offset = 10 + sz
                    end
                end
                pcall(function() src.seek(header_offset) end)

                local success_trash, trash = pcall(function() return src.read(512) end)
                if success_trash and trash then decoder(trash) end
                header_offset = header_offset + 512
                if monitor then drawProgressBar(monitor.getSize(), 10) end

                while not skip_request do
                    if seek_request then
                        local byte_offset = seek_request * CONFIG.bytesPerSec
                        local ok_seek = pcall(function() return src.seek(header_offset + byte_offset) end)
                        if ok_seek then
                            current_time_sec = seek_request
                            bytes_read = byte_offset
                            decoder = dfpwm.make_decoder()
                        end
                        seek_request = nil
                        if monitor then drawProgressBar(monitor.getSize(), 10) end
                    end

                    if is_playing then
                        local success_read, chunk = pcall(function() return src.read(4 * 1024) end)
                        if not success_read or not chunk then break end
                        
                        bytes_read = bytes_read + #chunk
                        local new_time = math.floor(bytes_read / CONFIG.bytesPerSec)
                        if new_time ~= current_time_sec then
                            current_time_sec = new_time
                            if monitor then drawProgressBar(monitor.getSize(), 10) end
                        end
                        playChunk(decoder(chunk))
                    else
                        os.pullEvent("play_status_changed")
                    end
                end
                pcall(function() src.close() end)
            end
            
            if not skip_request then
                if state.mode == 0 then
                    current_song_idx = current_song_idx + 1
                    if current_song_idx > #active_playlist then 
                        current_song_idx = 1 
                        is_playing = false
                        stopSpeakers()
                        os.queueEvent("play_status_changed")
                    end
                elseif state.mode == 1 then
                    current_song_idx = current_song_idx + 1
                    if current_song_idx > #active_playlist then current_song_idx = 1 end
                elseif state.mode == 2 then
                    -- REP
                elseif state.mode == 3 then
                    if #active_playlist > 1 then
                        local n = current_song_idx
                        while n == current_song_idx do n = math.random(1, #active_playlist) end
                        current_song_idx = n
                    end
                end
            end
            skip_request = false
            current_time_sec = 0
            os.sleep(0.1)
            drawUI()
        else
            os.sleep(0.5)
        end
    end
end

-- ===== SPLIT TO FLOPPIES =====
-- Splits a URL or local .dfpwm file into parts across mounted floppies.
-- Parts are named "Song.dfpwm.partN" and get a ".meta" descriptor;
-- the player reassembles them automatically on the next scan.
local function splitToFloppies(inputPath)
    local isUrl = inputPath:match("^https?://") ~= nil

    -- Pause playback while writing to the disks
    is_playing = false
    stopSpeakers()

    print("Source: " .. inputPath)

    local src
    if isUrl then
        if not http then
            print("Error: HTTP API is disabled.")
            return
        end
        local ok, resp = pcall(http.get, inputPath, nil, true)
        if not ok or not resp then
            print("Error: download failed.")
            return
        end
        if resp.getResponseCode() ~= 200 then
            print("Error: server returned HTTP " .. tostring(resp.getResponseCode()))
            resp.close()
            return
        end
        src = resp
    else
        if not fs.exists(inputPath) then
            print("Error: file not found: " .. inputPath)
            return
        end
        src = io.open(inputPath, "rb")
        if not src then
            print("Error: cannot open file.")
            return
        end
    end

    local function readSrc(n)
        if isUrl then return src.read(n) end
        return src:read(n)
    end
    local function closeSrc()
        if isUrl then pcall(function() src.close() end)
        else pcall(function() src:close() end) end
    end

    local trackName = inputPath:match("([^/]+)%.dfpwm") or "track"

    local function scanDrivesFree()
        local out = {}
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "drive" then
                local mp = disk.getMountPath(name)
                if mp then
                    local okf, free = pcall(fs.getFreeSpace, mp)
                    table.insert(out, {name = name, mount = mp, free = (okf and free) or 0})
                end
            end
        end
        return out
    end

    local function pickDrive(drives, minBytes)
        for _, d in ipairs(drives) do
            if d.free >= minBytes + CONFIG.reserveSpace then return d end
        end
        return nil
    end

    local drives = scanDrivesFree()
    local parts = {}
    local partIdx = 0
    local totalBytes = 0

    while true do
        local d = pickDrive(drives, CONFIG.partSize)
        local writeSize = CONFIG.partSize
        if not d then
            d = pickDrive(drives, 1)
            if d then writeSize = d.free - CONFIG.reserveSpace end
        end

        if not d then
            print("")
            print("Out of disk space!")
            print("Insert more floppies, then press Enter to continue.")
            print("Written so far: " .. partIdx .. " parts, " .. totalBytes .. " bytes")
            read()
            drives = scanDrivesFree()
        else
            local partName = trackName .. ".dfpwm.part" .. partIdx
            local out = fs.open(fs.combine(d.mount, partName), "wb")
            if not out then
                print("Error: cannot write to " .. d.mount)
                closeSrc()
                return
            end

            local written = 0
            while written < writeSize do
                local want = math.min(CONFIG.ioBuffer, writeSize - written)
                local data = readSrc(want)
                if not data then break end
                out.write(data)
                written = written + #data
                totalBytes = totalBytes + #data
            end
            out.close()

            d.free = d.free - written
            table.insert(parts, {mount = d.mount, drive = d.name, name = partName})
            print(string.format("Part %d -> %s (%d bytes)", partIdx, d.mount, written))
            partIdx = partIdx + 1

            if written < writeSize then break end -- end of input
        end
    end

    closeSrc()

    -- Write meta descriptor on every disk and label the floppies
    local totalParts = #parts
    local duration = math.floor(totalBytes * 8 / 48000)
    for i, p in ipairs(parts) do
        local meta = {
            name = trackName,
            size = totalBytes,
            parts = totalParts,
            index = i - 1,
            duration = duration,
        }
        local mf = fs.open(fs.combine(p.mount, p.name .. ".meta"), "w")
        if mf then
            mf.write(textutils.serializeJSON(meta))
            mf.close()
        end
        pcall(disk.setLabel, p.drive, trackName .. " [" .. i .. "/" .. totalParts .. "]")
    end

    print("")
    print("Done! " .. totalParts .. " parts, " .. totalBytes .. " bytes, ~" .. duration .. "s")
    print("The track appears once ALL parts are mounted.")
end

local function controlLoop()
    loadSettings()
    scanSpeakers()
    scanDisks()
    drawUI()
    
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        local clicked_id = nil
        
        if event == "peripheral" or event == "peripheral_detach" then
            scanSpeakers()
            monitor = getAdjacentMonitor()
            if monitor then drawUI() end
        elseif event == "char" then
            if state.is_searching then
                state.search = state.search .. p1
                state.page_all = 1; state.page_alb_r = 1; state.page_alb_l = 1
                drawUI()
            elseif state.is_adding_album then
                state.album_input = state.album_input .. p1
                term.write(p1)
            elseif state.is_adding_url then
                state.url_input = state.url_input .. p1
                term.write(p1)
            elseif state.is_splitting then
                state.split_input = state.split_input .. p1
                term.write(p1)
            end
        elseif event == "key" then
            if state.is_searching then
                if p1 == keys.backspace and #state.search > 0 then
                    state.search = state.search:sub(1, -2)
                    state.page_all = 1; state.page_alb_r = 1; state.page_alb_l = 1
                    drawUI()
                elseif p1 == keys.enter then
                    state.is_searching = false
                    drawUI()
                end
            elseif state.is_adding_album then
                if p1 == keys.backspace and #state.album_input > 0 then
                    state.album_input = state.album_input:sub(1, -2)
                    local x, y = term.getCursorPos()
                    term.setCursorPos(x-1, y)
                    term.write(" ")
                    term.setCursorPos(x-1, y)
                elseif p1 == keys.enter then
                    state.is_adding_album = false
                    local alb_name = state.album_input
                    if alb_name ~= "" then
                        if not state.albums[alb_name] then state.albums[alb_name] = {} end
                        local added_count = 0
                        for _, p in ipairs(state.selected_songs) do
                            local exists = false
                            for _, ap in ipairs(state.albums[alb_name]) do if ap == p then exists = true break end end
                            if not exists then table.insert(state.albums[alb_name], p); added_count = added_count + 1 end
                        end
                        saveAlbums()
                        print("\nSuccess! Added " .. added_count .. " tracks to " .. alb_name)
                        os.sleep(1.5)
                    end
                    state.selected_songs = {}
                    state.edit_mode = false
                    drawUI()
                end
            elseif state.is_adding_url then
                if p1 == keys.backspace and #state.url_input > 0 then
                    state.url_input = state.url_input:sub(1, -2)
                    local x, y = term.getCursorPos()
                    term.setCursorPos(x-1, y)
                    term.write(" ")
                    term.setCursorPos(x-1, y)
                elseif p1 == keys.enter then
                    state.is_adding_url = false
                    local url = state.url_input
                    if url:match("^https?://") then
                        addUrlTrack(url)
                        print("\nAdded web stream.")
                    else
                        print("\nInvalid URL (must start with http:// or https://)")
                    end
                    os.sleep(1.5)
                    drawUI()
                end
            elseif state.is_splitting then
                if p1 == keys.backspace and #state.split_input > 0 then
                    state.split_input = state.split_input:sub(1, -2)
                    local x, y = term.getCursorPos()
                    term.setCursorPos(x-1, y)
                    term.write(" ")
                    term.setCursorPos(x-1, y)
                elseif p1 == keys.enter then
                    state.is_splitting = false
                    local input = state.split_input
                    term.clear()
                    term.setCursorPos(1, 1)
                    if input ~= "" then
                        splitToFloppies(input)
                        print("")
                        print("Press Enter to return to the player...")
                        read()
                    end
                    scanDisks()
                    drawUI()
                end
            end
        end

        if event == "monitor_touch" then
            if state.is_adding_url or state.is_splitting then
                -- Terminal prompt in progress, monitor input is ignored
            elseif monitor and p1 ~= peripheral.getName(monitor) then
                -- Ignore other monitors on the network
            else
                local x, y = p2, p3
                for _, btn in ipairs(buttons) do
                    if y == btn.y and x >= btn.x1 and x <= btn.x2 then
                        clicked_id = btn.id
                        if clicked_id == "progress_bar" then
                            local bar_x = btn.x1
                            local bar_width = btn.x2 - btn.x1 + 1
                            local percentage = (x - bar_x) / bar_width
                            if percentage < 0 then percentage = 0 end
                            if percentage > 1 then percentage = 1 end
                            seek_request = math.floor(total_time_sec * percentage)
                            os.queueEvent("play_status_changed")
                        end
                        break
                    end
                end
                
                if clicked_id ~= "search_box" and clicked_id ~= "search_clear" and state.is_searching then
                    state.is_searching = false
                    drawUI()
                end

                if clicked_id then
                    if clicked_id:sub(1, 4) == "tab_" then
                        state.tab = clicked_id:sub(5)
                        state.edit_mode = false
                        state.selected_songs = {}
                        state.selected_albums = {}
                        state.is_adding_album = false
                    elseif clicked_id == "play" then
                        is_playing = not is_playing
                        if not is_playing then stopSpeakers() end
                        os.queueEvent("play_status_changed")
                    elseif clicked_id == "stop" then
                        is_playing = false
                        seek_request = 0
                        stopSpeakers()
                        os.queueEvent("play_status_changed")
                    elseif clicked_id == "prev" then
                        current_song_idx = current_song_idx - 1
                        if current_song_idx < 1 then current_song_idx = #active_playlist end
                        is_playing = true
                        skip_request = true
                        stopSpeakers()
                        os.queueEvent("play_status_changed")
                    elseif clicked_id == "next" then
                        current_song_idx = current_song_idx + 1
                        if current_song_idx > #active_playlist then current_song_idx = 1 end
                        is_playing = true
                        skip_request = true
                        stopSpeakers()
                        os.queueEvent("play_status_changed")
                    elseif clicked_id == "mode" then
                        state.mode = (state.mode + 1) % 4
                    elseif clicked_id == "search_box" then
                        if not state.is_adding_album then state.is_searching = true end
                    elseif clicked_id == "search_clear" then
                        state.search = ""
                        state.page_all = 1; state.page_alb_r = 1; state.page_alb_l = 1
                    elseif clicked_id == "edit" then
                        state.edit_mode = not state.edit_mode
                        if not state.edit_mode then 
                            state.selected_songs = {}
                            state.selected_albums = {}
                            if state.is_adding_album then
                                state.is_adding_album = false
                                print("\n[ Cancelled ]")
                            end
                        end
                    elseif clicked_id == "add_to_alb" then
                        if #state.selected_songs > 0 then
                            state.is_adding_album = true
                            state.album_input = ""
                            term.clear()
                            term.setCursorPos(1,1)
                            print("=== ADD TO ALBUM ===")
                            print("Selected " .. #state.selected_songs .. " tracks.")
                            print("Type new or existing Album name:")
                            print("(Or click CANCEL EDIT on monitor)")
                            term.write("> ")
                        end
                    elseif clicked_id == "del_alb" then
                        for _, a in ipairs(state.selected_albums) do state.albums[a] = nil end
                        saveAlbums()
                        state.selected_albums = {}
                        state.edit_mode = false
                    elseif clicked_id == "rem_tracks" then
                        local alb = state.albums[state.album_view]
                        if alb then
                            for _, sel_path in ipairs(state.selected_songs) do
                                for i = #alb, 1, -1 do
                                    if alb[i] == sel_path then table.remove(alb, i) end
                                end
                            end
                            saveAlbums()
                        end
                        state.selected_songs = {}
                        state.edit_mode = false
                    elseif clicked_id == "pall_prev" then state.page_all = math.max(1, state.page_all - 1)
                    elseif clicked_id == "pall_next" then state.page_all = state.page_all + 1
                    elseif clicked_id == "palb_prev" then state.page_alb_l = math.max(1, state.page_alb_l - 1)
                    elseif clicked_id == "palb_next" then state.page_alb_l = state.page_alb_l + 1
                    elseif clicked_id == "ptrack_prev" then state.page_alb_r = math.max(1, state.page_alb_r - 1)
                    elseif clicked_id == "ptrack_next" then state.page_alb_r = state.page_alb_r + 1
                    elseif clicked_id == "vol_up" then volume_level = math.min(10, volume_level + 1)
                    elseif clicked_id == "vol_down" then volume_level = math.max(1, volume_level - 1)
                    elseif clicked_id == "rescan" then scanDisks()
                    elseif clicked_id == "clear_alb" then state.albums = {}; saveAlbums()
                    elseif clicked_id == "add_url" then
                        state.is_adding_url = true
                        state.url_input = ""
                        term.clear()
                        term.setCursorPos(1,1)
                        print("=== ADD URL STREAM ===")
                        print("Enter direct URL to a .dfpwm file:")
                        print("(Seek needs Range support on the server)")
                        term.write("> ")
                    elseif clicked_id == "split_disks" then
                        state.is_splitting = true
                        state.split_input = ""
                        term.clear()
                        term.setCursorPos(1,1)
                        print("=== SPLIT TRACK TO FLOPPY DISKS ===")
                        print("Enter a URL or a local .dfpwm file path:")
                        print("(Playback pauses while writing)")
                        term.write("> ")
                    elseif clicked_id:sub(1, 4) == "spk_" then
                        local spk_name = clicked_id:sub(5)
                        state.speakers[spk_name] = not state.speakers[spk_name]
                        saveSpeakers()
                        if not state.speakers[spk_name] then
                            local p = peripheral.wrap(spk_name)
                            if p then pcall(function() p.stop() end) end
                        end
                    elseif clicked_id:sub(1, 8) == "sel_alb_" then
                        local idx = tonumber(clicked_id:sub(9))
                        local a_name = getAlbumList()[idx]
                        if a_name then
                            if state.edit_mode and not state.album_view then
                                local found = false
                                for i, name in ipairs(state.selected_albums) do
                                    if name == a_name then table.remove(state.selected_albums, i); found = true; break end
                                end
                                if not found then table.insert(state.selected_albums, a_name) end
                            else
                                if state.album_view == a_name then
                                    state.album_view = nil
                                else
                                    state.album_view = a_name
                                    state.page_alb_r = 1
                                end
                            end
                        end
                    elseif clicked_id:sub(1, 10) == "play_song_" then
                        local idx = tonumber(clicked_id:sub(11))
                        local item = getFilteredSongs()[idx]
                        if item then
                            if state.edit_mode then
                                local found = false
                                for i, p in ipairs(state.selected_songs) do
                                    if p == item.path then table.remove(state.selected_songs, i); found = true; break end
                                end
                                if not found then table.insert(state.selected_songs, item.path) end
                            else
                                active_playlist = {}
                                for _, v in ipairs(getFilteredSongs()) do table.insert(active_playlist, v.path) end
                                for i, p in ipairs(active_playlist) do
                                    if p == item.path then current_song_idx = i break end
                                end
                                is_playing = true
                                skip_request = true
                                stopSpeakers()
                                os.queueEvent("play_status_changed")
                            end
                        end
                    end
                    if monitor then drawUI() end
                end
            end
            
        elseif event == "rednet_message" then
            if p3 == "music_control" then
                if p2 == "play_pause" then
                    is_playing = not is_playing
                    if not is_playing then stopSpeakers() end
                    os.queueEvent("play_status_changed")
                elseif p2 == "skip" then
                    is_playing = true
                    skip_request = true
                    stopSpeakers()
                    os.queueEvent("play_status_changed")
                end
                if monitor then drawUI() end
            end
            
        elseif event == "disk" or event == "disk_eject" then
            scanDisks()
            current_song_idx = 1
            skip_request = true
            is_playing = false
            stopSpeakers()
            os.queueEvent("play_status_changed")
            if monitor then drawUI() end
        end
    end
end

parallel.waitForAny(audioLoop, controlLoop)
