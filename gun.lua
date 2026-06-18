-- ============================================
-- Artillery Fire Control System with Ballistics
-- Uses CC:CBC (Cannon Mount) and Create Avionics
-- Speed input in m/s, gravity in m/s²
-- Monitor updates every 1 second
-- ============================================

local CONFIG = {
    cannonPeripheral = "cannon_mount_0",   -- adjust if needed
    monitorSide = "top",
    updateInterval = 20,                   -- 20 ticks = 1 second
    minPitch = -90,
    maxPitch = 90,
    gravity_mps2 = 20                     -- standard Minecraft gravity (blocks/s²)
}

-- Convert gravity to blocks/tick² (1 tick = 1/20 s)
local GRAVITY_BPT2 = CONFIG.gravity_mps2 / 400

-- ============================================
-- Peripheral initialisation
-- ============================================

local monitor = peripheral.find("monitor")
if not monitor then error("Monitor not found!") end
monitor.setTextScale(0.5)
monitor.clear()

local cannon = peripheral.find("cannon_mount")
if not cannon then error("Cannon mount not found!") end

-- Enable computer control and verify
cannon.setComputerControl(true)
local isCC = cannon.isComputerControl()
if isCC then
    print("Computer control enabled successfully.")
else
    print("WARNING: Computer control could not be enabled.")
end

local navTable = peripheral.find("navigation_table")
if navTable then print("Navigation table detected (optional)") end

-- ============================================
-- System state
-- ============================================

local state = {
    position   = { x = 0, y = 0, z = 0 },
    target     = { x = nil, y = nil, z = nil },
    currentYaw   = 0,
    currentPitch = 0,
    targetYaw    = 0,
    targetPitch  = 0,
    isAssembled  = false,
    speed_mps    = 80,                  -- user‑visible speed (m/s)
    speed_bpt    = 80 / 20,             -- internal speed (blocks/tick)
    lastUpdate   = 0
}

-- ============================================
-- Utility functions
-- ============================================

local function normalizeAngle(angle)
    angle = angle % 360
    if angle > 180 then angle = angle - 360
    elseif angle < -180 then angle = angle + 360 end
    return angle
end

local function clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

local function getDistance(p1, p2)
    local dx = p1.x - p2.x
    local dy = p1.y - p2.y
    local dz = p1.z - p2.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

local function getHorizontalDist(p1, p2)
    local dx = p1.x - p2.x
    local dz = p1.z - p2.z
    return math.sqrt(dx*dx + dz*dz)
end

local function calculateYaw(from, to)
    local dx = to.x - from.x
    local dz = to.z - from.z
    local yaw = math.atan2(dx, dz) * (180 / math.pi)
    return normalizeAngle(yaw)
end

-- ============================================
-- Ballistic pitch calculation (internal units: blocks & ticks)
-- Returns pitch in degrees, or nil if target is unreachable
-- ============================================

local function calculateBallisticPitch(from, to, v_bpt, g_bpt2)
    local dx = to.x - from.x
    local dy = to.y - from.y
    local dz = to.z - from.z
    local d = math.sqrt(dx*dx + dz*dz)   -- horizontal distance
    local h = dy                         -- height difference (positive = target above)

    if d < 0.001 then
        if h > 0 then return 90 else return -90 end
    end

    local v2 = v_bpt * v_bpt
    local gd = g_bpt2 * d
    local discriminant = v2 * v2 - g_bpt2 * (g_bpt2 * d * d + 2 * h * v2)

    if discriminant < 0 then
        return nil   -- target cannot be reached with this speed
    end

    local sqrtDisc = math.sqrt(discriminant)
    local tanTheta = (v2 - sqrtDisc) / (gd)

    if tanTheta > 1e6 then tanTheta = 1e6 end
    if tanTheta < -1e6 then tanTheta = -1e6 end

    local pitchRad = math.atan(tanTheta)
    local pitchDeg = pitchRad * (180 / math.pi)
    return clamp(pitchDeg, CONFIG.minPitch, CONFIG.maxPitch)
end

-- ============================================
-- Cannon control functions
-- ============================================

