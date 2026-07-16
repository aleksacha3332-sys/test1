-- dual_barrel_guard.lua
-- Monitors two fluid barrels, manages redstone signals and sounds alarms.
-- Works even if computer.beep is unavailable.

-- ===== CONFIGURATION =====
local tanksConfig = {
    {
        name = "create:fluid_tank_0",   -- change to your peripheral name
        side = "left",
        highThreshold = 15,             -- buckets
        lowThreshold  = 5
    },
    {
        name = "create:fluid_tank_1",
        side = "right",
        highThreshold = 15,
        lowThreshold  = 5
    }
}

local globalHigh = 15
local globalLow  = 5
local checkInterval = 1.0

-- Sound settings
local beepFreq = 880      -- Hz
local beepDur  = 0.3      -- seconds
local beepInterval = 2.0  -- seconds between beeps

-- Monitor side (set to nil if no monitor)
local monitorSide = "top"

-- Rednet chat broadcast (optional)
local useRednet = false
local rednetChannel = 1
-- ==========================

-- Safe sound function
local function playAlertSound()
    -- Try computer.beep first
    if computer and computer.beep then
        computer.beep(beepFreq, beepDur)
        return
    end
    -- Try a speaker peripheral
    local speaker = peripheral.find("speaker")
    if speaker then
        speaker.playSound("block.note_block.pling", 1, beepFreq / 1000)
        return
    end
    -- Fallback: just print (no actual sound)
    print("[ALERT SOUND] BEEP (sound hardware unavailable)")
end

-- Helper: wrap monitor
local monitor = nil
if monitorSide then
    monitor = peripheral.wrap(monitorSide)
    if monitor then
        monitor.clear()
        monitor.setTextScale(0.5)
    else
        print("Monitor not found on side " .. monitorSide)
    end
end

local function writeMonitor(lines)
    if not monitor then return end
    monitor.clear()
    for i, line in ipairs(lines) do
        monitor.setCursorPos(1, i)
        monitor.write(line or "")
    end
end

-- Get fluid in mB
local function getTotalFluidMB(tankPeripheral)
    if not tankPeripheral or not tankPeripheral.tanks then return nil end
    local tanks = tankPeripheral.tanks()
    if not tanks or #tanks == 0 then return nil end
    local total = 0
    for _, tank in ipairs(tanks) do
        if tank then
            local amount = tank.amount or tank.stored or tank.fluidAmount or 0
            if type(amount) == "table" then amount = amount.amount or 0 end
            total = total + amount
        end
    end
    return total
end

-- Initialize tanks
local tanks = {}
for i, cfg in ipairs(tanksConfig) do
    local p = peripheral.wrap(cfg.name)
    if p and p.tanks then
        tanks[i] = {
            peripheral = p,
            config = cfg,
            side = cfg.side,
            high = cfg.highThreshold or globalHigh,
            low  = cfg.lowThreshold or globalLow,
            name = cfg.name,
            levelMB = nil,
            levelBuckets = nil,
            status = "unknown"
        }
        print("Connected to tank: " .. cfg.name)
    else
        print("ERROR: Tank not found: " .. cfg.name)
        tanks[i] = nil
    end
end

local validTanks = {}
for _, t in ipairs(tanks) do
    if t then table.insert(validTanks, t) end
end
tanks = validTanks

if #tanks == 0 then
    print("No valid tanks found. Exiting.")
    return
end

if useRednet then
    local modem = peripheral.find("modem")
    if modem then
        rednet.open(modem)
        print("Rednet opened on channel " .. rednetChannel)
    else
        print("Warning: Rednet enabled but no modem found.")
        useRednet = false
    end
end

print("Monitoring started. Press Ctrl+T to stop.")

local lowAlertActive = false
local lastBeepTime = 0
local lowTanksList = {}

while true do
    local anyLow = false
    local highCount = 0
    local highTankSide = nil

    for _, tank in ipairs(tanks) do
        local mb = getTotalFluidMB(tank.peripheral)
        if mb == nil then
            tank.levelMB = nil
            tank.levelBuckets = nil
            tank.status = "error"
        else
            tank.levelMB = mb
            tank.levelBuckets = mb / 1000
            if tank.levelBuckets < tank.low then
                tank.status = "low"
                anyLow = true
                table.insert(lowTanksList, tank.name .. " (" .. string.format("%.2f", tank.levelBuckets) .. " b)")
            elseif tank.levelBuckets > tank.high then
                tank.status = "high"
                highCount = highCount + 1
                highTankSide = tank.side
            else
                tank.status = "normal"
            end
        end
    end

    -- Redstone logic: signal on the side of the single high tank
    for _, tank in ipairs(tanks) do
        local shouldSignal = (highCount == 1 and tank.status == "high")
        redstone.setOutput(tank.side, shouldSignal)
    end

    -- Low-level alert
    if anyLow then
        local now = os.clock()
        if now - lastBeepTime >= beepInterval then
            playAlertSound()
            lastBeepTime = now
        end
        if not lowAlertActive then
            local msg = "LOW LEVEL ALERT: " .. table.concat(lowTanksList, ", ")
            print(msg)
            if useRednet then
                rednet.broadcast(msg, rednetChannel)
            end
            lowAlertActive = true
        end
    else
        if lowAlertActive then
            print("Low level alert cleared.")
            if useRednet then
                rednet.broadcast("Low level alert cleared.", rednetChannel)
            end
            lowAlertActive = false
        end
        lowTanksList = {}
    end

    -- Monitor display
    local lines = {}
    lines[1] = "=== Dual Barrel Guard ==="
    local i = 2
    for _, tank in ipairs(tanks) do
        local statusText = ""
        if tank.status == "low" then
            statusText = "LOW  <---"
        elseif tank.status == "high" then
            statusText = "HIGH  --->"
        elseif tank.status == "normal" then
            statusText = "OK"
        else
            statusText = "ERROR"
        end
        local levelStr = tank.levelBuckets and string.format("%.2f b", tank.levelBuckets) or "N/A"
        lines[i] = tank.name .. ": " .. levelStr .. "  " .. statusText
        i = i + 1
    end
    lines[i] = "Redstone: " .. (highCount == 1 and ("ON on " .. highTankSide) or "OFF")
    lines[i+1] = "Alert: " .. (lowAlertActive and "ACTIVE" or "OK")
    lines[i+2] = "Time: " .. os.date("%H:%M:%S")

    if monitor then
        writeMonitor(lines)
    end

    print(string.format("[%s] High: %d, Low: %s", os.date("%H:%M:%S"), highCount, anyLow and "YES" or "NO"))

    sleep(checkInterval)
end

-- Cleanup
print("Program stopped.")
if monitor then monitor.clear() monitor.setCursorPos(1,1) monitor.write("Stopped") end
if useRednet then rednet.close() end
