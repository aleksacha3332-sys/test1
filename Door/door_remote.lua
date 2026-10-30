--[[
  Door Remote (tablet / pocket computer part)
  ComputerCraft: Tweaked / Minecraft 1.21.1
  - Master terminal: shows a list of saved doors
  - Open (password checked by the door, door STAYS OPEN)
    and close any door manually
  - "Close all" button for every saved door at once
  - Doors are added in a separate menu (address + password)
  Requires a wireless modem equipped on the pocket computer.
]]

local DOORS_FILE = "doors.cfg"
local PROTOCOL   = "door_control"

local doors = {}

-- ===== Door list load / save =====
local function saveDoors()
    local f = fs.open(DOORS_FILE, "w")
    f.write(textutils.serialize(doors))
    f.close()
end

local function loadDoors()
    if fs.exists(DOORS_FILE) then
        local f = fs.open(DOORS_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        -- supports both the old plain-list format
        -- and the {doors=..., settings=...} format
        if type(data) == "table" then
            if type(data.doors) == "table" then
                doors = data.doors
            else
                doors = data
            end
        end
    end
end

-- ===== Modem =====
local function openModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            local ok, wireless = pcall(peripheral.call, side, "isWireless")
            if ok and wireless then
                rednet.open(side)
                return true
            end
        end
    end
    return false
end

-- ===== Send a command to one door =====
local function sendCommand(door, command)
    local msg = { command = command }
    if command == "open" then msg.password = door.password end
    rednet.send(door.address, msg, PROTOCOL)
    local id, reply = rednet.receive(PROTOCOL, 3)
    if not id then
        return false, "No answer (door offline?)"
    end
    if type(reply) == "table" and reply.status == "ok" then
        return true, (command == "open") and "Door opened!" or "Door closed!"
    else
        return false, "Access denied (wrong password)"
    end
end

-- ===== Close every saved door =====
local function closeAllDoors()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Close All Doors ===")
    print("")
    local closed, failed = 0, 0
    for _, d in ipairs(doors) do
        local ok, msg = sendCommand(d, "close")
        if ok then
            closed = closed + 1
            print("[OK]   " .. d.name)
        else
            failed = failed + 1
            print("[FAIL] " .. d.name .. " - " .. msg)
        end
    end
    print("")
    print("Closed: " .. closed .. ", failed: " .. failed)
    print("")
    print("Press any key...")
    os.pullEvent("key")
end

-- ===== Add-door menu =====
local function addDoorMenu()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Add Door ===")
    print("")

    write("Door name: ")
    local name = read()

    write("Door address (computer ID): ")
    local address = tonumber(read())
    if not address then
        print("Invalid address!")
        sleep(2)
        return
    end

    write("Door password: ")
    local password = read()

    table.insert(doors, { name = name, address = address, password = password })
    saveDoors()
    print("Door added!")
    sleep(2)
end

-- ===== Delete-door menu =====
local function deleteDoorMenu()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Delete Door ===")
    print("")
    for i, d in ipairs(doors) do
        print(i .. ") " .. d.name .. " [" .. d.address .. "]")
    end
    print("")
    write("Number to delete (empty = cancel): ")
    local n = tonumber(read())
    if n and doors[n] then
        table.remove(doors, n)
        saveDoors()
        print("Door deleted!")
    else
        print("Cancelled.")
    end
    sleep(2)
end

-- ===== Door control submenu =====
local function doorMenu(door)
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== " .. door.name .. " [" .. door.address .. "] ===")
        print("")
        print("O) Open  (stays open)")
        print("C) Close")
        print("B) Back")
        print("")
        write("> ")
        local choice = read()

        if choice == "b" or choice == "B" then
            return
        elseif choice == "o" or choice == "O" then
            print("")
            print("Sending request...")
            local _, msg = sendCommand(door, "open")
            print(msg)
            sleep(2)
        elseif choice == "c" or choice == "C" then
            print("")
            print("Sending request...")
            local _, msg = sendCommand(door, "close")
            print(msg)
            sleep(2)
        end
    end
end

-- ===== Main menu =====
local function mainMenu()
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== Door Remote ===")
        print("")
        if #doors == 0 then
            print("(no doors saved)")
        end
        for i, d in ipairs(doors) do
            print(i .. ") " .. d.name .. " [" .. d.address .. "]")
        end
        print("")
        print("A) Add door")
        print("D) Delete door")
        print("X) CLOSE ALL DOORS")
        print("Q) Quit")
        print("")
        write("> ")
        local choice = read()

        if choice == "q" or choice == "Q" then
            term.clear()
            term.setCursorPos(1, 1)
            return
        elseif choice == "a" or choice == "A" then
            addDoorMenu()
        elseif choice == "d" or choice == "D" then
            deleteDoorMenu()
        elseif choice == "x" or choice == "X" then
            closeAllDoors()
        else
            local n = tonumber(choice)
            if n and doors[n] then
                doorMenu(doors[n])
            end
        end
    end
end

-- ===== Main =====
if not openModem() then
    print("ERROR: no wireless modem equipped!")
    return
end

loadDoors()
mainMenu()
