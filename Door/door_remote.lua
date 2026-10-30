--[[
  Door Remote (tablet / pocket computer part)
  ComputerCraft: Tweaked / Minecraft 1.21.1
  - Shows a list of saved doors
  - Sends open-requests via rednet
  - Doors are added in a separate menu (address + password + coordinates)
  - GPS auto-open: opens doors automatically when you come close
    (requires a GPS constellation: 4 computers running "gps host")
  Requires a wireless modem equipped on the pocket computer.
]]

local DATA_FILE = "doors.cfg"
local PROTOCOL  = "door_control"

local doors = {}

local settings = {
    gpsAutoOpen = true,  -- auto open doors when the player is near
    gpsRange    = 6,     -- distance in blocks that triggers auto-open
    gpsCooldown = 5,     -- seconds between repeated opens of the same door
}

-- ===== Data load / save =====
local function saveData()
    local f = fs.open(DATA_FILE, "w")
    f.write(textutils.serialize({ doors = doors, settings = settings }))
    f.close()
end

local function loadData()
    if fs.exists(DATA_FILE) then
        local f = fs.open(DATA_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then
            if type(data.doors) == "table" then doors = data.doors end
            if type(data.settings) == "table" then
                for k, v in pairs(data.settings) do settings[k] = v end
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

-- ===== Send an open-request to a door =====
local function requestOpen(door)
    rednet.send(door.address, { command = "open", password = door.password }, PROTOCOL)
    local id, msg = rednet.receive(PROTOCOL, 3)
    if not id then
        return "No answer (door offline?)"
    end
    if type(msg) == "table" and msg.status == "ok" then
        return "Door opened!"
    else
        return "Access denied (wrong password)"
    end
end

-- ===== GPS auto-open (runs in parallel with the menu) =====
local lastSent = {}

local function gpsLoop()
    while true do
        if settings.gpsAutoOpen and #doors > 0 then
            local x, y, z = gps.locate(1)
            if x then
                local now = os.clock()
                for i, d in ipairs(doors) do
                    if d.x and d.y and d.z then
                        local dist = math.sqrt((x - d.x)^2 + (y - d.y)^2 + (z - d.z)^2)
                        if dist <= settings.gpsRange then
                            if not lastSent[i] or now - lastSent[i] >= settings.gpsCooldown then
                                rednet.send(d.address,
                                    { command = "open", password = d.password },
                                    PROTOCOL)
                                lastSent[i] = now
                            end
                        end
                    end
                end
            end
        end
        sleep(1)
    end
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

    print("")
    print("Door coordinates.")
    print("Press Enter on X to use your current")
    print("GPS position.")
    write("X: ")
    local xs = read()
    local x, y, z
    if xs == "" then
        x, y, z = gps.locate(3)
        if not x then
            print("No GPS signal! Door added without")
            print("coordinates - GPS auto-open will")
            print("not work for it.")
            sleep(3)
        else
            print("Position: " .. x .. " " .. y .. " " .. z)
            sleep(2)
        end
    else
        x = tonumber(xs)
        write("Y: ")
        y = tonumber(read())
        write("Z: ")
        z = tonumber(read())
        if not (x and y and z) then
            print("Invalid coordinates!")
            sleep(2)
            return
        end
    end

    table.insert(doors, {
        name = name, address = address,
        password = password, x = x, y = y, z = z,
    })
    saveData()
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
        saveData()
        print("Door deleted!")
    else
        print("Cancelled.")
    end
    sleep(2)
end

-- ===== GPS settings menu =====
local function gpsSettingsMenu()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== GPS Settings ===")
    print("")
    print("Auto-open: " .. (settings.gpsAutoOpen and "ON" or "OFF"))
    print("Range: " .. settings.gpsRange .. " blocks")
    print("")
    write("Toggle auto-open? (y/n): ")
    local c = read()
    if c == "y" or c == "Y" then
        settings.gpsAutoOpen = not settings.gpsAutoOpen
    end
    write("New range in blocks (empty = keep): ")
    local r = tonumber(read())
    if r and r > 0 then settings.gpsRange = r end
    saveData()
    print("Saved!")
    sleep(1)
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
            local gpsMark = (d.x and "*") or " "
            print(i .. ") " .. d.name .. " [" .. d.address .. "] " .. gpsMark)
        end
        print("")
        print("(* = has coordinates for GPS)")
        print("GPS auto-open: " .. (settings.gpsAutoOpen and "ON" or "OFF"))
        print("")
        print("A) Add door")
        print("D) Delete door")
        print("G) GPS settings")
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
        elseif choice == "g" or choice == "G" then
            gpsSettingsMenu()
        else
            local n = tonumber(choice)
            if n and doors[n] then
                print("")
                print("Sending request...")
                local result = requestOpen(doors[n])
                print(result)
                sleep(2)
            end
        end
    end
end

-- ===== Main =====
if not openModem() then
    print("ERROR: no wireless modem equipped!")
    return
end

loadData()
parallel.waitForAny(mainMenu, gpsLoop)
