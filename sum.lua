-- ============================================================================
--  КВАДРОКОПТЕР ДЛЯ CREATE: AVIONICS
--  С управлением от двухосевого пульта (4 аналоговых сигнала 0-15)
--  С автоопределением методов датчиков и защитой от ошибок
-- ============================================================================

-- ===== НАСТРОЙКИ (ИЗМЕНИТЕ ПОД СВОЁ ОБОРУДОВАНИЕ) =====
local PROPS = {
    FL = "propeller_bearing_0",   -- передний левый
    FR = "propeller_bearing_1",   -- передний правый
    BL = "propeller_bearing_2",   -- задний левый
    BR = "propeller_bearing_3"    -- задний правый
}
local GIMBAL = "gimbal_sensor_0"
local ALT = "altitude_sensor_0"
local MONITOR = "monitor_0"

-- Стороны для чтения аналогового редстоуна (0-15) от пульта
local SIDE_FORWARD = "front"   -- сигнал при наклоне вперёд
local SIDE_BACKWARD = "back"   -- сигнал при наклоне назад
local SIDE_LEFT = "left"       -- сигнал при наклоне влево
local SIDE_RIGHT = "right"     -- сигнал при наклоне вправо

-- Максимальный угол наклона в градусах (при полном отклонении)
local MAX_ANGLE = 30

-- Мёртвая зона для нормированного отклонения (0.05 = 5%)
local DEAD_ZONE = 0.05

-- Коэффициенты PID (подберите под свой дрон)
local PID = {
    pitch = { P = 2.0, D = 0.5 },
    roll  = { P = 2.0, D = 0.5 },
    alt   = { P = 1.0, D = 0.2 }
}

-- Базовая тяга для висения (подберите экспериментально)
local BASE_THRUST = 0.55
-- ============================================================

-- Вспомогательные функции
local function clamp(val, min, max)
    return math.max(min, math.min(max, val))
end

-- Безопасное подключение периферии с проверкой
local function safeWrap(name)
    local p = peripheral.wrap(name)
    if not p then
        error("Устройство не найдено: " .. name)
    end
    return p
end

-- ---- Подключаем устройства ----
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

print("=== Все устройства найдены ===")

-- ---- Определяем рабочий метод для altitude_sensor ----
local function getAltitudeSafe()
    -- Пробуем несколько возможных имён методов
    local possibleMethods = {"getAltitude", "getAltitudeData", "getAlt", "getHeight"}
    for _, method in ipairs(possibleMethods) do
        local success, result = pcall(function()
            return altSensor[method]()
        end)
        if success and type(result) == "table" and result.altitude ~= nil then
            return result   -- нашли рабочий метод
        end
    end
    -- Если ничего не подошло – выводим предупреждение и возвращаем заглушку
    print("Предупреждение: не удалось получить высоту. Использую заглушку (0 метров).")
    return { altitude = 0, verticalSpeed = 0 }
end

-- ---- Инициализация переменных PID ----
local prevErrPitch = 0
local prevErrRoll = 0
local prevErrAlt = 0
local targetAlt = nil   -- будет установлен при первом измерении

-- ---- Переменные для FPS ----
local lastTime = os.clock()
local frameCount = 0
local fps = 0
local fpsTimer = lastTime

print("Автопилот запущен. Управляйте джойстиком!")

-- ===== ГЛАВНЫЙ ЦИКЛ =====
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

    -- Преобразуем в нормированные отклонения [-1 .. +1]
    local netPitch = (sigFwd - sigBwd) / 15
    local netRoll  = (sigRgt - sigLft) / 15

    -- Мёртвая зона
    if math.abs(netPitch) < DEAD_ZONE then netPitch = 0 end
    if math.abs(netRoll)  < DEAD_ZONE then netRoll  = 0 end

    -- Целевые углы (градусы)
    local targetPitch = netPitch * MAX_ANGLE
    local targetRoll  = netRoll  * MAX_ANGLE

    -- ---- Считываем датчики ----
    local altData = getAltitudeSafe()
    local altitude = altData.altitude
    local vertSpeed = altData.verticalSpeed or 0

    -- Получаем углы от гироскопа
    local gimbalData = gimbal.getAngles()   -- должен быть метод getAngles
    local pitch = gimbalData.pitch
    local roll  = gimbalData.roll

    -- Устанавливаем целевую высоту при первом замере (если высота не 0)
    if targetAlt == nil then
        if altitude > 0.1 then
            targetAlt = altitude
        else
            targetAlt = 5   -- фиксированная высота, если сенсор не работает
            print("Высота не определена, установлена цель 5 м")
        end
        print("Целевая высота: " .. string.format("%.1f м", targetAlt))
    end

    -- ---- PID-регуляторы ----
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

    -- ---- Смешение мощностей (X-конфигурация) ----
    local powerFL = clamp(thrust + outRoll - outPitch, 0, 1)
    local powerFR = clamp(thrust - outRoll - outPitch, 0, 1)
    local powerBL = clamp(thrust + outRoll + outPitch, 0, 1)
    local powerBR = clamp(thrust - outRoll + outPitch, 0, 1)

    -- ---- Отправка команд на винты (параллельно для 20 Гц) ----
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
