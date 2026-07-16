-- dual_barrel_guard.lua
-- Monitors two fluid barrels (tanks) and manages redstone signals and alerts.

-- ===== CONFIGURATION =====
-- Define your tanks: each entry must have:
--   name  - peripheral name (as seen by 'peripheral list')
--   side  - computer side for redstone output (e.g., "left", "right", "back")
--   (optional) highThreshold and lowThreshold in buckets; if not set, global values are used.
local tanksConfig = {
    {
        name = "create:fluid_tank_0",    -- change to your peripheral name
        side = "left",
        highThreshold = 15,              -- buckets, above this = overfilled
        lowThreshold  = 5                -- buckets, below this = too low
    },
    {
        name = "create:fluid_tank_1",
        side = "right",
        highThreshold = 15,
        lowThreshold  = 5
    }
}

-- Global thresholds (used if not defined per tank)
local globalHigh = 15   -- buckets
local globalLow  = 5    -- buckets

-- Check interval (seconds)
local checkInterval = 1.0

-- Sound settings (for low-level alert)
local beepFreq = 880       -- Hz
local beepDur  = 0.3       -- seconds
local beepInterval = 2.0   -- seconds between beeps while alert active

-- Monitor side (set to nil if no monitor)
local monitorSide = "top"   -- or "left", "right", etc.

-- Rednet chat broadcast (optional) – set to true if you have a modem and want to send messages to chat
local useRednet = false
local rednetChannel = 1     -- channel to broadcast on
-- ==========================

-- Helper: wrap monitor if available
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

-- Get total fluid in mB from a tank peripheral
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
            status = "unknown" -- "low", "normal", "high"
        }
        print("Connected to tank: " .. cfg.name)
    else
        print("ERROR: Tank not found: " .. cfg.name)
        tanks[i] = nil
    end
end

-- Remove nil entries (if any tank not found)
local validTanks = {}
for _, t in ipairs(tanks) do
    if t then table.insert(validTanks, t) end
end
tanks = validTanks

if #tanks == 0 then
    print("No valid tanks found. Exiting.")
    return
end

-- Initialize rednet if requested
if useRednet then
    if not peripheral.find("modem") then
        print("Warning: Rednet enabled but no modem found.")
        useRednet = false
    else
        rednet.open(peripheral.find("modem"))
        print("Rednet opened on channel " .. rednetChannel)
    end
end

print("Monitoring started. Press Ctrl+T to stop.")

-- Alert state
local lowAlertActive = false
local lastBeepTime = 0
local lowTanksList = {}  -- list of tank names that are low

-- Main loop
while true do
    local anyLow = false
    local highCount = 0
    local highTankSide = nil  -- side of the single high tank

    -- Read each tank and determine status
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

    -- Determine redstone actions
    -- If exactly one tank is high -> signal on that side, off on the other
    -- If 0 or 2 high -> turn off both
    for _, tank in ipairs(tanks) do
        local shouldSignal = (highCount == 1 and tank.status == "high")
        redstone.setOutput(tank.side, shouldSignal)
    end

    -- Determine low-level alert
    local shouldAlert = anyLow
    if shouldAlert then
        local now = os.clock()
        if now - lastBeepTime >= beepInterval then
            computer.beep(beepFreq, beepDur)
            lastBeepTime = now
        end
        if not lowAlertActive then
            -- Alert just started: print message
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

    -- Prepare monitor display
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

    -- Console summary (only every cycle)
    print(string.format("[%s] High: %d, Low: %s", os.date("%H:%M:%S"), highCount, anyLow and "YES" or "NO"))

    sleep(checkInterval)
end

-- Cleanup (on Ctrl+T)
print("Program stopped.")
if monitor then monitor.clear() monitor.setCursorPos(1,1) monitor.write("Stopped") end
if useRednet then rednet.close() end