local function updateCannonInfo()
    local info = cannon.getInfo()
    if info then
        state.position.x = info.x or 0
        state.position.y = info.y or 0
        state.position.z = info.z or 0
        state.currentYaw = info.yaw or 0
        state.currentPitch = info.pitch or 0
        state.isAssembled = info.assembled or false
    end
end

local function aimAtTarget()
    if not state.target.x or not state.target.y or not state.target.z then
        return false, "No target set"
    end

    local yaw = calculateYaw(state.position, state.target)
    state.targetYaw = yaw

    local pitch = calculateBallisticPitch(
        state.position,
        state.target,
        state.speed_bpt,
        GRAVITY_BPT2
    )

    if not pitch then
        return false, string.format("Target unreachable at %.1f m/s", state.speed_mps)
    end

    state.targetPitch = pitch
    cannon.setTargetAngles(yaw, pitch)
    
    -- Optional: verify that angles were applied (debug)
    -- print("Set yaw="..yaw.." pitch="..pitch)
    return true, "OK"
end

local function fire()
    if not state.isAssembled then return false, "Cannon is not assembled" end
    cannon.fire(true)
    sleep(0.1)
    cannon.fire(false)
    return true, "Fired!"
end

local function assemble(enable)
    local result = cannon.assemble(enable)
    state.isAssembled = result
    return result
end

-- ============================================
-- Monitor display (all messages in English)
-- ============================================

local function drawUI()
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextColor(colors.cyan)
    monitor.write("╔═══════════════════════════════════════╗")
    monitor.setCursorPos(1, 2)
    monitor.write("║     ARTILLERY FIRE CONTROL           ║")
    monitor.setCursorPos(1, 3)
    monitor.write("╚═══════════════════════════════════════╝")

    local line = 5

    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("STATUS:")
    line = line + 1
    monitor.setTextColor(state.isAssembled and colors.green or colors.red)
    monitor.setCursorPos(3, line)
    monitor.write("Assembled: " .. tostring(state.isAssembled))
    line = line + 1

    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("POSITION:")
    line = line + 1
    monitor.setTextColor(colors.yellow)
    monitor.setCursorPos(3, line)
    monitor.write(string.format("X: %6.1f  Y: %6.1f  Z: %6.1f",
        state.position.x, state.position.y, state.position.z))
    line = line + 1

    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("PARAMETERS:")
    line = line + 1
    monitor.setTextColor(colors.yellow)
    monitor.setCursorPos(3, line)
    monitor.write(string.format("Yaw: %7.2f°  Pitch: %5.2f°", state.currentYaw, state.currentPitch))
    line = line + 1
    monitor.setCursorPos(3, line)
    monitor.write(string.format("Speed: %5.1f m/s", state.speed_mps))
    line = line + 1

    if state.target.x then
        monitor.setTextColor(colors.green)
        monitor.setCursorPos(3, line)
        monitor.write(string.format("Target Yaw: %7.2f°", state.targetYaw))
        line = line + 1
        monitor.setCursorPos(3, line)
        monitor.write(string.format("Target Pitch: %5.2f°", state.targetPitch))
        line = line + 1

        local dist = getDistance(state.position, state.target)
        monitor.setTextColor(colors.white)
        monitor.setCursorPos(1, line)
        monitor.write("DISTANCE:")
        line = line + 1
        monitor.setTextColor(colors.lime)
        monitor.setCursorPos(3, line)
        monitor.write(string.format("%7.1f blocks", dist))
        line = line + 1
    end

    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    if state.target.x then
        monitor.write("TARGET:")
        line = line + 1
        monitor.setTextColor(colors.orange)
        monitor.setCursorPos(3, line)
        monitor.write(string.format("X: %6.1f  Y: %6.1f  Z: %6.1f",
            state.target.x, state.target.y, state.target.z))
    else
        monitor.setTextColor(colors.gray)
        monitor.write("NO TARGET SET")
    end
    line = line + 1

    monitor.setTextColor(colors.gray)
    monitor.setCursorPos(1, 20)
    monitor.write("Commands: target <x> <y> <z> | speed <m/s> | fire")
    monitor.setCursorPos(1, 21)
    monitor.write("          assemble [on/off] | status | help | exit")
