-- ============================================
-- Draconic Reactor Controller (classic AUTO)
-- Holds Field at target (%) with:
--   flow = fieldDrainRate / (1 - targetStrength/100)
-- Features:
--  - Gate picker (INPUT/OUTPUT) on first run or if missing
--  - AUTO/MANUAL for input gate (AUTO keeps targetStrength)
--  - Smooth, flicker-free monitor redraw
--  - Separate control loop (~0.1s) for AUTO input
--  - Safety shutdowns: low field, high temp, low fuel
-- ============================================

-- === Modifiable ===
local reactorSide        = "back"
local targetStrength     = 50
local maxTemperature     = 8000
local safeTemperature    = 3000
local lowestFieldPercent = 15
local activateOnCharged  = 1

-- === Load lib/f (robusto: acepta lib/f o lib/f.lua) ===
local function loadF()
  if fs.exists("lib/f") then
    local ok, err = pcall(os.loadAPI, "lib/f")
    if not ok then error("Failed to load lib/f: "..tostring(err)) end
  elseif fs.exists("lib/f.lua") then
    local ok, err = pcall(os.loadAPI, "lib/f.lua")
    if not ok then error("Failed to load lib/f.lua: "..tostring(err)) end
  else
    error("Missing lib/f (or lib/f.lua). Run installer first.")
  end
end
loadF()

-- === Do not edit below ===
local version       = "0.60-optimized"
local autoInputGate = 1          -- 1=AUTO, 0=MANUAL
local curInputGate  = 222000     -- manual setpoint (rf/t)

-- Peripherals / UI
local reactor
local inputGate      -- feeds field (TO reactor)
local outputGate     -- extracts energy (FROM reactor)
local monitor_peripheral, monitor
local monX, monY
local mon = {}

-- State
local ri
local action          = "None since reboot"
local emergencyCharge = false
local emergencyTemp   = false

-- Saved gate names
local savedInputGateName, savedOutputGateName = nil, nil

-- === Config I/O ===
local function save_config()
  local sw = fs.open("config.txt", "w")
  sw.writeLine(tostring(version))
  sw.writeLine(tostring(autoInputGate))
  sw.writeLine(tostring(curInputGate))
  sw.writeLine(tostring(targetStrength))
  sw.writeLine(tostring(savedInputGateName or ""))
  sw.writeLine(tostring(savedOutputGateName or ""))
  sw.close()
end

local function load_config()
  if not fs.exists("config.txt") then return end
  local sr = fs.open("config.txt", "r"); if not sr then return end
  local v   = sr.readLine(); if v and v ~= "" then version = v end
  local a   = tonumber(sr.readLine() or ""); if a ~= nil then autoInputGate = a end
  local c   = tonumber(sr.readLine() or ""); if c ~= nil then curInputGate  = c end
  local ts  = tonumber(sr.readLine() or ""); if ts~=nil then targetStrength = ts end
  local inN = sr.readLine() or ""; if inN ~= "" then savedInputGateName  = inN end
  local outN= sr.readLine() or ""; if outN~= "" then savedOutputGateName = outN end
  sr.close()
end

-- === Gate picker ===
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
      if t=="flow_gate" or t=="flowgate" or t=="flux_gate" or t=="fluxgate" then
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
    local mark = (preselect and opt == preselect) and "  *" or ""
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

local function ensureGates()
  if savedInputGateName  then inputGate  = peripheral.wrap(savedInputGateName) end
  if savedOutputGateName then outputGate = peripheral.wrap(savedOutputGateName) end
  if inputGate and outputGate then return end

  local gates = detectFlowGates()
  if #gates < 2 then error("Need at least 2 flow gates (get/setSignalLowFlow).") end

  print("\nSelect gate that FEEDS the reactor field (INPUT to reactor).")
  local inName = menuPick("INPUT Flow Gate", gates, savedInputGateName)

  local remaining = {}
  for _, n in ipairs(gates) do if n ~= inName then table.insert(remaining, n) end end

  print("\nSelect gate that EXTRACTS energy FROM the reactor (OUTPUT).")
  local outName = menuPick("OUTPUT Flow Gate", remaining, savedOutputGateName)

  savedInputGateName  = inName
  savedOutputGateName = outName
  save_config()

  inputGate  = peripheral.wrap(savedInputGateName)
  outputGate = peripheral.wrap(savedOutputGateName)

  if not inputGate  then error("Failed to wrap INPUT gate: "..tostring(savedInputGateName)) end
  if not outputGate then error("Failed to wrap OUTPUT gate: "..tostring(savedOutputGateName)) end

  print("")
  print("INPUT  gate -> "..savedInputGateName)
  print("OUTPUT gate -> "..savedOutputGateName)
