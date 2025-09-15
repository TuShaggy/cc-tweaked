-- reactor/optimizer.lua
-- Optimizer with on-screen controls (advanced monitor required).
-- Adjustables via buttons:
--  - Optimize mode ON/OFF (A/B tests)
--  - Target temperature (°C)
--  - Field target (%) when Optimize=OFF
--  - Field MIN/MAX (%) limits when Optimize=ON
--  - Field STEP (%) for A/B probes
--  - AB PERIOD (s) and AB WINDOW (s)
-- Uses saved gates from main controller (config.txt) if present.

-- ====== Load lib/f ======
local function loadF()
  if fs.exists("lib/f") then
    assert(os.loadAPI("lib/f"))
  elseif fs.exists("lib/f.lua") then
    assert(os.loadAPI("lib/f.lua"))
  else
    error("Missing lib/f (or lib/f.lua). Run installer first.")
  end
end
loadF()

-- ====== Defaults ======
local reactorSide        = "back"
local lowestFieldPercent = 15
local maxTemperature     = 8000
local safeTemperature    = 3000

-- UI/optimizer params (persisted)
local optimizeEnabled = 1   -- 1=ON A/B, 0=OFF (fixed targetField)
local targetTemp      = 7500
local targetField     = 50  -- used when optimizeEnabled == 0
local fieldMin        = 30
local fieldMax        = 60
local fieldStep       = 5
local abPeriod        = 30
local abWindow        = 5

-- runtime
local reactor, inputGate, outputGate
local savedInputGateName, savedOutputGateName
local mon, monitor, monX, monY
local action = "Optimizer running"
local fieldTargetRuntime = targetField
local lastInputFlow = 0
local currentOutFlow = 0

-- ====== Persist optimizer.cfg ======
local function save_cfg()
  local w = fs.open("optimizer.cfg","w")
  w.writeLine(optimizeEnabled)
  w.writeLine(targetTemp)
  w.writeLine(targetField)
  w.writeLine(fieldMin)
  w.writeLine(fieldMax)
  w.writeLine(fieldStep)
  w.writeLine(abPeriod)
  w.writeLine(abWindow)
  w.close()
end

local function load_cfg()
  if not fs.exists("optimizer.cfg") then return end
  local r = fs.open("optimizer.cfg","r")
  optimizeEnabled = tonumber(r.readLine() or "") or optimizeEnabled
  targetTemp      = tonumber(r.readLine() or "") or targetTemp
  targetField     = tonumber(r.readLine() or "") or targetField
  fieldMin        = tonumber(r.readLine() or "") or fieldMin
  fieldMax        = tonumber(r.readLine() or "") or fieldMax
  fieldStep       = tonumber(r.readLine() or "") or fieldStep
  abPeriod        = tonumber(r.readLine() or "") or abPeriod
  abWindow        = tonumber(r.readLine() or "") or abWindow
  r.close()
end

-- ====== Read gate names from main config (if present) ======
local function read_main_config()
  if not fs.exists("config.txt") then return end
  local r = fs.open("config.txt","r")
  r.readLine()             -- version
  r.readLine()             -- autoInputGate
  r.readLine()             -- curInputGate
  local maybeTS = r.readLine() or "" -- targetStrength (may exist)
  local nIn  = r.readLine() or ""
  local nOut = r.readLine() or ""
  if nIn ~= "" then savedInputGateName  = nIn end
  if nOut~= "" then savedOutputGateName = nOut end
  r.close()
end

-- ====== Peripherals ======
local function detectFlowGates()
  local names = peripheral.getNames()
  local list = {}
  for _, n in ipairs(names) do
    local okGet = pcall(peripheral.call, n, "getSignalLowFlow")
    local okSet = pcall(peripheral.call, n, "setSignalLowFlow", 0)
    if okGet and okSet then table.insert(list, n) end
  end
  table.sort(list)
  return list
end

