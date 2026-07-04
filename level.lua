-- monitor.lua - Monitor Create barrel fluid level and output redstone signal
-- Uses peripheral API to find any tank (supports modems via peripheral.find)

-- Settings
local redstoneSide = "back"   -- side to output redstone signal
local threshold = 80.0        -- trigger level in percent (0-100)
local checkInterval = 1.0     -- check interval in seconds

-- Function to get fluid level percentage from a tank peripheral
local function getBarrelLevel(peripheral)
    if not peripheral.tanks then
        return nil
    end
    local tanks = peripheral.tanks()
    if not tanks or #tanks == 0 then
        return nil
    end
    local totalAmount = 0
    local totalCapacity = 0
    for _, tank in ipairs(tanks) do
        if tank then
            totalAmount = totalAmount + (tank.amount or 0)
            totalCapacity = totalCapacity + (tank.capacity or 0)
        end
    end
    if totalCapacity == 0 then
        return 0
    end
    return (totalAmount / totalCapacity) * 100
end

-- Main function
local function main()
    print("Searching for a fluid tank peripheral...")
    -- Find any peripheral that has a 'tanks' method (Create barrel, tank, etc.)
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
        print("ERROR: No fluid tank found. Make sure CC:C Bridge is installed and tank is connected (via modem if needed).")
        return
    end

    print("Monitoring started. Threshold: " .. threshold .. "%")
    print("Press Ctrl+T to stop.")

    local signalActive = false

    while true do
        local level = getBarrelLevel(barrel)
        if level == nil then
            print("ERROR: Failed to get fluid level.")
            break
        end

        local shouldSignal = level >= threshold

        if shouldSignal ~= signalActive then
            if shouldSignal then
                print(string.format("Threshold reached! Level: %.1f%%", level))
            else
                print(string.format("Level dropped below threshold: %.1f%%", level))
            end
            redstone.setOutput(redstoneSide, shouldSignal)
            signalActive = shouldSignal
        end

        sleep(checkInterval)
    end

    redstone.setOutput(redstoneSide, false)
    print("Program stopped.")
end

main()
