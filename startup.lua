-- ============================================
-- Draconic Reactor Controller + Mode Buttons
-- Keeps field at target (%) with:
--   input_flow = fieldDrainRate / (1 - target/100)
-- Adds big simple MODE buttons on the main screen:
--   AUTO (optimize), MAX, STABLE, ECO, CHARGE, COOL
-- Output gate is auto-regulated to a temp setpoint per mode.
-- ============================================

-- === Modifiable ===
local reactorSide        = "back"
local targetStrength     = 50    -- default % for STABLE / manual
local maxTemperature     = 8000
local safeTemperature    = 3000
local lowestFieldPercent = 15
local activateOnCharged  = 1

-- === Load lib/f (robust) ===
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

-- === State / config ===
local version       = "0.80-modes"
local autoInputGate = 1           -- 1=AUTO field control, 0=MANUAL
local curInputGate  = 222000      -- manual input gate setpoint (rf/t)

-- Peripherals / UI
local reactor
local inputGate      -- feeds field (TO reactor)
local outputGate     -- extracts energy (FROM reactor)
local monitor_peripheral, monitor
local monX, monY
local mon = {}

-- Reactor info + state
local ri
local action          = "None since reboot"
local emergencyCharge = false
local emergencyTemp   = false

-- Saved gate names
local savedInputGateName, savedOutputGateName = nil, nil

-- ====== Modes ======
local MODE_AUTO   = "AUTO"
local MODE_MAX    = "MAX"
local MODE_STABLE = "STABLE"
local MODE_ECO    = "ECO"
local MODE_CHARGE = "CHARGE"
local MODE_COOL   = "COOL"

local currentMode = MODE_STABLE

-- Runtime control params (computed from mode)
local fieldTargetRuntime = targetStrength
local autoFieldMin, autoFieldMax = 30, 65   -- for AUTO
local fieldStep       = 5
local abPeriod        = 25
local abWindow        = 4

-- Output control tuning per-mode
local tempTarget      = 7000
local tempKp          = 1200
local outputFlowMax   = 20000000

-- Smooth input flow
local lastInputSet    = nil
local smoothAlpha     = 0.30

-- Layout base Y (push original UI down to fit mode buttons)
local BASE_Y = 5

-- ====== Config I/O ======
local function save_config()
  local sw = fs.open("config.txt", "w")
  sw.writeLine(tostring(version))
  sw.writeLine(tostring(autoInputGate))
  sw.writeLine(tostring(curInputGate))
  sw.writeLine(tostring(targetStrength))
  sw.writeLine(tostring(savedInputGateName or ""))
  sw.writeLine(tostring(savedOutputGateName or ""))
  sw.writeLine(tostring(currentMode)) -- NEW line for mode
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
  local ouN = sr.readLine() or ""; if ouN ~= "" then savedOutputGateName = ouN end
  local m   = sr.readLine() or ""
  if m == MODE_AUTO or m == MODE_MAX or m == MODE_STABLE or m == MODE_ECO or m == MODE_CHARGE or m == MODE_COOL then
    currentMode = m
  end
  sr.close()
end

-- ====== Flow gate picker ======
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
  -- Try saved first
  if savedInputGateName then inputGate  = peripheral.wrap(savedInputGateName) end
  if savedOutputGateName then outputGate = peripheral.wrap(savedOutputGateName) end
  if inputGate and outputGate then return end

  local gates = detectFlowGates()
  if #gates < 2 then error("Need at least 2 flow gates (get/setSignalLowFlow).") end

  print("")
  print("Select gate that FEEDS the reactor field (INPUT to reactor).")
  local inName = menuPick("INPUT Flow Gate", gates, savedInputGateName)

  local remaining = {}
  for _, n in ipairs(gates) do if n ~= inName then table.insert(remaining, n) end end

  print("")
  print("Select gate that EXTRACTS energy FROM the reactor (OUTPUT).")
  local outName = menuPick("OUTPUT Flow Gate", remaining, savedOutputGateName)

  savedInputGateName  = inName
  savedOutputGateName = outName
  save_config()

  inputGate  = peripheral.wrap(savedInputGateName)
  outputGate = peripheral.wrap(savedOutputGateName)

  if not inputGate  then error("Failed to wrap INPUT gate: "..tostring(savedInputGateName)) end
  if not outputGate then error("Failed to wrap OUTPUT gate: "..tostring(savedOutputGateName)) end

  print("INPUT  gate -> "..savedInputGateName)
  print("OUTPUT gate -> "..savedOutputGateName)
