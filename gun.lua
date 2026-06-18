-- ============================================
-- Артиллерийская система наведения
-- Использует CC:CBC и Create Avionics
-- ============================================

-- Конфигурация
local CONFIG = {
    -- Имя периферийного устройства пушки (можно изменить при необходимости)
    cannonPeripheral = "cannon_mount_0",
    -- Сторона монитора
    monitorSide = "top",
    -- Задержка обновления монитора (в тиках)
    updateInterval = 5,
    -- Диапазон углов наведения (в градусах)
    minYaw = 0,
    maxYaw = 360,
    minPitch = -90,
    maxPitch = 90
}

-- ============================================
-- Инициализация периферийных устройств
-- ============================================

-- Поиск монитора
local monitor = peripheral.find("monitor")
if not monitor then
    error("Монитор не найден! Подключите монитор к компьютеру.")
end
monitor.setTextScale(0.5)
monitor.clear()
monitor.setCursorPos(1, 1)

-- Поиск пушки
local cannon = peripheral.find("cannon_mount")
if not cannon then
    error("Пушка не найдена! Убедитесь, что она подключена к компьютеру.")
end

-- Включаем компьютерное управление
cannon.setComputerControl(true)
print("✓ Компьютерное управление включено")

-- Поиск навигационного стола
local navTable = peripheral.find("navigation_table")
if not navTable then
    print("⚠ Навигационный стол не найден. Для работы с целями требуется Create Avionics.")
end

-- Поиск GPS (опционально)
local gps = peripheral.find("gps")
if gps then
    print("✓ GPS найден")
end

-- ============================================
-- Состояние системы
-- ============================================

local state = {
    -- Текущие координаты пушки (заполняются из getInfo)
    position = { x = 0, y = 0, z = 0 },
    -- Целевые координаты
    target = { x = nil, y = nil, z = nil },
    -- Текущие углы пушки
    currentYaw = 0,
    currentPitch = 0,
    -- Целевые углы
    targetYaw = 0,
    targetPitch = 0,
    -- Статус
    isAssembled = false,
    isFiring = false,
    isComputerControl = true,
    -- Время последнего обновления
    lastUpdate = 0
}

-- ============================================
-- Вспомогательные функции
-- ============================================

-- Нормализация угла в диапазон [-180, 180]
local function normalizeAngle(angle)
    angle = angle % 360
    if angle > 180 then
        angle = angle - 360
    elseif angle < -180 then
        angle = angle + 360
    end
    return angle
end

-- Ограничение угла в заданном диапазоне
local function clampAngle(angle, min, max)
    return math.max(min, math.min(max, angle))
end

-- Вычисление расстояния между двумя точками
local function getDistance(p1, p2)
    local dx = p1.x - p2.x
    local dy = p1.y - p2.y
    local dz = p1.z - p2.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Вычисление азимута (yaw) между двумя точками
local function calculateYaw(from, to)
    local dx = to.x - from.x
    local dz = to.z - from.z
    local yaw = math.atan2(dx, dz) * (180 / math.pi)
    return normalizeAngle(yaw)
end

-- Вычисление угла места (pitch) между двумя точками
local function calculatePitch(from, to)
    local dx = to.x - from.x
    local dy = to.y - from.y
    local dz = to.z - from.z
    local horizontalDist = math.sqrt(dx*dx + dz*dz)
    if horizontalDist < 0.001 then
        return dy > 0 and 90 or -90
    end
    local pitch = math.atan2(dy, horizontalDist) * (180 / math.pi)
    return clampAngle(pitch, CONFIG.minPitch, CONFIG.maxPitch)
end

-- ============================================
-- Функции управления пушкой
-- ============================================

-- Обновление информации о пушке
local function updateCannonInfo()
    local info = cannon.getInfo()
    if info then
        state.position.x = info.x or 0
        state.position.y = info.y or 0
        state.position.z = info.z or 0
        state.currentYaw = info.yaw or 0
        state.currentPitch = info.pitch or 0
        state.isAssembled = info.assembled or false
        state.isComputerControl = info.computerControl or false
    end
end

-- Наведение пушки на цель
local function aimAtTarget()
    if not state.target.x or not state.target.y or not state.target.z then
        return false, "Цель не задана"
    end
    
    local yaw = calculateYaw(state.position, state.target)
    local pitch = calculatePitch(state.position, state.target)
    
    state.targetYaw = yaw
    state.targetPitch = pitch
    
    cannon.setTargetAngles(yaw, pitch)
    return true, "OK"
end

-- Огонь!
local function fire()
    if not state.isAssembled then
        return false, "Пушка не собрана"
    end
    cannon.fire(true)
    sleep(0.1)
    cannon.fire(false)
    return true, "Выстрел!"
end

-- Сборка/разборка пушки
local function assemble(enable)
    local result = cannon.assemble(enable)
    state.isAssembled = result
    return result
end

-- ============================================
-- Функции отображения на мониторе
-- ============================================

