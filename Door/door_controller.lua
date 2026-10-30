--[[
  Door Controller (server part)
  ComputerCraft: Tweaked / Minecraft 1.21.1
  - Receives open-requests from the tablet via rednet
  - Opens the door automatically when a player comes close
    (Player Detector from Advanced Peripherals, or a redstone
    input like a pressure plate)
  - Closes the door after a timeout
]]

local CONFIG_FILE = "door_config.cfg"
local PROTOCOL    = "door_control"

-- ===== Default settings (overwritten by setup wizard) =====
local config = {
    password       = "1234",  -- access password
    outputSide     = "back",  -- redstone output side to the door
    openTime       = 5,       -- seconds the door stays open
    proximityRange = 4,       -- blocks for the player detector (0 = off)
    inputSide      = "none",  -- redstone input side for a plate ("none" = off)
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
local function setupWizard()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Door Controller Setup ===")
    print("")

    write("Door password: ")
    config.password = read()

    write("Redstone output side (front/back/left/right/top/bottom): ")
    config.outputSide = read()

    write("Door open time in seconds: ")
    config.openTime = tonumber(read()) or 5

    write("Proximity range in blocks (0 = disable): ")
    config.proximityRange = tonumber(read()) or 0

    write("Redstone input side for a plate (or 'none'): ")
    config.inputSide = read()

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
local doorOpen  = false
local openUntil = 0

local function setDoor(open)
    doorOpen = open
    redstone.setOutput(config.outputSide, open)
end

local function openDoor()
    openUntil = os.clock() + config.openTime
    if not doorOpen then setDoor(true) end
end

-- ===== Rednet loop: remote control from the tablet =====
local function rednetLoop()
    rednet.host(PROTOCOL, "door_" .. os.getComputerID())
    while true do
        local id, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" and msg.command == "open" then
            if msg.password == config.password then
                openDoor()
                rednet.send(id, { status = "ok" }, PROTOCOL)
            else
                rednet.send(id, { status = "denied" }, PROTOCOL)
            end
        end
    end
end

-- ===== Proximity loop: auto open when a player is near =====
local function proximityLoop()
    local detector = peripheral.find("playerDetector") -- Advanced Peripherals (optional)
    while true do
        if config.proximityRange > 0 and detector then
            local ok, players = pcall(detector.getPlayersInRange, config.proximityRange)
            if ok and type(players) == "table" and #players > 0 then
                openDoor()
            end
        end
        if config.inputSide ~= "none" and redstone.getInput(config.inputSide) then
            openDoor()
        end
        sleep(0.5)
    end
end

-- ===== Door timer: closes the door after the timeout =====
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

parallel.waitForAny(rednetLoop, proximityLoop, doorLoop)
