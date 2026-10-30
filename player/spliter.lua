-- ============================================
-- Floppy disk track splitter
-- Splits one big .dfpwm file into parts and
-- spreads them across all mounted floppy drives.
-- The player reassembles the parts automatically.
--
-- Usage:
--   split <input.dfpwm> [track name] [artist]
--
-- Example:
--   split song.dfpwm "My Song" "Some Artist"
-- ============================================

local CONFIG = {
    partSize = 120 * 1024,   -- bytes per floppy part (floppy = 128 KiB)
    ioBuffer = 16 * 1024,    -- read/write block size
    reserveSpace = 4 * 1024, -- keep free on each disk for meta files
    musicDir = "music",
    sampleRate = 48000,
    partExt = ".part",
    metaExt = ".meta",
}

-- ===== ARGS =====
local args = {...}
local inputPath = args[1]
if not inputPath then
    print("Usage: split <input.dfpwm> [track name] [artist]")
    return
end
if not fs.exists(inputPath) then
    print("Error: file not found: " .. inputPath)
    return
end

local trackName = args[2]
if not trackName then
    trackName = inputPath:match("([^/]+)%.dfpwm$") or "track"
end
local artist = args[3] or "Unknown"

-- ===== DRIVE HELPERS =====
local function scanDrives()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "drive" then
            local mp = disk.getMountPath(name)
            if mp then
                local ok, free = pcall(fs.getFreeSpace, mp)
                table.insert(out, {
                    name = name,
                    mount = mp,
                    free = (ok and free) or 0,
                })
            end
        end
    end
    return out
end

-- Pick a drive that has at least minBytes of free space
local function pickDrive(drives, minBytes)
    for _, d in ipairs(drives) do
        if d.free >= minBytes + CONFIG.reserveSpace then
            return d
        end
    end
    return nil
end

-- ===== SPLIT =====
print("Reading: " .. inputPath)
print("Track:   " .. trackName .. " - " .. artist)

local src = fs.open(inputPath, "rb")
if not src then
    print("Error: cannot open input file")
    return
end

local drives = scanDrives()
if #drives == 0 then
    print("Error: no mounted drives found. Insert floppies and try again.")
    src.close()
    return
end

local parts = {}       -- {mount=..., drive=..., name=...} in order
local partIdx = 0
local totalBytes = 0

while true do
    -- Choose a drive: full part if possible, otherwise whatever is left
    local d = pickDrive(drives, CONFIG.partSize)
    local writeSize = CONFIG.partSize
    if not d then
        d = pickDrive(drives, 1)
        if d then
            writeSize = d.free - CONFIG.reserveSpace
        end
    end

    if not d then
        print("")
        print("Out of disk space!")
        print("Insert more floppies, then press Enter to continue.")
        print("Written so far: " .. partIdx .. " parts, " .. totalBytes .. " bytes")
        read()
        drives = scanDrives()
    else
        local partName = trackName .. ".dfpwm" .. CONFIG.partExt .. partIdx
        local dir = fs.combine(d.mount, CONFIG.musicDir)
        fs.makeDir(dir)

        local out = fs.open(fs.combine(dir, partName), "wb")
        if not out then
            print("Error: cannot write to " .. d.mount)
            src.close()
            return
        end

        local written = 0
        while written < writeSize do
            local want = math.min(CONFIG.ioBuffer, writeSize - written)
            local data = src.read(want)
            if not data then break end
            out.write(data)
            written = written + #data
            totalBytes = totalBytes + #data
        end
        out.close()

        d.free = d.free - written
        table.insert(parts, {mount = d.mount, drive = d.name, name = partName})
        print(string.format("Part %d -> %s (%d bytes)", partIdx, d.mount, written))
        partIdx = partIdx + 1

        if written < writeSize then
            break -- end of input file
        end
    end
end

src.close()

-- ===== METADATA =====
-- Every disk that holds a part gets a small meta file so the player
-- knows the track name, total size and how many parts to expect.
local totalParts = #parts
local duration = math.floor(totalBytes * 8 / CONFIG.sampleRate)

for i, p in ipairs(parts) do
    local meta = {
        name = trackName,
        artist = artist,
        size = totalBytes,
        parts = totalParts,
        index = i - 1,
        duration = duration,
    }
    local mf = fs.open(fs.combine(p.mount, CONFIG.musicDir, p.name .. CONFIG.metaExt), "w")
    if mf then
        mf.write(textutils.serializeJSON(meta))
        mf.close()
    end
    -- Label the floppy so it is easy to identify
    pcall(disk.setLabel, p.drive, trackName .. " [" .. i .. "/" .. totalParts .. "]")
end

print("")
print("Done!")
print("Parts:    " .. totalParts)
print("Total:    " .. totalBytes .. " bytes")
print("Duration: ~" .. math.floor(duration / 60) .. "m " .. (duration % 60) .. "s")
print("Insert all " .. totalParts .. " floppies into the player to listen.")