-- Отрисовка интерфейса на мониторе
local function drawUI()
    monitor.clear()
    monitor.setCursorPos(1, 1)
    
    -- Заголовок
    monitor.setTextColor(colors.cyan)
    monitor.write("╔═══════════════════════════════════════╗")
    monitor.setCursorPos(1, 2)
    monitor.write("║     АРТИЛЛЕРИЙСКАЯ СИСТЕМА          ║")
    monitor.setCursorPos(1, 3)
    monitor.write("╚═══════════════════════════════════════╝")
    
    local line = 5
    
    -- Информация о пушке
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("📌 СТАТУС ПУШКИ:")
    line = line + 1
    
    monitor.setTextColor(state.isAssembled and colors.green or colors.red)
    monitor.setCursorPos(3, line)
    monitor.write("Собрана: " .. tostring(state.isAssembled))
    line = line + 1
    
    monitor.setTextColor(state.isComputerControl and colors.green or colors.red)
    monitor.setCursorPos(3, line)
    monitor.write("Комп. управление: " .. tostring(state.isComputerControl))
    line = line + 1
    
    -- Координаты
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("📍 ПОЗИЦИЯ:")
    line = line + 1
    monitor.setTextColor(colors.yellow)
    monitor.setCursorPos(3, line)
    monitor.write(string.format("X: %6.1f  Y: %6.1f  Z: %6.1f", 
        state.position.x, state.position.y, state.position.z))
    line = line + 1
    
    -- Углы
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(1, line)
    monitor.write("🎯 УГЛЫ НАВЕДЕНИЯ:")
    line = line + 1
    monitor.setTextColor(colors.yellow)
    monitor.setCursorPos(3, line)
    monitor.write(string.format("Текущий Yaw: %7.2f°", state.currentYaw))
    line = line + 1
    monitor.setCursorPos(3, line)
    monitor.write(string.format("Текущий Pitch: %5.2f°", state.currentPitch))
    line = line + 1
    
    if state.target.x then
        monitor.setTextColor(colors.green)
        monitor.setCursorPos(3, line)
        monitor.write(string.format("Целевой Yaw: %7.2f°", state.targetYaw))
        line = line + 1
        monitor.setCursorPos(3, line)
        monitor.write(string.format("Целевой Pitch: %5.2f°", state.targetPitch))
        line = line + 1
        
        -- Расстояние до цели
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
    
    -- Цель
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
    
    -- Строка помощи
    monitor.setTextColor(colors.gray)
    monitor.setCursorPos(1, 20)
    monitor.write("Команды: target <x> <y> <z> | fire | assemble")
    monitor.setCursorPos(1, 21)
    monitor.write("         status | help | exit")
end

-- ============================================
-- Обработка команд
-- ============================================

-- Парсинг и выполнение команд
local function processCommand(input)
    if not input or input == "" then
        return
    end
    
    -- Разбиваем на слова
    local args = {}
    for word in input:gmatch("%S+") do
        table.insert(args, word)
    end
    
    if #args == 0 then
        return
    end
    
    local cmd = args[1]:lower()
    
    -- Команда: help
    if cmd == "help" then
        print("Доступные команды:")
        print("  target <x> <y> <z>  - установить цель")
        print("  fire                - выстрелить")
        print("  assemble [on/off]   - собрать/разобрать пушку")
        print("  status              - показать статус")
        print("  exit                - выход из программы")
        return
    end
    
    -- Команда: target
    if cmd == "target" then
        if #args < 4 then
            print("Использование: target <x> <y> <z>")
            return
        end
        local x = tonumber(args[2])
        local y = tonumber(args[3])
        local z = tonumber(args[4])
        if not x or not y or not z then
            print("Ошибка: координаты должны быть числами")
            return
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
        return
    end
    
    -- Команда: fire
    if cmd == "fire" then
        local success, msg = fire()
        print(success and "✓ " .. msg or "✗ " .. msg)
        return
    end
    
    -- Команда: assemble
    if cmd == "assemble" then
        local enable
        if #args >= 2 then
            if args[2] == "on" or args[2] == "true" or args[2] == "1" then
                enable = true
            elseif args[2] == "off" or args[2] == "false" or args[2] == "0" then
                enable = false
            else
                print("Использование: assemble [on/off]")
                return
            end
        else
            enable = not state.isAssembled
        end
        local result = assemble(enable)
        print(result and "✓ Пушка " .. (enable and "собрана" or "разобрана") or "✗ Ошибка")
        return
    end
    
    -- Команда: status
    if cmd == "status" then
        print("=== СТАТУС СИСТЕМЫ ===")
        print("Позиция: " .. string.format("(%.1f, %.1f, %.1f)", 
            state.position.x, state.position.y, state.position.z))
        print("Углы: Yaw=%.2f°, Pitch=%.2f°".format(state.currentYaw, state.currentPitch))
        print("Собрана: " .. tostring(state.isAssembled))
        print("Комп. управление: " .. tostring(state.isComputerControl))
        if state.target.x then
            print("Цель: " .. string.format("(%.1f, %.1f, %.1f)", 
                state.target.x, state.target.y, state.target.z))
            print("Расстояние: " .. string.format("%.1f", 
                getDistance(state.position, state.target)))
        else
            print("Цель: не задана")
        end
        return
    end
    
    -- Команда: exit
    if cmd == "exit" then
        print("Завершение работы...")
        cannon.setComputerControl(false)
        return false
    end
    
    print("Неизвестная команда. Введите 'help' для списка команд.")
    return true
end

-- ============================================
-- Основной цикл программы
-- ============================================

print("=== Артиллерийская система наведения ===")
print("Введите 'help' для списка команд")
print("")

-- Основной цикл
local running = true
local tick = 0

while running do
    -- Обновление информации о пушке
    updateCannonInfo()
    
    -- Обновление монитора с заданной периодичностью
    tick = tick + 1
    if tick >= CONFIG.updateInterval then
        tick = 0
        drawUI()
    end
    
    -- Проверка ввода с клавиатуры (неблокирующая)
    local event, key, char = os.pullEvent("key")
    if event == "key" and char then
        -- Здесь можно обрабатывать нажатия клавиш для быстрого управления
    end
    
    -- Проверка ввода с консоли (блокирующая)
    -- Используем parallel для одновременного ожидания ввода и обновления
    -- Вместо этого используем простой подход: проверяем ввод каждую итерацию
    -- с помощью read() с таймаутом
end

-- Завершение
cannon.setComputerControl(false)
print("Программа завершена.")
