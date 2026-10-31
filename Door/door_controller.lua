--[[
  Door Controller (server part)
  ComputerCraft: Tweaked / Minecraft 1.21.1
  - Receives open/close requests via rednet
    (default: open = password, close = free;
     "free open" mode: open = free, close = password)
  - Touch screen UI on attached Advanced Monitors
    (supports ANY NUMBER of monitors at once,
     compact layout for 16x12 chars @ text scale 0.5)
  - Proximity auto-open (Player Detector from Advanced
    Peripherals or a redstone input like a pressure plate)
    still uses the auto-close timer
]]

local CONFIG_FILE = "door_config.cfg"
local PROTOCOL    = "door_control"

-- ===== Default settings (overwritten by setup wizard) =====
local config = {
    password       = "1234",  -- access password (digits only if you use a monitor PIN pad)
    outputSide     = "back",  -- redstone output side to the door
    openTime       = 5,       -- seconds the door stays open after PROXIMITY auto-open
    proximityRange = 4,       -- blocks for the player detector (0 = off)
    inputSide      = "none",  -- redstone input side for a plate ("none" = off)
    freeOpen       = false,   -- true: open without password, close WITH password
}

-- ===== Config load / save =====
local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize(config))
    f.close()
end

local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then
            for k, v in pairs(data) do config[k] = v end
            return true
        end
    end
    return false
end

-- ===== First-run setup wizard =====
local VALID_SIDES = {
    top = true, bottom = true, left = true,
    right = true, front = true, back = true,
}

local function askSide(prompt, allowNone)
    while true do
        write(prompt)
        local side = read()
        if VALID_SIDES[side] or (allowNone and side == "none") then
            return side
        end
        print("Invalid side! Valid: front/back/left/right/top/bottom"
            .. (allowNone and " or 'none'" or ""))
    end
end

local function setupWizard()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Door Controller Setup ===")
    print("")

    write("Door password (digits only!): ")
    config.password = read()

    print("Free open mode? Opening needs NO")
    print("password, but CLOSING does.")
    write("Enable? (y/n): ")
    local c = read()
    config.freeOpen = (c == "y" or c == "Y")

    config.outputSide = askSide(
        "Redstone output side (front/back/left/right/top/bottom): ", false)

    write("Auto-close time after proximity open (seconds): ")
    config.openTime = tonumber(read()) or 5

    write("Proximity range in blocks (0 = disable): ")
    config.proximityRange = tonumber(read()) or 0

    config.inputSide = askSide(
        "Redstone input side for a plate (or 'none'): ", true)

    saveConfig()
    print("")
    print("Setup saved!")
    print("This computer ID: " .. os.getComputerID())
    print("Write it down - it is the door address.")
    sleep(4)
end

-- ===== Modem =====
local function openModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            local ok, wireless = pcall(peripheral.call, side, "isWireless")
            if ok and wireless then
                rednet.open(side)
                return true
            end
        end
    end
    return false
end

-- ===== Door state =====
-- openUntil: moment to auto-close, or math.huge = stays open
-- until someone sends "close"
local doorOpen  = false
local openUntil = 0

-- forward declaration, the monitor UI is defined below
local refreshMonitors = function() end

local function setDoor(open)
    doorOpen = open
    local ok = pcall(redstone.setOutput, config.outputSide, open)
    if not ok then
        print("WARNING: bad redstone output side '" ..
            tostring(config.outputSide) .. "' - check your config!")
    end
    refreshMonitors()
end

-- timed open: used by proximity / pressure plate only
local function openDoorTimed()
    openUntil = math.max(openUntil, os.clock() + config.openTime)
    if not doorOpen then setDoor(true) end
end

-- permanent open: used by tablet / terminals / monitor PIN pad
local function openDoorHold()
    openUntil = math.huge
    if not doorOpen then setDoor(true) end
end

local function closeDoor()
    openUntil = 0
    if doorOpen then setDoor(false) end
end

