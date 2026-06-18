-- ============================================
-- Артиллерийская система с баллистикой (скорость в м/с)
-- ============================================

local CONFIG = {
    cannonPeripheral = "cannon_mount_0",
    monitorSide = "top",
    updateInterval = 5,
    minPitch = -90,
    maxPitch = 90,
    -- Гравитация в м/с² (стандарт Minecraft ~20, но можно изменить под свой мод)
    gravity_mps2 = 20
}

-- Пересчёт гравитации в блоки/тик²
local GRAVITY_BPT2 = CONFIG.gravity_mps2 / 400  -- т.к. 1 тик² = 1/400 с²

-- ============================================
-- Инициализация периферии
-- ============================================

local monitor = peripheral.find("monitor")
if not monitor then error("Монитор не найден!") end
monitor.setTextScale(0.5)
monitor.clear()

local cannon = peripheral.find("cannon_mount")
if not cannon then error("Пушка не найдена!") end
cannon.setComputerControl(true)

-- ============================================
-- Состояние системы
-- ============================================

local state = {
    position = { x = 0, y = 0, z = 0 },
    target   = { x = nil, y = nil, z = nil },
    currentYaw   = 0,
    currentPitch = 0,
    targetYaw    = 0,
    targetPitch  = 0,
    isAssembled  = false,
    speed_mps    = 80,            -- скорость в м/с (пользовательская)
    speed_bpt    = 80 / 20,       -- внутренняя скорость в блоках/тик
    lastUpdate   = 0
}

-- ============================================
-- Вспомогательные функции
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
-- Баллистический расчёт (внутренние единицы: блоки и тики)
-- ============================================

local function calculateBallisticPitch(from, to, v_bpt, g_bpt2)
    local dx = to.x - from.x
    local dy = to.y - from.y
    local dz = to.z - from.z
    local d = math.sqrt(dx*dx + dz*dz)
    local h = dy

    if d < 0.001 then
        if h > 0 then return 90 else return -90 end
    end

    local v2 = v_bpt * v_bpt
    local gd = g_bpt2 * d
    local discriminant = v2 * v2 - g_bpt2 * (g_bpt2 * d * d + 2 * h * v2)

    if discriminant < 0 then
        return nil
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
-- Управление пушкой
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
        return false, "Цель не задана"
    end

    local yaw = calculateYaw(state.position, state.target)
    state.targetYaw = yaw

    -- Используем внутреннюю скорость в блоках/тик
    local pitch = calculateBallisticPitch(
        state.position,
        state.target,
        state.speed_bpt,
        GRAVITY_BPT2
    )

    if not pitch then
        return false, string.format("Цель недостижима при скорости %.1f м/с", state.speed_mps)
    end

    state.targetPitch = pitch
    cannon.setTargetAngles(yaw, pitch)
    return true, "OK"
end

local function fire()
    if not state.isAssembled then return false, "Пушка не собрана" end
    cannon.fire(true)
    sleep(0.1)
    cannon.fire(false)
    return true, "Выстрел!"
end

local function assemble(enable)
    local result = cannon.assemble(enable)
    state.isAssembled = result
    return result
end

-- ============================================
-- Отрисовка монитора (скорость в м/с)
-- ============================================

local function drawUI()
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextColor(colors.cyan)
    monitor.write("╔═══════════════════════════════════════╗")
    monitor.setCursorPos(1, 2)
    monitor.write("║     АРТИЛЛЕРИЙСКАЯ СИСТЕМА          ║")
    monitor.setCursorPos(1, 3)
    monitor.write("╚═══════════════════════════════════════╝")

    local line = 5

    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("📌 СТАТУС:")
    line = line + 1
    monitor.setTextColor(state.isAssembled and colors.green or colors.red)
    monitor.setCursorPos(3, line)
    monitor.write("Собрана: " .. tostring(state.isAssembled))
    line = line + 1

    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("📍 ПОЗИЦИЯ:")
    line = line + 1
    monitor.setTextColor(colors.yellow)
    monitor.setCursorPos(3, line)
    monitor.write(string.format("X: %6.1f  Y: %6.1f  Z: %6.1f",
        state.position.x, state.position.y, state.position.z))
    line = line + 1

    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("🎯 ПАРАМЕТРЫ:")
    line = line + 1
    monitor.setTextColor(colors.yellow)
    monitor.setCursorPos(3, line)
    monitor.write(string.format("Yaw: %7.2f°  Pitch: %5.2f°", state.currentYaw, state.currentPitch))
    line = line + 1
    monitor.setCursorPos(3, line)
    monitor.write(string.format("Скорость: %5.1f м/с", state.speed_mps))
    line = line + 1

    if state.target.x then
        monitor.setTextColor(colors.green)
        monitor.setCursorPos(3, line)
        monitor.write(string.format("Целевой Yaw: %7.2f°", state.targetYaw))
        line = line + 1
        monitor.setCursorPos(3, line)
        monitor.write(string.format("Целевой Pitch: %5.2f°", state.targetPitch))
        line = line + 1

        local dist = getDistance(state.position, state.target)
        monitor.setTextColor(colors.white)
        monitor.setCursorPos(1, line)
        monitor.write("📏 ДИСТАНЦИЯ:")
        line = line + 1
        monitor.setTextColor(colors.lime)
        monitor.setCursorPos(3, line)
        monitor.write(string.format("%7.1f блоков", dist))
        line = line + 1
    end

    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    if state.target.x then
        monitor.write("🎯 ЦЕЛЬ:")
        line = line + 1
        monitor.setTextColor(colors.orange)
        monitor.setCursorPos(3, line)
        monitor.write(string.format("X: %6.1f  Y: %6.1f  Z: %6.1f",
            state.target.x, state.target.y, state.target.z))
    else
        monitor.setTextColor(colors.gray)
        monitor.write("🎯 ЦЕЛЬ НЕ ЗАДАНА")
    end
    line = line + 1

    monitor.setTextColor(colors.gray)
    monitor.setCursorPos(1, 20)
    monitor.write("Команды: target <x> <y> <z> | speed <м/с> | fire")
    monitor.setCursorPos(1, 21)
    monitor.write("         assemble [on/off] | status | help | exit")