local function ensure_peripherals()
  reactor = peripheral.wrap(reactorSide)
  if not reactor then error("No reactor on side '"..reactorSide.."'") end

  if savedInputGateName then inputGate  = peripheral.wrap(savedInputGateName) end
  if savedOutputGateName then outputGate = peripheral.wrap(savedOutputGateName) end

  if not inputGate or not outputGate then
    local gates = detectFlowGates()
    if #gates < 2 then error("Need at least 2 flow gates") end
    if not inputGate  then savedInputGateName  = gates[1]; inputGate  = peripheral.wrap(gates[1]) end
    local pick = (gates[2] == savedInputGateName) and gates[3] or gates[2]
    if not outputGate then savedOutputGateName = pick; outputGate = peripheral.wrap(pick) end
  end
end

-- ====== Monitor ======
local function ensure_monitor()
  local m = f.periphSearch("monitor")
  if not m then error("No advanced monitor found") end
  monitor = window.create(m, 1, 1, m.getSize())
  monX, monY = monitor.getSize()
  mon = {monitor=monitor, X=monX, Y=monY}
end

-- ====== Helpers ======
local function clamp(x,a,b) if x<a then return a elseif x>b then return b else return x end end
local function round(x) return math.floor(x + 0.5) end

local function fieldNeeded(info, pct)
  local denom = 1 - (pct/100)
  if denom <= 0 then denom = 0.001 end
  local drain = info.fieldDrainRate or 0
  local flux  = drain / denom
  if flux < 0 then flux = 0 end
  return round(flux)
end

local function percentField(info)
  if not info or not info.maxFieldStrength or info.maxFieldStrength == 0 then return 0 end
  return (info.fieldStrength / info.maxFieldStrength) * 100
end

local function avg_net(pct, seconds)
  local t0 = os.clock()
  local acc, n = 0, 0
  while os.clock() - t0 < seconds do
    local info = reactor.getReactorInfo()
    if info then
      local gen  = info.generationRate or 0
      local need = fieldNeeded(info, pct)
      acc = acc + (gen - need)
      n = n + 1
    end
    sleep(0.2)
  end
  if n == 0 then return -math.huge end
  return acc / n
end

-- ====== UI helpers ======
local function arrows(y)  -- same layout as tu UI anterior
  f.draw_text(mon,  2, y, " < ",  colors.white, colors.gray)
  f.draw_text(mon,  6, y, " <<",  colors.white, colors.gray)
  f.draw_text(mon, 10, y, "<<<",  colors.white, colors.gray)
  f.draw_text(mon, 17, y, ">>>",  colors.white, colors.gray)
  f.draw_text(mon, 21, y, ">> ",  colors.white, colors.gray)
  f.draw_text(mon, 25, y, " > ",  colors.white, colors.gray)
end

local function handleArrows(xPos, yRow, val, small, med, large, vmin, vmax)
  if yRow == 0 then return val end
  local delta = 0
  if     xPos >=  2 and xPos <=  4 then delta = -small
  elseif xPos >=  6 and xPos <=  9 then delta = -med
  elseif xPos >= 10 and xPos <= 12 then delta = -large
  elseif xPos >= 17 and xPos <= 19 then delta =  large
  elseif xPos >= 21 and xPos <= 23 then delta =  med
  elseif xPos >= 25 and xPos <= 27 then delta =  small
  end
  local out = clamp(val + delta, vmin, vmax)
  if out ~= val then save_cfg() end
  return out
end

-- ====== Control loops ======
local CONTROL_DT = 0.10
local TEMP_DT    = 0.20
local TEMP_KP    = 1500
local OUTFLOW_MAX= 20000000
local lastSet    = nil
local smoothAlpha= 0.30

local function inputLoop()
  while true do
    local info = reactor.getReactorInfo()
    if info then
      if info.status == "charging" then
        inputGate.setSignalLowFlow(900000)
        lastSet = nil
        lastInputFlow = 900000
      elseif info.status == "online" then
        local pct = (optimizeEnabled == 1) and fieldTargetRuntime or targetField
        local base = fieldNeeded(info, pct)
        if lastSet then base = lastSet*(1 - smoothAlpha) + base*smoothAlpha end
        base = round(base)
        inputGate.setSignalLowFlow(base)
        lastInputFlow = base
        lastSet = base
      end
    end
    sleep(CONTROL_DT)
  end
