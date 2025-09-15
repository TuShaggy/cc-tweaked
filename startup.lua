-- ============================================
-- Draconic Reactor Controller (classic AUTO)
-- Keeps Field at target (%) using:
--   flow = fieldDrainRate / (1 - targetStrength/100)
-- Adds: startup menu to pick INPUT/OUTPUT flow gates
-- (All multi-line if/then/end to avoid syntax errors)
-- ============================================

-- === modifiable variables ===
local reactorSide = "back"

local targetStrength = 50
local maxTemperature = 8000
local safeTemperature = 3000
local lowestFieldPercent = 15

local activateOnCharged = 1

-- === do not touch below ===
os.loadAPI("lib/f")

local version = "0.52-classic-auto+gate-picker"
local autoInputGate = 1
local curInputGate = 222000

-- monitor / peripherals
local mon, monitor, monX, monY
local reactor
local fluxgate        -- OUTPUT (from reactor)
local inputfluxgate   -- INPUT (to reactor)

-- reactor info
local ri

-- state
local action = "None since reboot"
local emergencyCharge = false
local emergencyTemp = false

-- saved names (persisted)
local savedInputGateName  = nil
local savedOutputGateName = nil

-- ------------- config I/O -------------
local function save_config()
  local sw = fs.open("config.txt", "w")
  sw.writeLine(version)
  sw.writeLine(autoInputGate)
  sw.writeLine(curInputGate)
  sw.writeLine(targetStrength)
  sw.writeLine(savedInputGateName or "")
  sw.writeLine(savedOutputGateName or "")
  sw.close()
end

local function load_config()
  if not fs.exists("config.txt") then return end
  local sr = fs.open("config.txt", "r")
  version         = sr.readLine() or version
  local a         = tonumber(sr.readLine() or "")
  local c         = tonumber(sr.readLine() or "")
  local ts        = tonumber(sr.readLine() or "")
  local inName    = sr.readLine() or ""
  local outName   = sr.readLine() or ""
  if a  ~= nil then autoInputGate  = a  end
  if c  ~= nil then curInputGate   = c  end
  if ts ~= nil then targetStrength = ts end
  if inName ~= ""  then savedInputGateName  = inName end
  if outName ~= "" then savedOutputGateName = outName end
  sr.close()
end

-- ------------- flow gate picker -------------
local function detectFlowGates()
  local names = peripheral.getNames()
  local list = {}
  for _, n in ipairs(names) do
    local okGet = pcall(peripheral.call, n, "getSignalLowFlow")
    local okSet = pcall(peripheral.call, n, "setSignalLowFlow", 0)
    if okGet and okSet then
      table.insert(list, n)
    else
      local t = string.lower(peripheral.getType(n) or "")
      if t == "flow_gate" or t == "flowgate" or t == "flux_gate" or t == "fluxgate" then
        table.insert(list, n)
      end
    end
  end
  table.sort(list)
  return list
end

local function menuPick(title, options, preselect)
  term.clear()
  term.setCursorPos(1,1)
  print("==== "..title.." ====")
  for i,opt in ipairs(options) do
    local mark = (preselect and opt == preselect) and " *" or ""
    print(string.format("[%d] %s%s", i, opt, mark))
  end
  while true do
    write("> #: ")
    local s = read()
    local idx = tonumber(s)
    if idx and options[idx] then return options[idx] end
    print("Invalid, try again")
  end
end

local function selectFlowGates()
  local gates = detectFlowGates()
  if #gates < 2 then
    error("Need at least 2 flow gates detected (supporting get/setSignalLowFlow).")
  end

  print("")
  print("Select gate that FEEDS the reactor field (INPUT to reactor).")
  local inName = menuPick("INPUT Flow Gate", gates, savedInputGateName)

  local remaining = {}
  for _, n in ipairs(gates) do
    if n ~= inName then table.insert(remaining, n) end
  end

  print("")
  print("Select gate that EXTRACTS energy FROM the reactor (OUTPUT).")
  local outName = menuPick("OUTPUT Flow Gate", remaining, savedOutputGateName)

  savedInputGateName  = inName
  savedOutputGateName = outName
  save_config()

  inputfluxgate = peripheral.wrap(savedInputGateName)
  fluxgate      = peripheral.wrap(savedOutputGateName)

  if not inputfluxgate then error("Failed to wrap INPUT gate: "..tostring(savedInputGateName)) end
  if not fluxgate then error("Failed to wrap OUTPUT gate: "..tostring(savedOutputGateName)) end

  print("")
  print("INPUT  gate -> "..savedInputGateName)
  print("OUTPUT gate -> "..savedOutputGateName)
