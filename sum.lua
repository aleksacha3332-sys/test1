-- ============================================================================
--  КВАДРОКОПТЕР С ДВУХОСЕВЫМ ПУЛЬТОМ (4 аналоговых выхода: вперёд/назад/влево/вправо)
-- ============================================================================

-- ===== НАСТРОЙКИ (ИЗМЕНИТЕ ПОД СВОЁ ОБОРУДОВАНИЕ) =====
local PROPS = {
    FL = "propeller_bearing_0",
    FR = "propeller_bearing_1",
    BL = "propeller_bearing_2",
    BR = "propeller_bearing_3"
}
local GIMBAL = "gimbal_sensor_0"
local ALT = "altitude_sensor_0"
local MONITOR = "monitor_0"

-- ⚠️ ВАЖНО: укажите стороны, к которым подключены провода от вашего пульта
local SIDE_FORWARD = "front"   -- сигнал 0-15 при наклоне ВПЕРЁД
local SIDE_BACKWARD = "back"   -- сигнал 0-15 при наклоне НАЗАД
local SIDE_LEFT = "left"       -- сигнал 0-15 при наклоне ВЛЕВО
local SIDE_RIGHT = "right"     -- сигнал 0-15 при наклоне ВПРАВО

-- Максимальный угол наклона в градусах (при сигнале 15)
local MAX_ANGLE = 30

-- Мёртвая зона для результирующего сигнала (от 0 до 1)
-- Например, 0.05 означает, что отклонение менее 5% игнорируется
local DEAD_ZONE = 0.05

-- Коэффициенты PID (подберите под свой дрон)
local PID = {
    pitch = { P = 2.0, D = 0.5 },
    roll  = { P = 2.0, D = 0.5 },
    alt   = { P = 1.0, D = 0.2 }
}
-- ============================================================

-- Вспомогательные функции
local function clamp(val, min, max)
    return math.max(min, math.min(max, val))
end

local function getPeripheral(name, expectedType)
    local p = peripheral.find(name)
    if not p then
        error("not found: " .. name .. " (need: " .. expectedType .. ")")
    end
    return p
end

-- Подключаем устройства
local fl = getPeripheral(PROPS.FL, "propeller_bearing")
local fr = getPeripheral(PROPS.FR, "propeller_bearing")
local bl = getPeripheral(PROPS.BL, "propeller_bearing")
local br = getPeripheral(PROPS.BR, "propeller_bearing")
local gimbal = getPeripheral(GIMBAL, "gimbal_sensor")
local altSensor = getPeripheral(ALT, "altitude_sensor")
local monitor = peripheral.wrap(MONITOR)
if monitor then
    monitor.setTextScale(0.5)
    monitor.clear()
end

print("all good")

-- Переменные для PID
local prevErrPitch = 0
local prevErrRoll = 0
local prevErrAlt = 0
local targetAlt = nil

-- Переменные для FPS
local lastTime = os.clock()
local frameCount = 0
local fps = 0
local fpsTimer = lastTime

-- Главный цикл
while true do
    local now = os.clock()
    local dt = now - lastTime
    if dt <= 0 then dt = 0.001 end
    lastTime = now

    -- ---- Считываем 4 сигнала с пульта (каждый 0..15) ----
    local sigFwd = redstone.getAnalogInput(SIDE_FORWARD)
    local sigBwd = redstone.getAnalogInput(SIDE_BACKWARD)
    local sigLft = redstone.getAnalogInput(SIDE_LEFT)
    local sigRgt = redstone.getAnalogInput(SIDE_RIGHT)

    -- ---- Преобразуем в нормированные отклонения [-1 .. +1] ----
    local netPitch = (sigFwd - sigBwd) / 15   -- +1 = полный вперёд, -1 = полный назад
    local netRoll  = (sigRgt - sigLft) / 15   -- +1 = полный вправо, -1 = полный влево

    -- Мёртвая зона (чтобы дрон не дрожал в центре)
    if math.abs(netPitch) < DEAD_ZONE then netPitch = 0 end
    if math.abs(netRoll)  < DEAD_ZONE then netRoll  = 0 end

    -- Целевые углы (градусы)
    local targetPitch = netPitch * MAX_ANGLE
    local targetRoll  = netRoll  * MAX_ANGLE

    -- ---- Считываем датчики ----
    local altData = altSensor.getAltitude()
    local altitude = altData.altitude
    local vertSpeed = altData.verticalSpeed

    local gimbalData = gimbal.getAngles()
    local pitch = gimbalData.pitch
    local roll  = gimbalData.roll

    -- Устанавливаем целевую высоту при первом замере
    if targetAlt == nil then
        targetAlt = altitude
        print("Целевая высота установлена: " .. string.format("%.1f", targetAlt))
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

    local baseThrust = 0.55  -- подберите под вес дрона
    local thrust = clamp(baseThrust + outAlt, 0.2, 0.9)

    -- Смешение мощностей (X-конфигурация)
    local powerFL = clamp(thrust + outRoll - outPitch, 0, 1)
    local powerFR = clamp(thrust - outRoll - outPitch, 0, 1)
    local powerBL = clamp(thrust + outRoll + outPitch, 0, 1)
    local powerBR = clamp(thrust - outRoll + outPitch, 0, 1)

    -- ---- Параллельная отправка команд (для 20 Гц) ----
    parallel.waitForAll(
        function() fl.setThrust(true, powerFL) end,
        function() fr.setThrust(true, powerFR) end,
        function() bl.setThrust(true, powerBL) end,
        function() br.setThrust(true, powerBR) end
    )

    -- ---- Вывод на монитор ----
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

    -- ---- Счётчик FPS ----
    frameCount = frameCount + 1
    if now - fpsTimer >= 1 then
        fps = frameCount
        frameCount = 0
        fpsTimer = now
    end

    sleep(0.01)
end