end

-- ====== Peripherals ======
monitor_peripheral = f.periphSearch("monitor")
if not monitor_peripheral then error("No valid monitor was found") end
monitor = window.create(monitor_peripheral, 1, 1, monitor_peripheral.getSize())
local okR; okR, reactor = pcall(peripheral.wrap, reactorSide)
if not okR or not reactor then error("No valid reactor on side '"..tostring(reactorSide).."'") end

monX, monY = monitor.getSize()
mon = { monitor = monitor, X = monX, Y = monY }

load_config()
ensureGates()

-- ====== Mode -> params ======
local function applyModeParams()
  if currentMode == MODE_AUTO then
    autoFieldMin, autoFieldMax = 30, 65
    tempTarget = 7400; tempKp = 1200
  elseif currentMode == MODE_MAX then
    tempTarget = 7800; tempKp = 1600
    fieldTargetRuntime = 48
  elseif currentMode == MODE_STABLE then
    tempTarget = 7000; tempKp = 1200
    fieldTargetRuntime = 50
  elseif currentMode == MODE_ECO then
    tempTarget = 6500; tempKp = 1000
    fieldTargetRuntime = 60
  elseif currentMode == MODE_CHARGE then
    tempTarget = 0;    tempKp = 0
  elseif currentMode == MODE_COOL then
    tempTarget = 0;    tempKp = 0
  end
end
applyModeParams()

-- ====== Drawing helpers ======
local function drawArrows(y)
  f.draw_text(mon,  2, y, " < ",  colors.white, colors.gray)
  f.draw_text(mon,  6, y, " <<",  colors.white, colors.gray)
  f.draw_text(mon, 10, y, "<<<",  colors.white, colors.gray)
  f.draw_text(mon, 17, y, ">>>",  colors.white, colors.gray)
  f.draw_text(mon, 21, y, ">> ",  colors.white, colors.gray)
  f.draw_text(mon, 25, y, " > ",  colors.white, colors.gray)
end

-- Mode buttons (two rows of 3 centered)
local ModeButtons = {} -- {x,y,w,h,label}
local function layoutModeButtons()
  ModeButtons = {}
  local labels = {MODE_AUTO, MODE_MAX, MODE_STABLE, MODE_ECO, MODE_CHARGE, MODE_COOL}
  local cols, rows = 3, 2
  local marginX = 2
  local spacing = 2
  local bw = math.max(8, math.floor((monX - marginX*2 - spacing*(cols-1)) / cols))
  local bh = 3
  for i, label in ipairs(labels) do
    local col = ((i-1) % cols)
    local row = math.floor((i-1) / cols)
    local x = marginX + col*(bw + spacing)
    local y = 1 + row*(bh + 1)  -- occupy lines 1..4
    table.insert(ModeButtons, {x=x, y=y, w=bw, h=bh, label=label})
  end
end
layoutModeButtons()

local function rect(x,y,w,h,color)
  for dy=0,h-1 do f.draw_line(mon, x, y+dy, w, color) end
end

