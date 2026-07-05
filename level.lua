-- monitor.lua - Monitor Create fluid barrel and show status on a monitor
-- Usage: monitor [threshold]  (e.g. monitor 75)
-- If no threshold given, uses 80%

-- === CONFIGURATION ===
local redstoneSide = "back"   -- side to output redstone signal
local checkInterval = 1.0     -- seconds between checks
-- =====================

-- Get threshold from command line argument or use default
local args = { ... }
local threshold = tonumber(args[1]) or 80.0
threshold = math.max(0, math.min(100, threshold)) -- clamp 0-100

-- Find a monitor peripheral
local monitor = nil
for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p and p.getSize then  -- it's a monitor
        monitor = p
        break
    end
end

if monitor then
    monitor.clear()
    monitor.setTextScale(0.5) -- small text to fit more info
else
    print("No monitor found. Using console only.")
end

-- Function to write to monitor (if available)
local function writeMonitor(line1, line2, line3, line4)
    if not monitor then return end
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write(line1 or "")
    monitor.setCursorPos(1, 2)
    monitor.write(line2 or "")
    monitor.setCursorPos(1, 3)
    monitor.write(line3 or "")
    monitor.setCursorPos(1, 4)
    monitor.write(line4 or "")
end

-- Function to get fluid level from a tank peripheral
local function getBarrelLevel(peripheral)
    if not peripheral.tanks then return nil end
    local tanks = peripheral.tanks()
    if not tanks or #tanks == 0 then return nil end
    local totalAmount = 0
    local totalCapacity = 0
    for _, tank in ipairs(tanks) do
        if tank then
            totalAmount = totalAmount + (tank.amount or 0)
            totalCapacity = totalCapacity + (tank.capacity or 0)
        end
    end
    if totalCapacity == 0 then return 0 end
    return (totalAmount / totalCapacity) * 100
end

-- Main loop
local function main()
    -- Find a tank peripheral (barrel, reservoir, etc.)
    local barrel = nil
    for _, name in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(name)
        if p and p.tanks then
            barrel = p
            print("Found tank: " .. name)
            break
        end
    end

    if not barrel then
        local errMsg = "ERROR: No fluid tank found. Make sure CC:C Bridge is installed and tank is connected."
        print(errMsg)
        if monitor then
            monitor.clear()
            monitor.setCursorPos(1, 1)
            monitor.write("ERROR: No tank found")
            monitor.setCursorPos(1, 2)
            monitor.write("Check CC:C Bridge")
        end
        return
    end

    print("Monitoring started. Threshold: " .. threshold .. "%")
    print("Press Ctrl+T to stop.")

    if monitor then
        writeMonitor("Barrel Monitor", "Threshold: " .. threshold .. "%", "Searching...", "")
    end

    local signalActive = false

    while true do
        local level = getBarrelLevel(barrel)
        if level == nil then
            local err = "ERROR: Failed to read tank"
            print(err)
            if monitor then writeMonitor("ERROR", "Cannot read tank", "Check connection", "") end
            break
        end

        local shouldSignal = level >= threshold

        -- Update redstone only if state changed
        if shouldSignal ~= signalActive then
            if shouldSignal then
                print(string.format("Threshold reached! Level: %.1f%%", level))
            else
                print(string.format("Level dropped below threshold: %.1f%%", level))
            end
            redstone.setOutput(redstoneSide, shouldSignal)
            signalActive = shouldSignal
        end

        -- Update monitor with current status
        local status = signalActive and "SIGNAL ON" or "signal off"
        local line1 = "Barrel Level: " .. string.format("%.1f%%", level)
        local line2 = "Threshold: " .. string.format("%.1f%%", threshold)
        local line3 = "Redstone: " .. status .. " (side: " .. redstoneSide .. ")"
        local line4 = "Signal: " .. (signalActive and "ON" or "OFF")
        if monitor then
            writeMonitor(line1, line2, line3, line4)
        end

        -- Also print to console every 5 seconds to avoid spam (but we print only on change, so it's fine)
        -- However, we can print periodically for debugging
        -- For clarity, we print every iteration but it's okay since sleep is 1s.

        sleep(checkInterval)
    end

    -- Cleanup
    redstone.setOutput(redstoneSide, false)
    print("Program stopped.")
    if monitor then
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.write("Program stopped")
    end
end

main()