end

-- ------------- peripherals -------------
monitor_peripheral = f.periphSearch("monitor")
monitor = window.create(monitor_peripheral, 1, 1, monitor_peripheral.getSize())
reactor = peripheral.wrap(reactorSide)

if monitor == nil then error("No valid monitor was found") end
if reactor == nil then error("No valid reactor was found") end

monX, monY = monitor.getSize()
mon = { monitor = monitor, X = monX, Y = monY }

load_config()
selectFlowGates()

-- ------------- buttons -------------
local function drawButtons(y)
  f.draw_text(mon, 2,  y, " < ",  colors.white, colors.gray)
  f.draw_text(mon, 6,  y, " <<",  colors.white, colors.gray)
  f.draw_text(mon, 10, y, "<<<",  colors.white, colors.gray)
  f.draw_text(mon, 17, y, ">>>",  colors.white, colors.gray)
  f.draw_text(mon, 21, y, ">> ",  colors.white, colors.gray)
  f.draw_text(mon, 25, y, " > ",  colors.white, colors.gray)
end

local function buttons()
  while true do
    local _, _, xPos, yPos = os.pullEvent("monitor_touch")

    -- OUTPUT gate controls
    if yPos == 8 then
      local cFlow = fluxgate.getSignalLowFlow()
      if     xPos >= 2  and xPos <= 4  then cFlow = cFlow - 1000
      elseif xPos >= 6  and xPos <= 9  then cFlow = cFlow - 10000
      elseif xPos >= 10 and xPos <= 12 then cFlow = cFlow - 100000
      elseif xPos >= 17 and xPos <= 19 then cFlow = cFlow + 100000
      elseif xPos >= 21 and xPos <= 23 then cFlow = cFlow + 10000
      elseif xPos >= 25 and xPos <= 27 then cFlow = cFlow + 1000
      end
      if cFlow < 0 then cFlow = 0 end
      fluxgate.setSignalLowFlow(cFlow)
    end

    -- INPUT gate controls (manual)
    if yPos == 10 and xPos ~= 14 and xPos ~= 15 and autoInputGate == 0 then
      if     xPos >= 2  and xPos <= 4  then curInputGate = curInputGate - 1000
      elseif xPos >= 6  and xPos <= 9  then curInputGate = curInputGate - 10000
      elseif xPos >= 10 and xPos <= 12 then curInputGate = curInputGate - 100000
      elseif xPos >= 17 and xPos <= 19 then curInputGate = curInputGate + 100000
      elseif xPos >= 21 and xPos <= 23 then curInputGate = curInputGate + 10000
      elseif xPos >= 25 and xPos <= 27 then curInputGate = curInputGate + 1000
      end
      if curInputGate < 0 then curInputGate = 0 end
      inputfluxgate.setSignalLowFlow(curInputGate)
      save_config()
    end

    -- INPUT gate toggle
    if yPos == 10 and (xPos == 14 or xPos == 15) then
      autoInputGate = 1 - autoInputGate -- toggle 0/1
      if autoInputGate == 0 then
        inputfluxgate.setSignalLowFlow(curInputGate)
      end
      save_config()
    end
  end
end

