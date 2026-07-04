--[[
  monitor.lua - Отслеживание уровня жидкости в бочке Create
  Использует периферийный API ComputerCraft и мод CC:C Bridge
]]

-- === НАСТРОЙКИ (измени под себя) ===
local barrelSide = "right"    -- С какой стороны от компьютера находится бочка
local redstoneSide = "back"   -- На какую сторону подавать редстоун-сигнал
local threshold = 80.0        -- Порог срабатывания в процентах (0-100)
local checkInterval = 1.0     -- Интервал проверки в секундах
-- ===================================

-- Функция для получения уровня жидкости в процентах
local function getBarrelLevel(peripheral)
    -- Пытаемся получить информацию о всех ёмкостях (танках) в блоке
    local tanks = peripheral.tanks()
    if not tanks or #tanks == 0 then
        return nil
    end

    -- Суммируем всю жидкость (на случай, если у бочки несколько слотов)
    local totalAmount = 0
    local totalCapacity = 0
    for _, tank in ipairs(tanks) do
        if tank then -- проверяем, что слот не пустой
            totalAmount = totalAmount + (tank.amount or 0)
            totalCapacity = totalCapacity + (tank.capacity or 0)
        end
    end

    if totalCapacity == 0 then
        return 0
    end

    return (totalAmount / totalCapacity) * 100
end

-- Основной цикл программы
local function main()
    print("Подключение к бочке...")

    -- Подключаемся к бочке как к периферии
    local barrel = peripheral.wrap(barrelSide)
    if not barrel then
        print("ОШИБКА: Бочка не найдена на стороне " .. barrelSide)
        print("Убедитесь, что установлен мод CC:C Bridge.")
        return
    end

    -- Проверяем, есть ли у бочки метод tanks() (признак, что это ёмкость)
    if not barrel.tanks then
        print("ОШИБКА: Блок на стороне " .. barrelSide .. " не является ёмкостью.")
        return
    end

    print("Начинаем мониторинг. Порог: " .. threshold .. "%")
    print("Для остановки нажмите Ctrl+T")

    -- Переменная для хранения предыдущего состояния сигнала
    local signalActive = false

    while true do
        local level = getBarrelLevel(barrel)

        if level == nil then
            print("ОШИБКА: Не удалось получить уровень жидкости.")
            break
        end

        -- Проверяем, достигнут ли порог
        local shouldSignal = level >= threshold

        -- Подаём сигнал, только если состояние изменилось
        if shouldSignal ~= signalActive then
            if shouldSignal then
                print(string.format("Достигнут порог! Уровень: %.1f%%", level))
            else
                print(string.format("Уровень упал ниже порога: %.1f%%", level))
            end

            -- Подаём сигнал на указанную сторону
            redstone.setOutput(redstoneSide, shouldSignal)
            signalActive = shouldSignal
        end

        -- Ждём перед следующей проверкой
        sleep(checkInterval)
    end

    -- Выключаем сигнал при завершении программы
    redstone.setOutput(redstoneSide, false)
    print("Программа остановлена.")
end

-- Запускаем программу
main()
