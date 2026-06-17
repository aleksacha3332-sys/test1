-- ============================================================================
--  QUADCOPTER FOR CREATE: AVIONICS
--  Auto-detects propeller control method, English output
-- ============================================================================

-- ===== SETTINGS (CHANGE TO YOUR DEVICE NAMES) =====
local PROPS = {
    FL = "propeller_bearing_0",   -- front left
    FR = "propeller_bearing_1",   -- front right
    BL = "propeller_bearing_2",   -- back left
    BR = "propeller_bearing_3"    -- back right
}
local GIMBAL = "gimbal_sensor_0"
local ALT = "altitude_sensor_0"
local MONITOR = "monitor_0"

-- Redstone sides for the 4 analog inputs (0-15) from your controller
local SIDE_FORWARD = "front"   -- signal when tilting forward
local SIDE_BACKWARD = "back"   -- signal when tilting backward
local SIDE_LEFT = "left"       -- signal when tilting left
local SIDE_RIGHT = "right"     -- signal when tilting right

-- Max tilt angle in degrees (when stick is fully deflected)
local MAX_ANGLE = 30

-- Dead zone for normalized deflection (0.05 = 5%)
local DEAD_ZONE = 0.05

-- PID coefficients (tune for your drone)
local PID = {
    pitch = { P = 2.0, D = 0.5 },
    roll  = { P = 2.0, D = 0.5 },
    alt   = { P = 1.0, D = 0.2 }
}

-- Base thrust for hovering (adjust experimentally)
local BASE_THRUST = 0.55
-- ============================================================

-- Helper functions
local function clamp(val, min, max)
    return math.max(min, math.min(max, val))
end

-- Safe peripheral wrapping with error message in English
local function safeWrap(name)
    local p = peripheral.wrap(name)
    if not p then
        error("Device not found: " .. name)
    end
    return p
end

-- ---- Connect peripherals ----
local fl = safeWrap(PROPS.FL)
local fr = safeWrap(PROPS.FR)
local bl = safeWrap(PROPS.BL)
local br = safeWrap(PROPS.BR)
local gimbal = safeWrap(GIMBAL)
local altSensor = safeWrap(ALT)
local monitor = peripheral.wrap(MONITOR)

if monitor then
    monitor.setTextScale(0.5)
    monitor.clear()
end

print("=== All devices found ===")

-- ---- Auto-detect method for setting propeller thrust ----
local function getPropellerControlMethod(prop)
    -- List of possible method names to set thrust/power/speed
    local candidates = {"setThrust", "setSpeed", "setPower", "setTargetThrust", "setThrustPercent", "set"}
    for _, method in ipairs(candidates) do
        if prop[method] and type(prop[method]) == "function" then
            -- Test with a dummy call to see if it works
            local success, err = pcall(function() prop[method](prop, true, 0.5) end)
            if success then
                return method
            end
            -- Try without the boolean parameter (some may accept just a number)
            success, err = pcall(function() prop[method](prop, 0.5) end)
            if success then
                return method, false   -- second return indicates no boolean needed
            end
        end
    end
    error("No recognized control method found for propeller: " .. tostring(prop))
end

-- ---- Prepare control functions for each propeller ----
local function makeSetFunction(prop)
    local method, needsBool = getPropellerControlMethod(prop)
    return function(value)
        if needsBool == false then
            prop[method](prop, value)
        else
            prop[method](prop, true, value)   -- assume boolean first param
        end
    end
end

local setFL = makeSetFunction(fl)
local setFR = makeSetFunction(fr)
local setBL = makeSetFunction(bl)
local setBR = makeSetFunction(br)

print("Propeller control methods detected successfully.")

-- ---- Safe altitude reading ----
local function getAltitudeSafe()
    local possibleMethods = {"getAltitude", "getAltitudeData", "getAlt", "getHeight"}
    for _, method in ipairs(possibleMethods) do
        local success, result = pcall(function()
            return altSensor[method]()
        end)
        if success and type(result) == "table" and result.altitude ~= nil then
            return result
        end
    end
    print("Warning: failed to get altitude. Using dummy (0 m).")
    return { altitude = 0, verticalSpeed = 0 }
end

-- ---- Safe gimbal angles reading ----
local function getGimbalAnglesSafe()
    local methods = {"getAngles", "getData", "getEuler", "getAngle"}
    for _, method in ipairs(methods) do
        local success, result = pcall(function()
            return gimbal[method]()
        end)
        if success and type(result) == "table" then
            if result.pitch ~= nil and result.roll ~= nil then
                return result
            end
            if result.pitchAngle ~= nil and result.rollAngle ~= nil then
                return { pitch = result.pitchAngle, roll = result.rollAngle }
            end
            if #result >= 2 then
                return { pitch = result[1] or 0, roll = result[2] or 0 }
            end
        end
    end
    print("Warning: failed to get gimbal angles. Using zeros.")
    return { pitch = 0, roll = 0 }
end

-- ---- PID state variables ----
local prevErrPitch = 0
local prevErrRoll = 0
local prevErrAlt = 0
local targetAlt = nil   -- set on first valid measurement

