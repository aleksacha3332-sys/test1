-- Tank Cannon Controller
-- For CC:Tweaked, CC:CBC and a sublevel_sensor on a moving structure.
-- Tested design target: Minecraft 1.21.1.
-- Ballistic model adapted from:
-- https://github.com/Malex21/CreateBigCannons-BallisticCalculator
-- Original formula credit: sashafiesta and Malex21.
-- Angles use degrees, distances use blocks and time uses game ticks.

local CONFIG = {
    sensorType = "sublevel_sensor",
    mountType = "cannon_mount",

    -- Change these two values to match the loaded cannon.
    barrelLength = 5,
    powderCharges = 4,

    -- Direction of the unrotated cannon relative to the structure:
    -- "forward", "right", "back" or "left".
    baseForward = "forward",

    -- World position used as the ballistic origin:
    -- "auto" detects local mount coordinates, "mount" trusts CC:CBC,
    -- and "sensor" always uses the structure position plus cannonOffset.
    positionSource = "auto",
    mountPositionMismatch = 128,
    cannonOffset = { forward = 0, up = 0, right = 0 },

    -- Ballistic search limits in world space.
    worldPitchMin = -30,
    worldPitchMax = 60,

    -- Physical mount limits in local mount space.
    mountPitchMin = -30,
    mountPitchMax = 60,

    -- Calibration offsets. Keep these at zero for a standard CBC mount.
    yawOffset = 0,
    pitchOffset = 0,
    invertYaw = false,
    invertPitch = false,

    -- CBC ballistic constants.
    speedPerCharge = 2,
    drag = 0.99,
    gravity = 0.05,
    fuzeOffset = -10,
    maxAirTime = 100000,

    -- Solver quality. More samples give better accuracy but cost more time.
    coarseSamples = 91,
    refinementSamples = 21,
    refinementPasses = 4,
    minimumPrecision = 85,

    -- Aiming and firing.
    yawLimit = 10,
    yawTolerance = 0.20,
    pitchTolerance = 0.20,
    stableUpdatesRequired = 3,
    trackInterval = 0.35,
    firePulseTicks = 2,
    autoFireCooldown = 3,
    autoAssemble = true,

    -- A speaker plays this sound once after a stable aim is acquired.
    aimSoundEnabled = true,
    aimSound = "minecraft:entity.player.levelup",
    aimSoundVolume = 3,
    aimSoundPitch = 1,

    -- An attached monitor and speaker are optional.
    useMonitor = true,
}

local sensor = peripheral.find(CONFIG.sensorType)
local mount = peripheral.find(CONFIG.mountType)
local monitor = CONFIG.useMonitor and peripheral.find("monitor") or nil
local speaker = CONFIG.aimSoundEnabled and peripheral.find("speaker") or nil

if not sensor then
    error("No " .. CONFIG.sensorType .. " peripheral found", 0)
end
if not mount then
    error("No " .. CONFIG.mountType .. " peripheral found", 0)
end

local state = {
    running = true,
    tracking = false,
    armed = false,
    autoFire = false,
    target = nil,
    arc = "low",
    solutions = nil,
    solution = nil,
    info = nil,
    sensorData = nil,
    cannonPosition = nil,
    positionSourceUsed = "mount",
    positionNotice = nil,
    initialYaw = nil,
    aimAnnounced = false,
    lastError = nil,
    lastNotice = nil,
    stableUpdates = 0,
    lastFireTime = -math.huge,
}

local PI = math.pi
local RAD = PI / 180
local DEG = 180 / PI

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function wrapYaw(value)
    value = value % 360
    if value < 0 then
        value = value + 360
    end
    return value
end

local function angleDifference(a, b)
    return (a - b + 180) % 360 - 180
end

local function atan2(y, x)
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 and y >= 0 then
        return math.atan(y / x) + PI
    elseif x < 0 and y < 0 then
        return math.atan(y / x) - PI
    elseif x == 0 and y > 0 then
        return PI / 2
    elseif x == 0 and y < 0 then
        return -PI / 2
    end
    return 0
end

