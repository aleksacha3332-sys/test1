-- Autopilot one-file installer for ComputerCraft (MC 1.21.1).
-- Run this file on the computer: it creates the full autopilot package.
-- All in-code text is English; explanations live in README.md.

local FILES = {
  ["autopilot/config.lua"] = [==[
-- Autopilot configuration.
-- Adjust the values below to match your machine wiring.

local MOD = "AP_CONFIG"
if _G[MOD] then return _G[MOD] end

local config = {}

config.VERSION = "1.2.0"

-- ===================== PERIPHERALS =====================
-- Valid sides: "top", "bottom", "left", "right", "front", "back".
-- Set a side to nil for auto-detect.

-- Side of the sublevel_sensor (netherite block on the structure).
config.SENSOR_SIDE = nil

-- Side of the touch monitor (any size works, 4x3 or larger recommended).
config.MONITOR_SIDE = nil

-- Wireless modem side for notification broadcast (optional, nil = auto).
config.MODEM_SIDE = nil

-- ===================== REDSTONE WIRING =====================
-- Tank drive uses four redstone outputs. Signal strength is ignored,
-- only ON/OFF matters. All four sides must be different.

config.REDSTONE = {
    LEFT_FORWARD   = "left",
    LEFT_BACKWARD  = "right",
    RIGHT_FORWARD  = "top",
    RIGHT_BACKWARD = "bottom",
}

-- ===================== DRIVE TUNING =====================
-- PWM period in seconds used for low-speed approaches.
config.PWM_PERIOD = 0.4

-- Heading error thresholds in degrees.
config.TURN_PIVOT_DEG = 60   -- pivot in place above this error
config.TURN_DIFF_DEG  = 12   -- gentle differential turn above this error

-- Distance (blocks) where PWM duty starts ramping down.
config.SLOWDOWN_DIST = 4.0

-- ===================== SCAN PROFILES =====================
-- name -> { arriveRadius, sampleEvery, dutyMin }
-- "cruise"  = fast, coarse, rare sampling (long trips)
-- "normal"  = balanced
-- "precise" = slow, tight radius, frequent sampling (landings)

config.PROFILES = {
    cruise  = { arriveRadius = 3.0,  sampleEvery = 1.0, dutyMin = 1.0 },
    normal  = { arriveRadius = 1.2,  sampleEvery = 0.4, dutyMin = 0.6 },
    precise = { arriveRadius = 0.35, sampleEvery = 0.1, dutyMin = 0.3 },
}

config.DEFAULT_PROFILE = "normal"

-- Vertical tolerance (blocks) required for landing legs.
config.LANDING_DY = 1.0

-- ===================== STORAGE =====================
-- Route data is striped across disks in fixed-size chunks,
-- the manifest and POI index are replicated on every disk.
config.CHUNK_SIZE    = 4096
config.MANIFEST_FILE = "manifest.dat"
config.POI_FILE      = "poi.dat"
config.LOG_FILE      = "autopilot.log"

-- ===================== NOTIFICATIONS =====================
-- Messages are appended to the log and broadcast on this rednet channel.
config.REDNET_CHANNEL = 4242

local _G_ref = _G
_G_ref[MOD] = config
return config
]==],
  ["autopilot/drive.lua"] = [==[
-- Tank drive: four redstone outputs, ON/OFF only.

local MOD = "AP_DRIVE"
if _G[MOD] then return _G[MOD] end

-- dofile'd chunks run in _G without "shell"; main.lua sets AP_DIR.
local DIR = _G.AP_DIR or "/autopilot"
local function lib(name) return dofile(fs.combine(DIR, name)) end
local config = lib("config.lua")

local drive = {}

local sides = {
    lf = config.REDSTONE.LEFT_FORWARD,
    lb = config.REDSTONE.LEFT_BACKWARD,
    rf = config.REDSTONE.RIGHT_FORWARD,
    rb = config.REDSTONE.RIGHT_BACKWARD,
}

local current = { lf = false, lb = false, rf = false, rb = false }

local function applyOne(side, on)
    if side then redstone.setOutput(side, on and true or false) end
end

-- Set raw track outputs. Each argument is a boolean.
function drive.set(lf, lb, rf, rb)
    current = { lf = lf, lb = lb, rf = rf, rb = rb }
    applyOne(sides.lf, lf)
    applyOne(sides.lb, lb)
    applyOne(sides.rf, rf)
    applyOne(sides.rb, rb)
end

function drive.stop()
    drive.set(false, false, false, false)
end

function drive.get() return current end

-- Convenience directions.
function drive.forward()     drive.set(true, false, true, false)  end
function drive.backward()    drive.set(false, true, false, true)  end
function drive.pivotLeft()   drive.set(false, true, true, false)  end
function drive.pivotRight()  drive.set(true, false, false, true)  end

_G[MOD] = drive
return drive
]==],
  ["autopilot/main.lua"] = [==[
-- Autopilot entry point.
-- Run: autopilot/main.lua   (or place a startup.lua next to it)

-- Modules are loaded with dofile, which runs in the plain global
-- environment (_G) where "shell" does not exist. Resolve the package
-- directory here (main.lua runs with the shell environment) and share it.
local DIR = "/"
do
    local ok, prog = pcall(function() return shell.getRunningProgram() end)
    if ok and type(prog) == "string" then
        DIR = fs.getDir(prog)
        if not DIR or DIR == "" then DIR = "/" end
    end
end
if DIR:sub(1, 1) ~= "/" then DIR = "/" .. DIR end
_G.AP_DIR = DIR

local function lib(name) return dofile(fs.combine(DIR, name)) end

local config = lib("config.lua")
local state = lib("state.lua")
local sensor = lib("sensor.lua")
local drive = lib("drive.lua")
local storage = lib("storage.lua")
local notify = lib("notify.lua")
local nav = lib("nav.lua")
local recorder = lib("record.lua")
local mapui = lib("mapui.lua")

local PROFILE_ORDER = { "cruise", "normal", "precise" }

local function countPois()
    local n = 0
    for _ in pairs(state.pois) do n = n + 1 end
    return n
end

local function refreshAll()
    state.routes = {}
    state.routeOrder = {}
    for _, meta in ipairs(storage.listRoutes()) do
        local route = storage.loadRoute(meta.id)
        if route then
            state.routes[route.id] = route
            state.routeOrder[#state.routeOrder + 1] = route.id
        end
    end
    storage.loadPOIs()
    state.pois = storage.getPOIs()
    state.rev = state.rev + 1
end

local function resolveTarget(name)
    if not name then return nil end
    if state.pois[name] then
        return { kind = "poi", name = name, label = name }
    end
    local id = storage.findRouteByName(name)
    if id then
        return { kind = "route", id = id, label = name }
    end
    local num = tonumber(name:match("^#(%d+)$"))
    if num and state.routes[num] then
        return { kind = "route", id = num, label = "#" .. num }
    end
    return nil
end

local function printHelp()
    print([[
Autopilot console commands:
  go <name|#id>        drive to a POI or route
  stop                 abort autopilot
  rec [landing]        start recording (landing = precise route)
  save [name]          save recording to disks
  discard              drop recording
  mark                 mark nearest recorded point as special POI
  land                 mark nearest recorded point as landing point
  attach <poi> <route> attach a landing route to a POI
  routes               list stored routes
  pois                 list points of interest
  profile <name>       scan profile: cruise | normal | precise
  status               show nav status and position
  refresh              reload routes and POIs from disks
  help                 this help
  exit                 shutdown

Drive keys: W/S forward/back, A/D pivot.
Map hotkeys: G = go to selected, X = stop, N = cycle profile.]])
end

local function console()
    printHelp()
    while true do
        write("> ")
        state.consoleBusy = true
        local line = read()
        state.consoleBusy = false
        if not line then break end
        local args = {}
        for word in line:gmatch("%S+") do args[#args + 1] = word end
        local cmd, a2, a3 = args[1], args[2], args[3]
        if cmd == "go" then
            local sel = resolveTarget(a2)
            if not sel then
                print("unknown target, see 'routes' / 'pois'")
            else
                local ok, err = nav.gotoTarget(sel)
                if not ok then print(err) end
            end
        elseif cmd == "stop" then
            nav.abort("console stop")
        elseif cmd == "rec" then
            local ok, err = recorder.start(a2 == "landing" and "landing" or "normal")
            if not ok then print(err) end
        elseif cmd == "save" then
            local ok, err = recorder.finish(a2)
            print(ok and "saved" or ("error: " .. tostring(err)))
            if ok then refreshAll() end
        elseif cmd == "discard" then
            local ok, err = recorder.discard()
            if not ok then print(err) end
        elseif cmd == "mark" then
            local ok, err = recorder.mark({ special = true })
            if not ok then print(err) end
        elseif cmd == "land" then
            local ok, err = recorder.mark({ landing = true })
            if not ok then print(err) end
        elseif cmd == "attach" then
            if a2 and a3 and state.pois[a2] then
                state.pois[a2].landingRoute = a3
                storage.savePOIs(state.pois)
                print("attached " .. a3 .. " to " .. a2)
            else
                print("usage: attach <poi> <landing route>")
            end
        elseif cmd == "routes" then
            for _, r in ipairs(storage.listRoutes()) do
                print(string.format("#%-4d %-18s %-8s %4d pts", r.id, r.name, r.kind, r.points))
            end
        elseif cmd == "pois" then
            for name, p in pairs(state.pois) do
                print(string.format("%-22s %8.1f %6.1f %8.1f", name, p.x, p.y, p.z))
            end
        elseif cmd == "profile" then
            if a2 and config.PROFILES[a2] then
                state.profile = a2
                print("profile: " .. a2)
            else
                print("profiles: cruise normal precise")
            end
        elseif cmd == "status" then
            print((state.nav.status or "idle") .. " | " .. (state.statusMsg or ""))
            if state.position then
                print(string.format("pos: %.1f %.1f %.1f  heading %.0f",
                    state.position.x, state.position.y, state.position.z, state.heading))
            else
                print("pos: unknown")
            end
        elseif cmd == "refresh" then
            refreshAll()
            print("reloaded " .. #state.routeOrder .. " routes, " .. countPois() .. " POIs")
        elseif cmd == "help" then
            printHelp()
        elseif cmd == "exit" then
            error("AUTOPILOT_EXIT", 0)
        elseif cmd ~= nil and cmd ~= "" then
            print("unknown command, try 'help'")
        end
    end
end

local function keyLoop()
    while true do
        local _, key = os.pullEvent("key")
        if not state.consoleBusy then
            if key == keys.g then
                if state.selected then
                    local ok, err = nav.gotoTarget(state.selected)
                    if not ok then notify.send("warn", tostring(err)) end
                else
                    notify.send("warn", "Nothing selected on the map")
                end
            elseif key == keys.x then
                nav.abort("hotkey")
            elseif key == keys.n then
                for i, p in ipairs(PROFILE_ORDER) do
                    if p == state.profile then
                        state.profile = PROFILE_ORDER[(i % #PROFILE_ORDER) + 1]
                        notify.send("info", "profile: " .. state.profile)
                        break
                    end
                end
            end
        end
    end
end

local function sensorLoop()
    while true do
        local st = sensor.getState()
        if st and st.x then
            state.position = { x = st.x, y = st.y, z = st.z }
            state.heading = sensor.headingOf(st)
        end
        os.sleep(0.5)
    end
end

local function main()
    sensor.init()
    storage.init()
    notify.init()
    mapui.init()
    refreshAll()

    state.profile = config.DEFAULT_PROFILE
    drive.stop()

    term.clear()
    term.setCursorPos(1, 1)
    print("=== Autopilot v" .. config.VERSION .. " ===")
    print(string.format("sensor: %s | disks: %d | routes: %d | POIs: %d | monitor: %s",
        sensor.hasSensor() and "sublevel_sensor" or "GPS",
        storage.driveCount(), #state.routeOrder, countPois(),
        mapui.available() and "yes" or "no"))
    notify.send("info", "Autopilot online")

    local ok, err = pcall(parallel.waitForAll,
        console, recorder.run, nav.run, keyLoop, sensorLoop, mapui.run)
    drive.stop()
    if err == "AUTOPILOT_EXIT" then
        print("Autopilot shutdown.")
    else
        notify.send("error", "crashed: " .. tostring(err))
        print("Error: " .. tostring(err))
    end
end

main()
]==],
  ["autopilot/mapui.lua"] = [==[
-- Interactive touch map on a monitor.
-- Tap a point to select it, use the bottom row buttons to zoom and GO/STOP.

local MOD = "AP_MAPUI"
if _G[MOD] then return _G[MOD] end

-- dofile'd chunks run in _G without "shell"; main.lua sets AP_DIR.
local DIR = _G.AP_DIR or "/autopilot"
local function lib(name) return dofile(fs.combine(DIR, name)) end
local config = lib("config.lua")
local state = lib("state.lua")
local notify = lib("notify.lua")
local nav = lib("nav.lua")

local mapui = {}

local mon = nil
local monSide = nil

local view = { scale = nil, cx = 0, cz = 0, autoFit = true }

local hits = {}     -- selectable targets with screen positions
local buttons = {}  -- clickable button zones for the last draw

local C = {
    grid      = colors.gray,
    normal    = colors.yellow,
    landing   = colors.orange,
    recording = colors.cyan,
    poi       = colors.magenta,
    special   = colors.pink,
    selected  = colors.lime,
    vehicle   = colors.green,
    header    = colors.white,
    status    = colors.lightGray,
    button    = colors.blue,
    danger    = colors.red,
}

local GRID_STEPS = { 1, 2, 5, 10, 20, 50, 100, 200, 500 }

function mapui.init()
    mon = nil
    monSide = nil
    if config.MONITOR_SIDE and peripheral.isPresent(config.MONITOR_SIDE)
        and peripheral.getType(config.MONITOR_SIDE) == "monitor" then
        monSide = config.MONITOR_SIDE
    else
        for _, side in ipairs(peripheral.getNames()) do
            if peripheral.getType(side) == "monitor" then
                monSide = side
                break
            end
        end
    end
    if monSide then
        mon = peripheral.wrap(monSide)
        pcall(function() mon.setTextScale(0.5) end)
        mon.setBackgroundColor(colors.black)
        mon.clear()
    end
end

function mapui.available() return mon ~= nil end

local function autoFit()
    local w, h = mon.getSize()
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    local function add(x, z)
        if x < minX then minX = x end
        if x > maxX then maxX = x end
        if z < minZ then minZ = z end
        if z > maxZ then maxZ = z end
    end
    for _, route in pairs(state.routes) do
        for _, p in ipairs(route.points) do add(p.x, p.z) end
    end
    for _, p in pairs(state.pois) do add(p.x, p.z) end
    if state.recording then
        for _, p in ipairs(state.recording.points) do add(p.x, p.z) end
    end
    if state.position then add(state.position.x, state.position.z) end
    if minX == math.huge then
        minX, maxX = view.cx - 8, view.cx + 8
        minZ, maxZ = view.cz - 8, view.cz + 8
    end
    view.cx = (minX + maxX) / 2
    view.cz = (minZ + maxZ) / 2
    local spanX = math.max(2, maxX - minX)
    local spanZ = math.max(2, maxZ - minZ)
    view.scale = math.min((w - 4) / spanX, (h - 5) / spanZ)
    view.scale = math.max(0.05, math.min(view.scale, 50))
end

local function toScreen(wx, wz)
    local w, h = mon.getSize()
    local sx = math.floor(w / 2 + (wx - view.cx) * view.scale + 0.5)
    local sy = math.floor(h / 2 + (wz - view.cz) * view.scale + 0.5)
    return sx, sy
end

local function drawCell(x, y, col)
    local w, h = mon.getSize()
    if x < 1 or y < 2 or x > w or y > h - 2 then return end
    mon.setCursorPos(x, y)
    mon.setBackgroundColor(col)
    mon.write(" ")
end

local function drawText(x, y, text, col)
    local w, h = mon.getSize()
    if x < 1 or y < 1 or y > h then return end
    mon.setCursorPos(x, y)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(col)
    mon.write(text:sub(1, math.max(0, w - x + 1)))
end

local function drawLine(x1, y1, x2, y2, col)
    local dx = math.abs(x2 - x1)
    local dy = math.abs(y2 - y1)
    local sx = x1 < x2 and 1 or -1
    local sy = y1 < y2 and 1 or -1
    local err = dx - dy
    local x, y = x1, y1
    while true do
        drawCell(x, y, col)
        if x == x2 and y == y2 then break end
        local e2 = 2 * err
        if e2 > -dy then err = err - dy x = x + sx end
        if e2 < dx then err = err + dx y = y + sy end
    end
end

local function sameSel(a, b)
    if not a or not b then return false end
    if a.kind ~= b.kind then return false end
    if a.kind == "poi" then return a.name == b.name end
    return a.id == b.id and a.index == b.index
end

local function drawGrid()
    local w, h = mon.getSize()
    local step = GRID_STEPS[#GRID_STEPS]
    for _, s in ipairs(GRID_STEPS) do
        if s * view.scale >= 6 then
            step = s
            break
        end
    end
    local cx1 = view.cx - (w / 2) / view.scale
    local cx2 = view.cx + (w / 2) / view.scale
    local cz1 = view.cz - (h / 2) / view.scale
    local cz2 = view.cz + (h / 2) / view.scale
    local x = math.floor(cx1 / step) * step
    while x <= cx2 do
        local sx = math.floor(w / 2 + (x - view.cx) * view.scale + 0.5)
        for y = 2, h - 2 do
            drawCell(sx, y, C.grid)
        end
        x = x + step
    end
    local z = math.floor(cz1 / step) * step
    while z <= cz2 do
        local sy = math.floor(h / 2 + (z - view.cz) * view.scale + 0.5)
        for px = 1, w do
            drawCell(px, sy, C.grid)
        end
        z = z + step
    end
end

local function drawRoute(route, col)
    local prev
    for i, p in ipairs(route.points) do
        local sx, sy = toScreen(p.x, p.z)
        if prev then drawLine(prev[1], prev[2], sx, sy, col) end
        drawCell(sx, sy, col)
        if p.landing then drawCell(sx + 1, sy, C.landing) end
        if p.special then drawCell(sx, sy, C.special) end
        hits[#hits + 1] = {
            x = sx, y = sy,
            sel = { kind = "routePoint", id = route.id, index = i, label = route.name .. "#" .. i },
        }
        prev = { sx, sy }
    end
end

local function drawPOIs()
    local w = mon.getSize()
    for name, p in pairs(state.pois) do
        local sx, sy = toScreen(p.x, p.z)
        drawCell(sx, sy, C.poi)
        drawCell(sx + 1, sy, C.poi)
        if view.scale > 1.5 then
            drawText(sx + 3, sy, name, C.poi)
        end
        hits[#hits + 1] = {
            x = sx, y = sy,
            sel = { kind = "poi", name = name, label = name },
        }
    end
end

local function drawVehicle()
    if not state.position then return end
    local sx, sy = toScreen(state.position.x, state.position.z)
    drawCell(sx, sy, C.vehicle)
    local rad = math.rad(state.heading or 0)
    local dx = -math.sin(rad)
    local dz = math.cos(rad)
    local ox = dx > 0.38 and 1 or (dx < -0.38 and -1 or 0)
    local oy = dz > 0.38 and 1 or (dz < -0.38 and -1 or 0)
    drawCell(sx + ox, sy + oy, C.vehicle)
end

local function drawSelection()
    if not state.selected then return end
    for _, hit in ipairs(hits) do
        if sameSel(hit.sel, state.selected) then
            local sx, sy = hit.x, hit.y
            for ox = -1, 1 do
                for oy = -1, 1 do
                    if ox ~= 0 or oy ~= 0 then
                        drawCell(sx + ox, sy + oy, C.selected)
                    end
                end
            end
            drawCell(sx, sy, C.selected)
            return
        end
    end
end

local function drawHeader()
    local w = mon.getSize()
    local selLabel = state.selected and (state.selected.label or state.selected.kind) or "-"
    local txt = string.format("AP %s | %s | sel:%s | %s",
        state.mode, state.profile, selLabel, state.nav.status or "")
    drawText(1, 1, txt, C.header)
end

local function drawStatus()
    local w, h = mon.getSize()
    local col = C.status
    if state.statusLevel == "error" then col = colors.red
    elseif state.statusLevel == "warn" then col = colors.orange end
    drawText(1, h - 1, state.statusMsg or "", col)
end

local function drawButtons()
    local w, h = mon.getSize()
    local defs = {
        { label = "FIT", action = function() view.autoFit = true end },
        { label = "Z-", action = function()
            view.scale = math.max(0.05, view.scale / 1.5)
            view.autoFit = false
        end },
        { label = "Z+", action = function()
            view.scale = math.min(50, view.scale * 1.5)
            view.autoFit = false
        end },
        { label = "GO", action = function()
            if not state.selected then
                notify.send("warn", "Nothing selected on the map")
                return
            end
            local ok, err = nav.gotoTarget(state.selected)
            if not ok then notify.send("warn", tostring(err)) end
        end },
        { label = "STOP", col = C.danger, action = function()
            nav.abort("map stop")
        end },
    }
    local x = 1
    for _, b in ipairs(defs) do
        local bw = #b.label + 2
        if x + bw - 1 > w then break end
        mon.setCursorPos(x, h)
        mon.setBackgroundColor(b.col or C.button)
        mon.setTextColor(colors.white)
        mon.write(" " .. b.label .. " ")
        buttons[#buttons + 1] = { x1 = x, x2 = x + bw - 1, action = b.action }
        x = x + bw + 1
    end
end

local function draw()
    if not mon then return end
    if view.autoFit or not view.scale then autoFit() end
    local w, h = mon.getSize()
    hits = {}
    buttons = {}
    mon.setBackgroundColor(colors.black)
    mon.clear()
    if w < 10 or h < 5 then
        drawText(1, 1, "monitor too small", C.danger)
        return
    end
    drawGrid()
    for _, id in ipairs(state.routeOrder) do
        local route = state.routes[id]
        if route then
            local col = route.kind == "landing" and C.landing or C.normal
            drawRoute(route, col)
        end
    end
    if state.recording then
        drawRoute({ id = -1, name = "REC", points = state.recording.points }, C.recording)
    end
    drawPOIs()
    drawSelection()
    drawVehicle()
    drawHeader()
    drawStatus()
    drawButtons()
end

local function handleTouch(x, y)
    local w, h = mon.getSize()
    if y == h then
        for _, b in ipairs(buttons) do
            if x >= b.x1 and x <= b.x2 then
                b.action()
                return
            end
        end
        return
    end
    local best, bestD = nil, 3 * 3
    for _, hit in ipairs(hits) do
        local dx, dy = hit.x - x, hit.y - y
        local d = dx * dx + dy * dy
        if d < bestD then
            bestD = d
            best = hit
        end
    end
    if best then
        state.selected = best.sel
        notify.send("info", "Selected: " .. (best.sel.label or best.sel.kind))
        state.rev = state.rev + 1
    end
end

-- Coroutine loop: periodic redraw and touch handling.
function mapui.run()
    if not mon then
        -- keep the coroutine alive so parallel.waitForAll keeps running
        while true do os.sleep(1) end
    end
    local timer = os.startTimer(0.5)
    draw()
    while true do
        local ev, p1, x, y = os.pullEvent()
        if ev == "timer" and p1 == timer then
            draw()
            timer = os.startTimer(0.5)
        elseif ev == "monitor_touch" and monSide and p1 == monSide then
            handleTouch(x, y)
            draw()
        elseif ev == "monitor_resize" and monSide and p1 == monSide then
            view.autoFit = true
            draw()
        elseif ev == "peripheral_detach" and p1 == monSide then
            mapui.init()
        end
    end
end

_G[MOD] = mapui
return mapui
]==],
  ["autopilot/nav.lua"] = [==[
-- Autopilot navigation: waypoint following with scan profiles,
-- landing route support and PWM speed control.

local MOD = "AP_NAV"
if _G[MOD] then return _G[MOD] end

-- dofile'd chunks run in _G without "shell"; main.lua sets AP_DIR.
local DIR = _G.AP_DIR or "/autopilot"
local function lib(name) return dofile(fs.combine(DIR, name)) end
local config = lib("config.lua")
local state = lib("state.lua")
local drive = lib("drive.lua")
local sensor = lib("sensor.lua")
local notify = lib("notify.lua")
local storage = lib("storage.lua")

local nav = {}

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local queue = {}        -- list of legs to follow
local pwmClock = 0      -- accumulated seconds in the current PWM cycle
local wasActive = false

local function normAngle(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    if a < -180 then a = a + 360 end
    return a
end

local function bearingTo(dx, dz)
    -- yaw-style bearing: 0 = +Z, 90 = -X (matches the heading convention)
    return math.deg(atan2(-dx, dz))
end

local function profileOf(leg)
    if leg.landing then
        return config.PROFILES.precise, "precise"
    end
    return config.PROFILES[state.profile] or config.PROFILES.normal, state.profile
end

function nav.isActive() return state.nav.active end

function nav.abort(reason)
    if state.nav.active then
        state.nav.active = false
        state.nav.status = "idle"
        drive.stop()
        notify.send("warn", "Autopilot stopped: " .. (reason or "manual stop"))
        state.rev = state.rev + 1
    end
end

local function buildLegsForRoute(route, uptoIndex)
    local legs = {}
    local n = math.min(uptoIndex or #route.points, #route.points)
    for i = 1, n do
        local p = route.points[i]
        legs[#legs + 1] = {
            x = p.x, y = p.y, z = p.z,
            landing = p.landing == true,
            label = route.name .. "#" .. i,
        }
    end
    return legs
end

-- Start navigation to a selected target.
-- sel = { kind="route", id } | { kind="routePoint", id, index } | { kind="poi", name }
function nav.gotoTarget(sel)
    if nav.isActive() then return false, "autopilot already active" end
    local legs = {}
    local destLabel = "?"

    if sel.kind == "poi" then
        local poi = state.pois[sel.name]
        if not poi then return false, "POI not found" end
        destLabel = "POI " .. poi.name
        -- follow the route that contains the POI up to it
        if poi.routeId then
            local route = storage.loadRoute(poi.routeId)
            if route then
                for _, l in ipairs(buildLegsForRoute(route, poi.index)) do
                    legs[#legs + 1] = l
                end
            end
        end
        -- final direct leg to the POI itself
        legs[#legs + 1] = { x = poi.x, y = poi.y, z = poi.z, label = poi.name }
        -- optional precise landing route at the very end
        if poi.landingRoute then
            local lid = storage.findRouteByName(poi.landingRoute)
            if lid then
                local lr = storage.loadRoute(lid)
                if lr then
                    for _, l in ipairs(buildLegsForRoute(lr)) do
                        l.landing = true
                        legs[#legs + 1] = l
                    end
                    destLabel = destLabel .. " (landing)"
                end
            else
                notify.send("warn", "Landing route not found: " .. poi.landingRoute)
            end
        end
    elseif sel.kind == "route" then
        local route = storage.loadRoute(sel.id)
        if not route then return false, "route not found" end
        destLabel = "route " .. route.name
        legs = buildLegsForRoute(route)
    elseif sel.kind == "routePoint" then
        local route = storage.loadRoute(sel.id)
        if not route then return false, "route not found" end
        destLabel = route.name .. "#" .. sel.index
        legs = buildLegsForRoute(route, sel.index)
    else
        return false, "unknown selection kind"
    end

    if #legs == 0 then return false, "no legs to follow" end

    queue = legs
    state.nav.active = true
    state.nav.legIndex = 1
    state.nav.legCount = #legs
    state.nav.status = "enroute"
    state.mode = "auto"
    pwmClock = 0
    notify.send("info", string.format("Autopilot started -> %s (%d legs)", destLabel, #legs))
    state.rev = state.rev + 1
    return true
end

-- Apply PWM to a raw signal set (duty in 0..1).
local function applyWithDuty(lf, lb, rf, rb, duty, dt)
    pwmClock = pwmClock + dt
    if pwmClock >= config.PWM_PERIOD then
        pwmClock = pwmClock % config.PWM_PERIOD
    end
    local onTime = config.PWM_PERIOD * math.min(1, math.max(0, duty))
    if pwmClock <= onTime then
        drive.set(lf, lb, rf, rb)
    else
        drive.stop()
    end
end

local lastTick = nil

local function tick()
    local now = os.clock()
    local dt = lastTick and (now - lastTick) or 0.1
    lastTick = now

    local st = sensor.getState()
    if not st or not st.x then
        nav.abort("position lost")
        return
    end

    local leg = queue[state.nav.legIndex]
    if not leg then
        state.nav.active = false
        state.nav.status = "idle"
        drive.stop()
        notify.send("info", "Arrived at destination")
        state.rev = state.rev + 1
        return
    end

    local dx, dz = leg.x - st.x, leg.z - st.z
    local dist = math.sqrt(dx * dx + dz * dz)
    local dy = math.abs((leg.y or st.y) - st.y)
    local prof = profileOf(leg)

    local arrived = dist < prof.arriveRadius
    if leg.landing then
        arrived = arrived and dy <= config.LANDING_DY
    end

    if arrived then
        state.nav.legIndex = state.nav.legIndex + 1
        pwmClock = 0
        notify.send("info", string.format("Waypoint %d/%d reached", state.nav.legIndex - 1, state.nav.legCount))
        if state.nav.legIndex > #queue then
            state.nav.active = false
            state.nav.status = "idle"
            drive.stop()
            notify.send("info", "Arrived at destination")
        end
        state.rev = state.rev + 1
        return
    end

    local err = normAngle(bearingTo(dx, dz) - sensor.headingOf(st))
    local ae = math.abs(err)

    local duty = 1.0
    if dist < config.SLOWDOWN_DIST then
        duty = prof.dutyMin + (1 - prof.dutyMin) * (dist / config.SLOWDOWN_DIST)
    end

    local lf, lb, rf, rb
    if ae > config.TURN_PIVOT_DEG then
        -- pivot in place towards the target
        if err > 0 then
            lf, lb, rf, rb = true, false, false, true   -- pivot right
        else
            lf, lb, rf, rb = false, true, true, false   -- pivot left
        end
        duty = 1.0
    elseif ae > config.TURN_DIFF_DEG then
        -- gentle differential turn while moving
        if err > 0 then
            lf, lb, rf, rb = true, false, false, false  -- left track only -> turn right
        else
            lf, lb, rf, rb = false, false, true, false  -- right track only -> turn left
        end
    else
        lf, lb, rf, rb = true, false, true, false       -- straight ahead
    end

    applyWithDuty(lf, lb, rf, rb, duty, dt)
    state.nav.status = string.format("leg %d/%d err=%.0f dist=%.1f", state.nav.legIndex, #queue, err, dist)
end

-- Coroutine loop: runs navigation while active, idles otherwise.
function nav.run()
    while true do
        if state.nav.active then
            wasActive = true
            tick()
            local _, profName = profileOf(queue[state.nav.legIndex] or {})
            local prof = config.PROFILES[profName] or config.PROFILES.normal
            os.sleep(prof.sampleEvery)
        else
            if wasActive then
                drive.stop()
                wasActive = false
            end
            os.sleep(0.5)
        end
    end
end

_G[MOD] = nav
return nav
]==],
  ["autopilot/notify.lua"] = [==[
-- Notification hub: local log + rednet broadcast for a central system.

local MOD = "AP_NOTIFY"
if _G[MOD] then return _G[MOD] end

-- dofile'd chunks run in _G without "shell"; main.lua sets AP_DIR.
local DIR = _G.AP_DIR or "/autopilot"
local function lib(name) return dofile(fs.combine(DIR, name)) end
local config = lib("config.lua")
local state = lib("state.lua")

local notify = {}

local modemSide = nil

function notify.init()
    modemSide = nil
    local function trySide(side)
        if side and peripheral.isPresent(side)
            and peripheral.getType(side) == "modem" then
            modemSide = side
        end
    end
    if config.MODEM_SIDE then
        trySide(config.MODEM_SIDE)
    else
        for _, side in ipairs(peripheral.getNames()) do
            if peripheral.getType(side) == "modem" then
                modemSide = side
                break
            end
        end
    end
    if modemSide then
        pcall(rednet.open, modemSide)
    end
end

function notify.hasModem() return modemSide ~= nil end

local function timestamp()
    local ok, s = pcall(os.date, "%H:%M:%S")
    if ok and type(s) == "string" then return s end
    return tostring(math.floor((os.epoch and os.epoch("utc") or 0) / 1000) % 86400)
end

-- level: "info" | "warn" | "error"
function notify.send(level, msg)
    if level ~= "info" and level ~= "warn" and level ~= "error" then
        level = "info"
    end
    local line = "[" .. timestamp() .. "] [" .. level:upper() .. "] " .. msg
    state.statusMsg = msg
    state.statusLevel = level
    state.rev = state.rev + 1
    -- append to the log
    pcall(function()
        local f = fs.open(config.LOG_FILE, "a")
        if f then
            f.writeLine(line)
            f.close()
        end
    end)
    -- broadcast for the central notification system
    if modemSide then
        pcall(rednet.broadcast, {
            source = "autopilot",
            level = level,
            message = msg,
            position = state.position,
            nav = {
                active = state.nav.active,
                leg = state.nav.legIndex,
                legs = state.nav.legCount,
                status = state.nav.status,
            },
        }, config.REDNET_CHANNEL)
    end
    print(line)
end

_G[MOD] = notify
return notify
]==],
  ["autopilot/record.lua"] = [==[
-- Route recording: manual driving with W/S/A/D while positions
-- are sampled automatically into a point list.

local MOD = "AP_RECORD"
if _G[MOD] then return _G[MOD] end

-- dofile'd chunks run in _G without "shell"; main.lua sets AP_DIR.
local DIR = _G.AP_DIR or "/autopilot"
local function lib(name) return dofile(fs.combine(DIR, name)) end
local config = lib("config.lua")
local state = lib("state.lua")
local drive = lib("drive.lua")
local sensor = lib("sensor.lua")
local notify = lib("notify.lua")
local storage = lib("storage.lua")

local recorder = {}

local pressed = {}   -- key codes currently held down

local SAMPLE_EVERY = 0.5   -- seconds between position samples
local MIN_DIST = 0.8       -- minimum horizontal movement to store a new point

local function timestamp()
    local ok, s = pcall(os.date, "%H%M%S")
    if ok and type(s) == "string" then return s end
    return tostring(os.clock())
end

local function driveFromKeys()
    if state.mode ~= "manual" and state.mode ~= "record" then return end
    if state.nav.active then return end  -- autopilot owns the motors
    local w = pressed[keys.w] or pressed[keys.up]
    local s = pressed[keys.s] or pressed[keys.down]
    local a = pressed[keys.a] or pressed[keys.left]
    local d = pressed[keys.d] or pressed[keys.right]
    if w and not s then
        if a and not d then
            drive.set(true, false, false, false)
        elseif d and not a then
            drive.set(false, false, true, false)
        else
            drive.forward()
        end
    elseif s and not w then
        if a and not d then
            drive.set(false, true, false, false)
        elseif d and not a then
            drive.set(false, false, false, true)
        else
            drive.backward()
        end
    elseif a and not d then
        drive.pivotLeft()
    elseif d and not a then
        drive.pivotRight()
    else
        drive.stop()
    end
end

local function sample()
    local rec = state.recording
    if not rec then return end
    local st = sensor.getState()
    if not st or not st.x then
        notify.send("warn", "Recording: position lost, point skipped")
        return
    end
    local last = rec.points[#rec.points]
    if last then
        local dx, dz = st.x - last.x, st.z - last.z
        local moved = math.sqrt(dx * dx + dz * dz) >= MIN_DIST
        local climbed = math.abs(st.y - last.y) >= 0.5
        if not moved and not climbed then return end
    end
    rec.points[#rec.points + 1] = { x = st.x, y = st.y, z = st.z }
    state.rev = state.rev + 1
end

function recorder.start(kind)
    if state.recording then return false, "already recording" end
    state.recording = { kind = kind or "normal", points = {} }
    state.mode = "record"
    notify.send("info", "Recording started (" .. state.recording.kind .. ")")
    state.rev = state.rev + 1
    return true
end

function recorder.isRecording() return state.recording ~= nil end

-- Finish the recording and save it under the given name.
function recorder.finish(name)
    local rec = state.recording
    if not rec then return false, "nothing to save" end
    if #rec.points == 0 then
        state.recording = nil
        state.mode = "manual"
        return false, "no points recorded"
    end
    name = name or ("route_" .. timestamp())
    local route = { id = nil, name = name, kind = rec.kind, points = rec.points }
    local id, err = storage.saveRoute(route)
    state.recording = nil
    state.mode = "manual"
    if not id then
        notify.send("error", "Save failed: " .. tostring(err))
        return false, err
    end
    -- register special / landing points as POIs
    local pois = storage.getPOIs()
    local changed = false
    for i, p in ipairs(route.points) do
        if p.special or p.landing then
            local poiName = name .. "#" .. i
            pois[poiName] = {
                name = poiName,
                x = p.x, y = p.y, z = p.z,
                routeId = id,
                index = i,
            }
            changed = true
        end
    end
    if changed then storage.savePOIs(pois) end
    notify.send("info", string.format("Route '%s' saved: %d points across %d disk(s)",
        name, #route.points, storage.driveCount()))
    state.rev = state.rev + 1
    return true, id
end

function recorder.discard()
    if not state.recording then return false, "not recording" end
    state.recording = nil
    state.mode = "manual"
    notify.send("warn", "Recording discarded")
    state.rev = state.rev + 1
    return true
end

-- Flag names of a flags table, for messages.
local function flagList(flags)
    local parts = {}
    for k, v in pairs(flags) do
        if v then parts[#parts + 1] = k end
    end
    return table.concat(parts, ",")
end

-- Mark the recorded point closest to the vehicle with the given flags,
-- e.g. { special = true } or { landing = true }.
function recorder.mark(flags)
    local rec = state.recording
    if not rec then return false, "start recording first (rec)" end
    if #rec.points == 0 then return false, "no points recorded yet" end
    local st = sensor.getState()
    local best, bestD = nil, math.huge
    for i, p in ipairs(rec.points) do
        local d = math.huge
        if st and st.x then
            local dx, dz = p.x - st.x, p.z - st.z
            d = dx * dx + dz * dz
        end
        if d < bestD then
            bestD = d
            best = i
        end
    end
    local p = rec.points[best]
    for k, v in pairs(flags) do p[k] = v end
    notify.send("info", string.format("Point %d marked (%s)", best, flagList(flags)))
    state.rev = state.rev + 1
    return true
end

-- Coroutine loop: key handling, manual driving and periodic sampling.
function recorder.run()
    local timer = os.startTimer(SAMPLE_EVERY)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "key" then
            pressed[p1] = true
            driveFromKeys()
        elseif ev == "key_up" then
            pressed[p1] = nil
            driveFromKeys()
        elseif ev == "timer" and p1 == timer then
            driveFromKeys()
            sample()
            timer = os.startTimer(SAMPLE_EVERY)
        end
    end
end

_G[MOD] = recorder
return recorder
]==],
  ["autopilot/sensor.lua"] = [==[
-- Position/orientation source: sublevel_sensor preferred, GPS fallback.

local MOD = "AP_SENSOR"
if _G[MOD] then return _G[MOD] end

-- dofile'd chunks run in _G without "shell"; main.lua sets AP_DIR.
local DIR = _G.AP_DIR or "/autopilot"
local function lib(name) return dofile(fs.combine(DIR, name)) end
local config = lib("config.lua")
local state = lib("state.lua")

local sensor = {}

local handle = nil
local lastGood = nil

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

function sensor.init()
    handle = nil
    if config.SENSOR_SIDE and peripheral.isPresent(config.SENSOR_SIDE) then
        handle = peripheral.wrap(config.SENSOR_SIDE)
    else
        for _, side in ipairs(peripheral.getNames()) do
            if peripheral.getType(side) == "sublevel_sensor" then
                handle = peripheral.wrap(side)
                break
            end
        end
    end
end

function sensor.hasSensor() return handle ~= nil end

-- Accepts either {x=,y=,z=} tables or plain arrays.
local function vec3(v)
    if type(v) ~= "table" then return nil end
    return v.x or v[1], v.y or v[2], v.z or v[3]
end

-- Returns a state table { x, y, z, yaw, pitch, roll, forward={x,y,z} }
-- or nil when position is unavailable.
function sensor.getState()
    if handle then
        local ok = handle.isOnSubLevel()
        if ok then
            local x, y, z = vec3(handle.getPosition())
            local fx, fy, fz = vec3(handle.getForward())
            local st = {
                x = x, y = y, z = z,
                yaw = handle.getYaw(),
                pitch = handle.getPitch(),
                roll = handle.getRoll(),
                forward = { x = fx, y = fy, z = fz },
            }
            state.sensorOk = x ~= nil
            if x then lastGood = st end
            return st
        end
        state.sensorOk = false
        return nil
    end
    -- Fallback: GPS (no orientation data).
    local x, y, z = gps.locate(2)
    if x then
        local st = { x = x, y = y, z = z, forward = nil }
        state.sensorOk = true
        lastGood = st
        return st
    end
    state.sensorOk = false
    return nil
end

-- World heading in degrees derived from the forward vector
-- (0 = +Z/south, 90 = -X/west), matching Minecraft yaw conventions.
function sensor.headingOf(st)
    if st and st.forward and st.forward.x then
        return math.deg(atan2(-st.forward.x, st.forward.z))
    end
    return (st and st.yaw) or 0
end

function sensor.lastGood() return lastGood end

_G[MOD] = sensor
return sensor
]==],
  ["autopilot/startup.lua"] = [==[
-- Autostart: place this file in the computer root as startup.lua
-- (or run shell.run from your existing startup).

shell.run("autopilot/main.lua")
]==],
  ["autopilot/state.lua"] = [==[
-- Shared mutable state (singleton shared by every module).

local MOD = "AP_STATE"
if _G[MOD] then return _G[MOD] end

local state = {
    mode = "manual",            -- "manual" | "record" | "auto"
    profile = "normal",         -- active scan profile name
    selected = nil,             -- { kind="route"|"routePoint"|"poi", ..., label }
    routes = {},                -- [routeId] = { id, name, kind, points }
    routeOrder = {},            -- ordered list of route ids
    pois = {},                  -- [name] = { name, x, y, z, routeId, index, landingRoute }
    position = nil,             -- { x, y, z } of the vehicle
    heading = 0,                -- current heading in degrees
    sensorOk = false,
    recording = nil,            -- { kind, points } while recording
    nav = {
        active = false,
        legIndex = 0,
        legCount = 0,
        status = "idle",
    },
    statusMsg = "ready",
    statusLevel = "info",       -- "info" | "warn" | "error"
    consoleBusy = false,        -- true while the console reads a command line
    rev = 0,                    -- bumped to request a map redraw
}

_G[MOD] = state
return state
]==],
  ["autopilot/storage.lua"] = [==[
-- Multi-disk storage: route data is striped across disks in chunks,
-- the manifest and POI index are replicated on every disk so any
-- single disk can rebuild the full picture.

local MOD = "AP_STORAGE"
if _G[MOD] then return _G[MOD] end

-- dofile'd chunks run in _G without "shell"; main.lua sets AP_DIR.
local DIR = _G.AP_DIR or "/autopilot"
local function lib(name) return dofile(fs.combine(DIR, name)) end
local config = lib("config.lua")

local storage = {}

local drives = {}   -- sorted list of { side, mount, label }

-- Probe a single drive side defensively: any failure (missing methods,
-- non-standard peripherals typed "drive") simply skips the drive.
local function tryDrive(side)
    local d = peripheral.wrap(side)
    if type(d) ~= "table" then return end
    if not d.isDiskPresent or not d.isDiskPresent() then return end
    local mount = nil
    if d.getMountPath then
        mount = d.getMountPath()
    end
    if not mount then return end
    local label = nil
    if d.getDiskLabel then
        local ok, lbl = pcall(d.getDiskLabel)
        if ok then label = lbl end
    end
    drives[#drives + 1] = {
        side = side,
        mount = mount,
        label = label,
    }
end

local function scanDrives()
    drives = {}
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "drive" then
            pcall(tryDrive, side)
        end
    end
    table.sort(drives, function(a, b) return a.side < b.side end)
    return drives
end

-- ---------- manifest (replicated) ----------

local manifest = { nextRouteId = 1, routes = {} }
local pois = {}

local function manifestPath(mount) return fs.combine(mount, config.MANIFEST_FILE) end
local function poiPath(mount) return fs.combine(mount, config.POI_FILE) end

local function readSerialized(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local data = textutils.unserialize(f.readAll())
    f.close()
    return data
end

local function writeEverywhere(relative, content)
    for _, d in ipairs(drives) do
        local f = fs.open(fs.combine(d.mount, relative), "w")
        if f then
            f.write(content)
            f.close()
        end
    end
end

function storage.init()
    scanDrives()
    for _, d in ipairs(drives) do
        local data = readSerialized(manifestPath(d.mount))
        if data and data.routes then
            manifest = data
            break
        end
    end
    for _, d in ipairs(drives) do
        local data = readSerialized(poiPath(d.mount))
        if data then
            pois = data
            break
        end
    end
end

function storage.refresh() scanDrives() end
function storage.driveCount() return #drives end
function storage.drives() return drives end

function storage.saveManifest()
    writeEverywhere(config.MANIFEST_FILE, textutils.serialize(manifest))
end

-- ---------- POI index (replicated) ----------

function storage.getPOIs() return pois end

-- Reload the POI index from any disk that has it.
function storage.loadPOIs()
    scanDrives()
    for _, d in ipairs(drives) do
        local data = readSerialized(poiPath(d.mount))
        if data then
            pois = data
            break
        end
    end
    return pois
end

function storage.savePOIs(newPois)
    if newPois then pois = newPois end
    writeEverywhere(config.POI_FILE, textutils.serialize(pois))
end

-- ---------- route chunk striping ----------

local function chunkName(routeId, index)
    return "rt_" .. routeId .. "_" .. index
end

function storage.deleteChunks(id)
    scanDrives()
    for _, d in ipairs(drives) do
        local i = 1
        while fs.exists(fs.combine(d.mount, chunkName(id, i))) do
            fs.delete(fs.combine(d.mount, chunkName(id, i)))
            i = i + 1
        end
    end
end

-- Save a route table { id=nil|num, name, kind, points }.
-- Serializes the points, stripes them across disks, updates the manifest.
function storage.saveRoute(route)
    scanDrives()
    if #drives == 0 then return nil, "no disk drives present" end
    local data = textutils.serialize(route.points)
    local id = route.id
    if id == nil then
        id = manifest.nextRouteId
        manifest.nextRouteId = manifest.nextRouteId + 1
        route.id = id
    else
        storage.deleteChunks(id)
    end
    local count = math.max(1, math.ceil(#data / config.CHUNK_SIZE))
    for i = 1, count do
        local part = data:sub((i - 1) * config.CHUNK_SIZE + 1, i * config.CHUNK_SIZE)
        local d = drives[((i - 1) % #drives) + 1]
        local f = fs.open(fs.combine(d.mount, chunkName(id, i)), "w")
        if f then
            f.write(part)
            f.close()
        end
    end
    manifest.routes[id] = {
        name = route.name,
        kind = route.kind,
        chunks = count,
        points = #route.points,
    }
    storage.saveManifest()
    return id
end

function storage.loadRoute(id)
    scanDrives()
    local meta = manifest.routes[id]
    if not meta then return nil, "route not found" end
    if #drives == 0 then return nil, "no disk drives present" end
    local buf = {}
    for i = 1, meta.chunks do
        local d = drives[((i - 1) % #drives) + 1]
        if not d then return nil, "disk missing for chunk " .. i end
        local f = fs.open(fs.combine(d.mount, chunkName(id, i)), "r")
        if not f then return nil, "chunk missing: " .. i end
        buf[#buf + 1] = f.readAll()
        f.close()
    end
    local points = textutils.unserialize(table.concat(buf))
    if not points then return nil, "corrupt route data" end
    return { id = id, name = meta.name, kind = meta.kind, points = points }
end

function storage.deleteRoute(id)
    storage.deleteChunks(id)
    manifest.routes[id] = nil
    storage.saveManifest()
end

function storage.listRoutes()
    local out = {}
    for id, meta in pairs(manifest.routes) do
        out[#out + 1] = {
            id = id,
            name = meta.name,
            kind = meta.kind,
            points = meta.points,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function storage.findRouteByName(name)
    for id, meta in pairs(manifest.routes) do
        if meta.name == name then return id end
    end
    return nil
end

function storage.freeSpace()
    local total = 0
    for _, d in ipairs(drives) do
        total = total + (fs.getFreeSpace(d.mount) or 0)
    end
    return total
end

_G[MOD] = storage
return storage
]==],
}

local function writeFile(path, content)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local f = fs.open(path, "w")
    if not f then
        print("ERROR: cannot write " .. path)
        return false
    end
    f.write(content)
    f.close()
    return true
end

local function main()
    local names = {}
    for path in pairs(FILES) do names[#names + 1] = path end
    table.sort(names)
    local ok = 0
    for _, path in ipairs(names) do
        if writeFile(path, FILES[path]) then
            ok = ok + 1
        end
    end
    print(string.format("Installed %d/%d files into /autopilot/", ok, #names))
    if not fs.exists("startup.lua") then
        writeFile("startup.lua", 'shell.run("autopilot/main.lua")\n')
        print("Created startup.lua (autorun)")
    else
        print("startup.lua already exists, left untouched")
    end
    print("Start with: autopilot/main.lua")
end

main()