end

-- === Peripherals ===
monitor_peripheral = f.periphSearch("monitor")
if not monitor_peripheral then error("No valid monitor was found") end
monitor = window.create(monitor_peripheral, 1, 1, monitor_peripheral.getSize())
local okR; okR, reactor = pcall(peripheral.wrap, reactorSide)
if not okR or not reactor then error("No valid reactor on side '"..tostring(reactorSide).."'") end

monX, monY = monitor.getSize()
mon = { monitor = monitor, X = monX, Y = monY }

load_config()
ensureGates()

-- === Buttons (layout como original) ===
local function drawButtons(y)
  f.draw_text(mon,  2, y, " < ",  colors.white, colors.gray)
  f.draw_text(mon,  6, y, " <<",  colors.white, colors.gray)
  f.draw_text(mon, 10, y, "<<<",  colors.white, colors.gray)
  f.draw_text(mon, 17, y, ">>>",  colors.white, colors.gray)
  f.draw_text(mon, 21, y, ">> ",  colors.white, colors.gray)
  f.draw_text(mon, 25, y, " > ",  colors.white, colors.gray)
end

local function buttons()
  while true do
    local _, _, xPos, yPos = os.pullEvent("monitor_touch")

    -- OUTPUT
    if yPos == 8 then
      local c = outputGate.getSignalLowFlow()
      if     xPos >=  2 and xPos <=  4 then c = c - 1000
      elseif xPos >=  6 and xPos <=  9 then c = c - 10000
      elseif xPos >= 10 and xPos <= 12 then c = c - 100000
      elseif xPos >= 17 and xPos <= 19 then c = c + 100000
      elseif xPos >= 21 and xPos <= 23 then c = c + 10000
      elseif xPos >= 25 and xPos <= 27 then c = c + 1000
      end
      if c < 0 then c = 0 end
      outputGate.setSignalLowFlow(c)
    end

    -- INPUT (manual)
    if yPos == 10 and autoInputGate == 0 and xPos ~= 14 and xPos ~= 15 then
      if     xPos >=  2 and xPos <=  4 then curInputGate = curInputGate - 1000
      elseif xPos >=  6 and xPos <=  9 then curInputGate = curInputGate - 10000
      elseif xPos >= 10 and xPos <= 12 then curInputGate = curInputGate - 100000
      elseif xPos >= 17 and xPos <= 19 then curInputGate = curInputGate + 100000
      elseif xPos >= 21 and xPos <= 23 then curInputGate = curInputGate + 10000
      elseif xPos >= 25 and xPos <= 27 then curInputGate = curInputGate + 1000
      end
      if curInputGate < 0 then curInputGate = 0 end
      inputGate.setSignalLowFlow(curInputGate)
      save_config()
    end

    -- Toggle AUTO/MANUAL
    if yPos == 10 and (xPos == 14 or xPos == 15) then
      autoInputGate = 1 - autoInputGate
      if autoInputGate == 0 then inputGate.setSignalLowFlow(curInputGate) end
      save_config()
    end
  end
end

-- === Control loop (AUTO input ~0.1s) ===
local CONTROL_INTERVAL = 0.10
local lastSet = nil
local smoothAlpha = 0.30