end

-- ============================================
-- Command processor (all output in English)
-- ============================================

local function processCommand(input)
    if not input or input == "" then return true end

    local args = {}
    for word in input:gmatch("%S+") do table.insert(args, word) end
    if #args == 0 then return true end

    local cmd = args[1]:lower()

    if cmd == "help" then
        print("Available commands:")
        print("  target <x> <y> <z>   - set target coordinates")
        print("  speed <value>        - set projectile speed in m/s")
        print("  fire                 - fire the cannon")
        print("  assemble [on/off]    - assemble/disassemble the cannon")
        print("  status               - show current status")
        print("  exit                 - exit program")
        return true
    end

    if cmd == "target" then
        if #args < 4 then
            print("Usage: target <x> <y> <z>")
            return true
        end
        local x = tonumber(args[2])
        local y = tonumber(args[3])
        local z = tonumber(args[4])
        if not x or not y or not z then
            print("Error: coordinates must be numbers")
            return true
        end
        state.target.x = x
        state.target.y = y
        state.target.z = z

        local success, msg = aimAtTarget()
        if success then
            print("Target set: (" .. x .. ", " .. y .. ", " .. z .. ")")
            print("  Yaw: " .. string.format("%.2f", state.targetYaw) .. "°")
            print("  Pitch: " .. string.format("%.2f", state.targetPitch) .. "°")
        else
            print("Error: " .. msg)
        end
        return true
    end

    if cmd == "speed" then
        if #args < 2 then
            print("Current speed: " .. state.speed_mps .. " m/s")
            return true
        end
        local v_mps = tonumber(args[2])
        if not v_mps or v_mps <= 0 then
            print("Error: speed must be a positive number")
            return true
        end
        state.speed_mps = v_mps
        state.speed_bpt = v_mps / 20
        print("Speed set to " .. v_mps .. " m/s")
        if state.target.x then
            local success, msg = aimAtTarget()
            if not success then
                print("Warning: " .. msg)
            end
        end
        return true
    end

    if cmd == "fire" then
        local success, msg = fire()
        print(success and "OK: " .. msg or "Error: " .. msg)
        return true
    end

    if cmd == "assemble" then
        local enable
        if #args >= 2 then
            if args[2] == "on" or args[2] == "true" or args[2] == "1" then
                enable = true
            elseif args[2] == "off" or args[2] == "false" or args[2] == "0" then
                enable = false
            else
                print("Usage: assemble [on/off]")
                return true
            end
        else
            enable = not state.isAssembled
        end
        local result = assemble(enable)
        print(result and "Cannon " .. (enable and "assembled" or "disassembled") or "Error")
        return true
    end

    if cmd == "status" then
        print("=== SYSTEM STATUS ===")
        print(string.format("Position: (%.1f, %.1f, %.1f)", state.position.x, state.position.y, state.position.z))
        print(string.format("Angles: Yaw=%.2f°, Pitch=%.2f°", state.currentYaw, state.currentPitch))
        print("Assembled: " .. tostring(state.isAssembled))
        print("Speed: " .. state.speed_mps .. " m/s")
        if state.target.x then
            print(string.format("Target: (%.1f, %.1f, %.1f)", state.target.x, state.target.y, state.target.z))
            print("Distance: " .. string.format("%.1f", getDistance(state.position, state.target)))
        else
            print("Target: not set")
        end
        return true
    end

    if cmd == "exit" then
        print("Shutting down...")
        cannon.setComputerControl(false)
        return false
    end

    print("Unknown command. Type 'help' for list.")
    return true
end

-- ============================================
-- Main loop
-- ============================================

print("=== Artillery Fire Control System ===")
print("Type 'help' for commands")
print("")

local running = true
local tick = 0

while running do
    updateCannonInfo()

    tick = tick + 1
    if tick >= CONFIG.updateInterval then
        tick = 0
        drawUI()
    end

    local event, key = os.pullEvent("key")
    if event == "key" and key == keys.enter then
        write("> ")
        local cmd = read()
        if cmd then
            running = processCommand(cmd)
        end
    end
end

cannon.setComputerControl(false)
print("Program terminated.")