-- ===== Touch monitor UI (any number of Advanced Monitors) =====
-- compact layout sized for 16x12 chars at text scale 0.5
local monitors = {}
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
        local mon = peripheral.wrap(name)
        mon.setTextScale(0.5)
        table.insert(monitors, mon)
    end
end

local pinState   = nil    -- nil = main screen, string = PIN being entered
local pinPurpose = "open" -- what the PIN pad will do: "open" or "close"
local PIN_MAX    = 8

local function forEachMonitor(fn)
    for _, mon in ipairs(monitors) do
        pcall(fn, mon)
    end
end

local function monCenter(mon, y, text, fg)
    local w = mon.getSize()
    mon.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
    if fg then mon.setTextColor(fg) end
    mon.write(text)
    mon.setTextColor(colors.white)
end

local function monButton(mon, x1, y1, x2, y2, color, label)
    mon.setBackgroundColor(color)
    for yy = y1, y2 do
        mon.setCursorPos(x1, yy)
        mon.write(string.rep(" ", x2 - x1 + 1))
    end
    local tx = x1 + math.max(0, math.floor((x2 - x1 + 1 - #label) / 2))
    local ty = y1 + math.floor((y2 - y1) / 2)
    mon.setCursorPos(tx, ty)
    mon.write(label)
    mon.setBackgroundColor(colors.black)
end

local function drawMainOn(mon)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    monCenter(mon, 1, "DOOR CONTROL")
    if doorOpen then
        monCenter(mon, 2, "Status: OPEN", colors.lime)
    else
        monCenter(mon, 2, "Status: CLOSED", colors.red)
    end

    -- left half = OPEN, right half = CLOSE, rows 4..bottom
    local mid = math.floor(w / 2)
    monButton(mon, 1, 4, mid - 1, h, colors.green, "OPEN")
    monButton(mon, mid + 1, 4, w, h, colors.red, "CLOSE")
end

local function drawPinPadOn(mon)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    monCenter(mon, 1, "PIN TO " .. string.upper(pinPurpose))
    -- PIN display doubles as a CANCEL zone (tap it to go back)
    monCenter(mon, 2, "[" .. string.rep("*", #pinState) .. "]", colors.yellow)

    local keys = {
        { "1", "2", "3" },
        { "4", "5", "6" },
        { "7", "8", "9" },
        { "C", "0", "OK" },
    }
    local cellW = math.floor(w / 3)
    local cellH = math.max(1, math.floor((h - 3) / 4))
    for r, row in ipairs(keys) do
        for c, key in ipairs(row) do
            local x1 = (c - 1) * cellW + 1
            local y1 = 4 + (r - 1) * cellH
            local x2 = (c == 3) and w or (c * cellW)
            local y2 = math.min(h, y1 + cellH - 1)
            local color = colors.gray
            if key == "OK" then color = colors.green end
            if key == "C"  then color = colors.orange end
            monButton(mon, x1, y1, x2, y2, color, key)
        end
    end
end

local function drawAll()
    if pinState == nil then
        forEachMonitor(drawMainOn)
    else
        forEachMonitor(drawPinPadOn)
    end
end

local function monFlash(text, color)
    forEachMonitor(function(mon)
        mon.setBackgroundColor(colors.black)
        mon.clear()
        local _, h = mon.getSize()
        monCenter(mon, math.max(1, math.floor(h / 2)), text, color)
    end)
    sleep(1.5)
end

local function handleMainTouch(x, y)
    local w = monitors[1].getSize()
    local mid = math.floor(w / 2)
    if y < 4 then return end

    if x < mid then
        -- OPEN
        if config.freeOpen then
            openDoorHold() -- free open: no PIN needed
            monFlash("OPENED", colors.lime)
            drawAll()
        else
            pinPurpose = "open"
            pinState = ""
            drawAll()
        end
    elseif x > mid then
        -- CLOSE
        if config.freeOpen then
            pinPurpose = "close" -- closing is protected in free open mode
            pinState = ""
            drawAll()
        else
            closeDoor() -- no password needed
            monFlash("CLOSED", colors.red)
            drawAll()
        end
    end
end

local function handlePinTouch(x, y)
    -- tapping the PIN display cancels the entry
    if y <= 2 then
        pinState = nil
        drawAll()
        return
    end

    local w, h = monitors[1].getSize()
    local cellW = math.floor(w / 3)
    local cellH = math.max(1, math.floor((h - 3) / 4))
    local col = math.min(3, math.floor((x - 1) / cellW) + 1)
    local row = math.floor((y - 4) / cellH) + 1
    if row < 1 or row > 4 then return end

    local keys = {
        { "1", "2", "3" },
        { "4", "5", "6" },
        { "7", "8", "9" },
        { "C", "0", "OK" },
    }
    local key = keys[row][col]

    if key == "C" then
        pinState = ""
        drawAll()
    elseif key == "OK" then
        if pinState == config.password then
            if pinPurpose == "open" then
                openDoorHold()
                monFlash("ACCESS GRANTED", colors.lime)
            else
                closeDoor()
                monFlash("CLOSED", colors.red)
            end
        else
            monFlash("WRONG PIN", colors.red)
        end
        pinState = nil
        drawAll()
    elseif #pinState < PIN_MAX then
        pinState = pinState .. key
        drawAll()
    end
end

-- called by setDoor so the status line stays up to date
refreshMonitors = function()
    if #monitors > 0 and pinState == nil then
        forEachMonitor(function(mon) pcall(drawMainOn, mon) end)
    end
end

local function monitorLoop()
    if #monitors == 0 then
        -- no monitors attached: just idle forever
        while true do sleep(3600) end
    end
    drawAll()
    while true do
        local _, _, x, y = os.pullEvent("monitor_touch")
        if pinState == nil then
            handleMainTouch(x, y)
        else
            handlePinTouch(x, y)
        end
    end
end

-- ===== Rednet loop: remote control (tablet / door terminals) =====
local function rednetLoop()
    rednet.host(PROTOCOL, "door_" .. os.getComputerID())
    while true do
        local id, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            if msg.command == "open" then
                -- free open mode: no password needed to open
                if config.freeOpen or msg.password == config.password then
                    openDoorHold() -- stays open until someone closes it
                    rednet.send(id, { status = "ok" }, PROTOCOL)
                else
                    rednet.send(id, { status = "denied" }, PROTOCOL)
                end
            elseif msg.command == "close" then
                -- free open mode: closing REQUIRES the password
                if config.freeOpen and msg.password ~= config.password then
                    rednet.send(id, { status = "denied" }, PROTOCOL)
                else
                    closeDoor()
                    rednet.send(id, { status = "ok" }, PROTOCOL)
                end
            end
        end
    end
end

-- ===== Proximity loop: auto open (timed) when a player is near =====
local function proximityLoop()
    local detector = peripheral.find("playerDetector") -- Advanced Peripherals (optional)
    while true do
        if config.proximityRange > 0 and detector then
            local ok, players = pcall(detector.getPlayersInRange, config.proximityRange)
            if ok and type(players) == "table" and #players > 0 then
                openDoorTimed()
            end
        end
        if config.inputSide ~= "none" then
            local ok, active = pcall(redstone.getInput, config.inputSide)
            if ok and active then
                openDoorTimed()
            end
        end
        sleep(0.5)
    end
end

-- ===== Door timer: closes only TIMED (proximity) opens =====
local function doorLoop()
    while true do
        if doorOpen and os.clock() >= openUntil then
            setDoor(false)
        end
        sleep(0.1)
    end
end

-- ===== Main =====
if not loadConfig() then
    setupWizard()
end

if not openModem() then
    print("ERROR: no wireless modem attached!")
    return
end

term.clear()
term.setCursorPos(1, 1)
print("Door controller online.")
print("Computer ID (door address): " .. os.getComputerID())
print("Touch monitors found: " .. #monitors)
if config.freeOpen then
    print("Mode: free open (closing needs password)")
else
    print("Mode: normal (opening needs password)")
end

parallel.waitForAny(rednetLoop, proximityLoop, doorLoop, monitorLoop)