end

local function outputLoop()
  currentOutFlow = outputGate.getSignalLowFlow()
  while true do
    local info = reactor.getReactorInfo()
    if info and info.status ~= "offline" then
      local err = (info.temperature or 0) - targetTemp
      local newOut = clamp(currentOutFlow + err*TEMP_KP, 0, OUTFLOW_MAX)
      newOut = round(newOut)
      if newOut ~= currentOutFlow then
        outputGate.setSignalLowFlow(newOut)
        currentOutFlow = newOut
      end
      if info.temperature and info.temperature > maxTemperature then
        outputGate.setSignalLowFlow(OUTFLOW_MAX)
        currentOutFlow = OUTFLOW_MAX
      end
    end
    sleep(TEMP_DT)
  end
end

local function optimizerLoop()
  local lastProbe = os.clock()
  fieldTargetRuntime = clamp(targetField, fieldMin, fieldMax)
  while true do
    local now = os.clock()
    if optimizeEnabled == 1 and (now - lastProbe) >= abPeriod then
      local a = clamp(fieldTargetRuntime - fieldStep, fieldMin, fieldMax)
      local b = clamp(fieldTargetRuntime + fieldStep, fieldMin, fieldMax)

      fieldTargetRuntime = a; sleep(0.5)
      local scoreA = avg_net(a, abWindow)

      fieldTargetRuntime = b; sleep(0.5)
      local scoreB = avg_net(b, abWindow)

      if scoreA >= scoreB then fieldTargetRuntime = a else fieldTargetRuntime = b end
      lastProbe = now
    else
      fieldTargetRuntime = clamp(fieldTargetRuntime, fieldMin, fieldMax)
    end

    -- extra safeguards
    local info = reactor.getReactorInfo()
    if info then
      local fp = percentField(info)
      if fp < (lowestFieldPercent + 5) then
        fieldTargetRuntime = clamp(math.max(fieldTargetRuntime, lowestFieldPercent + 12), fieldMin, fieldMax)
      end
      if info.status == "charged" then reactor.activateReactor() end
      if info.status == "online" and (info.temperature or 0) > maxTemperature then
        reactor.stopReactor()
      end
      if (info.fuelConversion and info.maxFuelConversion and info.maxFuelConversion > 0) then
        local fuelPercent = 100 - (info.fuelConversion / info.maxFuelConversion * 100)
        if fuelPercent <= 10 then reactor.stopReactor() end
      end
    end

    sleep(0.5)
  end
end

