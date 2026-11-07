-- CC Arcade for CC:Tweaked
-- Minecraft 1.21.1
-- Use one or two advanced monitors. A 3x3 monitor at scale 0.5 is recommended.
-- All games are controlled with monitor_touch events.

local VERSION = "1.0.0"
local SCORE_FILE = "cc_arcade_scores.cfg"
local C = colors

local detected = { peripheral.find("monitor") }
local advanced = {}
for _, monitor in ipairs(detected) do
    if monitor.isColor and monitor.isColor() then
        advanced[#advanced + 1] = monitor
    end
end

table.sort(advanced, function(a, b)
    return peripheral.getName(a) < peripheral.getName(b)
end)

if #advanced == 0 then
    error("Connect an advanced monitor before starting CC Arcade.")
end

local main = advanced[1]
local info = advanced[2] or advanced[1]
local mainName = peripheral.getName(main)
local oldMainScale = main.getTextScale()
local oldInfoScale = info.getTextScale()

main.setTextScale(0.5)
if info ~= main then
    info.setTextScale(0.5)
end

local scores = {}
local gameDefs = {}

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function writeAt(screen, x, y, text, fg, bg)
    local width, height = screen.getSize()
    x = math.floor(x)
    y = math.floor(y)
    if y < 1 or y > height or x > width then
        return
    end
    text = tostring(text)
    if x < 1 then
        text = text:sub(2 - x)
        x = 1
    end
    if #text == 0 then
        return
    end
    text = text:sub(1, width - x + 1)
    screen.setCursorPos(x, y)
    screen.setTextColor(fg or C.white)
    screen.setBackgroundColor(bg or C.black)
    screen.write(text)
end

local function fill(screen, x, y, width, height, bg, character)
    local screenWidth, screenHeight = screen.getSize()
    character = character or " "
    local x1 = math.max(1, math.floor(x))
    local y1 = math.max(1, math.floor(y))
    local x2 = math.min(screenWidth, math.floor(x + width - 1))
    local y2 = math.min(screenHeight, math.floor(y + height - 1))
    if x2 < x1 or y2 < y1 then
        return
    end
    screen.setBackgroundColor(bg or C.black)
    local line = string.rep(character, x2 - x1 + 1)
    for row = y1, y2 do
        screen.setCursorPos(x1, row)
        screen.write(line)
    end
end

local function clear(screen, bg)
    screen.setBackgroundColor(bg or C.black)
    screen.clear()
end

local function center(screen, y, text, fg, bg)
    local width = screen.getSize()
    writeAt(screen, math.floor((width - #tostring(text)) / 2) + 1, y, text, fg, bg)
end

local function button(screen, x, y, width, height, label, bg, fg)
    fill(screen, x, y, width, height, bg or C.gray)
    local textY = y + math.floor((height - 1) / 2)
    local textX = x + math.floor((width - #tostring(label)) / 2)
    writeAt(screen, textX, textY, label, fg or C.white, bg or C.gray)
    return { x = x, y = y, w = width, h = height }
end

local function hit(area, x, y)
    return area and x >= area.x and x < area.x + area.w and y >= area.y and y < area.y + area.h
end

local function header(screen, title, subtitle)
    local width = screen.getSize()
    fill(screen, 1, 1, width, 3, C.blue)
    center(screen, 1, title, C.white, C.blue)
    if subtitle then
        center(screen, 2, subtitle, C.lightBlue, C.blue)
    end
end

local function backButton()
    local width, height = main.getSize()
    return button(main, width - 7, height, 8, 1, "Back", C.red)
end

local function gameBase(title, subtitle)
    clear(main)
    header(main, title, subtitle)
    return backButton()
end

local function wrappedLines(text, width)
    local lines = {}
    local current = ""
    for word in tostring(text):gmatch("%S+") do
        if #current == 0 then
            current = word
        elseif #current + #word + 1 <= width then
            current = current .. " " .. word
        else
            lines[#lines + 1] = current
            current = word
        end
    end
    if #current > 0 then
        lines[#lines + 1] = current
    end
    return lines
end

local function bestText(id)
    local value = scores[id]
    if value == nil then
        return "--"
    end
    for _, game in ipairs(gameDefs) do
        if game.id == id then
            return tostring(value) .. (game.unit and (" " .. game.unit) or "")
        end
    end
    return tostring(value)
end

local function showInfo(title, description, statusLines, id)
    if info == main then
        return
    end
    clear(info)
    header(info, title, "CC Arcade " .. VERSION)
    local width, height = info.getSize()
    local y = 5
    for _, line in ipairs(wrappedLines(description or "", width - 4)) do
        if y > height - 4 then
            break
        end
        writeAt(info, 3, y, line, C.lightGray)
        y = y + 1
    end
    y = y + 1
    if id then
        writeAt(info, 3, y, "Best: " .. bestText(id), C.yellow)
        y = y + 2
    end
    for _, line in ipairs(statusLines or {}) do
        if y > height - 2 then
            break
        end
        for _, wrapped in ipairs(wrappedLines(line, width - 4)) do
            writeAt(info, 3, y, wrapped, C.white)
            y = y + 1
        end
    end
    fill(info, 1, height, width, 1, C.gray)
    center(info, height, "Use the main monitor to play", C.white, C.gray)
end

local function loadScores()
    if not fs.exists(SCORE_FILE) then
        return
    end
    local file = fs.open(SCORE_FILE, "r")
    if file then
        local data = file.readAll()
        file.close()
        local loaded = textutils.unserialize(data)
        if type(loaded) == "table" then
            scores = loaded
        end
    end
end

local function saveScores()
    local file = fs.open(SCORE_FILE, "w")
    if file then
        file.write(textutils.serialize(scores))
        file.close()
    end
end

local function recordResult(id, value)
    if value == nil then
        return
    end
    local definition
    for _, game in ipairs(gameDefs) do
        if game.id == id then
            definition = game
            break
        end
    end
    local old = scores[id]
    local better = old == nil
    if old ~= nil and definition then
        if definition.lowerIsBetter then
            better = value < old
        else
            better = value > old
        end
    end
    if better then
        scores[id] = value
        saveScores()
    end
end

local function resultScreen(title, detail)
    local width, height = main.getSize()
    local boxWidth = math.min(width - 4, math.max(30, #tostring(detail) + 6))
    local x = math.floor((width - boxWidth) / 2) + 1
    local y = math.floor(height / 2) - 3
    fill(main, x, y, boxWidth, 7, C.gray)
    center(main, y + 2, title, C.yellow, C.gray)
    center(main, y + 4, detail, C.white, C.gray)
    center(main, y + 6, "Touch to continue", C.lightGray, C.gray)
    local timer = os.startTimer(4)
    while true do
        local event, p1 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            return
        elseif event == "timer" and p1 == timer then
            return
        end
    end
end

local function gridAreas(columns, rows, x, y, cellWidth, cellHeight, gap)
    gap = gap or 0
    local areas = {}
    for row = 1, rows do
        areas[row] = {}
        for column = 1, columns do
            areas[row][column] = {
                x = x + (column - 1) * (cellWidth + gap),
                y = y + (row - 1) * (cellHeight + gap),
                w = cellWidth,
                h = cellHeight
            }
        end
    end
    return areas
end

local function randomFreeCell(columns, rows, occupied)
    local free = {}
    for row = 1, rows do
        for column = 1, columns do
            if not occupied[column .. "," .. row] then
                free[#free + 1] = { x = column, y = row }
            end
        end
    end
    if #free == 0 then
        return nil
    end
    return free[math.random(#free)]
end

math.randomseed(os.epoch("utc") % 2147483647)
loadScores()

-- 1. Reaction
local function playReaction()
    local back = gameBase("Reaction", "Wait for green, then touch the screen")
    local state = "waiting"
    local startedAt = 0
    local waitTimer = os.startTimer(1.5 + math.random() * 2.5)
    local timeoutTimer = nil

    local function draw()
        local width, height = main.getSize()
        local bg = state == "ready" and C.green or C.orange
        fill(main, 2, 5, width - 2, height - 6, bg)
        center(main, math.floor(height / 2) - 1,
            state == "ready" and "TAP NOW!" or "WAIT...", state == "ready" and C.white or C.yellow, bg)
        center(main, math.floor(height / 2) + 1,
            state == "ready" and "Touch anywhere in this panel" or "Do not touch yet", C.white, bg)
        back = backButton()
    end

    draw()
    showInfo("Reaction", "Wait until the panel turns green. Touch it as quickly as possible. An early touch ends the round.",
        { "The result is measured in milliseconds.", "Lower results are better." }, "reaction")

    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            elseif state == "waiting" then
                resultScreen("Too soon!", "Wait for the green panel.")
                return nil
            elseif state == "ready" then
                local elapsed = math.max(1, math.floor((os.clock() - startedAt) * 1000 + 0.5))
                resultScreen("Reaction time", elapsed .. " ms")
                return elapsed
            end
        elseif event == "timer" and p1 == waitTimer and state == "waiting" then
            state = "ready"
            startedAt = os.clock()
            timeoutTimer = os.startTimer(3)
            draw()
        elseif event == "timer" and p1 == timeoutTimer and state == "ready" then
            resultScreen("Time expired", "Try to react faster.")
            return nil
        end
    end
end

-- 2. Whack-a-Mole
local function playWhack()
    local back = gameBase("Whack-a-Mole", "Hit as many targets as you can in 30 seconds")
    local width, height = main.getSize()
    local cellWidth = math.min(11, math.floor((width - 8) / 3))
    local cellHeight = 4
    local boardWidth = cellWidth * 3 + 2
    local areas = gridAreas(3, 3, math.floor((width - boardWidth) / 2) + 1, 6, cellWidth, cellHeight, 1)
    local flat = {}
    for row = 1, 3 do
        for column = 1, 3 do
            flat[#flat + 1] = areas[row][column]
        end
    end

    local hitsScore = 0
    local misses = 0
    local active = math.random(9)
    local startedAt = os.clock()
    local lastMove = startedAt
    local timer = os.startTimer(0.1)

    local function draw()
        writeAt(main, 3, 4, string.format("Time: %02d  Hits: %d  Misses: %d",
            math.max(0, math.ceil(30 - (os.clock() - startedAt))), hitsScore, misses), C.yellow)
        for index, area in ipairs(flat) do
            local isActive = index == active
            button(main, area.x, area.y, area.w, area.h, isActive and "MOLE" or "", isActive and C.orange or C.gray)
        end
        back = backButton()
        showInfo("Whack-a-Mole", "Touch the brown MOLE buttons before they move. The round lasts 30 seconds.",
            { "Hits: " .. hitsScore, "Misses: " .. misses, "More hits give a better result." }, "whack")
    end

    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            end
            for index, area in ipairs(flat) do
                if hit(area, p2, p3) then
                    if index == active then
                        hitsScore = hitsScore + 1
                        active = nil
                        lastMove = os.clock()
                    else
                        misses = misses + 1
                    end
                    draw()
                    break
                end
            end
        elseif event == "timer" and p1 == timer then
            local now = os.clock()
            if now - startedAt >= 30 then
                resultScreen("Round complete", "Hits: " .. hitsScore .. "  Misses: " .. misses)
                return hitsScore
            end
            if now - lastMove >= 0.45 then
                active = math.random(9)
                lastMove = now
            end
            draw()
            timer = os.startTimer(0.1)
        end
    end
end

-- 3. Simon
local function playSimon()
    local back = gameBase("Simon", "Watch the sequence, then repeat it")
    local width, height = main.getSize()
    local padWidth = math.min(16, math.floor((width - 7) / 2))
    local padHeight = math.min(6, math.floor((height - 11) / 2))
    local areas = gridAreas(2, 2, math.floor((width - (padWidth * 2 + 1)) / 2) + 1, 6,
        padWidth, padHeight, 1)
    local pads = { areas[1][1], areas[1][2], areas[2][1], areas[2][2] }
    local padColors = { C.green, C.red, C.yellow, C.blue }
    local sequence = { math.random(4) }
    local inputIndex = 1
    local showIndex = 1
    local state = "show"
    local phase = "on"
    local lit = sequence[1]
    local timer = os.startTimer(0.6)

    local function draw()
        writeAt(main, 3, 4, "Round: " .. #sequence .. "  " ..
            (state == "input" and "Your turn" or state == "between" and "Correct!" or "Watch"), C.yellow)
        for index, area in ipairs(pads) do
            local isLit = lit == index
            button(main, area.x, area.y, area.w, area.h, tostring(index),
                isLit and C.white or padColors[index], isLit and C.black or C.white)
        end
        back = backButton()
        showInfo("Simon", "Watch the pads flash, then touch them in the same order. Each round adds one step.",
            { "Round: " .. #sequence, "Completed rounds: " .. (#sequence - 1),
                state == "input" and "Your turn." or "Watch the sequence." }, "simon")
    end

    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            elseif state == "input" then
                for index, area in ipairs(pads) do
                    if hit(area, p2, p3) then
                        if sequence[inputIndex] ~= index then
                            local score = #sequence - 1
                            resultScreen("Wrong pad", "Completed rounds: " .. score)
                            return score
                        end
                        inputIndex = inputIndex + 1
                        if inputIndex > #sequence then
                            state = "between"
                            timer = os.startTimer(0.6)
                        end
                        draw()
                        break
                    end
                end
            end
        elseif event == "timer" and p1 == timer then
            if state == "between" then
                sequence[#sequence + 1] = math.random(4)
                inputIndex = 1
                showIndex = 1
                state = "show"
                phase = "on"
                lit = sequence[1]
                timer = os.startTimer(0.5)
            elseif state == "show" and phase == "on" then
                lit = nil
                phase = "off"
                timer = os.startTimer(0.15)
            elseif state == "show" then
                showIndex = showIndex + 1
                if showIndex > #sequence then
                    state = "input"
                    inputIndex = 1
                    lit = nil
                else
                    lit = sequence[showIndex]
                    phase = "on"
                    timer = os.startTimer(0.45)
                end
            end
            draw()
        end
    end
end

-- 4. Memory
local function playMemory()
    local back = gameBase("Memory", "Find all eight matching pairs")
    local symbols = {}
    local alphabet = { "A", "B", "C", "D", "E", "F", "G", "H" }
    for _, symbol in ipairs(alphabet) do
        symbols[#symbols + 1] = symbol
        symbols[#symbols + 1] = symbol
    end
    for index = #symbols, 2, -1 do
        local other = math.random(index)
        symbols[index], symbols[other] = symbols[other], symbols[index]
    end

    local width = main.getSize()
    local cellWidth = math.min(8, math.floor((width - 11) / 4))
    local areas = gridAreas(4, 4, math.floor((width - (cellWidth * 4 + 3)) / 2) + 1, 6,
        cellWidth, 3, 1)
    local revealed = {}
    local matched = {}
    local first, second = nil, nil
    local attempts = 0
    local pairsFound = 0
    local locked = false
    local hideTimer = nil

    local function draw()
        writeAt(main, 3, 4, "Moves: " .. attempts .. "  Pairs: " .. pairsFound .. "/8", C.yellow)
        for index = 1, 16 do
            local row = math.floor((index - 1) / 4) + 1
            local column = (index - 1) % 4 + 1
            local area = areas[row][column]
            local visible = revealed[index] or matched[index]
            local bg = matched[index] and C.green or visible and C.lightBlue or C.gray
            button(main, area.x, area.y, area.w, area.h, visible and symbols[index] or "?", bg,
                visible and C.black or C.white)
        end
        back = backButton()
        showInfo("Memory", "Turn over two cards. Matching symbols stay open. Complete all eight pairs in as few moves as possible.",
            { "Moves: " .. attempts, "Pairs: " .. pairsFound .. "/8", "Fewer moves are better." }, "memory")
    end

    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            elseif not locked then
                for index = 1, 16 do
                    local row = math.floor((index - 1) / 4) + 1
                    local column = (index - 1) % 4 + 1
                    if hit(areas[row][column], p2, p3) and not matched[index] and not revealed[index] then
                        revealed[index] = true
                        if not first then
                            first = index
                        else
                            second = index
                            attempts = attempts + 1
                            if symbols[first] == symbols[second] then
                                matched[first] = true
                                matched[second] = true
                                pairsFound = pairsFound + 1
                                revealed[first] = nil
                                revealed[second] = nil
                                first, second = nil, nil
                                if pairsFound == 8 then
                                    draw()
                                    resultScreen("All pairs found", "Moves: " .. attempts)
                                    return attempts
                                end
                            else
                                locked = true
                                hideTimer = os.startTimer(0.75)
                            end
                        end
                        draw()
                        break
                    end
                end
            end
        elseif event == "timer" and p1 == hideTimer then
            revealed[first] = nil
            revealed[second] = nil
            first, second = nil, nil
            locked = false
            hideTimer = nil
            draw()
        end
    end
end

-- 5. Minesweeper
local function playMinesweeper()
    local columns, rows, mineCount = 8, 6, 10
    local back = gameBase("Minesweeper", "Open every safe cell. The first cell is always safe")
    local width, height = main.getSize()
    local cellWidth = math.min(5, math.floor((width - 11) / columns))
    local areas = gridAreas(columns, rows, math.floor((width - (columns * cellWidth + columns - 1)) / 2) + 1,
        6, cellWidth, 2, 1)
    local mines, numbers, revealed, flagged = {}, {}, {}, {}
    local generated = false
    local exploded = false
    local revealedCount = 0
    local flagMode = false
    local startedAt = os.clock()
    local finishedAt = nil
    local timer = os.startTimer(1)
    local mode

    local function indexOf(column, row)
        return (row - 1) * columns + column
    end

    local function generate(safeIndex)
        local placed = 0
        while placed < mineCount do
            local index = math.random(columns * rows)
            if index ~= safeIndex and not mines[index] then
                mines[index] = true
                placed = placed + 1
            end
        end
        for row = 1, rows do
            for column = 1, columns do
                local count = 0
                for dy = -1, 1 do
                    for dx = -1, 1 do
                        local nx, ny = column + dx, row + dy
                        if nx >= 1 and nx <= columns and ny >= 1 and ny <= rows and mines[indexOf(nx, ny)] then
                            count = count + 1
                        end
                    end
                end
                numbers[indexOf(column, row)] = count
            end
        end
        generated = true
        startedAt = os.clock()
    end

    local function draw()
        local elapsed = math.floor((finishedAt or os.clock()) - startedAt)
        writeAt(main, 3, 4, "Time: " .. elapsed .. " s  Open: " .. revealedCount .. "/" .. (columns * rows - mineCount), C.yellow)
        for row = 1, rows do
            for column = 1, columns do
                local index = indexOf(column, row)
                local area = areas[row][column]
                local label = ""
                local bg, fg = C.gray, C.white
                if revealed[index] then
                    bg = C.lightGray
                    fg = C.black
                    if numbers[index] > 0 then
                        label = tostring(numbers[index])
                    end
                elseif flagged[index] then
                    label = "F"
                    fg = C.yellow
                elseif exploded and mines[index] then
                    label = "X"
                    bg = C.red
                end
                button(main, area.x, area.y, area.w, area.h, label, bg, fg)
            end
        end
        mode = button(main, 2, height, 12, 1, flagMode and "Mode: Flag" or "Mode: Open", flagMode and C.orange or C.cyan)
        back = backButton()
        showInfo("Minesweeper", "Numbers show how many mines touch a cell. Use Flag mode to mark suspected mines. Win by opening every safe cell.",
            { "Mines: " .. mineCount, "Time: " .. elapsed .. " s", "The first opened cell is safe.",
                "A winning time is saved; lower is better." }, "mines")
    end

    local function reveal(startIndex)
        if revealed[startIndex] or flagged[startIndex] then
            return false
        end
        if mines[startIndex] then
            exploded = true
            finishedAt = os.clock()
            return true
        end
        local stack = { startIndex }
        while #stack > 0 do
            local index = table.remove(stack)
            if not revealed[index] and not flagged[index] and not mines[index] then
                revealed[index] = true
                revealedCount = revealedCount + 1
                if numbers[index] == 0 then
                    local row = math.floor((index - 1) / columns) + 1
                    local column = (index - 1) % columns + 1
                    for dy = -1, 1 do
                        for dx = -1, 1 do
                            local nx, ny = column + dx, row + dy
                            if nx >= 1 and nx <= columns and ny >= 1 and ny <= rows then
                                local neighbor = indexOf(nx, ny)
                                if not revealed[neighbor] and not mines[neighbor] then
                                    stack[#stack + 1] = neighbor
                                end
                            end
                        end
                    end
                end
            end
        end
        return false
    end

    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            elseif hit(mode, p2, p3) and not exploded then
                flagMode = not flagMode
                draw()
            elseif not exploded then
                local handled = false
                for row = 1, rows do
                    for column = 1, columns do
                        if hit(areas[row][column], p2, p3) then
                            local index = indexOf(column, row)
                            if flagMode then
                                if not revealed[index] then
                                    flagged[index] = not flagged[index] or nil
                                end
                            else
                                if not generated then
                                    generate(index)
                                end
                                if reveal(index) then
                                    draw()
                                    resultScreen("Boom!", "You touched a mine.")
                                    return nil
                                elseif revealedCount == columns * rows - mineCount then
                                    finishedAt = os.clock()
                                    local elapsed = math.max(1, math.floor(finishedAt - startedAt))
                                    draw()
                                    resultScreen("Field cleared", "Time: " .. elapsed .. " s")
                                    return elapsed
                                end
                            end
                            draw()
                            handled = true
                            break
                        end
                    end
                    if handled then
                        break
                    end
                end
            end
        elseif event == "timer" and p1 == timer and not exploded then
            draw()
            timer = os.startTimer(1)
        end
    end
end

-- 6. Snake
local function playSnake()
    local back = gameBase("Snake", "Eat food and avoid walls and your own tail")
    local width, height = main.getSize()
    local columns = math.min(24, math.floor((width - 4) / 2))
    local rows = math.min(15, height - 12)
    local boardX = math.floor((width - columns * 2) / 2) + 1
    local boardY = 5
    local middle = math.floor(rows / 2)
    local snake = { { x = 5, y = middle }, { x = 4, y = middle }, { x = 3, y = middle } }
    local direction = { x = 1, y = 0 }
    local occupied = { ["3," .. middle] = true, ["4," .. middle] = true, ["5," .. middle] = true }
    local food = randomFreeCell(columns, rows, occupied)
    local score = 0
    local timer = os.startTimer(0.15)
    local controls = {}

    local function setDirection(x, y)
        if #snake > 1 and x == -direction.x and y == -direction.y then
            return
        end
        direction = { x = x, y = y }
    end

    local function draw()
        writeAt(main, 3, 4, "Length: " .. #snake .. "  Food: " .. score, C.yellow)
        fill(main, boardX, boardY, columns * 2, rows, C.black)
        writeAt(main, boardX + (food.x - 1) * 2, boardY + food.y - 1, "[]", C.red, C.black)
        for index, part in ipairs(snake) do
            writeAt(main, boardX + (part.x - 1) * 2, boardY + part.y - 1,
                index == 1 and "()" or "[]", index == 1 and C.lime or C.green, C.black)
        end
        controls.left = button(main, 2, height - 2, 7, 2, "<", C.gray)
        controls.down = button(main, 10, height - 2, 7, 2, "v", C.gray)
        controls.up = button(main, 18, height - 2, 7, 2, "^", C.gray)
        controls.right = button(main, 26, height - 2, 7, 2, ">", C.gray)
        back = backButton()
        showInfo("Snake", "Use the on-screen arrow buttons to turn. Eat red food to grow. Touching a wall or your tail ends the run.",
            { "Food eaten: " .. score, "Length: " .. #snake, "Higher scores are better." }, "snake")
    end

    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            elseif hit(controls.left, p2, p3) then
                setDirection(-1, 0)
            elseif hit(controls.right, p2, p3) then
                setDirection(1, 0)
            elseif hit(controls.up, p2, p3) then
                setDirection(0, -1)
            elseif hit(controls.down, p2, p3) then
                setDirection(0, 1)
            end
        elseif event == "timer" and p1 == timer then
            local head = { x = snake[1].x + direction.x, y = snake[1].y + direction.y }
            if head.x < 1 or head.x > columns or head.y < 1 or head.y > rows then
                resultScreen("Game over", "Food eaten: " .. score)
                return score
            end
            local ate = food and head.x == food.x and head.y == food.y
            if not ate then
                local tail = table.remove(snake)
                occupied[tail.x .. "," .. tail.y] = nil
            end
            if occupied[head.x .. "," .. head.y] then
                resultScreen("Game over", "Food eaten: " .. score)
                return score
            end
            table.insert(snake, 1, head)
            occupied[head.x .. "," .. head.y] = true
            if ate then
                score = score + 1
                food = randomFreeCell(columns, rows, occupied)
                if not food then
                    resultScreen("Board complete", "Perfect snake!")
                    return score
                end
            end
            draw()
            timer = os.startTimer(0.14)
        end
    end
end

-- 7. 2048
local function play2048()
    local back = gameBase("2048", "Slide tiles and merge equal numbers")
    local width, height = main.getSize()
    local cellWidth = math.min(8, math.floor((width - 11) / 4))
    local areas = gridAreas(4, 4, math.floor((width - (cellWidth * 4 + 3)) / 2) + 1, 6, cellWidth, 3, 1)
    local grid = {}
    for row = 1, 4 do
        grid[row] = { 0, 0, 0, 0 }
    end
    local score = 0
    local controls = {}

    local function addTile()
        local empty = {}
        for row = 1, 4 do
            for column = 1, 4 do
                if grid[row][column] == 0 then
                    empty[#empty + 1] = { row, column }
                end
            end
        end
        if #empty > 0 then
            local cell = empty[math.random(#empty)]
            grid[cell[1]][cell[2]] = math.random() < 0.9 and 2 or 4
        end
    end

    local function slideLine(line)
        local compact = {}
        for index = 1, 4 do
            if line[index] ~= 0 then
                compact[#compact + 1] = line[index]
            end
        end
        local output = {}
        local gained = 0
        local index = 1
        while index <= #compact do
            if index < #compact and compact[index] == compact[index + 1] then
                local value = compact[index] * 2
                output[#output + 1] = value
                gained = gained + value
                index = index + 2
            else
                output[#output + 1] = compact[index]
                index = index + 1
            end
        end
        while #output < 4 do
            output[#output + 1] = 0
        end
        return output, gained
    end

    local tileColors = {
        [0] = C.gray, [2] = C.lightGray, [4] = C.yellow, [8] = C.orange,
        [16] = C.red, [32] = C.magenta, [64] = C.purple, [128] = C.blue,
        [256] = C.cyan, [512] = C.lime, [1024] = C.green, [2048] = C.white
    }

    local function draw()
        writeAt(main, 3, 4, "Score: " .. score, C.yellow)
        for row = 1, 4 do
            for column = 1, 4 do
                local value = grid[row][column]
                local area = areas[row][column]
                local bg = tileColors[value] or C.pink
                local fg = (value == 0 or value == 2 or value == 4 or value == 2048) and C.black or C.white
                button(main, area.x, area.y, area.w, area.h, value == 0 and "" or tostring(value), bg, fg)
            end
        end
        controls.left = button(main, 2, height - 2, 7, 2, "<", C.gray)
        controls.down = button(main, 10, height - 2, 7, 2, "v", C.gray)
        controls.up = button(main, 18, height - 2, 7, 2, "^", C.gray)
        controls.right = button(main, 26, height - 2, 7, 2, ">", C.gray)
        back = backButton()
        showInfo("2048", "Use the on-screen arrows. Equal tiles merge when they collide. New tiles appear after every valid move.",
            { "Score: " .. score, "Reach 2048 or keep playing for a higher score." }, "2048")
    end

    local function canMove()
        for row = 1, 4 do
            for column = 1, 4 do
                if grid[row][column] == 0 then
                    return true
                end
                if column < 4 and grid[row][column] == grid[row][column + 1] then
                    return true
                end
                if row < 4 and grid[row][column] == grid[row + 1][column] then
                    return true
                end
            end
        end
        return false
    end

    local function move(direction)
        local nextGrid = {}
        for row = 1, 4 do
            nextGrid[row] = { 0, 0, 0, 0 }
        end
        local moved = false
        local gainedTotal = 0
        for lineIndex = 1, 4 do
            local line = {}
            for position = 1, 4 do
                if direction == "left" then
                    line[position] = grid[lineIndex][position]
                elseif direction == "right" then
                    line[position] = grid[lineIndex][5 - position]
                elseif direction == "up" then
                    line[position] = grid[position][lineIndex]
                else
                    line[position] = grid[5 - position][lineIndex]
                end
            end
            local result, gained = slideLine(line)
            gainedTotal = gainedTotal + gained
            for position = 1, 4 do
                local row, column
                if direction == "left" then
                    row, column = lineIndex, position
                elseif direction == "right" then
                    row, column = lineIndex, 5 - position
                elseif direction == "up" then
                    row, column = position, lineIndex
                else
                    row, column = 5 - position, lineIndex
                end
                nextGrid[row][column] = result[position]
                if nextGrid[row][column] ~= grid[row][column] then
                    moved = true
                end
            end
        end
        if moved then
            grid = nextGrid
            score = score + gainedTotal
            addTile()
        end
        return moved
    end

    addTile()
    addTile()
    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            local direction = nil
            if hit(back, p2, p3) then
                return nil
            elseif hit(controls.left, p2, p3) then
                direction = "left"
            elseif hit(controls.right, p2, p3) then
                direction = "right"
            elseif hit(controls.up, p2, p3) then
                direction = "up"
            elseif hit(controls.down, p2, p3) then
                direction = "down"
            end
            if direction then
                move(direction)
                draw()
                if not canMove() then
                    resultScreen("No moves left", "Score: " .. score)
                    return score
                end
            end
        end
    end
end

-- 8. Tic-Tac-Toe
local function playTicTacToe()
    local back = gameBase("Tic-Tac-Toe", "Build a win streak against the computer")
    local width, height = main.getSize()
    local cellWidth = math.min(9, math.floor((width - 8) / 3))
    local areas = gridAreas(3, 3, math.floor((width - (cellWidth * 3 + 2)) / 2) + 1, 6, cellWidth, 4, 1)
    local board = {}
    local streak = 0
    local message = "Your turn: X"

    local function resetBoard()
        for index = 1, 9 do
            board[index] = ""
        end
        message = "Your turn: X"
    end

    local function winner(state)
        local lines = {
            { 1, 2, 3 }, { 4, 5, 6 }, { 7, 8, 9 },
            { 1, 4, 7 }, { 2, 5, 8 }, { 3, 6, 9 },
            { 1, 5, 9 }, { 3, 5, 7 }
        }
        for _, line in ipairs(lines) do
            local a, b, c = line[1], line[2], line[3]
            if state[a] ~= "" and state[a] == state[b] and state[a] == state[c] then
                return state[a]
            end
        end
        return nil
    end

    local function isFull()
        for index = 1, 9 do
            if board[index] == "" then
                return false
            end
        end
        return true
    end

    local function emptyCells()
        local cells = {}
        for index = 1, 9 do
            if board[index] == "" then
                cells[#cells + 1] = index
            end
        end
        return cells
    end

    local function computerMove()
        local empty = emptyCells()
        for _, symbol in ipairs({ "O", "X" }) do
            for _, index in ipairs(empty) do
                board[index] = symbol
                local wins = winner(board) == symbol
                board[index] = ""
                if wins then
                    board[index] = "O"
                    return
                end
            end
        end
        if board[5] == "" then
            board[5] = "O"
            return
        end
        local corners = {}
        for _, index in ipairs({ 1, 3, 7, 9 }) do
            if board[index] == "" then
                corners[#corners + 1] = index
            end
        end
        if #corners > 0 then
            board[corners[math.random(#corners)]] = "O"
        elseif #empty > 0 then
            board[empty[math.random(#empty)]] = "O"
        end
    end

    local function draw()
        writeAt(main, 3, 4, "Win streak: " .. streak .. "  " .. message, C.yellow)
        for index = 1, 9 do
            local row = math.floor((index - 1) / 3) + 1
            local column = (index - 1) % 3 + 1
            local area = areas[row][column]
            local symbol = board[index]
            local bg = symbol == "X" and C.cyan or symbol == "O" and C.magenta or C.gray
            button(main, area.x, area.y, area.w, area.h, symbol, bg)
        end
        back = backButton()
        showInfo("Tic-Tac-Toe", "You are X and always move first. Win as many rounds as possible. A draw starts a new board; a loss ends the run.",
            { "Win streak: " .. streak, "The computer blocks and takes winning moves." }, "tictactoe")
    end

    resetBoard()
    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            end
            for index = 1, 9 do
                local row = math.floor((index - 1) / 3) + 1
                local column = (index - 1) % 3 + 1
                if hit(areas[row][column], p2, p3) and board[index] == "" then
                    board[index] = "X"
                    if winner(board) == "X" then
                        streak = streak + 1
                        message = "You won! Next round..."
                        draw()
                        sleep(0.8)
                        resetBoard()
                    elseif isFull() then
                        message = "Draw! Next round..."
                        draw()
                        sleep(0.8)
                        resetBoard()
                    else
                        computerMove()
                        if winner(board) == "O" then
                            message = "Computer wins"
                            draw()
                            resultScreen("Run complete", "Win streak: " .. streak)
                            return streak
                        elseif isFull() then
                            message = "Draw! Next round..."
                            draw()
                            sleep(0.8)
                            resetBoard()
                        else
                            message = "Your turn: X"
                        end
                    end
                    draw()
                    break
                end
            end
        end
    end
end

-- 9. Breakout
local function playBreakout()
    local back = gameBase("Breakout", "Clear all bricks with three lives")
    local width, height = main.getSize()
    local left, right = 2, width - 1
    local top = 5
    local paddleY = height - 5
    local paddleWidth = 9
    local paddleX = math.floor((width - paddleWidth) / 2) + 1
    local brickColumns, brickRows = 8, 3
    local brickWidth = math.floor((right - left + 1) / brickColumns)
    local bricks = {}
    local remaining = brickColumns * brickRows
    for row = 1, brickRows do
        bricks[row] = {}
        for column = 1, brickColumns do
            bricks[row][column] = true
        end
    end
    local ball = { x = math.floor(width / 2), y = paddleY - 3, dx = 1, dy = -1 }
    local lives = 3
    local score = 0
    local controls = {}
    local timer = os.startTimer(0.1)

    local function resetBall(direction)
        ball.x = math.floor(width / 2)
        ball.y = paddleY - 3
        ball.dx = direction or (math.random() < 0.5 and -1 or 1)
        ball.dy = -1
    end

    local function draw()
        fill(main, 1, 4, width, height - 4, C.black)
        writeAt(main, 3, 4, "Score: " .. score .. "  Lives: " .. lives .. "  Bricks: " .. remaining, C.yellow)
        local brickColors = { C.red, C.orange, C.yellow }
        for row = 1, brickRows do
            for column = 1, brickColumns do
                if bricks[row][column] then
                    fill(main, left + (column - 1) * brickWidth, top + row - 1, brickWidth - 1, 1, brickColors[row])
                end
            end
        end
        fill(main, paddleX, paddleY, paddleWidth, 1, C.cyan, "=")
        writeAt(main, ball.x, ball.y, "O", C.white, C.black)
        controls.left = button(main, 2, height - 2, 10, 2, "Left", C.gray)
        controls.right = button(main, 13, height - 2, 10, 2, "Right", C.gray)
        back = backButton()
        showInfo("Breakout", "Touch the playfield to move the paddle, or use Left and Right. Clear all 24 bricks before losing three balls.",
            { "Score: " .. score, "Lives: " .. lives, "Bricks: " .. remaining,
                "Each brick gives 10 points. Remaining lives give a bonus." }, "breakout")
    end

    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            elseif hit(controls.left, p2, p3) then
                paddleX = clamp(paddleX - 4, left, right - paddleWidth + 1)
            elseif hit(controls.right, p2, p3) then
                paddleX = clamp(paddleX + 4, left, right - paddleWidth + 1)
            elseif p3 >= top and p3 < paddleY then
                paddleX = clamp(p2 - math.floor(paddleWidth / 2), left, right - paddleWidth + 1)
            end
            draw()
        elseif event == "timer" and p1 == timer then
            local nextX = ball.x + ball.dx
            local nextY = ball.y + ball.dy
            if nextX < left then
                nextX = left
                ball.dx = 1
            elseif nextX > right then
                nextX = right
                ball.dx = -1
            end
            if nextY < top then
                nextY = top
                ball.dy = 1
            end

            local brickRow = nextY - top + 1
            if brickRow >= 1 and brickRow <= brickRows then
                local brickColumn = math.floor((nextX - left) / brickWidth) + 1
                if brickColumn >= 1 and brickColumn <= brickColumns and bricks[brickRow][brickColumn] then
                    bricks[brickRow][brickColumn] = false
                    remaining = remaining - 1
                    score = score + 10
                    ball.dy = -ball.dy
                    nextY = ball.y
                    if remaining == 0 then
                        score = score + lives * 100
                        draw()
                        resultScreen("All bricks cleared", "Score: " .. score)
                        return score
                    end
                end
            end

            if ball.dy > 0 and nextY >= paddleY and ball.y < paddleY and
                    nextX >= paddleX and nextX < paddleX + paddleWidth then
                local offset = nextX - (paddleX + math.floor(paddleWidth / 2))
                ball.dx = offset < -1 and -1 or offset > 1 and 1 or 0
                ball.dy = -1
                nextY = paddleY - 1
            elseif nextY > paddleY then
                lives = lives - 1
                if lives <= 0 then
                    draw()
                    resultScreen("Game over", "Score: " .. score)
                    return score
                end
                resetBall()
                nextX, nextY = ball.x, ball.y
            end

            ball.x, ball.y = nextX, nextY
            draw()
            timer = os.startTimer(0.09)
        end
    end
end

-- 10. Pong
local function playPong()
    local back = gameBase("Pong", "First to five goals wins the match")
    local width, height = main.getSize()
    local top, bottom = 5, height - 5
    local paddleHeight = 6
    local playerY = math.floor((top + bottom - paddleHeight) / 2) + 1
    local aiY = playerY
    local playerScore, aiScore = 0, 0
    local ball = { x = math.floor(width / 2), y = math.floor((top + bottom) / 2), dx = 1, dy = 1 }
    local controls = {}
    local timer = os.startTimer(0.1)

    local function resetBall(direction)
        ball.x = math.floor(width / 2)
        ball.y = math.floor((top + bottom) / 2)
        ball.dx = direction
        ball.dy = math.random(-1, 1)
    end

    local function matchScore()
        return playerScore * 100 - aiScore * 10
    end

    local function draw()
        fill(main, 1, 4, width, height - 4, C.black)
        writeAt(main, 3, 4, "You: " .. playerScore .. "  Computer: " .. aiScore, C.yellow)
        for y = top, bottom, 2 do
            writeAt(main, math.floor(width / 2), y, "|", C.gray, C.black)
        end
        fill(main, 2, playerY, 1, paddleHeight, C.cyan, "|")
        fill(main, width - 1, aiY, 1, paddleHeight, C.magenta, "|")
        writeAt(main, ball.x, ball.y, "O", C.white, C.black)
        controls.up = button(main, 2, height - 2, 10, 2, "Up", C.gray)
        controls.down = button(main, 13, height - 2, 10, 2, "Down", C.gray)
        back = backButton()
        showInfo("Pong", "Touch the playfield to place your left paddle, or use Up and Down. The first side to score five goals wins.",
            { "You: " .. playerScore, "Computer: " .. aiScore, "Match points: " .. matchScore(),
                "Goals give 100 points; conceded goals subtract 10." }, "pong")
    end

    draw()
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "monitor_touch" and p1 == mainName then
            if hit(back, p2, p3) then
                return nil
            elseif hit(controls.up, p2, p3) then
                playerY = clamp(playerY - 2, top, bottom - paddleHeight + 1)
            elseif hit(controls.down, p2, p3) then
                playerY = clamp(playerY + 2, top, bottom - paddleHeight + 1)
            elseif p3 >= top and p3 <= bottom then
                playerY = clamp(p3 - math.floor(paddleHeight / 2), top, bottom - paddleHeight + 1)
            end
            draw()
        elseif event == "timer" and p1 == timer then
            if ball.dx > 0 and math.random() < 0.75 then
                if aiY + math.floor(paddleHeight / 2) < ball.y then
                    aiY = aiY + 1
                elseif aiY + math.floor(paddleHeight / 2) > ball.y then
                    aiY = aiY - 1
                end
            end
            aiY = clamp(aiY, top, bottom - paddleHeight + 1)

            local nextX = ball.x + ball.dx
            local nextY = ball.y + ball.dy
            if nextY < top then
                nextY = top
                ball.dy = 1
            elseif nextY > bottom then
                nextY = bottom
                ball.dy = -1
            end

            if ball.dx < 0 and nextX <= 3 and nextY >= playerY and nextY < playerY + paddleHeight then
                ball.dx = 1
                nextX = 3
                local offset = nextY - (playerY + math.floor(paddleHeight / 2))
                ball.dy = clamp(offset, -1, 1)
            elseif ball.dx > 0 and nextX >= width - 2 and nextY >= aiY and nextY < aiY + paddleHeight then
                ball.dx = -1
                nextX = width - 2
                local offset = nextY - (aiY + math.floor(paddleHeight / 2))
                ball.dy = clamp(offset, -1, 1)
            end

            if nextX < 1 then
                aiScore = aiScore + 1
                resetBall(1)
            elseif nextX > width then
                playerScore = playerScore + 1
                resetBall(-1)
            else
                ball.x, ball.y = nextX, nextY
            end

            if playerScore >= 5 or aiScore >= 5 then
                draw()
                resultScreen(playerScore >= 5 and "You won the match" or "Computer won the match",
                    playerScore .. " : " .. aiScore .. "  Points: " .. matchScore())
                return matchScore()
            end
            draw()
            timer = os.startTimer(0.09)
        end
    end
end

gameDefs = {
    { id = "reaction", name = "Reaction", description = "Test your reaction speed.", unit = "ms", lowerIsBetter = true, run = playReaction },
    { id = "whack", name = "Whack-a-Mole", description = "Hit moving targets for 30 seconds.", run = playWhack },
    { id = "simon", name = "Simon", description = "Repeat a growing light sequence.", run = playSimon },
    { id = "memory", name = "Memory", description = "Find all matching pairs.", unit = "moves", lowerIsBetter = true, run = playMemory },
    { id = "mines", name = "Minesweeper", description = "Clear a minefield.", unit = "s", lowerIsBetter = true, run = playMinesweeper },
    { id = "snake", name = "Snake", description = "Grow without hitting yourself.", unit = "food", run = playSnake },
    { id = "2048", name = "2048", description = "Merge tiles and build a high score.", unit = "pts", run = play2048 },
    { id = "tictactoe", name = "Tic-Tac-Toe", description = "Build a win streak against the computer.", unit = "wins", run = playTicTacToe },
    { id = "breakout", name = "Breakout", description = "Break bricks and protect your lives.", unit = "pts", run = playBreakout },
    { id = "pong", name = "Pong", description = "Win a touch-controlled Pong match.", unit = "pts", run = playPong }
}

local function drawInfoMenu()
    if info == main then
        return
    end
    clear(info)
    header(info, "CC Arcade", "Ten games. One touch menu.")
    local width, height = info.getSize()
    writeAt(info, 3, 5, "Touch a game on the main monitor.", C.lightBlue)
    writeAt(info, 3, 7, "BEST RESULTS", C.yellow)
    local row = 9
    for _, game in ipairs(gameDefs) do
        if row > height - 2 then
            break
        end
        writeAt(info, 3, row, game.name, C.white)
        writeAt(info, width - #bestText(game.id) - 2, row, bestText(game.id), C.lightGray)
        row = row + 1
    end
    fill(info, 1, height, width, 1, C.gray)
    center(info, height, "Advanced monitors required", C.white, C.gray)
end

local function drawMenu()
    clear(main)
    header(main, "CC ARCADE", "Choose a game by touching its button")
    local width, height = main.getSize()
    local gap = 1
    local columnWidth = math.floor((width - 3) / 2)
    local step = math.max(2, math.floor((height - 7) / 5))
    local areas = {}
    for index, game in ipairs(gameDefs) do
        local column = (index - 1) % 2
        local row = math.floor((index - 1) / 2)
        local x = 2 + column * (columnWidth + gap)
        local y = 5 + row * step
        areas[index] = button(main, x, y, columnWidth, step - 1,
            string.format("%2d. %s", index, game.name), index % 2 == 0 and C.cyan or C.lightBlue, C.black)
    end
    local exitArea = button(main, width - 7, height, 8, 1, "Exit", C.red)
    writeAt(main, 2, height, "Touch a game. No keyboard needed.", C.lightGray)
    drawInfoMenu()
    return areas, exitArea
end

local function runArcade()
    while true do
        local areas, exitArea = drawMenu()
        local selected = nil
        while selected == nil do
            local event, p1, p2, p3 = os.pullEvent()
            if event == "monitor_touch" and p1 == mainName then
                if hit(exitArea, p2, p3) then
                    return
                end
                for index, area in ipairs(areas) do
                    if hit(area, p2, p3) then
                        selected = gameDefs[index]
                        break
                    end
                end
            elseif event == "monitor_resize" then
                areas, exitArea = drawMenu()
            end
        end

        showInfo(selected.name, selected.description, { "Loading..." }, selected.id)
        local value = selected.run()
        recordResult(selected.id, value)
    end
end

local ok, err = xpcall(runArcade, debug.traceback)
main.setTextScale(oldMainScale)
if info ~= main then
    info.setTextScale(oldInfoScale)
    clear(info)
end
clear(main)

if not ok then
    error(err)
end