-- ---- FPS counter ----
local lastTime = os.clock()
local frameCount = 0
local fps = 0
local fpsTimer = lastTime

print("Autopilot started. Use joystick!")

-- ===== MAIN LOOP =====
while true do
    local now = os.clock()
    local dt = now - lastTime
    if dt <= 0 then dt = 0.001 end
    lastTime = now

    -- ---- Read 4 analog signals from controller (0..15) ----
    local sigFwd = redstone.getAnalogInput(SIDE_FORWARD)
    local sigBwd = redstone.getAnalogInput(SIDE_BACKWARD)
    local sigLft = redstone.getAnalogInput(SIDE_LEFT)
    local sigRgt = redstone.getAnalogInput(SIDE_RIGHT)

    -- Convert to normalized deflection [-1 .. +1]
    local netPitch = (sigFwd - sigBwd) / 15
    local netRoll  = (sigRgt - sigLft) / 15

    -- Dead zone
    if math.abs(netPitch) < DEAD_ZONE then netPitch = 0 end
    if math.abs(netRoll)  < DEAD_ZONE then netRoll  = 0 end

    -- Target angles (degrees)
    local targetPitch = netPitch * MAX_ANGLE
    local targetRoll  = netRoll  * MAX_ANGLE

    -- ---- Read sensors ----
    local altData = getAltitudeSafe()
    local altitude = altData.altitude
    local vertSpeed = altData.verticalSpeed or 0

    local gimbalData = getGimbalAnglesSafe()
    local pitch = gimbalData.pitch
    local roll  = gimbalData.roll

    -- Set target altitude on first valid reading
    if targetAlt == nil then
        if altitude > 0.1 then
            targetAlt = altitude
        else
            targetAlt = 5   -- fallback if sensor not working
            print("Altitude unknown, target set to 5 m")
        end
        print("Target altitude: " .. string.format("%.1f m", targetAlt))
    end

    -- ---- PID controllers ----
    local errPitch = targetPitch - pitch
    local errRoll  = targetRoll - roll
    local errAlt   = targetAlt - altitude

    local pPitch = PID.pitch.P * errPitch
    local dPitch = PID.pitch.D * ((errPitch - prevErrPitch) / dt)
    local outPitch = pPitch + dPitch
    prevErrPitch = errPitch

    local pRoll = PID.roll.P * errRoll
    local dRoll = PID.roll.D * ((errRoll - prevErrRoll) / dt)
    local outRoll = pRoll + dRoll
    prevErrRoll = errRoll

    local pAlt = PID.alt.P * errAlt
    local dAlt = PID.alt.D * ((errAlt - prevErrAlt) / dt)
    local outAlt = pAlt + dAlt
    prevErrAlt = errAlt

    local thrust = clamp(BASE_THRUST + outAlt, 0.2, 0.9)

    -- ---- Mixer (X-configuration) ----
    local powerFL = clamp(thrust + outRoll - outPitch, 0, 1)
    local powerFR = clamp(thrust - outRoll - outPitch, 0, 1)
    local powerBL = clamp(thrust + outRoll + outPitch, 0, 1)
    local powerBR = clamp(thrust - outRoll + outPitch, 0, 1)

    -- ---- Send motor commands in parallel (using auto-detected methods) ----
    parallel.waitForAll(
        function() setFL(powerFL) end,
        function() setFR(powerFR) end,
        function() setBL(powerBL) end,
        function() setBR(powerBR) end
    )

    -- ---- Display on monitor ----
    if monitor then
        monitor.clear()
        monitor.setCursorPos(1,1)
        monitor.write("=== QUADCOPTER STATUS ===")
        monitor.setCursorPos(1,2)
        monitor.write(string.format("Pitch: % 6.1f° (target % 6.1f°)", pitch, targetPitch))
        monitor.setCursorPos(1,3)
        monitor.write(string.format("Roll:  % 6.1f° (target % 6.1f°)", roll, targetRoll))
        monitor.setCursorPos(1,4)
        monitor.write(string.format("Alt: % 6.1fm  VSpd: % 5.1f m/s", altitude, vertSpeed))
        monitor.setCursorPos(1,5)
        monitor.write("--- Motor Powers ---")
        monitor.setCursorPos(1,6)
        monitor.write(string.format("FL: %5.1f%%  FR: %5.1f%%", powerFL*100, powerFR*100))
        monitor.setCursorPos(1,7)
        monitor.write(string.format("BL: %5.1f%%  BR: %5.1f%%", powerBL*100, powerBR*100))
        monitor.setCursorPos(1,8)
        monitor.write(string.format("Stick: F%d B%d  L%d R%d", sigFwd, sigBwd, sigLft, sigRgt))
        monitor.setCursorPos(1,9)
        monitor.write(string.format("Net: P%+.2f R%+.2f", netPitch, netRoll))
        monitor.setCursorPos(1,10)
        monitor.write(string.format("FPS: %d", fps))
    end

    -- ---- FPS counter ----
    frameCount = frameCount + 1
    if now - fpsTimer >= 1 then
        fps = frameCount
        frameCount = 0
        fpsTimer = now
    end

    sleep(0.01)
end