-- ====== UI: draw & buttons ======
local function drawUI()
  monitor.setVisible(false)
  f.clear(mon)

  local info = reactor.getReactorInfo() or {}
  local gen  = info.generationRate or 0
  local fp   = percentField(info)
  local temp = info.temperature or 0
  local net  = gen - lastInputFlow

  -- header
  f.draw_text_lr(mon, 2, 2, 1, "Optimizer", (optimizeEnabled==1 and "ON" or "OFF"), colors.white,
    (optimizeEnabled==1 and colors.green or colors.orange), colors.black)

  f.draw_text_lr(mon, 2, 4, 1, "Mode", (optimizeEnabled==1 and "Optimize" or "Fixed"), colors.white, colors.white, colors.black)
  f.draw_text(mon, 14, 4, (optimizeEnabled==1 and "OP" or "FX"), colors.white, colors.gray)

  f.draw_text_lr(mon, 2, 6, 1, "Target Temp", f.format_int(targetTemp).." C", colors.white, colors.lime, colors.black)
  arrows(7)

  if optimizeEnabled == 1 then
    f.draw_text_lr(mon, 2, 9, 1, "Field Min", fieldMin.."%", colors.white, colors.blue, colors.black);   arrows(10)
    f.draw_text_lr(mon, 2,11, 1, "Field Max", fieldMax.."%", colors.white, colors.blue, colors.black);   arrows(12)
    f.draw_text_lr(mon, 2,13, 1, "Field Step", fieldStep.." %", colors.white, colors.cyan, colors.black);arrows(14)
    f.draw_text_lr(mon, 2,15, 1, "AB Period", abPeriod.." s", colors.white, colors.cyan, colors.black);  arrows(16)
    f.draw_text_lr(mon, 2,17, 1, "AB Window", abWindow.." s", colors.white, colors.cyan, colors.black);  arrows(18)
    f.draw_text_lr(mon, 2,19, 1, "Field Target (runtime)", string.format("%.1f%%", fieldTargetRuntime), colors.gray, colors.white, colors.black)
  else
    f.draw_text_lr(mon, 2, 9, 1, "Field Target", targetField.."%", colors.white, colors.blue, colors.black)
    arrows(10)
  end

  -- live stats
  f.draw_text_lr(mon, monX-26, 2, 1, "Temp", f.format_int(temp).."C", colors.white, colors.lime, colors.black)
  f.draw_text_lr(mon, monX-26, 4, 1, "Field", string.format("%.1f%%", fp), colors.white, colors.lime, colors.black)
  f.draw_text_lr(mon, monX-26, 6, 1, "Gen", f.format_int(gen).." rf/t", colors.white, colors.lime, colors.black)
  f.draw_text_lr(mon, monX-26, 8, 1, "In  (to field)", f.format_int(lastInputFlow).." rf/t", colors.white, colors.blue, colors.black)
  f.draw_text_lr(mon, monX-26,10, 1, "Out (to net)", f.format_int(currentOutFlow).." rf/t", colors.white, colors.blue, colors.black)
  f.draw_text_lr(mon, monX-26,12, 1, "Net", f.format_int(net).." rf/t", colors.white, (net>=0 and colors.green or colors.red), colors.black)

  monitor.setVisible(true)
end

local function buttons()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")

    -- Mode toggle
    if y == 4 and (x == 14 or x == 15) then
      optimizeEnabled = 1 - optimizeEnabled
      save_cfg()
    end

    -- Target Temp (y=7 arrows)
    if y == 7 then
      local before = targetTemp
      targetTemp = handleArrows(x, 7, targetTemp, 50, 250, 1000, 1000, 20000)
      if targetTemp ~= before then save_cfg() end
    end

    if optimizeEnabled == 1 then
      if y == 10 then local b = fieldMin; fieldMin = handleArrows(x,10, fieldMin,1,5,10, lowestFieldPercent+5, fieldMax-1); if fieldMin~=b then save_cfg() end end
      if y == 12 then local b = fieldMax; fieldMax = handleArrows(x,12, fieldMax,1,5,10, fieldMin+1, 90); if fieldMax~=b then save_cfg() end end
      if y == 14 then local b = fieldStep; fieldStep = handleArrows(x,14, fieldStep,1,2,5, 1, 15); if fieldStep~=b then save_cfg() end end
      if y == 16 then local b = abPeriod; abPeriod = handleArrows(x,16, abPeriod,5,15,30, 5, 300); if abPeriod~=b then save_cfg() end end
      if y == 18 then local b = abWindow; abWindow = handleArrows(x,18, abWindow,1,2,5, 1, 60); if abWindow~=b then save_cfg() end end
    else
      if y == 10 then local b = targetField; targetField = handleArrows(x,10, targetField,1,5,10, lowestFieldPercent+10, 80); if targetField~=b then save_cfg() end end
    end

    drawUI()
  end
end

-- ====== Boot ======
local function main()
  load_cfg()
  read_main_config()
  ensure_peripherals()
  ensure_monitor()

  -- initial draw
  drawUI()

  -- loops
  parallel.waitForAny(inputLoop, outputLoop, optimizerLoop, buttons,
    function() while true do drawUI() sleep(0.15) end end)
end

local ok, err = pcall(main)
if not ok then printError("optimizer: "..tostring(err)) end