local function drawModeButton(b, active)
  rect(b.x, b.y, b.w, b.h, active and colors.green or colors.gray)
  local lx = b.x + math.floor((b.w - #b.label)/2)
  local ly = b.y + math.floor(b.h/2)
  f.draw_text(mon, lx, ly, b.label, colors.white, colors.black)
end

local function pointIn(b, x, y)
  return x >= b.x and x <= (b.x+b.w-1) and y >= b.y and y <= (b.y+b.h-1)
end

-- ====== Buttons handler ======
local function buttons()
  while true do
    local _, _, xPos, yPos = os.pullEvent("monitor_touch")

    -- First: check mode buttons
    for _, b in ipairs(ModeButtons) do
      if pointIn(b, xPos, yPos) then
        currentMode = b.label
        applyModeParams()
        action = "Mode -> "..currentMode
        save_config()
        goto NEXT_TOUCH_DONE
      end
    end

    -- OUTPUT gate controls (arrows row)
    if yPos == (BASE_Y + 6) then
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

    -- INPUT gate controls (manual only)
    if yPos == (BASE_Y + 8) and autoInputGate == 0 and xPos ~= 14 and xPos ~= 15 then
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

    -- INPUT AUTO/MANUAL toggle
    if yPos == (BASE_Y + 8) and (xPos == 14 or xPos == 15) then
      autoInputGate = 1 - autoInputGate
      if autoInputGate == 0 then inputGate.setSignalLowFlow(curInputGate) end
      save_config()
    end

    ::NEXT_TOUCH_DONE::
  end
end

-- ====== Control loops ======
local CONTROL_INTERVAL = 0.10
local OUTPUT_INTERVAL  = 0.20
local lastSetOutput    = nil
local currentOutFlow   = 0

local function clamp(x,a,b) if x<a then return a elseif x>b then return b else return x end end
local function round(x) return math.floor(x + 0.5) end

local function inputNeeded(info, fieldPct)
  local denom = 1 - (fieldPct/100)
  if denom <= 0 then denom = 0.001 end
  local drain = info.fieldDrainRate or 0
  local flux  = drain / denom
  if flux < 0 then flux = 0 end
  return round(flux)
end

local function avg_net(pct, seconds)
  local t0 = os.clock()
  local acc, n = 0, 0
  while os.clock() - t0 < seconds do
    local info = reactor.getReactorInfo()
    if info then
      local gen  = info.generationRate or 0
      local need = inputNeeded(info, pct)
      acc = acc + (gen - need)
      n = n + 1
    end
    sleep(0.2)
  end
  if n == 0 then return -math.huge end
  return acc / n
end

local function fieldPercent(info)
  if not info or not info.maxFieldStrength or info.maxFieldStrength == 0 then return 0 end
  return (info.fieldStrength / info.maxFieldStrength) * 100
end

-- Input (field) controller
local function inputLoop()
  local t = os.startTimer(CONTROL_INTERVAL)
  while true do
    local ev, id = os.pullEvent()
    if ev == "timer" and id == t then
      local info = reactor.getReactorInfo()
      if info then
        if info.status == "charging" or currentMode == MODE_CHARGE then
          inputGate.setSignalLowFlow(900000)
          lastInputSet = nil
        elseif currentMode == MODE_COOL then
          -- keep field comfortably high while cooling
          local base = inputNeeded(info, 65)
          inputGate.setSignalLowFlow(base)
          lastInputSet = base
        elseif info.status == "online" then
          local target = fieldTargetRuntime
          if autoInputGate == 0 then
            target = targetStrength -- manual mode sticks to targetStrength
          end
          local base = inputNeeded(info, target)
          if lastInputSet then base = lastInputSet*(1 - smoothAlpha) + base*smoothAlpha end
          base = round(base)
          inputGate.setSignalLowFlow(base)
          lastInputSet = base
        end
      end
      t = os.startTimer(CONTROL_INTERVAL)
    end
  end
end

-- Output (temperature) controller
local function outputLoop()
  local tt = os.startTimer(OUTPUT_INTERVAL)
  while true do
    local ev, id = os.pullEvent()
    if ev == "timer" and id == tt then
      local info = reactor.getReactorInfo()
      if info then
        if currentMode == MODE_CHARGE then
          outputGate.setSignalLowFlow(0)
          currentOutFlow = 0
        elseif currentMode == MODE_COOL then
          outputGate.setSignalLowFlow(outputFlowMax)
          currentOutFlow = outputFlowMax
        elseif info.status ~= "offline" then
          local err = (info.temperature or 0) - tempTarget
          local newOut = clamp((currentOutFlow or 0) + err*tempKp, 0, outputFlowMax)
          newOut = round(newOut)
          if newOut ~= currentOutFlow then
            outputGate.setSignalLowFlow(newOut)
            currentOutFlow = newOut
          end
          if info.temperature and info.temperature > maxTemperature then
            outputGate.setSignalLowFlow(outputFlowMax)
            currentOutFlow = outputFlowMax
          end
        end
      end
      tt = os.startTimer(OUTPUT_INTERVAL)
    end
  end
end

-- AUTO optimizer (A/B around current target)
local function optimizerLoop()
  local lastProbe = os.clock()
  fieldTargetRuntime = targetStrength
  while true do
    if currentMode == MODE_AUTO then
      local now = os.clock()
      if now - lastProbe >= abPeriod then
        local a = clamp(fieldTargetRuntime - fieldStep, autoFieldMin, autoFieldMax)
        local b = clamp(fieldTargetRuntime + fieldStep, autoFieldMin, autoFieldMax)

        fieldTargetRuntime = a; sleep(0.5)
        local scoreA = avg_net(a, abWindow)

        fieldTargetRuntime = b; sleep(0.5)
        local scoreB = avg_net(b, abWindow)

        if scoreA >= scoreB then fieldTargetRuntime = a else fieldTargetRuntime = b end
        lastProbe = now
      else
        fieldTargetRuntime = clamp(fieldTargetRuntime, autoFieldMin, autoFieldMax)
      end
    else
      -- fixed targets per mode
      if currentMode == MODE_MAX then       fieldTargetRuntime = 48
      elseif currentMode == MODE_STABLE then fieldTargetRuntime = 50
      elseif currentMode == MODE_ECO then    fieldTargetRuntime = 60
      end
      sleep(0.2)
    end

    -- extra safety
    local info = reactor.getReactorInfo()
    if info then
      local fp = fieldPercent(info)
      if fp < (lowestFieldPercent + 5) then
        fieldTargetRuntime = math.max(fieldTargetRuntime, lowestFieldPercent + 12)
      end
      if info.status == "charged" and activateOnCharged == 1 and currentMode ~= MODE_COOL then
        reactor.activateReactor()
      end
      if info.status == "online" and (info.temperature or 0) > maxTemperature then
        reactor.stopReactor()
        action = "Overtemp -> STOP"
      end
      if (info.fuelConversion and info.maxFuelConversion and info.maxFuelConversion > 0) then
        local fuelPercent = 100 - (info.fuelConversion / info.maxFuelConversion * 100)
        if fuelPercent <= 10 then reactor.stopReactor(); action = "Low fuel -> STOP" end
      end
    end
  end
end

-- ====== Main UI update (flicker-free) ======
local function update()
  while true do
    monitor.setVisible(false)
    f.clear(mon)

    -- draw mode buttons
    for _, b in ipairs(ModeButtons) do
      drawModeButton(b, b.label == currentMode)
    end

    ri = reactor.getReactorInfo()
    if ri == nil then error("reactor has an invalid setup") end

    -- Status color
    local statusColor = colors.red
    if     ri.status == "online"  or ri.status == "charged" then statusColor = colors.green
    elseif ri.status == "offline"                           then statusColor = colors.gray
    elseif ri.status == "charging"                          then statusColor = colors.orange
    end

    -- Rows shifted by BASE_Y
    f.draw_text_lr(mon, 2, BASE_Y + 0, 1, "Reactor Status", string.upper(ri.status), colors.white, statusColor, colors.black)
    f.draw_text_lr(mon, 2, BASE_Y + 2, 1, "Generation", f.format_int(ri.generationRate or 0) .. " rf/t", colors.white, colors.lime, colors.black)

    local tempColor = colors.red
    if ri.temperature <= 5000 then tempColor = colors.green
    elseif ri.temperature <= 6500 then tempColor = colors.orange end
    f.draw_text_lr(mon, 2, BASE_Y + 4, 1, "Temperature", f.format_int(ri.temperature or 0) .. "C", colors.white, tempColor, colors.black)

    -- Output row
    f.draw_text_lr(mon, 2, BASE_Y + 5, 1, "Output Gate", f.format_int(outputGate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)
    drawArrows(BASE_Y + 6)

    -- Input row
    f.draw_text_lr(mon, 2, BASE_Y + 7, 1, "Input Gate", f.format_int(inputGate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)
    if autoInputGate == 1 then
      f.draw_text(mon, 14, BASE_Y + 8, "AU", colors.white, colors.gray)
    else
      f.draw_text(mon, 14, BASE_Y + 8, "MA", colors.white, colors.gray)
      drawArrows(BASE_Y + 8)
    end

    -- Energy saturation
    local satPercent = math.ceil((ri.energySaturation or 0) / (ri.maxEnergySaturation or 1) * 10000) * 0.01
    f.draw_text_lr(mon, 2, BASE_Y + 9, 1, "Energy Saturation", string.format("%.2f%%", satPercent), colors.white, colors.white, colors.black)
    f.progress_bar(mon, 2, BASE_Y +10, mon.X-2, satPercent, 100, colors.blue, colors.gray)

    -- Field %
    local fieldPct = math.ceil((ri.fieldStrength or 0) / (ri.maxFieldStrength or 1) * 10000) * 0.01
    local fieldColor = colors.red
    if fieldPct >= 50 then fieldColor = colors.green
    elseif fieldPct > 30 then fieldColor = colors.orange end

    local fieldTitle = (autoInputGate==1) and ("Field Strength ("..currentMode..")") or "Field Strength"
    f.draw_text_lr(mon, 2, BASE_Y +12, 1, fieldTitle, string.format("%.2f%%", fieldPct), colors.white, fieldColor, colors.black)
    f.progress_bar(mon, 2, BASE_Y +13, mon.X-2, fieldPct, 100, fieldColor, colors.gray)

    -- Fuel
    local fuelPercent = 100 - math.ceil((ri.fuelConversion or 0) / (ri.maxFuelConversion or 1) * 10000) * 0.01
    local fuelColor = colors.red
    if fuelPercent >= 70 then fuelColor = colors.green
    elseif fuelPercent > 30 then fuelColor = colors.orange end

    f.draw_text_lr(mon, 2, BASE_Y +15, 1, "Fuel", string.format("%.2f%%", fuelPercent), colors.white, fuelColor, colors.black)
    f.progress_bar(mon, 2, BASE_Y +16, mon.X-2, fuelPercent, 100, fuelColor, colors.gray)

    f.draw_text_lr(mon, 2, BASE_Y +18, 1, "Action", action, colors.gray, colors.gray, colors.black)

    -- Safeguards (same as before)
    if emergencyCharge == true then reactor.chargeReactor() end

    if ri.status == "charging" then
      inputGate.setSignalLowFlow(900000)
      emergencyCharge = false
    end

    if emergencyTemp == true and ri.status == "stopping" and ri.temperature < safeTemperature then
      reactor.activateReactor()
      emergencyTemp = false
    end

    if ri.status == "charged" and activateOnCharged == 1 and currentMode ~= MODE_COOL then
      reactor.activateReactor()
    end

    if fuelPercent <= 10 then
      reactor.stopReactor()
      action = "Fuel below 10%, refuel"
    end

    if fieldPct <= lowestFieldPercent and ri.status == "online" then
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

parallel.waitForAny(buttons, inputLoop, outputLoop, optimizerLoop, update)