-- ------------- update loop -------------
local function update()
  while true do
    monitor.setVisible(false)
    f.clear(mon)

    ri = reactor.getReactorInfo()
    if ri == nil then
      error("reactor has an invalid setup")
    end

    local statusColor = colors.red
    if ri.status == "online" or ri.status == "charged" then
      statusColor = colors.green
    elseif ri.status == "offline" then
      statusColor = colors.gray
    elseif ri.status == "charging" then
      statusColor = colors.orange
    end

    f.draw_text_lr(mon, 2, 2, 1, "Reactor Status", string.upper(ri.status), colors.white, statusColor, colors.black)
    f.draw_text_lr(mon, 2, 4, 1, "Generation", f.format_int(ri.generationRate) .. " rf/t", colors.white, colors.lime, colors.black)

    local tempColor = colors.red
    if ri.temperature <= 5000 then
      tempColor = colors.green
    elseif ri.temperature >= 5000 and ri.temperature <= 6500 then
      tempColor = colors.orange
    end
    f.draw_text_lr(mon, 2, 6, 1, "Temperature", f.format_int(ri.temperature) .. "C", colors.white, tempColor, colors.black)

    f.draw_text_lr(mon, 2, 7, 1, "Output Gate", f.format_int(fluxgate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)
    drawButtons(8)

    f.draw_text_lr(mon, 2, 9, 1, "Input Gate", f.format_int(inputfluxgate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)

    if autoInputGate == 1 then
      f.draw_text(mon, 14, 10, "AU", colors.white, colors.gray)
    else
      f.draw_text(mon, 14, 10, "MA", colors.white, colors.gray)
      drawButtons(10)
    end

    local satPercent = math.ceil(ri.energySaturation / ri.maxEnergySaturation * 10000) * 0.01
    f.draw_text_lr(mon, 2, 11, 1, "Energy Saturation", satPercent .. "%", colors.white, colors.white, colors.black)
    f.progress_bar(mon, 2, 12, mon.X-2, satPercent, 100, colors.blue, colors.gray)

    local fieldPercent = math.ceil(ri.fieldStrength / ri.maxFieldStrength * 10000) * 0.01
    local fieldColor = colors.red
    if fieldPercent >= 50 then
      fieldColor = colors.green
    elseif fieldPercent > 30 then
      fieldColor = colors.orange
    end

    if autoInputGate == 1 then
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength T:" .. targetStrength, fieldPercent .. "%", colors.white, fieldColor, colors.black)
      local denom = 1 - (targetStrength/100)
      if denom <= 0 then denom = 0.001 end
      local fluxval = ri.fieldDrainRate / denom
      if fluxval < 0 then fluxval = 0 end
      inputfluxgate.setSignalLowFlow(math.floor(fluxval + 0.5))
    else
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength", fieldPercent .. "%", colors.white, fieldColor, colors.black)
      inputfluxgate.setSignalLowFlow(curInputGate)
    end
    f.progress_bar(mon, 2, 15, mon.X-2, fieldPercent, 100, fieldColor, colors.gray)

    local fuelPercent = 100 - math.ceil(ri.fuelConversion / ri.maxFuelConversion * 10000) * 0.01
    local fuelColor = colors.red
    if fuelPercent >= 70 then
      fuelColor = colors.green
    elseif fuelPercent > 30 then
      fuelColor = colors.orange
    end

    f.draw_text_lr(mon, 2, 17, 1, "Fuel ", fuelPercent .. "%", colors.white, fuelColor, colors.black)
    f.progress_bar(mon, 2, 18, mon.X-2, fuelPercent, 100, fuelColor, colors.gray)

    f.draw_text_lr(mon, 2, 19, 1, "Action ", action, colors.gray, colors.gray, colors.black)

    -- reactor interaction / safeguards (expanded into multiline ifs)
    if emergencyCharge == true then
      reactor.chargeReactor()
    end

    if ri.status == "charging" then
      inputfluxgate.setSignalLowFlow(900000)
      emergencyCharge = false
    end

    if emergencyTemp == true and ri.status == "stopping" and ri.temperature < safeTemperature then
      reactor.activateReactor()
      emergencyTemp = false
    end

    if ri.status == "charged" and activateOnCharged == 1 then
      reactor.activateReactor()
    end

    if fuelPercent <= 10 then
      reactor.stopReactor()
      action = "Fuel below 10%, refuel"
    end

    if fieldPercent <= lowestFieldPercent and ri.status == "online" then
      action = "Field Str < " .. lowestFieldPercent .. "%"
      reactor.stopReactor()
      reactor.chargeReactor()
      emergencyCharge = true
    end

    if ri.temperature > maxTemperature then
      reactor.stopReactor()
      action = "Temp > " .. maxTemperature
      emergencyTemp = true
    end

    monitor.setVisible(true)
    sleep(0.05)
  end
end

parallel.waitForAny(buttons, update)
