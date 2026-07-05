-- monitor.lua - Monitor Create barrel fluid amount in buckets and output redstone
-- Usage: monitor [thresholdInBuckets]   e.g. monitor 15  (threshold = 15 buckets)
-- If no argument, default threshold = 10 buckets

-- === CONFIGURATION ===
local redstoneSide = "back"   -- side to output redstone signal
local checkInterval = 1.0     -- seconds between checks
-- =====================

-- Get threshold from command line (in buckets)
local args = { ... }
local thresholdBuckets = tonumber(args[1]) or 10
local thresholdMB = thresholdBuckets * 1000   -- 1 bucket = 1000 mB

-- Find a monitor
local monitor = nil
for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p and p.getSize then
        monitor = p
        break
    end
end

if monitor then
    monitor.clear()
    monitor.setTextScale(0.5)
else
    print("No monitor found. Using console only.")
end

-- Helper: write to monitor (up to 4 lines)
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

-- Function to get total fluid amount in mB from a tank peripheral
local function getTotalFluidMB(peripheral)
    if not peripheral.tanks then return nil end
    local tanks = peripheral.tanks()
    if not tanks or #tanks == 0 then return nil end

    local total = 0
    -- tanks is an array of tank objects
    for _, tank in ipairs(tanks) do
        if tank then
            -- Try to get amount; field names vary
            local amount = tank.amount or tank.stored or tank.fluidAmount or 0
            -- Sometimes amount is in mB directly; sometimes it's a table with 'amount'
            if type(amount) == "table" then
                amount = amount.amount or 0
            end
            total = total + amount
        end
    end
    return total
end

-- Main loop
local function main()
    -- Find a tank (barrel, reservoir, etc.)
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
        local err = "ERROR: No fluid tank found. Install CC:C Bridge and connect tank."
        print(err)
        if monitor then
            monitor.clear()
            monitor.setCursorPos(1, 1)
            monitor.write("ERROR: No tank")
            monitor.setCursorPos(1, 2)
            monitor.write("Check CC:C Bridge")
        end
        return
    end

    -- Debug: print raw tank data once
    print("Raw tank data (for debugging):")
    local debugData = barrel.tanks()
    if debugData then
        print(textutils.serialize(debugData))
    else
        print("tanks() returned nil")
    end

    print("Monitoring started. Threshold: " .. thresholdBuckets .. " buckets (" .. thresholdMB .. " mB)")
    print("Press Ctrl+T to stop.")

    if monitor then
        writeMonitor("Barrel Monitor", "Threshold: " .. thresholdBuckets .. " buckets", "Starting...", "")
    end

    local signalActive = false

    while true do
        local totalMB = getTotalFluidMB(barrel)
        if totalMB == nil then
            local err = "ERROR: Failed to read tank data"
            print(err)
            if monitor then writeMonitor("ERROR", "Cannot read tank", "Check connection", "") end
            break
        end

        local totalBuckets = totalMB / 1000
        local shouldSignal = totalMB >= thresholdMB

        -- Update redstone only on state change
        if shouldSignal ~= signalActive then
            if shouldSignal then
                print(string.format("Threshold reached! Fluid: %.2f buckets (%.0f mB)", totalBuckets, totalMB))
            else
                print(string.format("Fluid dropped below threshold: %.2f buckets (%.0f mB)", totalBuckets, totalMB))
            end
            redstone.setOutput(redstoneSide, shouldSignal)
            signalActive = shouldSignal
        end

        -- Update monitor (and console every loop)
        local status = signalActive and "ON" or "OFF"
        local line1 = string.format("Fluid: %.2f buckets (%.0f mB)", totalBuckets, totalMB)
        local line2 = string.format("Threshold: %.2f buckets (%.0f mB)", thresholdBuckets, thresholdMB)
        local line3 = "Redstone: " .. status .. "  (side: " .. redstoneSide .. ")"
        local line4 = "Signal: " .. status

        if monitor then
            writeMonitor(line1, line2, line3, line4)
        end

        -- Also print to console periodically (every check, but it's fine)
        print(string.format("[%s] Fluid: %.2f buckets, threshold: %.2f, signal: %s", os.date("%H:%M:%S"), totalBuckets, thresholdBuckets, status))

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
