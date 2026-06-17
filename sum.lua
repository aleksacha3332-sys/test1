-- ==========================================
-- НАСТРОЙКА ВХОДОВ (Ваш пульт управления)
-- ==========================================
local inputSides = {
  G   = "left",    -- Крен влево (на ПК)
  B   = "right",   -- Крен вправо (на ПК)
  V   = "front",   -- Тангаж вперед (на ПК)
  A   = "back",    -- Тангаж назад (на ПК)
  Y_L = "bottom",  -- Поворот влево (на ПК, снизу)
  
  -- Y_R перенесен! Теперь мы не опрашиваем верх ПК ("top").
  -- Вместо этого мы будем считывать сигнал прямо через блок Реле 0.
}

-- ==========================================
-- ПОДКЛЮЧЕНИЕ РЕДСТОУН РЕЛЕ
-- ==========================================
-- ВАЖНО: Для работы новой схемы Реле 0 должно стоять вплотную к компьютеру!
local relay0 = peripheral.wrap("redstone_relay_0") -- УСКОРЕНИЕ (Макс. 10)
local relay1 = peripheral.wrap("redstone_relay_1") -- ЗАМЕДЛЕНИЕ (0 - нет, 15 - стоп)
local relay2 = peripheral.wrap("redstone_relay_2") -- РЕВЕРС ТЯГИ (0 - выкл, 15 - вкл)

-- Проверка подключения устройств
if not relay0 or not relay1 or not relay2 then
  print("[ОШИБКА]: Одно из трех Реле не найдено!")
  return
end
print("[ГОТОВО]: Все 3 реле подключены. Физика Yaw перенаправлена на Реле 0!")

-- Направление выходов на реле
local outputSides = {
  out1 = "front",
  out2 = "back",
  out3 = "left",
  out4 = "right"
}

-- ==========================================
-- ФУНКЦИЯ УПРАВЛЕНИЯ ОДНИМ МОТОРОМ
-- ==========================================
local function setMotor(side, out_val, is_idle)
  if is_idle then
    -- РЕЖИМ ХОВЕРА: Кнопок не жмем — глушим газ, зажимаем тормоз
    relay0.setAnalogOutput(side, 0)
    relay1.setAnalogOutput(side, 15)
    relay2.setAnalogOutput(side, 0)
  else
    -- Режим активного полета
    if out_val > 0 then
      -- 1. Набор мощности (Ограничение до 10)
      local accel = math.min(out_val, 10)
      relay0.setAnalogOutput(side, accel)
      relay1.setAnalogOutput(side, 0)
      relay2.setAnalogOutput(side, 0)
      
    elseif out_val < 0 then
      -- 2. Активный реверс при резком развороте
      local accel = math.min(math.abs(out_val), 10)
      relay0.setAnalogOutput(side, accel)
      relay1.setAnalogOutput(side, 0)
      relay2.setAnalogOutput(side, 15)
      
    else
      -- 3. Нейтральная передача (Дрейф)
      relay0.setAnalogOutput(side, 0)
      relay1.setAnalogOutput(side, 0)
      relay2.setAnalogOutput(side, 0)
    end
  end
end

-- ==========================================
-- ГЛАВНЫЙ ПОЛЕТНЫЙ ЦИКЛ
-- ==========================================
while true do
  -- Считываем стандартные аналоговые сигналы с корпуса ПК
  local a = redstone.getAnalogInput(inputSides.A)
  local b = redstone.getAnalogInput(inputSides.B)
  local v = redstone.getAnalogInput(inputSides.V)
  local g = redstone.getAnalogInput(inputSides.G)
  local yaw_l = redstone.getAnalogInput(inputSides.Y_L)
  
  -- НОВАЯ ЛОГИКА: Считываем сигнал Y_R, который приходит на ВЕРХУШКУ Редстоун Реле 0.
  -- Функция подтягивает уровень сигнала, проходящего через блок периферии.
  local yaw_r = relay0.getAnalogInput("top") 
  
  -- Считаем общую силу поворота вокруг оси
  local yaw = yaw_r - yaw_l 
  
  -- Проверяем, отпущен ли пульт управления
  local is_idle = (a == 0 and b == 0 and v == 0 and g == 0 and yaw_l == 0 and yaw_r == 0)

  -- Вычисляем результирующую матрицу для каждого винта
  local out1_val = a + g + yaw
  local out2_val = a + b - yaw
  local out3_val = b + v + yaw
  local out4_val = v + g - yaw

  -- Передаем значения на моторы через функцию распределения по реле
  setMotor(outputSides.out1, out1_val, is_idle)
  setMotor(outputSides.out2, out2_val, is_idle)
  setMotor(outputSides.out3, out3_val, is_idle)
  setMotor(outputSides.out4, out4_val, is_idle)

  -- Задержка в 1 тик сервера для предотвращения лагов
  os.sleep(0.05)
end