local function controlLoop()
  local t = os.startTimer(CONTROL_INTERVAL)
  while true do
    local ev, id = os.pullEvent()
    if ev == "timer" and id == t then
      local info = reactor.getReactorInfo()
      if info then
        if info.status == "charging" then
          inputGate.setSignalLowFlow(900000)
          lastSet = nil
        elseif info.status == "online" then
          if autoInputGate == 1 then
            local denom = 1 - (targetStrength/100)
            if denom <= 0 then denom = 0.001 end
            local base = (info.fieldDrainRate or 0) / denom
            if base < 0 then base = 0 end
            if lastSet then base = lastSet*(1 - smoothAlpha) + base*smoothAlpha end
            base = math.floor(base + 0.5)
            inputGate.setSignalLowFlow(base)
            lastSet = base
          else
            inputGate.setSignalLowFlow(curInputGate)
          end
        end
      end
      t = os.startTimer(CONTROL_INTERVAL)
    end
  end
end

-- === UI loop (draw + safety) ===
local function update()
  while true do
    monitor.setVisible(false)
    f.clear(mon)

    ri = reactor.getReactorInfo()
    if ri == nil then error("reactor has an invalid setup") end

    local statusColor = colors.red
    if     ri.status == "online"  or ri.status == "charged" then statusColor = colors.green
    elseif ri.status == "offline"                           then statusColor = colors.gray
    elseif ri.status == "charging"                          then statusColor = colors.orange
    end

    f.draw_text_lr(mon, 2, 2, 1, "Reactor Status", string.upper(ri.status), colors.white, statusColor, colors.black)
    f.draw_text_lr(mon, 2, 4, 1, "Generation", f.format_int(ri.generationRate or 0) .. " rf/t", colors.white, colors.lime, colors.black)

    local tempColor = colors.red
    if ri.temperature <= 5000 then tempColor = colors.green
    elseif ri.temperature <= 6500 then tempColor = colors.orange end
    f.draw_text_lr(mon, 2, 6, 1, "Temperature", f.format_int(ri.temperature or 0) .. "C", colors.white, tempColor, colors.black)

    f.draw_text_lr(mon, 2, 7, 1, "Output Gate", f.format_int(outputGate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)
    drawButtons(8)

    f.draw_text_lr(mon, 2, 9, 1, "Input Gate", f.format_int(inputGate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)
    if autoInputGate == 1 then
      f.draw_text(mon, 14, 10, "AU", colors.white, colors.gray)
    else
      f.draw_text(mon, 14, 10, "MA", colors.white, colors.gray)
      drawButtons(10)
    end

    local satPercent   = math.ceil((ri.energySaturation or 0) / (ri.maxEnergySaturation or 1) * 10000) * 0.01
    f.draw_text_lr(mon, 2, 11, 1, "Energy Saturation", string.format("%.2f%%", satPercent), colors.white, colors.white, colors.black)
    f.progress_bar(mon, 2, 12, mon.X-2, satPercent, 100, colors.blue, colors.gray)

    local fieldPercent = math.ceil((ri.fieldStrength or 0) / (ri.maxFieldStrength or 1) * 10000) * 0.01
    local fieldColor   = colors.red
    if fieldPercent >= 50 then fieldColor = colors.green
    elseif fieldPercent > 30 then fieldColor = colors.orange end

    if autoInputGate == 1 then
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength T:" .. targetStrength, string.format("%.2f%%", fieldPercent), colors.white, fieldColor, colors.black)
    else
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength", string.format("%.2f%%", fieldPercent), colors.white, fieldColor, colors.black)
    end
    f.progress_bar(mon, 2, 15, mon.X-2, fieldPercent, 100, fieldColor, colors.gray)

    local fuelPercent  = 100 - math.ceil((ri.fuelConversion or 0) / (ri.maxFuelConversion or 1) * 10000) * 0.01
    local fuelColor    = colors.red
    if fuelPercent >= 70 then fuelColor = colors.green
    elseif fuelPercent > 30 then fuelColor = colors.orange end
    f.draw_text_lr(mon, 2, 17, 1, "Fuel", string.format("%.2f%%", fuelPercent), colors.white, fuelColor, colors.black)
    f.progress_bar(mon, 2, 18, mon.X-2, fuelPercent, 100, fuelColor, colors.gray)

    f.draw_text_lr(mon, 2, 19, 1, "Action", action, colors.gray, colors.gray, colors.black)

    -- Safeguards
    if emergencyCharge == true then reactor.chargeReactor() end

    if ri.status == "charging" then
      inputGate.setSignalLowFlow(900000)
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

parallel.waitForAny(buttons, controlLoop, update)
