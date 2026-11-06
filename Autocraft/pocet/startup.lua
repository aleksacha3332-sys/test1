-- ============================================================================
-- AEGIS REMOTE CONTROL TERMINAL (POCKET COMPUTER) v2
-- Target: ComputerCraft Advanced Pocket Computer with Ender/Wireless Modem
-- Protocol: AEGIS_REMOTE (rednet)
-- ============================================================================

local CONFIG_FILE = "remote_config.json"
local PROTOCOL    = "AEGIS_REMOTE"

local native = term.current()
local W, H = native.getSize()
-- Off-screen buffer: everything is drawn here, then shown at once (no flicker)
local scr = window.create(native, 1, 1, W, H, false)

-- CC font drawing characters (kept as escapes so the source stays ASCII)
local CH_DOT  = string.char(7)    -- small bullet
local CH_LINE = string.char(131)  -- thin line at the top of a cell
local CH_BAR  = string.char(140)  -- thin bar in the middle of a cell

-- Layout
local TOP = 4          -- first content row
local BOT = 17         -- last content row

-- ----------------------------------------------------------------------------
-- CONFIG
-- ----------------------------------------------------------------------------
local Config = { serverId = nil, serverLabel = nil }

local function loadConfig()
    if not fs.exists(CONFIG_FILE) then return end
    local f = fs.open(CONFIG_FILE, "r")
    if not f then return end
    local data = f.readAll()
    f.close()
    local ok, obj = pcall(textutils.unserializeJSON, data)
    if ok and type(obj) == "table" then
        Config.serverId    = tonumber(obj.serverId)
        Config.serverLabel = obj.serverLabel
    end
end

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    if f then
        f.write(textutils.serializeJSON(Config))
        f.close()
    end
end

-- ----------------------------------------------------------------------------
-- MODEM
-- ----------------------------------------------------------------------------
local modemSide = nil

