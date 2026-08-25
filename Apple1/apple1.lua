Cpu = require("cpu")

local maxClockSpeed = 1000

local openBus = function() return 0 end

local ram = {}
local rom = {}

local readFunctions =  {}
local writeFunctions = {}

for x=0,0xFFFF,1 do
    ram[x] = 0
    rom[x] = 0
    readFunctions[x] = openBus
    writeFunctions[x] = openBus
end

local function readMemory(address) return ram[address] end
local function writeMemory(address, data) ram[address] = data end

local function readRom(address) return rom[address] end

local function readBus(address) return readFunctions[address](address) end
local function writeBus(address, data) writeFunctions[address](address,data) end

local function setupMemoryRange(start,stop,readFunc,writeFunc)
    for x=start,stop,1 do
        readFunctions[x] = readFunc
        writeFunctions[x] = writeFunc
    end
end

setupMemoryRange(0x0000,0x0FFF,readMemory,writeMemory)
setupMemoryRange(0xE000,0xEFFF,readMemory,writeMemory)
setupMemoryRange(0xFF00,0xFFFF,readRom,openBus)

local function stringDump()
    local dump = cpu.dump()
    return string.format("PC:%X A:%X X:%X Y:%X SP:%X S:%X",dump.pc,dump.a,dump.x,dump.y,dump.sp,dump.status)
end

local inputBuffer = {}

local keyboardData = 0
local keyboardCont = 0
local displayData = 0
local displayCont = 0

local function writeToDisplay(data)
    if data == 0x8D then write("\n") return end --edge case for CR
    write(string.pack("B",bit.band(data,0x7F)))
end

local function getNextKeyFromBuffer()
    if #inputBuffer == 0 then return end
    local out = inputBuffer[1] --get next in queue
    if #inputBuffer == 1 then inputBuffer = {} return out end

    for i=1,#inputBuffer-1,1 do --shift rest of buffer down by one
        inputBuffer[i] = inputBuffer[i+1]
    end 
    inputBuffer[#inputBuffer] = nil

    return out
end

local function receiveKeyPress(keycode)
    if keyboardCont < 0x80 then
        updateKeyboardRegister(keycode)
        return
    end
    if #inputBuffer >= 8 then
        return
    end
    inputBuffer[#inputBuffer+1] = keycode
end

function updateKeyboardRegister(keycode)
    if not keycode then
        keyboardCont = bit.band(keyboardCont,0x7F)
    else
        keyboardCont = bit.bor(keyboardCont,0x80)
        keyboardData = bit.bor(keycode,0x80)
    end
end

readFunctions[0xd010] = function(address) local out = keyboardData updateKeyboardRegister(getNextKeyFromBuffer()) return out end
readFunctions[0xd011] = function(address) return keyboardCont end

readFunctions[0xd012] = function(address) return bit.bor(0x00,displayData) end
readFunctions[0xd013] = function(address) return displayCont end

writeFunctions[0xd011] = function(address,data) keyboardCont = data end
writeFunctions[0xd012] = function(address,data) writeToDisplay(data) end
writeFunctions[0xd013] = function(address,data) displayCont = data end

local cpu = Cpu(readBus, writeBus)

local function loadRomFromFile(path,start)
    local handle = fs.open(path,"rb")
    local data = handle.readAll()
    handle.close()

    for x=1,#data,1 do
        rom[(x-1+start)%0x10000] = string.unpack("B",data,x)
    end
end


local function mainThread()
    loadRomFromFile("wozmon.bin",0xFF00)
    
    local status
    while true do
        status = cpu.run(maxClockSpeed/20)
        if status ~= 0 then error("CPU HALTED "..stringDump()) end
        sleep()
    end
end

local function inputThread()
    term.setCursorBlink(true)

    local event
    while true do
        event = {os.pullEvent()}
        if event[1] == "char" then
        receiveKeyPress(string.unpack("B",string.upper(event[2])))
        elseif event[1] == "key" then --yes yes i know its awful
        if event[2] == keys.backspace then receiveKeyPress(0xDF) end
        if event[2] == keys.enter then receiveKeyPress(0x8D) end
        if event[2] == keys.apostrophe then receiveKeyPress(0x9B) end
        if event[2] == keys.delete then cpu.reset() end
        end --i just want this to work already
    end
end

parallel.waitForAny(inputThread,mainThread)