end

-- ============================================
-- Обработка команд
-- ============================================

local function processCommand(input)
    if not input or input == "" then return true end

    local args = {}
    for word in input:gmatch("%S+") do table.insert(args, word) end
    if #args == 0 then return true end

    local cmd = args[1]:lower()

    if cmd == "help" then
        print("Доступные команды:")
        print("  target <x> <y> <z>   - установить цель")
        print("  speed <значение>     - задать скорость в м/с")
        print("  fire                 - выстрелить")
        print("  assemble [on/off]    - собрать/разобрать пушку")
        print("  status               - показать статус")
        print("  exit                 - выход")
        return true
    end

    if cmd == "target" then
        if #args < 4 then
            print("Использование: target <x> <y> <z>")
            return true
        end
        local x = tonumber(args[2])
        local y = tonumber(args[3])
        local z = tonumber(args[4])
        if not x or not y or not z then
            print("Ошибка: координаты должны быть числами")
            return true
        end
        state.target.x = x
        state.target.y = y
        state.target.z = z

        local success, msg = aimAtTarget()
        if success then
            print("✓ Цель установлена: (" .. x .. ", " .. y .. ", " .. z .. ")")
            print("  Yaw: " .. string.format("%.2f", state.targetYaw) .. "°")
            print("  Pitch: " .. string.format("%.2f", state.targetPitch) .. "°")
        else
            print("✗ " .. msg)
        end
        return true
    end

    if cmd == "speed" then
        if #args < 2 then
            print("Текущая скорость: " .. state.speed_mps .. " м/с")
            return true
        end
        local v_mps = tonumber(args[2])
        if not v_mps or v_mps <= 0 then
            print("Ошибка: скорость должна быть положительным числом")
            return true
        end
        state.speed_mps = v_mps
        state.speed_bpt = v_mps / 20   -- пересчёт в блоки/тик
        print("✓ Скорость установлена: " .. v_mps .. " м/с")
        if state.target.x then
            local success, msg = aimAtTarget()
            if not success then
                print("⚠ " .. msg)
            end
        end
        return true
    end

    if cmd == "fire" then
        local success, msg = fire()
        print(success and "✓ " .. msg or "✗ " .. msg)
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
                print("Использование: assemble [on/off]")
                return true
            end
        else
            enable = not state.isAssembled
        end
        local result = assemble(enable)
        print(result and "✓ Пушка " .. (enable and "собрана" or "разобрана") or "✗ Ошибка")
        return true
    end

    if cmd == "status" then
        print("=== СТАТУС СИСТЕМЫ ===")
        print(string.format("Позиция: (%.1f, %.1f, %.1f)", state.position.x, state.position.y, state.position.z))
        print(string.format("Углы: Yaw=%.2f°, Pitch=%.2f°", state.currentYaw, state.currentPitch))
        print("Собрана: " .. tostring(state.isAssembled))
        print("Скорость: " .. state.speed_mps .. " м/с")
        if state.target.x then
            print(string.format("Цель: (%.1f, %.1f, %.1f)", state.target.x, state.target.y, state.target.z))
            print("Расстояние: " .. string.format("%.1f", getDistance(state.position, state.target)))
        else
            print("Цель: не задана")
        end
        return true
    end

    if cmd == "exit" then
        print("Завершение работы...")
        cannon.setComputerControl(false)
        return false
    end

    print("Неизвестная команда. Введите 'help' для списка.")
    return true
end

-- ============================================
-- Основной цикл
-- ============================================

print("=== Артиллерийская система (скорость в м/с) ===")
print("Введите 'help' для списка команд")
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
print("Программа завершена.")