local function ensureModem()
    if modemSide and rednet.isOpen(modemSide) then return true end
    modemSide = nil
    local candidates = { "back" }
    for _, n in ipairs(peripheral.getNames()) do candidates[#candidates + 1] = n end
    for _, name in ipairs(candidates) do
        if peripheral.getType(name) == "modem" then
            local m = peripheral.wrap(name)
            if m and (not m.isWireless or m.isWireless()) then
                pcall(rednet.open, name)
                if rednet.isOpen(name) then
                    modemSide = name
                    return true
                end
            end
        end
    end
    return false
end

local function showNoModemScreen()
    native.setBackgroundColor(colors.black)
    native.clear()
    native.setCursorPos(1, 1)
    native.setTextColor(colors.cyan)
    print(" AEGIS REMOTE")
    print("")
    native.setTextColor(colors.red)
    print(" No wireless modem found")
    print("")
    native.setTextColor(colors.white)
    print(" Combine this pocket with")
    print(" an Ender Modem in a")
    print(" crafting table.")
    print("")
    native.setTextColor(colors.lightGray)
    print(" Retrying automatically...")
    print(" Ctrl+T to exit")
    local t = os.startTimer(3)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "terminate" then error("Terminated", 0) end
        if ev == "key" or ev == "mouse_click" then return end
        if ev == "timer" and p1 == t then return end
    end
end

-- ----------------------------------------------------------------------------
-- NETWORK
-- ----------------------------------------------------------------------------
-- Expected reply type for each request; replies of other types are stale and ignored
local EXPECT = {
    GET_STATE = "STATE", GET_RECIPES = "RECIPES", GET_KEEP = "KEEP",
    GET_VAULTS = "VAULTS", GET_ERRORS = "ERRORS", GET_MAX = "MAX", GET_QUEUE = "QUEUE", PING = "PONG"
}

local lostPairing = false

local function request(msgType, payload, timeout)
    if not Config.serverId then return nil, "Not paired" end
    if not ensureModem() then return nil, "No modem" end

    local req = payload or {}
    req.type = msgType
    req.pocketId = os.getComputerID()
    rednet.send(Config.serverId, req, PROTOCOL)

    local want = EXPECT[msgType]
    local timer = os.startTimer(timeout or 2)
    while true do
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "terminate" then
            error("Terminated", 0)
        elseif ev == "rednet_message" and p1 == Config.serverId and p3 == PROTOCOL and type(p2) == "table" then
            local t = p2.type
            if t == "UNAUTHORIZED" then
                os.cancelTimer(timer)
                lostPairing = true
                return nil, "Not paired"
            elseif (want and t == want) or (not want and (t == "OK" or t == "ERR")) then
                os.cancelTimer(timer)
                return p2
            end
        elseif ev == "timer" and p1 == timer then
            return nil, "No response"
        end
    end
end

local function pairWith(targetId, timeout)
    if not ensureModem() then return false, "No modem" end
    local req = {
        type = "PAIR",
        pocketId = os.getComputerID(),
        label = os.getComputerLabel() or ("Pocket #" .. os.getComputerID())
    }
    if targetId then
        rednet.send(targetId, req, PROTOCOL)
    else
        rednet.broadcast(req, PROTOCOL)
    end
    local timer = os.startTimer(timeout or 4)
    while true do
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "terminate" then
            error("Terminated", 0)
        elseif ev == "rednet_message" and p3 == PROTOCOL and type(p2) == "table" then
            if p2.type == "PAIR_OK" then
                os.cancelTimer(timer)
                Config.serverId    = tonumber(p2.serverId) or p1
                Config.serverLabel = p2.serverLabel or ("Aegis #" .. tostring(Config.serverId))
                saveConfig()
                lostPairing = false
                return true, Config.serverLabel
            elseif p2.type == "PAIR_DENIED" then
                os.cancelTimer(timer)
                return false, "Denied: press PAIR REMOTE"
            end
        elseif ev == "timer" and p1 == timer then
            return false, "No server answered"
        end
    end
end

-- ----------------------------------------------------------------------------
-- STATE
-- ----------------------------------------------------------------------------
local activeTab   = "RECIPES"
local activeModal = nil   -- nil | "PAIR" | "CRAFT" | "KEEP" | "ERRVIEW"

local server = {
    online = false, used = 0, total = 0, free = 0,
    status = "IDLE", busy = false, queue = 0, errors = 0, asPaused = false
}

local recipesList, keepList, vaultsList, errorsList, queueList = {}, {}, {}, {}, {}
local numInputStr = ""
local numInputTarget = "picker"
local numInputArg = nil
local numInputTitle = "ENTER QUANTITY"
local numInputMin = 1

local curPage = 1
local search  = ""
local toast, toastColor, toastTimer = "", colors.yellow, nil
local zones = {}

local picker = { item = nil, name = "", stock = 0, max = nil, qty = 1 }
local keepEd = { item = nil, name = "", thr = 16, tgt = 64, field = "tgt" }
local errView = nil
local pendingDelete = nil

local function setToast(msg, sec, col)
    toast = msg or ""
    toastColor = col or colors.yellow
    if toastTimer then os.cancelTimer(toastTimer) end
    toastTimer = os.startTimer(sec or 3)
end

-- ----------------------------------------------------------------------------
-- HELPERS
-- ----------------------------------------------------------------------------
local function fmtNum(n)
    n = tonumber(n) or 0
    if n > 9999 then return ">9999" end
    return tostring(math.floor(n))
end

local function fit(s, n)
    s = tostring(s or "")
    if n <= 0 then return "" end
    if #s <= n then return s end
    if n == 1 then return s:sub(1, 1) end
    return s:sub(1, n - 1) .. "."
end

local function wrap(s, w)
    local out = {}
    s = tostring(s or "")
    while #s > w do
        local cut = s:sub(1, w):match("^.*()[%s_]")
        if not cut or cut < math.floor(w / 2) then cut = w end
        out[#out + 1] = s:sub(1, cut):gsub("%s+$", "")
        s = s:sub(cut + 1)
    end
    out[#out + 1] = s
    return out
end

local function matches(name)
    return search == "" or tostring(name or ""):lower():find(search:lower(), 1, true) ~= nil
end

-- ----------------------------------------------------------------------------
-- DRAWING PRIMITIVES
-- ----------------------------------------------------------------------------
local function txt(x, y, s, fg, bg)
    scr.setCursorPos(x, y)
    scr.setTextColor(fg or colors.white)
    scr.setBackgroundColor(bg or colors.black)
    scr.write(s)
end

local function fill(y, bg, x1, x2)
    x1, x2 = x1 or 1, x2 or W
    if x2 < x1 then return end
    scr.setCursorPos(x1, y)
    scr.setBackgroundColor(bg)
    scr.write(string.rep(" ", x2 - x1 + 1))
end

local function zone(id, arg, x1, x2, y1, y2)
    zones[#zones + 1] = { id = id, arg = arg, x1 = x1, x2 = x2, y1 = y1, y2 = y2 or y1 }
end

local function button(x1, x2, y, label, fg, bg, id, arg)
    fill(y, bg, x1, x2)
    local w = x2 - x1 + 1
    local l = fit(label, w)
    txt(x1 + math.floor((w - #l) / 2), y, l, fg, bg)
    if id then zone(id, arg, x1, x2, y) end
end

local function center(y, s, fg, bg)
    s = fit(s, W)
    txt(math.floor((W - #s) / 2) + 1, y, s, fg, bg)
end

local function bar(x, y, w, val, max, col, emptyCol, bg)
    local n = 0
    if max and max > 0 then n = math.floor(math.min(1, (val or 0) / max) * w + 0.5) end
    txt(x, y, string.rep(CH_BAR, n), col, bg)
    txt(x + n, y, string.rep(CH_BAR, w - n), emptyCol or colors.gray, bg)
end

local function usageColor(frac)
    if frac >= 0.9 then return colors.red end
    if frac >= 0.7 then return colors.orange end
    return colors.lime
end

local function modalHeader(title)
    fill(1, colors.gray)
    txt(2, 1, title, colors.cyan, colors.gray)
end

local function paginate(n, perPage)
    local pages = math.max(1, math.ceil(n / perPage))
    if curPage > pages then curPage = pages end
    if curPage < 1 then curPage = 1 end
    local s = (curPage - 1) * perPage + 1
    return s, math.min(n, s + perPage - 1), pages
end

local function emptyState(line1, line2)
    local y = math.floor((TOP + BOT) / 2) - 1
    center(y, line1, colors.lightGray)
    if line2 then center(y + 2, line2, colors.gray) end
end

-- ----------------------------------------------------------------------------
-- DATA SYNC
-- ----------------------------------------------------------------------------
local function syncState()
    local rep = request("GET_STATE", nil, 1.5)
    if rep then
        server.online   = true
        server.used     = rep.usedSlots or 0
        server.total    = rep.totSlots or 0
        server.free     = rep.freeSlots or 0
        server.status   = rep.status or "IDLE"
        server.busy     = rep.crafting or false
        server.queue    = rep.queueCount or 0
        server.errors   = rep.errorCount or 0
        server.asPaused = rep.autostockPaused or false
        return true
    end
    server.online = false
    return false
end

local function syncQueue()
    local rep = request("GET_QUEUE", nil, 3)
    if rep and type(rep.list) == "table" then
        queueList = rep.list
        server.queue = #queueList
        return true
    end
    return false
end

local function syncTab()
    local rep
    if activeTab == "RECIPES" then
        rep = request("GET_RECIPES", nil, 3)
        if rep and type(rep.list) == "table" then recipesList = rep.list end
    elseif activeTab == "KEEP" then
        rep = request("GET_KEEP", nil, 3)
        if rep and type(rep.list) == "table" then
            keepList = rep.list
            server.asPaused = rep.pausedAll or false
        end
    elseif activeTab == "VAULTS" then
        rep = request("GET_VAULTS", nil, 3)
        if rep and type(rep.list) == "table" then
            vaultsList = rep.list
            server.used  = rep.usedSlots or server.used
            server.total = rep.totSlots or server.total
            server.free  = rep.freeSlots or server.free
        end
    elseif activeTab == "ERRORS" then
        rep = request("GET_ERRORS", nil, 3)
        if rep and type(rep.list) == "table" then
            errorsList = rep.list
            server.errors = #errorsList
        end
    end
    return rep ~= nil
end

local draw -- forward declaration

local function reload(showLoading)
    if showLoading then
        setToast("Loading...", 5, colors.lightGray)
        draw()
    end
    local ok = syncState() and syncTab()
    if showLoading then
        if ok then
            toast = ""
        else
            setToast("Server not responding", 4, colors.red)
        end
    end
    if lostPairing then
        activeModal = "PAIR"
        setToast("Pairing lost, pair again", 5, colors.red)
    end
end

-- ----------------------------------------------------------------------------
-- MAIN SCREEN: HEADER / TABS / FOOTER
-- ----------------------------------------------------------------------------
local TABS = {
    { id = "RECIPES", label = "REQ" },
    { id = "KEEP",    label = "KEEP" },
    { id = "VAULTS",  label = "VAULT" },
    { id = "ERRORS",  label = "ERR" }
}

local function drawHeader()
    -- Row 1: title + status (tap title to open pairing settings)
    fill(1, colors.gray)
    txt(2, 1, "AEGIS", colors.cyan, colors.gray)
    txt(8, 1, "remote", colors.lightGray, colors.gray)
    zone("open_pair", nil, 1, 13, 1)

    local st, col
    if not server.online then
        st, col = "OFFLINE", colors.red
    elseif server.busy or server.status ~= "IDLE" then
        st, col = "BUSY", colors.orange
    else
        st, col = "IDLE", colors.lime
    end
    local s = CH_DOT .. " " .. st
    txt(W - #s, 1, s, col, colors.gray)
end

local function drawTabs()
    for i, t in ipairs(TABS) do
        local x1 = math.floor((i - 1) * W / 4) + 1
        local x2 = math.floor(i * W / 4)
        local active = (activeTab == t.id)
        local label = t.label
        local fg = active and colors.white or colors.lightGray
        if t.id == "ERRORS" and server.errors > 0 then
            label = label .. " " .. server.errors
            if not active then fg = colors.red end
        end
        button(x1, x2, 2, label, fg, active and colors.gray or colors.black, "tab", t.id)
        txt(x1, 3, string.rep(CH_LINE, x2 - x1 + 1), active and colors.lime or colors.gray)
    end
end

local function drawFooter(pages)
    -- Row H-1: pager
    if pages > 1 then
        local y = H - 1
        button(1, 5, y, "<", curPage > 1 and colors.white or colors.gray, colors.gray, "prev")
        button(W - 4, W, y, ">", curPage < pages and colors.white or colors.gray, colors.gray, "next")
        center(y, curPage .. " / " .. pages, colors.lightGray)
    end

    -- Row H: bottom action bar (Queue button, Autostock, FIND, SYNC)
    local qBg = server.queue > 0 and colors.yellow or colors.gray
    local qFg = server.queue > 0 and colors.black or colors.white
    button(1, 6, H, "Q:" .. server.queue, qFg, qBg, "open_queue")

    txt(8, H, server.asPaused and "AS:OFF" or "AS:ON", server.asPaused and colors.orange or colors.lightGray)

    button(15, 20, H, search ~= "" and "FIND*" or "FIND",
        search ~= "" and colors.cyan or colors.white, colors.gray, "find")
    button(22, W, H, "SYNC", colors.lime, colors.gray, "sync")
end

-- ----------------------------------------------------------------------------
-- TAB: RECIPES
-- ----------------------------------------------------------------------------
local function renderRecipes()
    local list = {}
    for _, r in ipairs(recipesList) do
        if matches(r.name or r.id) then list[#list + 1] = r end
    end
    local per = 5
    local s, e, pages = paginate(#list, per)

    if #list == 0 then
        if search ~= "" then
            emptyState("Nothing found", "Tap FIND to change")
        else
            emptyState("No recipes yet", "Learn them on the main PC")
        end
    end

    local y = TOP
    for i = s, e do
        local r = list[i]
        fill(y, colors.gray)
        fill(y + 1, colors.gray)

        local stock = fmtNum(r.stock or 0)
        txt(2, y, fit(r.name or r.id, W - 4 - #stock), colors.white, colors.gray)
        txt(W - #stock, y, stock, colors.cyan, colors.gray)

        button(2, 8, y + 1, "CRAFT", colors.black, colors.lime, "craft", r)
        local kCol = r.isKept and colors.yellow or colors.lightGray
        button(10, 16, y + 1, "+KEEP", colors.black, kCol, "keep_edit", r)

        local mx, mcol
        if r.maxCraft == nil then
            mx, mcol = "?", colors.lightGray
        elseif r.maxCraft > 0 then
            mx, mcol = fmtNum(r.maxCraft), colors.lime
        else
            mx, mcol = "0", colors.red
        end
        txt(W - #mx, y + 1, mx, mcol, colors.gray)

        y = y + 3
    end
    drawFooter(pages)
end

-- ----------------------------------------------------------------------------
-- TAB: KEEP
-- ----------------------------------------------------------------------------
local function renderKeep()
    if server.asPaused then
        button(1, 12, TOP, "RESUME ALL", colors.black, colors.lime, "pause_all")
    else
        button(1, 12, TOP, "PAUSE ALL", colors.white, colors.red, "pause_all")
    end
    button(14, W, TOP, "RUN NOW", colors.black, colors.orange, "run_all")

    local list = {}
    for _, k in ipairs(keepList) do
        if matches(k.name or k.id) then list[#list + 1] = k end
    end
    local top = TOP + 2
    local per = math.floor((BOT - top + 2) / 3)
    local s, e, pages = paginate(#list, per)

    if #list == 0 then
        emptyState("No keep rules", "Add via +KEEP in REC")
    end

    local y = top
    for i = s, e do
        local k = list[i]
        fill(y, colors.gray)
        fill(y + 1, colors.gray)

        local stock, thr, tgt = k.stock or 0, k.threshold or 1, k.target or 1
        local scol = colors.yellow
        if stock < thr then scol = colors.red elseif stock >= tgt then scol = colors.lime end
        local amount = fmtNum(stock) .. "/" .. fmtNum(tgt)
        local name = (k.paused and "|| " or "") .. (k.name or k.id)
        txt(2, y, fit(name, W - 4 - #amount), k.paused and colors.lightGray or colors.white, colors.gray)
        txt(W - #amount, y, amount, scol, colors.gray)

        button(2, 8, y + 1, "CRAFT", colors.black, colors.lime, "keep_run", k)
        if k.paused then
            button(10, 16, y + 1, "RESUME", colors.black, colors.lime, "keep_pause", k)
        else
            button(10, 16, y + 1, "PAUSE", colors.black, colors.orange, "keep_pause", k)
        end
        button(18, 20, y + 1, "E", colors.black, colors.cyan, "keep_edit", k)
        if pendingDelete == k.id then
            button(22, 24, y + 1, "OK", colors.white, colors.red, "keep_del", k)
        else
            button(22, 24, y + 1, "X", colors.white, colors.red, "keep_del", k)
        end
        y = y + 3
    end
    drawFooter(pages)
end

-- ----------------------------------------------------------------------------
-- TAB: VAULTS
-- ----------------------------------------------------------------------------
local function renderVaults()
    local frac = server.total > 0 and server.used / server.total or 0
    txt(2, TOP, "Total", colors.lightGray)
    local tot = server.used .. " / " .. server.total
    txt(W - #tot, TOP, tot, colors.white)
    bar(2, TOP + 1, W - 2, server.used, server.total, usageColor(frac))
    txt(2, TOP + 2, server.free .. " free", colors.lightGray)
    local pct = math.floor(frac * 100) .. "%"
    txt(W - #pct, TOP + 2, pct, usageColor(frac))

    local top = TOP + 4
    local per = math.floor((BOT - top + 2) / 3)
    local s, e, pages = paginate(#vaultsList, per)

    if #vaultsList == 0 then
        center(top + 2, "No MAIN vaults set", colors.lightGray)
    end

    local y = top
    for i = s, e do
        local v = vaultsList[i]
        fill(y, colors.gray)
        fill(y + 1, colors.gray)
        local vf = (v.max or 0) > 0 and (v.used or 0) / v.max or 0
        local p = (v.pct or 0) .. "%"
        txt(2, y, fit(v.name or "vault", W - 4 - #p), colors.white, colors.gray)
        txt(W - #p, y, p, usageColor(vf), colors.gray)
        local cnt = fmtNum(v.used or 0) .. "/" .. fmtNum(v.max or 0)
        local bw = W - 4 - #cnt
        bar(2, y + 1, bw, v.used or 0, v.max or 0, usageColor(vf), colors.black, colors.gray)
        txt(W - #cnt, y + 1, cnt, colors.lightGray, colors.gray)
        y = y + 3
    end
    drawFooter(pages)
end

-- ----------------------------------------------------------------------------
-- TAB: ERRORS
-- ----------------------------------------------------------------------------
local function renderErrors()
    if #errorsList == 0 then
        txt(2, TOP, "Error log", colors.lightGray)
        emptyState("No errors", "System is healthy")
        drawFooter(1)
        return
    end
    txt(2, TOP, #errorsList .. " error" .. (#errorsList > 1 and "s" or ""), colors.white)
    button(W - 7, W, TOP, "CLEAR", colors.white, colors.red, "clear_err")

    local top = TOP + 2
    local per = math.floor((BOT - top + 2) / 3)
    local s, e, pages = paginate(#errorsList, per)
    local y = top
    for i = s, e do
        local er = errorsList[i]
        fill(y, colors.gray)
        fill(y + 1, colors.gray)
        local t = er.time or "--:--"
        txt(2, y, t, colors.lightGray, colors.gray)
        txt(3 + #t, y, fit(er.title or "! ERROR", W - 3 - #t), colors.red, colors.gray)
        local d = (er.lines and er.lines[1]) or ""
        txt(2, y + 1, fit(d, W - 2), colors.white, colors.gray)
        zone("err_view", er, 1, W, y, y + 1)
        y = y + 3
    end
    drawFooter(pages)
end

-- ----------------------------------------------------------------------------
-- MODAL: CRAFT ORDER
-- ----------------------------------------------------------------------------
local function renderPicker()
    modalHeader("CRAFT ORDER")

    local lines = wrap(picker.name, W - 2)
    txt(2, 3, lines[1] or "", colors.white)
    if lines[2] then txt(2, 4, fit(lines[2], W - 2), colors.white) end

    txt(2, 5, "In stock", colors.lightGray)
    local st = fmtNum(picker.stock)
    txt(W - 1 - #st, 5, st, colors.cyan)
    txt(2, 6, "Craftable", colors.lightGray)
    local mx, mcol = "?", colors.lightGray
    if picker.max then
        mx = fmtNum(picker.max)
        mcol = picker.max > 0 and colors.lime or colors.red
    end
    txt(W - 1 - #mx, 6, mx, mcol)

    if toast ~= "" then center(7, toast, toastColor) end

    -- Quantity panel (clickable to type number) with 1-char margins
    for y = 8, 10 do fill(y, colors.gray, 2, 25) end
    local diff = picker.qty - picker.stock
    local over = picker.max and diff > picker.max
    local dispStr = fmtNum(picker.qty)
    if diff > 0 then
        dispStr = dispStr .. " (+" .. fmtNum(diff) .. ")"
    end
    center(9, dispStr, over and colors.red or colors.yellow, colors.gray)
    zone("open_num_picker", nil, 2, 25, 8, 10)

    -- Column 1 (+1, +32, +64) at 2..8
    -- Column 2 (-1, -32, -64) at 10..16
    -- Column 3 (MAX, NUM, RESET) at 18..25
    button(2, 8, 12, "+1", colors.black, colors.lime, "qty", 1)
    button(10, 16, 12, "-1", colors.white, colors.red, "qty", -1)
    button(18, 25, 12, "MAX", colors.black, colors.cyan, "qty_max")

    button(2, 8, 14, "+32", colors.black, colors.lime, "qty", 32)
    button(10, 16, 14, "-32", colors.white, colors.red, "qty", -32)
    button(18, 25, 14, "NUM", colors.black, colors.yellow, "open_num_picker")

    button(2, 8, 16, "+64", colors.black, colors.lime, "qty", 64)
    button(10, 16, 16, "-64", colors.white, colors.red, "qty", -64)
    button(18, 25, 16, "RESET", colors.white, colors.gray, "qty_reset")

    -- Row 18: START and +QUEUE on one line, separated by gap, not touching screen edges
    button(2, 12, 18, "START", colors.black, colors.lime, "craft_start")
    button(14, 25, 18, "+QUEUE", colors.black, colors.cyan, "craft_queue")

    -- Row 20: BACK with margins
    button(2, 25, 20, "BACK", colors.white, colors.gray, "close")
end

-- ----------------------------------------------------------------------------
local function renderQueue()
    modalHeader("CRAFT QUEUE (" .. #queueList .. ")")
    if #queueList == 0 then
        emptyState("Queue is empty", "Add crafts via +QUEUE")
        button(1, W, H, "CLOSE", colors.white, colors.gray, "close")
        return
    end

    local per = 4
    local s, e, pages = paginate(#queueList, per)
    local y = 4
    for i = s, e do
        local qe = queueList[i]
        fill(y, colors.gray)
        fill(y + 1, colors.gray)

        local name = qe.name or "item"
        local unit = (qe.kind == "fluid" and not qe.isItem) and "mB" or "x"
        local qStr = unit .. fmtNum(qe.qty or 1)
        txt(2, y, fit(name, W - 4 - #qStr), colors.white, colors.gray)
        txt(W - #qStr, y, qStr, colors.yellow, colors.gray)

        button(2, 9, y + 1, "CRAFT", colors.black, colors.lime, "q_run", i)
        button(11, 15, y + 1, " E ", colors.black, colors.cyan, "q_edit", i)
        button(17, 21, y + 1, " X ", colors.white, colors.red, "q_del", i)

        y = y + 3
    end

    if pages > 1 then
        local py = H - 2
        button(1, 5, py, "<", curPage > 1 and colors.white or colors.gray, colors.gray, "prev")
        button(W - 4, W, py, ">", curPage < pages and colors.white or colors.gray, colors.gray, "next")
        center(py, curPage .. " / " .. pages, colors.lightGray)
    end

    button(2, 25, H - 1, "CRAFT ALL", colors.black, colors.orange, "q_run_all")
    button(2, 25, H, "CLOSE", colors.white, colors.gray, "close")
end

local function renderKeypad()
    modalHeader(numInputTitle or "ENTER NUMBER")

    txt(2, 3, "Min: " .. numInputMin .. "   Max: 9999", colors.lightGray)

    -- Display Box
    fill(5, colors.gray)
    fill(6, colors.gray)
    local s = (numInputStr == "" and "0" or numInputStr) .. "_"
    center(5, s, colors.yellow, colors.gray)
    center(6, "Type or tap numbers", colors.lightGray, colors.gray)

    -- Keypad Grid
    local function kbtn(x1, x2, y, ch)
        button(x1, x2, y, ch, colors.white, colors.gray, "kp_num", ch)
    end
    kbtn(2, 8, 8, "1");   kbtn(10, 16, 8, "2");   kbtn(18, 24, 8, "3")
    kbtn(2, 8, 10, "4");  kbtn(10, 16, 10, "5");  kbtn(18, 24, 10, "6")
    kbtn(2, 8, 12, "7");  kbtn(10, 16, 12, "8");  kbtn(18, 24, 12, "9")
    button(2, 8, 14, "CLR", colors.white, colors.red, "kp_clr")
    kbtn(10, 16, 14, "0")
    button(18, 24, 14, "<", colors.white, colors.orange, "kp_back")

    if toast ~= "" then center(16, toast, toastColor) end

    button(2, 25, H - 1, "OK", colors.black, colors.lime, "kp_ok")
    button(2, 25, H, "CANCEL", colors.white, colors.gray, "kp_cancel")
end

-- MODAL: KEEP RULE
-- ----------------------------------------------------------------------------
local function renderKeepModal()
    modalHeader("KEEP RULE")

    local lines = wrap(keepEd.name, W - 2)
    txt(2, 3, lines[1] or "", colors.white)
    if lines[2] then txt(2, 4, fit(lines[2], W - 2), colors.white) end

    local function field(y, key, label, val)
        local sel = (keepEd.field == key)
        local bg = sel and colors.cyan or colors.gray
        local fg = sel and colors.black or colors.white
        fill(y, bg)
        txt(2, y, label, fg, bg)
        local v = tostring(val)
        txt(W - #v, y, v, sel and colors.black or colors.yellow, bg)
        zone("keep_field", key, 1, W, y)
    end
    field(6, "thr", "Min (trigger)", keepEd.thr)
    field(8, "tgt", "Target", keepEd.tgt)
    center(10, "Below min -> craft to tgt", colors.lightGray)

    -- 4 buttons: widths 5,6,6,6 with 1-col gaps
    button(1, 5, 12, "-10", colors.white, colors.red, "keep_adj", -10)
    button(7, 12, 12, "-1", colors.white, colors.red, "keep_adj", -1)
    button(14, 19, 12, "+1", colors.black, colors.lime, "keep_adj", 1)
    button(21, W, 12, "+10", colors.black, colors.lime, "keep_adj", 10)
    button(1, 12, 14, "-64", colors.white, colors.red, "keep_adj", -64)
    button(14, W, 14, "+64", colors.black, colors.lime, "keep_adj", 64)

    if toast ~= "" then center(16, toast, toastColor) end

    button(2, 25, H - 1, "SAVE", colors.black, colors.lime, "keep_save")
    button(2, 25, H, "CANCEL", colors.white, colors.gray, "close")
end

-- ----------------------------------------------------------------------------
-- MODAL: ERROR DETAILS
-- ----------------------------------------------------------------------------
local function renderErrView()
    modalHeader("ERROR DETAILS")
    local er = errView or {}
    txt(2, 3, er.time or "--:--", colors.lightGray)
    local y = 5
    for _, l in ipairs(wrap(er.title or "! ERROR", W - 2)) do
        if y > H - 2 then break end
        txt(2, y, l, colors.red)
        y = y + 1
    end
    y = y + 1
    for _, raw in ipairs(er.lines or {}) do
        for _, l in ipairs(wrap(raw, W - 2)) do
            if y > H - 2 then break end
            txt(2, y, l, colors.white)
            y = y + 1
        end
    end
    button(1, W, H, "BACK", colors.white, colors.gray, "close")
end

-- ----------------------------------------------------------------------------
-- MODAL: PAIRING
-- ----------------------------------------------------------------------------
local function renderPair()
    modalHeader("PAIRING")
    local creditStr = "Made by Mstr_Max"
    txt(math.max(10, W - #creditStr), 1, creditStr, colors.white, colors.gray)

    if Config.serverId then
        txt(2, 3, "Paired with", colors.lightGray)
        txt(2, 4, fit(Config.serverLabel or ("#" .. Config.serverId), W - 2), colors.lime)
    else
        txt(2, 3, "Not paired yet", colors.red)
    end

    txt(2, 6, "1. On the main monitor:", colors.yellow)
    txt(2, 7, "NETWORK > PAIR REMOTE", colors.white)
    txt(2, 9, "2. Then tap here:", colors.yellow)

    button(2, W - 1, 11, "SEARCH & PAIR", colors.black, colors.lime, "pair_auto")
    button(2, W - 1, 13, "PAIR BY ID", colors.black, colors.cyan, "pair_id")

    if toast ~= "" then center(15, toast, toastColor) end

    if Config.serverId then
        button(2, W - 1, H - 2, "BACK", colors.white, colors.gray, "close")
    else
        button(2, W - 1, H - 2, "EXIT", colors.white, colors.gray, "exit")
    end
    center(H, "Pocket ID #" .. os.getComputerID(), colors.gray)
end

-- ----------------------------------------------------------------------------
-- DISPATCH
-- ----------------------------------------------------------------------------
local function confirmKeypad()
    local val = tonumber(numInputStr)
    if not val or val < numInputMin then
        setToast("Min allowed is " .. numInputMin, 2, colors.orange)
    else
        val = math.min(9999, val)
        if numInputTarget == "picker" then
            picker.qty = val
            activeModal = "CRAFT"
        elseif numInputTarget == "queue_edit" then
            local rep, err = request("QUEUE_EDIT", { idx = numInputArg, qty = val }, 3)
            syncQueue()
            activeModal = "QUEUE"
            setToast((rep and rep.msg) or err or "Updated", 2, colors.lime)
        end
    end
end

draw = function()
    zones = {}
    scr.setVisible(false)
    scr.setBackgroundColor(colors.black)
    scr.clear()

    if activeModal == "PAIR" or not Config.serverId then
        renderPair()
    elseif activeModal == "CRAFT" then
        renderPicker()
    elseif activeModal == "QUEUE" then
        renderQueue()
    elseif activeModal == "KEYPAD" then
        renderKeypad()
    elseif activeModal == "KEEP" then
        renderKeepModal()
    elseif activeModal == "ERRVIEW" then
        renderErrView()
    else
        drawHeader()
        drawTabs()
        if activeTab == "RECIPES" then
            renderRecipes()
        elseif activeTab == "KEEP" then
            renderKeep()
        elseif activeTab == "VAULTS" then
            renderVaults()
        else
            renderErrors()
        end
    end

    scr.setVisible(true)
end

-- Simple full-screen text prompt (uses the real terminal)
local function prompt(title, hint)
    native.setBackgroundColor(colors.black)
    native.clear()
    native.setCursorPos(1, 1)
    native.setBackgroundColor(colors.gray)
    native.clearLine()
    native.setTextColor(colors.cyan)
    native.write(" " .. title)
    native.setBackgroundColor(colors.black)
    native.setTextColor(colors.lightGray)
    native.setCursorPos(2, 3)
    native.write(hint or "")
    native.setCursorPos(2, 5)
    native.setTextColor(colors.white)
    native.write("> ")
    native.setTextColor(colors.yellow)
    local inp = read()
    return ((inp or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function closeModal()
    activeModal = nil
    toast = ""
    reload(true)
end

-- ----------------------------------------------------------------------------
-- INPUT
-- ----------------------------------------------------------------------------
local function handleTouch(x, y)
    local hit = nil
    for i = #zones, 1, -1 do
        local z = zones[i]
        if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then hit = z break end
    end
    if not hit then
        pendingDelete = nil
        return
    end
    local id, a = hit.id, hit.arg
    if id ~= "keep_del" then pendingDelete = nil end

    -- Navigation
    if id == "tab" then
        if activeTab ~= a then
            activeTab = a
            curPage = 1
            reload(true)
        end
    elseif id == "prev" then
        curPage = curPage - 1
    elseif id == "next" then
        curPage = curPage + 1
    elseif id == "sync" then
        reload(true)
        if toast == "" then setToast("Updated", 2, colors.lime) end
    elseif id == "find" then
        search = prompt("SEARCH", "Empty input clears filter")
        curPage = 1
    elseif id == "close" then
        closeModal()
    elseif id == "exit" then
        error("Terminated", 0)

    -- Pairing
    elseif id == "open_pair" then
        activeModal = "PAIR"
        toast = ""
    elseif id == "pair_auto" or id == "pair_id" then
        local target = nil
        if id == "pair_id" then
            target = tonumber(prompt("PAIR BY ID", "Main computer ID:"))
            if not target then
                setToast("Invalid ID", 3, colors.red)
                return
            end
        end
        setToast("Searching...", 5, colors.lightGray)
        draw()
        local ok, res = pairWith(target, 4)
        if ok then
            activeModal = nil
            reload(true)
            setToast("Paired: " .. res, 3, colors.lime)
        else
            setToast(res, 4, colors.red)
        end

    -- Craft order
    elseif id == "craft" then
        picker.item  = a.id
        picker.name  = a.name or a.id
        picker.stock = a.stock or 0
        picker.max   = a.maxCraft
        picker.qty   = (picker.stock and picker.stock > 0) and picker.stock or 1
        activeModal  = "CRAFT"
        toast = ""
        if picker.max == nil then
            setToast("Calculating max...", 3, colors.lightGray)
            draw()
            local rep = request("GET_MAX", { item = a.id }, 3)
            if rep and rep.item == a.id then
                picker.max = rep.max
                a.maxCraft = rep.max
            end
            toast = ""
        end
    elseif id == "qty" then
        local minQty = (picker.stock and picker.stock > 0) and picker.stock or 1
        picker.qty = math.max(minQty, math.min(99999, picker.qty + a))
    elseif id == "qty_max" then
        if picker.max and picker.max > 0 then
            picker.qty = picker.stock + picker.max
        else
            setToast(picker.max == 0 and "Nothing craftable" or "Max unknown", 2, colors.orange)
        end
    elseif id == "qty_reset" then
        picker.qty = (picker.stock and picker.stock > 0) and picker.stock or 1
    elseif id == "craft_start" then
        if picker.qty <= picker.stock then
            setToast("Add items (+1, +32...)", 3, colors.orange)
        else
            setToast("Sending...", 3, colors.lightGray)
            draw()
            local rep, err = request("CRAFT_ORDER", { item = picker.item, qty = picker.qty }, 4)
            if rep and rep.type == "OK" then
                activeModal = nil
                reload(false)
                setToast(rep.msg or "Order sent", 4, colors.lime)
            else
                setToast((rep and rep.msg) or err or "Failed", 4, colors.red)
            end
        end
    elseif id == "open_num_picker" then
        numInputStr = tostring(picker.qty)
        numInputTarget = "picker"
        numInputTitle = "CRAFT QUANTITY"
        numInputMin = (picker.stock and picker.stock > 0) and picker.stock or 1
        activeModal = "KEYPAD"

    elseif id == "craft_queue" then
        local diff = picker.qty - picker.stock
        if diff <= 0 then
            setToast("Add items to craft", 3, colors.orange)
        else
            setToast("Adding...", 3, colors.lightGray)
            draw()
            local rep, err = request("QUEUE_ADD", { item = picker.item, qty = picker.qty }, 4)
            if rep and rep.type == "OK" then
                activeModal = nil
                reload(false)
                setToast(rep.msg or "Enqueued", 3, colors.cyan)
            else
                setToast((rep and rep.msg) or err or "Failed", 4, colors.red)
            end
        end

    elseif id == "open_queue" then
        setToast("Loading queue...", 2, colors.lightGray)
        draw()
        syncQueue()
        curPage = 1
        activeModal = "QUEUE"

    elseif id == "q_run" then
        setToast("Starting...", 3, colors.lightGray)
        draw()
        local rep, err = request("QUEUE_RUN", { idx = a }, 4)
        if rep and rep.type == "OK" then
            syncQueue()
            reload(false)
            setToast(rep.msg or "Craft started", 3, colors.lime)
        else
            setToast((rep and rep.msg) or err or "Failed", 4, colors.red)
        end

    elseif id == "q_edit" then
        local qe = queueList[a]
        if qe then
            numInputStr = tostring(qe.qty or 1)
            numInputTarget = "queue_edit"
            numInputArg = a
            numInputTitle = "EDIT QUEUE QTY"
            numInputMin = 1
            activeModal = "KEYPAD"
        end

    elseif id == "q_del" then
        local rep, err = request("QUEUE_DELETE", { idx = a }, 3)
        syncQueue()
        setToast((rep and rep.msg) or err or "Removed", 2, colors.yellow)

    elseif id == "q_run_all" then
        setToast("Starting all...", 3, colors.lightGray)
        draw()
        local rep, err = request("QUEUE_RUN_ALL", nil, 4)
        if rep and rep.type == "OK" then
            syncQueue()
            reload(false)
            setToast(rep.msg or "All crafts started", 3, colors.lime)
        else
            setToast((rep and rep.msg) or err or "Failed", 4, colors.red)
        end

    elseif id == "kp_num" then
        if #numInputStr < 4 then
            numInputStr = numInputStr .. tostring(a)
        end

    elseif id == "kp_clr" then
        numInputStr = ""

    elseif id == "kp_back" then
        if #numInputStr > 0 then
            numInputStr = numInputStr:sub(1, #numInputStr - 1)
        end

    elseif id == "kp_ok" then
        confirmKeypad()

    elseif id == "kp_cancel" then
        activeModal = (numInputTarget == "picker") and "CRAFT" or "QUEUE"

    -- Keep rule editor
    elseif id == "keep_edit" then
        keepEd.item  = a.id
        keepEd.name  = a.name or a.id
        keepEd.thr   = a.threshold or 16
        keepEd.tgt   = a.target or 64
        keepEd.field = "tgt"
        if a.isKept and not a.threshold then
            -- Opened from REC tab: take the real values from the keep list if known
            for _, k in ipairs(keepList) do
                if k.id == a.id then keepEd.thr, keepEd.tgt = k.threshold, k.target break end
            end
        end
        activeModal = "KEEP"
        toast = ""
    elseif id == "keep_field" then
        keepEd.field = a
    elseif id == "keep_adj" then
        if keepEd.field == "thr" then
            keepEd.thr = math.max(1, keepEd.thr + a)
            if keepEd.tgt < keepEd.thr then keepEd.tgt = keepEd.thr end
        else
            keepEd.tgt = math.max(keepEd.thr, keepEd.tgt + a)
        end
    elseif id == "keep_save" then
        local rep, err = request("KEEP_SET", { item = keepEd.item, threshold = keepEd.thr, target = keepEd.tgt }, 2)
        if rep and rep.type == "OK" then
            activeModal = nil
            reload(false)
            setToast("Rule saved", 3, colors.lime)
        else
            setToast((rep and rep.msg) or err or "Save failed", 3, colors.red)
        end

    -- Keep tab actions
    elseif id == "pause_all" then
        local rep, err = request("KEEP_PAUSE_ALL", nil, 2)
        if rep and rep.type == "OK" then
            server.asPaused = rep.paused and true or false
            setToast(server.asPaused and "Autostock paused" or "Autostock resumed", 2, colors.lime)
        else
            setToast(err or "Failed", 3, colors.red)
        end
    elseif id == "run_all" then
        local rep, err = request("KEEP_TRIGGER_ALL", nil, 2)
        setToast((rep and rep.msg) or err or "Failed", 3, (rep and rep.type == "OK") and colors.lime or colors.red)
    elseif id == "keep_run" then
        local rep, err = request("KEEP_TRIGGER", { item = a.id }, 2)
        setToast((rep and rep.msg) or err or "Failed", 3, (rep and rep.type == "OK") and colors.lime or colors.red)
    elseif id == "keep_pause" then
        local rep, err = request("KEEP_TOGGLE", { item = a.id }, 2)
        if rep and rep.type == "OK" then
            a.paused = rep.paused and true or false
        else
            setToast(err or "Failed", 3, colors.red)
        end
    elseif id == "keep_del" then
        if pendingDelete ~= a.id then
            pendingDelete = a.id
            setToast("Tap OK to delete", 3, colors.orange)
        else
            pendingDelete = nil
            local rep, err = request("KEEP_DELETE", { item = a.id }, 2)
            if rep and rep.type == "OK" then
                syncTab()
                setToast("Rule deleted", 2, colors.lime)
            else
                setToast(err or "Failed", 3, colors.red)
            end
        end

    -- Errors
    elseif id == "err_view" then
        errView = a
        activeModal = "ERRVIEW"
    elseif id == "clear_err" then
        local rep, err = request("CLEAR_ERRORS", nil, 2)
        if rep and rep.type == "OK" then
            errorsList = {}
            server.errors = 0
            setToast("Log cleared", 2, colors.lime)
        else
            setToast(err or "Failed", 3, colors.red)
        end
    end

    if lostPairing then
        activeModal = "PAIR"
        setToast("Pairing lost, pair again", 5, colors.red)
    end
end

-- ----------------------------------------------------------------------------
-- MAIN LOOP
-- ----------------------------------------------------------------------------
local function main()
    loadConfig()
    while not ensureModem() do showNoModemScreen() end

    if Config.serverId then
        reload(true)
    else
        activeModal = "PAIR"
    end

    local syncTimer = os.startTimer(5)
    local ticks = 0

    while true do
        draw()
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "terminate" then
            error("Terminated", 0)
        elseif ev == "mouse_click" then
            handleTouch(p2, p3)
        elseif ev == "mouse_scroll" and not activeModal then
            curPage = curPage + p1
        elseif ev == "char" then
            if activeModal == "KEYPAD" and p1 >= "0" and p1 <= "9" then
                if #numInputStr < 4 then numInputStr = numInputStr .. p1 end
            end
        elseif ev == "key" then
            if activeModal == "KEYPAD" then
                if p1 == keys.backspace then
                    if #numInputStr > 0 then numInputStr = numInputStr:sub(1, #numInputStr - 1) end
                elseif p1 == keys.enter then
                    confirmKeypad()
                elseif p1 == keys.esc then
                    activeModal = (numInputTarget == "picker") and "CRAFT" or "QUEUE"
                end
            elseif not activeModal then
                if p1 == keys.left or p1 == keys.up then curPage = curPage - 1 end
                if p1 == keys.right or p1 == keys.down then curPage = curPage + 1 end
            end
        elseif ev == "timer" then
            if p1 == syncTimer then
                if not activeModal and Config.serverId then
                    ticks = ticks + 1
                    syncState()
                    if ticks % 3 == 0 then syncTab() end
                    if lostPairing then
                        activeModal = "PAIR"
                        setToast("Pairing lost, pair again", 5, colors.red)
                    end
                end
                syncTimer = os.startTimer(5)
            elseif p1 == toastTimer then
                toast = ""
                toastTimer = nil
            end
        end
    end
end

-- Crash guard: Ctrl+T exits cleanly, other errors wait for a key (no spam loop)
while true do
    local ok, err = pcall(main)
    native.setBackgroundColor(colors.black)
    native.clear()
    native.setCursorPos(1, 1)
    if ok or err == "Terminated" then
        native.setTextColor(colors.yellow)
        print("Aegis Remote stopped.")
        return
    end
    native.setTextColor(colors.red)
    print("Aegis Remote error:")
    native.setTextColor(colors.white)
    print(tostring(err))
    print("")
    native.setTextColor(colors.yellow)
    print("Any key: restart")
    print("Ctrl+T: exit")
    while true do
        local ev = os.pullEvent()
        if ev == "terminate" then return end
        if ev == "key" or ev == "mouse_click" then break end
    end
end
