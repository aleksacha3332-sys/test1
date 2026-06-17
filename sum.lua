-- ============================================================================
--  QUADCOPTER WITH ROTATION SPEED CONTROLLERS (FIXED)
--  Uses the correct method 'setTargetSpeed' as per the official wiki.
-- ============================================================================

-- ===== SETTINGS =====
local GIMBAL = "gimbal_sensor_0"
local ALT = "altitude_sensor_0"
local MONITOR = "monitor_0"

-- Redstone sides for the 4 analog inputs (0-15) from your controller
local SIDE_FORWARD = "front"
local SIDE_BACKWARD = "back"
local SIDE_LEFT = "left"
local SIDE_RIGHT = "right"

-- Max tilt angle (degrees)
local MAX_ANGLE = 30
local DEAD_ZONE = 0.05

-- PID coefficients
local PID = {
    pitch = { P = 2.0, D = 0.5 },
    roll  = { P = 2.0, D = 0.5 },
    alt   = { P = 1.0, D = 0.2 }
}

-- Base thrust for hovering (0..1)
local BASE_THRUST = 0.55

-- Speed range (RPM) for motors
local MIN_RPM = 0
local MAX_RPM = 256
-- ============================================================

-- Helper functions
local function clamp(val, min, max)
    return math.max(min, math.min(max, val))
end

-- Safe peripheral wrapping
local function safeWrap(name)
    local p = peripheral.wrap(name)
    if not p then
        error("Device not found: " .. name)
    end
    return p
end

-- ---- Find all Create_RotationSpeedController peripherals ----
local function findControllers()
    local controllers = {}
    -- The correct type name from the wiki is "Create_RotationSpeedController"[reference:4]
    for name, obj in pairs(peripheral.find("Create_RotationSpeedController")) do
        table.insert(controllers, {name = name, obj = obj})
    end
    table.sort(controllers, function(a, b) return a.name < b.name end)
    
    if #controllers < 4 then
        error("Need at least 4 Create_RotationSpeedController, found " .. #controllers)
    end
    
    local fl = controllers[1].obj
    local fr = controllers[2].obj
    local bl = controllers[3].obj
    local br = controllers[4].obj
    
    print("Found controllers: " .. controllers[1].name .. ", " .. controllers[2].name .. ", " .. controllers[3].name .. ", " .. controllers[4].name)
    return fl, fr, bl, br
end

-- ---- Connect peripherals ----
local fl, fr, bl, br = findControllers()
local gimbal = safeWrap(GIMBAL)
local altSensor = safeWrap(ALT)
local monitor = peripheral.wrap(MONITOR)

if monitor then
    monitor.setTextScale(0.5)
    monitor.clear()
end

print("=== All devices found ===")

-- The wiki confirms the method is 'setTargetSpeed'[reference:5]
local function makeSetSpeedFunction(controller)
    return function(rpm)
        controller.setTargetSpeed(controller, rpm)
    end
end

local setSpeedFL = makeSetSpeedFunction(fl)
local setSpeedFR = makeSetSpeedFunction(fr)
local setSpeedBL = makeSetSpeedFunction(bl)
local setSpeedBR = makeSetSpeedFunction(br)

print("Speed controllers ready. Using method: setTargetSpeed")

-- ---- Safe altitude reading ----
local function getAltitudeSafe()
    local possibleMethods = {"getHeight", "getAltitude", "getAltitudeData", "getAlt"}
    for _, method in ipairs(possibleMethods) do
        local success, result = pcall(function()
            return altSensor[method]()
        end)
        if success then
            if type(result) == "number" then
                return { altitude = result, verticalSpeed = 0 }
            end
            if type(result) == "table" and result.altitude ~= nil then
                return result
            end
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

-- ---- PID state ----
local prevErrPitch = 0
local prevErrRoll = 0
local prevErrAlt = 0
local targetAlt = nil

-- ---- FPS ----
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

    -- ---- Read controller signals ----
    local sigFwd = redstone.getAnalogInput(SIDE_FORWARD)
    local sigBwd = redstone.getAnalogInput(SIDE_BACKWARD)
    local sigLft = redstone.getAnalogInput(SIDE_LEFT)
    local sigRgt = redstone.getAnalogInput(SIDE_RIGHT)

    local netPitch = (sigFwd - sigBwd) / 15
    local netRoll  = (sigRgt - sigLft) / 15

    if math.abs(netPitch) < DEAD_ZONE then netPitch = 0 end
    if math.abs(netRoll)  < DEAD_ZONE then netRoll  = 0 end

    local targetPitch = netPitch * MAX_ANGLE
    local targetRoll  = netRoll  * MAX_ANGLE

    -- ---- Read sensors ----
    local altData = getAltitudeSafe()
    local altitude = altData.altitude
    local vertSpeed = altData.verticalSpeed or 0

    local gimbalData = getGimbalAnglesSafe()
    local pitch = gimbalData.pitch
    local roll  = gimbalData.roll

    if targetAlt == nil then
        if altitude > 0.1 then
            targetAlt = altitude
        else
            targetAlt = 5
            print("Altitude unknown, target set to 5 m")
        end
        print("Target altitude: " .. string.format("%.1f m", targetAlt))
    end

    -- ---- PID ----
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

    local rpmFL = MIN_RPM + powerFL * (MAX_RPM - MIN_RPM)
    local rpmFR = MIN_RPM + powerFR * (MAX_RPM - MIN_RPM)
    local rpmBL = MIN_RPM + powerBL * (MAX_RPM - MIN_RPM)
    local rpmBR = MIN_RPM + powerBR * (MAX_RPM - MIN_RPM)

    -- ---- Send RPM commands ----
    parallel.waitForAll(
        function() setSpeedFL(rpmFL) end,
        function() setSpeedFR(rpmFR) end,
        function() setSpeedBL(rpmBL) end,
        function() setSpeedBR(rpmBR) end
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
        monitor.write("--- Motor RPM ---")
        monitor.setCursorPos(1,6)
        monitor.write(string.format("FL: %4.0f  FR: %4.0f", rpmFL, rpmFR))
        monitor.setCursorPos(1,7)
        monitor.write(string.format("BL: %4.0f  BR: %4.0f", rpmBL, rpmBR))
        monitor.setCursorPos(1,8)
        monitor.write(string.format("Stick: F%d B%d  L%d R%d", sigFwd, sigBwd, sigLft, sigRgt))
        monitor.setCursorPos(1,9)
        monitor.write(string.format("Net: P%+.2f R%+.2f", netPitch, netRoll))
        monitor.setCursorPos(1,10)
        monitor.write(string.format("FPS: %d", fps))
    end

    -- ---- FPS ----
    frameCount = frameCount + 1
    if now - fpsTimer >= 1 then
        fps = frameCount
        frameCount = 0
        fpsTimer = now
    end

    sleep(0.01)
end