local function vector(x, y, z)
    return { x = x, y = y, z = z }
end

local function add(a, b)
    return vector(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function scale(a, value)
    return vector(a.x * value, a.y * value, a.z * value)
end

local function dot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function length(a)
    return math.sqrt(dot(a, a))
end

local function normalize(a)
    local size = length(a)
    if size < 1e-9 then
        return nil, "A sensor axis has zero length"
    end
    return scale(a, 1 / size)
end

local function parseVector(a, b, c)
    if type(a) == "table" then
        return vector(
            tonumber(a.x or a[1]),
            tonumber(a.y or a[2]),
            tonumber(a.z or a[3])
        )
    end
    return vector(tonumber(a), tonumber(b), tonumber(c))
end

local function readVector(reader, label)
    local ok, a, b, c = pcall(reader)
    if not ok then
        return nil, label .. " failed: " .. tostring(a)
    end
    local result = parseVector(a, b, c)
    if not result.x or not result.y or not result.z then
        return nil, label .. " returned an invalid vector"
    end
    return result
end

local function readRotation()
    local ok, a, b, c = pcall(sensor.getRotation)
    if not ok then
        return nil
    end
    if type(a) == "table" then
        return {
            yaw = tonumber(a.yaw or a[1]),
            pitch = tonumber(a.pitch or a[2]),
            roll = tonumber(a.roll or a[3]),
        }
    end
    return { yaw = tonumber(a), pitch = tonumber(b), roll = tonumber(c) }
end

local function readSensor()
    local ok, attached = pcall(sensor.isOnSubLevel)
    if not ok then
        return nil, "Sensor status failed: " .. tostring(attached)
    end
    if not attached then
        return nil, "The sensor is not on a sublevel"
    end

    local forward, forwardError = readVector(sensor.getForward, "getForward")
    local up, upError = readVector(sensor.getUp, "getUp")
    local right, rightError = readVector(sensor.getRight, "getRight")
    if not forward then return nil, forwardError end
    if not up then return nil, upError end
    if not right then return nil, rightError end

    forward = normalize(forward)
    up = normalize(up)
    right = normalize(right)
    if not forward or not up or not right then
        return nil, "The sensor returned an invalid orientation"
    end

    local position = readVector(sensor.getPosition, "getPosition")
    return {
        forward = forward,
        up = up,
        right = right,
        position = position,
        rotation = readRotation(),
    }
end

local function readMount()
    local ok, info = pcall(mount.getInfo)
    if not ok then
        return nil, "Cannon telemetry failed: " .. tostring(info)
    end
    if type(info) ~= "table" then
        return nil, "Cannon telemetry returned no data"
    end
    if not tonumber(info.x) or not tonumber(info.y) or not tonumber(info.z) then
        return nil, "Cannon telemetry has no valid position"
    end
    return info
end

local function baseAxes(sensorData)
    local forward = sensorData.forward
    local right = sensorData.right

    if CONFIG.baseForward == "right" then
        forward, right = sensorData.right, scale(sensorData.forward, -1)
    elseif CONFIG.baseForward == "back" then
        forward, right = scale(sensorData.forward, -1), scale(sensorData.right, -1)
    elseif CONFIG.baseForward == "left" then
        forward, right = scale(sensorData.right, -1), sensorData.forward
    elseif CONFIG.baseForward ~= "forward" then
        return nil, "Invalid baseForward in CONFIG"
    end

    return { forward = forward, right = right, up = sensorData.up }
end

local function getCannonPosition(info, sensorData)
    local mountPosition = vector(tonumber(info.x), tonumber(info.y), tonumber(info.z))
    local sensorPosition = sensorData.position
    local offset = CONFIG.cannonOffset

    if not sensorPosition then
        return mountPosition, "mount", "Sensor position unavailable; using raw mount coordinates"
    end

    local sensorBasedPosition = add(sensorPosition, add(
        scale(sensorData.forward, tonumber(offset.forward) or 0),
        add(
            scale(sensorData.up, tonumber(offset.up) or 0),
            scale(sensorData.right, tonumber(offset.right) or 0)
        )
    ))

    if CONFIG.positionSource == "sensor" then
        return sensorBasedPosition, "sensor", nil
    elseif CONFIG.positionSource == "mount" then
        return mountPosition, "mount", nil
    elseif CONFIG.positionSource ~= "auto" then
        return nil, nil, "Invalid positionSource in CONFIG"
    end

    local mismatch = length(add(mountPosition, scale(sensorBasedPosition, -1)))
    if mismatch > CONFIG.mountPositionMismatch then
        return sensorBasedPosition, "sensor", "Mount coordinates appear local; using structure position"
    end
    return mountPosition, "mount", nil
end

local function worldDirection(yaw, pitch)
    local horizontal = math.cos(pitch * RAD)
    return vector(
        horizontal * math.cos(yaw * RAD),
        math.sin(pitch * RAD),
        horizontal * math.sin(yaw * RAD)
    )
end

local function toMountAngles(direction, axes)
    local forwardAmount = dot(direction, axes.forward)
    local rightAmount = dot(direction, axes.right)
    local upAmount = dot(direction, axes.up)
    local horizontal = math.sqrt(forwardAmount ^ 2 + rightAmount ^ 2)

    local yaw = atan2(rightAmount, forwardAmount) * DEG
    local pitch = atan2(upAmount, horizontal) * DEG

    if CONFIG.invertYaw then yaw = -yaw end
    if CONFIG.invertPitch then pitch = -pitch end

    return wrapYaw(yaw + CONFIG.yawOffset), pitch + CONFIG.pitchOffset
end

local function verticalAirTimes(startY, targetY, verticalSpeed)
    local time = 0
    local ascendingTime = nil

    if startY <= targetY then
        while time < CONFIG.maxAirTime do
            startY = startY + verticalSpeed
            verticalSpeed = CONFIG.drag * verticalSpeed - CONFIG.gravity
            time = time + 1

            if startY > targetY then
                ascendingTime = time - 1
                break
            end
            if verticalSpeed < 0 then
                return nil, nil
            end
        end
    end

    while time < CONFIG.maxAirTime do
        startY = startY + verticalSpeed
        verticalSpeed = CONFIG.drag * verticalSpeed - CONFIG.gravity
        time = time + 1

        if startY <= targetY then
            return ascendingTime, time
        end
    end

    return nil, nil
end

local function evaluatePitch(pitch, cannon, target, horizontalDistance)
    local pitchRad = pitch * RAD
    local initialSpeed = CONFIG.powderCharges * CONFIG.speedPerCharge
    local horizontalSpeed = math.cos(pitchRad) * initialSpeed
    local verticalSpeed = math.sin(pitchRad) * initialSpeed

    if horizontalSpeed <= 1e-9 or CONFIG.drag <= 0 or CONFIG.drag >= 1 then
        return nil
    end

    local muzzleOffset = CONFIG.barrelLength * math.cos(pitchRad)
    local remainingDistance = horizontalDistance - muzzleOffset
    local logarithmArgument = 1 - remainingDistance * (1 - CONFIG.drag) / horizontalSpeed
    if logarithmArgument <= 0 then
        return nil
    end

    local horizontalTime = math.abs(math.log(logarithmArgument) / math.log(CONFIG.drag))
    local muzzleY = cannon.y + math.sin(pitchRad) * CONFIG.barrelLength
    local ascendingTime, descendingTime = verticalAirTimes(muzzleY, target.y, verticalSpeed)
    if not descendingTime then
        return nil
    end

    local ascendingError = ascendingTime and math.abs(horizontalTime - ascendingTime) or math.huge
    local descendingError = math.abs(horizontalTime - descendingTime)
    local residual, airTime

    if ascendingError < descendingError then
        residual, airTime = ascendingError, ascendingTime
    else
        residual, airTime = descendingError, descendingTime
    end

    if not airTime or airTime <= 0 then
        return nil
    end

    return {
        worldPitch = pitch,
        residual = residual,
        airTime = airTime,
        horizontalTime = horizontalTime,
        precision = clamp((1 - residual / airTime) * 100, 0, 100),
        fuzeTime = math.max(0, math.floor(airTime + residual / 2 + CONFIG.fuzeOffset)),
    }
end

local function better(candidate, best)
    return candidate and (not best or candidate.residual < best.residual)
end

local function refinePitch(center, radius, cannon, target, distance)
    local best = nil
    local samples = math.max(3, math.floor(CONFIG.refinementSamples))

    for _ = 1, CONFIG.refinementPasses do
        local minimum = math.max(CONFIG.worldPitchMin, center - radius)
        local maximum = math.min(CONFIG.worldPitchMax, center + radius)
        local step = (maximum - minimum) / (samples - 1)
        best = nil

        for index = 0, samples - 1 do
            local pitch = minimum + step * index
            local candidate = evaluatePitch(pitch, cannon, target, distance)
            if better(candidate, best) then
                best = candidate
            end
        end

        if not best then
            return nil
        end
        center = best.worldPitch
        radius = math.max(radius / 10, step)
    end

    return best
end

local function solveTrajectories(cannon, target)
    local dx = target.x - cannon.x
    local dz = target.z - cannon.z
    local distance = math.sqrt(dx * dx + dz * dz)
    if distance < 1e-6 then
        return nil, "The target is directly above or below the mount"
    end

    local samples = math.max(3, math.floor(CONFIG.coarseSamples))
    local step = (CONFIG.worldPitchMax - CONFIG.worldPitchMin) / (samples - 1)
    local evaluated = {}
    local bestOverall = nil

    for index = 0, samples - 1 do
        local pitch = CONFIG.worldPitchMin + step * index
        local candidate = evaluatePitch(pitch, cannon, target, distance)
        evaluated[index + 1] = candidate
        if better(candidate, bestOverall) then
            bestOverall = candidate
        end
    end

    if not bestOverall then
        return nil, "Target unreachable: check charges, barrel length and pitch limits"
    end

    local minima = {}
    for index = 2, #evaluated - 1 do
        local previous = evaluated[index - 1]
        local current = evaluated[index]
        local following = evaluated[index + 1]
        if current and previous and following
            and current.residual <= previous.residual
            and current.residual <= following.residual then
            minima[#minima + 1] = current
        end
    end

    if #minima == 0 then
        minima[1] = bestOverall
    end
    table.sort(minima, function(a, b) return a.worldPitch < b.worldPitch end)

    local lowSeed = minima[1]
    local highSeed = minima[#minima]
    local low = refinePitch(lowSeed.worldPitch, step, cannon, target, distance)
    local high = nil

    if highSeed ~= lowSeed then
        high = refinePitch(highSeed.worldPitch, step, cannon, target, distance)
    end

    local worldYaw = wrapYaw(atan2(dz, dx) * DEG)
    return {
        low = low,
        high = high,
        worldYaw = worldYaw,
        distance = distance,
    }
end

local function prepareSolution(raw, trajectory, sensorData)
    if not raw then return nil end
    local axes, axesError = baseAxes(sensorData)
    if not axes then return nil, axesError end

    local direction = worldDirection(trajectory.worldYaw, raw.worldPitch)
    local yaw, pitch = toMountAngles(direction, axes)
    if state.initialYaw and math.abs(angleDifference(yaw, state.initialYaw)) > CONFIG.yawLimit then
        return nil, string.format("Required yaw %.2f is outside the +/-%.1f degree sector", yaw, CONFIG.yawLimit)
    end
    if pitch < CONFIG.mountPitchMin or pitch > CONFIG.mountPitchMax then
        return nil, string.format("Required local pitch %.2f is outside mount limits", pitch)
    end

    return {
        yaw = yaw,
        pitch = pitch,
        worldYaw = trajectory.worldYaw,
        worldPitch = raw.worldPitch,
        airTime = raw.airTime,
        fuzeTime = raw.fuzeTime,
        precision = raw.precision,
        residual = raw.residual,
        distance = trajectory.distance,
    }
end

local function calculateSolutions()
    local info, infoError = readMount()
    local sensorData, sensorError = readSensor()
    state.info = info or state.info
    state.sensorData = sensorData

    if not info then return nil, infoError end
    if not sensorData then return nil, sensorError end

    local cannon, positionSource, positionNotice = getCannonPosition(info, sensorData)
    state.cannonPosition = cannon
    state.positionSourceUsed = positionSource or "unknown"
    state.positionNotice = positionNotice
    if not cannon then return nil, positionNotice end
    if not state.target then return nil, "No target is set" end

    local trajectories, solveError = solveTrajectories(cannon, state.target)
    if not trajectories then return nil, solveError end

    local low, lowError = prepareSolution(trajectories.low, trajectories, sensorData)
    local high, highError = prepareSolution(trajectories.high, trajectories, sensorData)
    if not low and not high then
        return nil, lowError or highError or "No usable trajectory"
    end

    return {
        low = low,
        high = high,
        lowError = lowError,
        highError = highError,
    }
end

local function isAimed(info, solution)
    if not info or not solution or not tonumber(info.yaw) or not tonumber(info.pitch) then
        return false
    end
    return math.abs(angleDifference(tonumber(info.yaw), solution.yaw)) <= CONFIG.yawTolerance
        and math.abs(tonumber(info.pitch) - solution.pitch) <= CONFIG.pitchTolerance
end

local function fireReadiness()
    if not state.armed then return false, "The controller is not armed" end
    if not state.target or not state.solution then return false, "No valid firing solution" end
    if not state.info or not state.info.assembled then return false, "The cannon is not assembled" end
    if not state.info.computerControl then return false, "Computer control is disabled" end
    if state.solution.precision < CONFIG.minimumPrecision then
        return false, string.format("Precision %.1f%% is below the configured minimum", state.solution.precision)
    end
    if state.stableUpdates < CONFIG.stableUpdatesRequired then
        return false, "The mount has not settled on the target"
    end
    if not isAimed(state.info, state.solution) then
        return false, "The mount is still moving"
    end
    return true
end

local function fireOnce()
    local ready, reason = fireReadiness()
    if not ready then
        return false, reason
    end

    local ok, fireError = pcall(function()
        mount.fire(true)
        sleep(math.max(1, CONFIG.firePulseTicks) / 20)
        mount.fire(false)
    end)
    pcall(mount.fire, false)

    if not ok then
        state.autoFire = false
        return false, "Firing failed: " .. tostring(fireError)
    end

    state.lastFireTime = os.clock()
    state.stableUpdates = 0
    return true
end

local function playAimSound()
    if not speaker or not CONFIG.aimSoundEnabled then return end
    local ok, soundError = pcall(
        speaker.playSound,
        CONFIG.aimSound,
        clamp(CONFIG.aimSoundVolume, 0, 3),
        CONFIG.aimSoundPitch
    )
    if not ok then
        state.lastNotice = "Aim sound failed: " .. tostring(soundError)
    end
end

local function updateAim()
    local solutions, calculateError = calculateSolutions()
    state.solutions = solutions
    state.lastError = calculateError
    state.lastNotice = state.positionNotice

    if not solutions then
        state.solution = nil
        state.stableUpdates = 0
        state.aimAnnounced = false
        return
    end

    state.solution = solutions[state.arc]
    if not state.solution then
        state.solution = solutions.low or solutions.high
        state.lastNotice = "The selected arc is unavailable; using the other arc"
    end

    if state.tracking and state.solution then
        mount.setTargetAngles(state.solution.yaw, state.solution.pitch)
    end

    local aimedNow = state.tracking and isAimed(state.info, state.solution)
    if aimedNow then
        state.stableUpdates = state.stableUpdates + 1
        if state.stableUpdates >= CONFIG.stableUpdatesRequired and not state.aimAnnounced then
            playAimSound()
            state.aimAnnounced = true
        end
    else
        state.stableUpdates = 0
        state.aimAnnounced = false
    end

    if state.autoFire and state.tracking then
        if os.clock() - state.lastFireTime >= CONFIG.autoFireCooldown then
            local fired, fireError = fireOnce()
            if not fired and fireError and not string.find(fireError, "still moving", 1, true)
                and not string.find(fireError, "not settled", 1, true) then
                state.lastNotice = fireError
            end
        end
    end
end

local function formatTarget()
    if not state.target then return "none" end
    return string.format("%.1f %.1f %.1f", state.target.x, state.target.y, state.target.z)
end

local function formatStructurePosition()
    local position = state.sensorData and state.sensorData.position
    if position and position.x and position.y and position.z then
        return string.format("%.2f %.2f %.2f", position.x, position.y, position.z)
    end
    return "unavailable"
end

local function formatCannonPosition()
    local position = state.cannonPosition
    if position and position.x and position.y and position.z then
        return string.format("%.2f %.2f %.2f", position.x, position.y, position.z)
    end
    return "unavailable"
end

local function monitorLine(line, text)
    monitor.setCursorPos(1, line)
    monitor.clearLine()
    monitor.write(text)
end

local function drawMonitor()
    if not monitor then return end
    pcall(function()
        monitor.setTextScale(0.5)
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
        monitor.clear()

        monitorLine(1, "TANK CANNON CONTROLLER")
        monitorLine(2, "Target: " .. formatTarget())
        monitorLine(3, string.format("Mode: %s  Arc: %s", state.tracking and "TRACK" or "HOLD", state.arc))
        monitorLine(4, string.format("Armed: %s  Auto: %s", state.armed and "YES" or "NO", state.autoFire and "YES" or "NO"))

        local rotation = state.sensorData and state.sensorData.rotation
        if rotation and rotation.yaw and rotation.pitch and rotation.roll then
            monitorLine(5, string.format("Ship Y/P/R: %.1f %.1f %.1f", rotation.yaw, rotation.pitch, rotation.roll))
        else
            monitorLine(5, "Ship Y/P/R: unavailable")
        end

        monitorLine(6, "Ship X/Y/Z: " .. formatStructurePosition())

        monitorLine(7, "Gun X/Y/Z: " .. formatCannonPosition())

        if state.info and tonumber(state.info.yaw) and tonumber(state.info.pitch) then
            monitorLine(8, string.format("Mount Y/P: %.2f %.2f", state.info.yaw, state.info.pitch))
            monitorLine(9, string.format("Assembled: %s  Speed: %.0f/%.0f",
                tostring(state.info.assembled),
                tonumber(state.info.yawShaftSpeed) or 0,
                tonumber(state.info.pitchShaftSpeed) or 0))
        else
            monitorLine(8, "Mount telemetry unavailable")
            monitorLine(9, "")
        end

        if state.solution then
            monitorLine(10, string.format("Aim Y/P: %.3f %.3f", state.solution.yaw, state.solution.pitch))
            monitorLine(11, string.format("World Y/P: %.3f %.3f", state.solution.worldYaw, state.solution.worldPitch))
            monitorLine(12, string.format("Range: %.1f  Precision: %.1f%%", state.solution.distance, state.solution.precision))
            monitorLine(13, string.format("Flight: %d ticks  Fuze: %d", state.solution.airTime, state.solution.fuzeTime))
            monitorLine(14, string.format("Settled: %d/%d", state.stableUpdates, CONFIG.stableUpdatesRequired))
        else
            monitorLine(10, "Aim: no solution")
            for line = 11, 14 do monitorLine(line, "") end
        end

        local message = state.lastError or state.lastNotice or "Ready"
        monitor.setTextColor(state.lastError and colors.red or colors.lightGray)
        monitorLine(15, string.sub(message, 1, 60))
        monitor.setTextColor(colors.white)
    end)
end

local function printStatus()
    print("Target: " .. formatTarget())
    print(string.format("Tracking: %s | Armed: %s | Auto fire: %s | Arc: %s",
        tostring(state.tracking), tostring(state.armed), tostring(state.autoFire), state.arc))
    print(string.format("Charges: %d | Barrel length: %d", CONFIG.powderCharges, CONFIG.barrelLength))
    print(string.format("Yaw center: %.2f | Sector: +/-%.1f | Speaker: %s",
        state.initialYaw or 0, CONFIG.yawLimit, speaker and "connected" or "missing"))
    print("Structure X/Y/Z: " .. formatStructurePosition())

    if state.sensorData and state.sensorData.rotation then
        local rotation = state.sensorData.rotation
        print(string.format("Structure yaw/pitch/roll: %.2f / %.2f / %.2f",
            rotation.yaw or 0, rotation.pitch or 0, rotation.roll or 0))
    else
        print("Structure orientation: unavailable")
    end

    if state.info then
        print(string.format("Mount raw X/Y/Z: %.2f / %.2f / %.2f",
            tonumber(state.info.x) or 0, tonumber(state.info.y) or 0, tonumber(state.info.z) or 0))
        print(string.format("Mount yaw/pitch: %.3f / %.3f | Assembled: %s",
            tonumber(state.info.yaw) or 0, tonumber(state.info.pitch) or 0, tostring(state.info.assembled)))
    end
    print(string.format("Ballistic origin: %s | Source: %s", formatCannonPosition(), state.positionSourceUsed))

    if state.solution then
        print(string.format("Solution yaw/pitch: %.4f / %.4f", state.solution.yaw, state.solution.pitch))
        print(string.format("World yaw/pitch: %.4f / %.4f", state.solution.worldYaw, state.solution.worldPitch))
        print(string.format("Distance: %.2f | Flight: %d ticks | Fuze: %d | Precision: %.1f%%",
            state.solution.distance, state.solution.airTime, state.solution.fuzeTime, state.solution.precision))
    end

    if state.lastNotice then print("Notice: " .. state.lastNotice) end
    if state.lastError then print("Error: " .. state.lastError) end
end

local function printHelp()
    print("Commands:")
    print("  target <x> <y> <z> [low|high] - set target and track")
    print("  aim | hold                     - resume or hold aiming")
    print("  arc <low|high>                 - select trajectory")
    print("  charges <n> | length <n>       - update ballistic settings")
    print("  origin <auto|mount|sensor>     - select position source")
    print("  center                         - set the yaw sector center")
    print("  arm | disarm                   - enable or disable firing")
    print("  fire                           - fire when aimed and settled")
    print("  auto                           - toggle automatic firing")
    print("  status | scan | clear          - information and target reset")
    print("  help | quit                    - help or safe shutdown")
end

local function scanPeripherals()
    for _, name in ipairs(peripheral.getNames()) do
        print(name .. ": " .. peripheral.getType(name))
    end
end

local function setTarget(x, y, z, arc)
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or not y or not z then
        print("Usage: target <x> <y> <z> [low|high]")
        return
    end
    if arc and arc ~= "low" and arc ~= "high" then
        print("Arc must be low or high")
        return
    end

    state.target = vector(x, y, z)
    state.arc = arc or state.arc
    state.tracking = true
    state.stableUpdates = 0
    state.aimAnnounced = false
    state.lastError = nil
    print("Target set: " .. formatTarget() .. " | Arc: " .. state.arc)
end

local function handleCommand(line)
    local arguments = {}
    for word in string.gmatch(line or "", "%S+") do
        arguments[#arguments + 1] = word
    end
    if #arguments == 0 then return end

    local command = string.lower(arguments[1])
    if command == "target" then
        setTarget(arguments[2], arguments[3], arguments[4], arguments[5] and string.lower(arguments[5]))
    elseif command == "aim" then
        if not state.target then print("Set a target first") return end
        state.tracking = true
        print("Tracking enabled")
    elseif command == "hold" then
        state.tracking = false
        state.autoFire = false
        print("Tracking held; automatic firing disabled")
    elseif command == "arc" and (arguments[2] == "low" or arguments[2] == "high") then
        state.arc = arguments[2]
        state.stableUpdates = 0
        print("Selected arc: " .. state.arc)
    elseif command == "charges" and tonumber(arguments[2]) then
        CONFIG.powderCharges = math.max(1, math.floor(tonumber(arguments[2])))
        state.stableUpdates = 0
        print("Powder charges: " .. CONFIG.powderCharges)
    elseif command == "length" and tonumber(arguments[2]) then
        CONFIG.barrelLength = math.max(1, math.floor(tonumber(arguments[2])))
        state.stableUpdates = 0
        print("Barrel length: " .. CONFIG.barrelLength)
    elseif command == "origin" and (arguments[2] == "auto" or arguments[2] == "mount" or arguments[2] == "sensor") then
        CONFIG.positionSource = arguments[2]
        state.stableUpdates = 0
        print("Position source: " .. CONFIG.positionSource)
    elseif command == "center" then
        local info, centerError = readMount()
        if info and tonumber(info.yaw) then
            state.initialYaw = wrapYaw(tonumber(info.yaw))
            state.stableUpdates = 0
            state.aimAnnounced = false
            print(string.format("Yaw sector center: %.2f", state.initialYaw))
        else
            print("Cannot set yaw center: " .. tostring(centerError))
        end
    elseif command == "arm" then
        local ok, armError = pcall(function()
            mount.setComputerControl(true)
            if CONFIG.autoAssemble and not mount.assemble(true) then
                error("The cannon could not be assembled")
            end
        end)
        if ok then
            state.armed = true
            print("Controller armed")
        else
            print("Arming failed: " .. tostring(armError))
        end
    elseif command == "disarm" then
        state.armed = false
        state.autoFire = false
        pcall(mount.fire, false)
        print("Controller disarmed")
    elseif command == "fire" then
        local fired, fireError = fireOnce()
        print(fired and "Fire pulse sent" or ("Cannot fire: " .. tostring(fireError)))
    elseif command == "auto" then
        if not state.armed then print("Arm the controller first") return end
        if not state.target or not state.tracking then print("Set and track a target first") return end
        state.autoFire = not state.autoFire
        print("Automatic firing: " .. tostring(state.autoFire))
    elseif command == "status" then
        printStatus()
    elseif command == "scan" then
        scanPeripherals()
    elseif command == "clear" then
        state.target = nil
        state.solution = nil
        state.solutions = nil
        state.tracking = false
        state.autoFire = false
        state.stableUpdates = 0
        print("Target cleared; automatic firing disabled")
    elseif command == "help" then
        printHelp()
    elseif command == "quit" or command == "exit" then
        state.running = false
    else
        print("Unknown command. Type help.")
    end
end

local function commandLoop()
    while state.running do
        term.write("> ")
        local line = read()
        if line then handleCommand(line) end
    end
end

local function trackingLoop()
    while state.running do
        local ok, updateError = pcall(updateAim)
        if not ok then
            state.lastError = tostring(updateError)
            state.solution = nil
            state.stableUpdates = 0
            state.autoFire = false
            pcall(mount.fire, false)
        end
        drawMonitor()
        sleep(CONFIG.trackInterval)
    end
end

local startupOk, startupError = pcall(function()
    local initialInfo = mount.getInfo()
    state.initialYaw = wrapYaw(tonumber(initialInfo.yaw) or 0)
    mount.setComputerControl(true)
    if CONFIG.autoAssemble then
        mount.assemble(true)
    end
end)
if not startupOk then
    pcall(mount.fire, false)
    error("Cannon initialization failed: " .. tostring(startupError), 0)
end

local arguments = { ... }
if #arguments >= 3 then
    setTarget(arguments[1], arguments[2], arguments[3], arguments[4] and string.lower(arguments[4]))
end

print("Tank Cannon Controller loaded")
print(string.format("Yaw sector: %.2f +/- %.1f degrees", state.initialYaw, CONFIG.yawLimit))
print("Firing starts disarmed. Type arm to enable it.")
if CONFIG.aimSoundEnabled and not speaker then
    print("No speaker found; aim sound is disabled")
end
print("Type help for commands. Default trajectory: " .. state.arc)
printHelp()

local ok, runtimeError = xpcall(function()
    parallel.waitForAny(commandLoop, trackingLoop)
end, debug.traceback)

state.running = false
state.autoFire = false
pcall(mount.fire, false)

if not ok then
    error(runtimeError, 0)
end
print("Controller stopped safely")
