-- reactor/pilot.lua
-- Simple Reactor Pilot with big buttons:
--  AUTO   -> auto-optimize (A/B tests under the hood)
--  MAX    -> push max net power safely
--  STABLE -> hold field ~50%, moderate temp
--  ECO    -> cooler & gentler, fuel-friendly
--  CHARGE -> charge reactor (input flood, zero output)
--  COOL   -> emergency cooldown (max output)
--
-- Uses saved gates from config.txt (created by your main controller).
-- Requires advanced monitor (for touch).

-- ===== Load lib/f (robust) =====
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

-- ===== Basic constants (safe) =====
local reactorSide        = "back"
local lowestFieldPercent = 15
local maxTemperature     = 8000
local safeTemperature    = 3000

-- ===== Mode enum =====
local MODE_AUTO   = "AUTO"
local MODE_MAX    = "MAX"
local MODE_STABLE = "STABLE"
local MODE_ECO    = "ECO"
local MODE_CHARGE = "CHARGE"
local MODE_COOL   = "COOL"

-- Saved / runtime
local currentMode = MODE_AUTO     -- default
local fieldTargetRuntime = 50     -- % used by controller
local lastInputFlow = 0
local currentOutFlow = 0
local action = "Pilot running"

-- A/B optimizer (used in AUTO)
local abPeriod = 25     -- s
local abWindow = 4      -- s
local fieldStep = 5     -- %
local autoFieldMin = 30
local autoFieldMax = 65

-- Peripherals
local reactor, inputGate, outputGate
local savedInputGateName, savedOutputGateName
local monitor, monX, monY
local mon = {}

-- ===== Persist pilot.cfg (only currentMode) =====
local function save_pilot_cfg()
  local w = fs.open("pilot.cfg", "w")
  w.writeLine(currentMode)
  w.close()
end

local function load_pilot_cfg()
  if not fs.exists("pilot.cfg") then return end
  local r = fs.open("pilot.cfg", "r")
  local m = r.readLine() or MODE_AUTO
  r.close()
  if m == MODE_AUTO or m == MODE_MAX or m == MODE_STABLE or m == MODE_ECO or m == MODE_CHARGE or m == MODE_COOL then
    currentMode = m
  end
end

-- ===== Read gate names from main config.txt (if present) =====
local function read_main_config()
  if not fs.exists("config.txt") then return end
  local r = fs.open("config.txt","r")
  r.readLine()             -- version
  r.readLine()             -- autoInputGate
  r.readLine()             -- curInputGate
  r.readLine()             -- targetStrength (maybe)
  local nIn  = r.readLine() or ""
  local nOut = r.readLine() or ""
  r.close()
  if nIn ~= ""  then savedInputGateName  = nIn end
  if nOut ~= "" then savedOutputGateName = nOut end
end

-- ===== Detect & wrap =====
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

local function ensure_monitor()
  local m = f.periphSearch("monitor")
  if not m then error("No advanced monitor found") end
  monitor = window.create(m, 1, 1, m.getSize())
  monX, monY = monitor.getSize()
  mon = {monitor=monitor, X=monX, Y=monY}
end

-- ===== Helpers =====
local function clamp(x,a,b) if x<a then return a elseif x>b then return b else return x end end
local function round(x) return math.floor(x + 0.5) end

local function percentField(info)
  if not info or not info.maxFieldStrength or info.maxFieldStrength == 0 then return 0 end
  return (info.fieldStrength / info.maxFieldStrength) * 100
end

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

-- ===== Mode targets =====
local function mode_targets(mode)
  -- returns: fieldMin, fieldMax, tempTarget, kp, behavior
  -- behavior: "AUTO", "FIXED", "CHARGE", "COOL"
  if mode == MODE_AUTO then
    return autoFieldMin, autoFieldMax, 7400, 1200, "AUTO"
  elseif mode == MODE_MAX then
    return 35, 60, 7800, 1600, "FIXED", 48  -- fixed field ~48%
  elseif mode == MODE_STABLE then
    return 45, 55, 7000, 1200, "FIXED", 50  -- fixed 50%
  elseif mode == MODE_ECO then
    return 55, 70, 6500, 1000, "FIXED", 60  -- fixed 60%
  elseif mode == MODE_CHARGE then
    return 50, 60, 0,    0,    "CHARGE"
  elseif mode == MODE_COOL then
    return 60, 70, 0,    0,    "COOL"
  end
  return 45, 55, 7000, 1200, "FIXED", 50
end

-- ===== Buttons layout =====
local Buttons = {} -- {x,y,w,h,label,mode}
local function make_buttons()
  Buttons = {}
  local cols, rows = 3, 2
  local margin = 2
  local spacing = 2
  local bw = math.max(6, math.floor((monX - margin*2 - spacing*(cols-1)) / cols))
  local bh = 4
  local labels = {
    {MODE_AUTO,   "AUTO"},
    {MODE_MAX,    "MAX"},
    {MODE_STABLE, "STABLE"},
    {MODE_ECO,    "ECO"},
    {MODE_CHARGE, "CHARGE"},
    {MODE_COOL,   "COOL"},
  }
  for i, pair in ipairs(labels) do
    local col = ((i-1) % cols)
    local row = math.floor((i-1) / cols)
    local x = margin + col*(bw + spacing)
    local y = 4 + row*(bh + 1)
    table.insert(Buttons, {x=x, y=y, w=bw, h=bh, mode=pair[1], label=pair[2]})
  end
end

local function draw_button(b, active)
  for dy = 0, b.h-1 do
    local bg = active and colors.green or colors.gray
    if dy == 0 or dy == b.h-1 then bg = active and colors.lime or colors.lightGray end
    f.draw_line(mon, b.x, b.y+dy, b.w, bg)
  end
  local lx = b.x + math.floor((b.w - #b.label)/2)
  local ly = b.y + math.floor(b.h/2)
  f.draw_text(mon, lx, ly, b.label, colors.white, colors.black)
end

local function inside(b, x, y)
  return x >= b.x and x <= (b.x + b.w - 1) and y >= b.y and y <= (b.y + b.h - 1)
end

-- ===== Draw UI =====
local function drawUI()
  monitor.setVisible(false)
  f.clear(mon)

  f.draw_text_lr(mon, 2, 1, 1, "Reactor Pilot", currentMode, colors.white, colors.cyan, colors.black)

  -- Buttons
  for _, b in ipairs(Buttons) do
    draw_button(b, b.mode == currentMode)
  end

  local info = reactor.getReactorInfo() or {}
  local gen  = info.generationRate or 0
  local fp   = percentField(info)
  local temp = info.temperature or 0
  local net  = gen - lastInputFlow

  -- Live stats
  local y0 = Buttons[#Buttons].y + Buttons[#Buttons].h + 1
  f.draw_text_lr(mon, 2,  y0+0, 1, "Temp", f.format_int(temp).." C", colors.white, colors.lime, colors.black)
  f.draw_text_lr(mon, 2,  y0+1, 1, "Field", string.format("%.1f%%", fp), colors.white, colors.lime, colors.black)
  f.draw_text_lr(mon, 2,  y0+2, 1, "Gen", f.format_int(gen).." rf/t", colors.white, colors.lime, colors.black)
  f.draw_text_lr(mon, 2,  y0+3, 1, "In (field)", f.format_int(lastInputFlow).." rf/t", colors.white, colors.blue, colors.black)
  f.draw_text_lr(mon, 2,  y0+4, 1, "Out", f.format_int(currentOutFlow).." rf/t", colors.white, colors.blue, colors.black)
  f.draw_text_lr(mon, 2,  y0+5, 1, "Net", f.format_int(net).." rf/t", colors.white, (net>=0 and colors.green or colors.red), colors.black)
  f.draw_text_lr(mon, 2,  y0+7, 1, "Action", action, colors.gray, colors.gray, colors.black)

  monitor.setVisible(true)
end

-- ===== Controllers =====
local CONTROL_DT = 0.10
local TEMP_DT    = 0.20
local lastSet    = nil
local smoothAlpha= 0.30
local OUTFLOW_MAX= 20000000

local function inputLoop()
  while true do
    local info = reactor.getReactorInfo()
    if info then
      local fmin, fmax, tempTarget, kp, behavior, fixedTarget = mode_targets(currentMode)

      if info.status == "charging" or currentMode == MODE_CHARGE then
        inputGate.setSignalLowFlow(900000)
        lastSet = nil
        lastInputFlow = 900000
      elseif currentMode == MODE_COOL then
        -- keep field comfortably high while cooling
        fieldTargetRuntime = clamp(65, fmin, fmax)
        local base = inputNeeded(info, fieldTargetRuntime)
        inputGate.setSignalLowFlow(base)
        lastInputFlow = base
        lastSet = base
      elseif info.status == "online" then
        if behavior == "AUTO" then
          -- fieldTargetRuntime updated by optimizerLoop
          fieldTargetRuntime = clamp(fieldTargetRuntime, fmin, fmax)
        elseif behavior == "FIXED" then
          fieldTargetRuntime = clamp(fixedTarget or 50, fmin, fmax)
        end

        local base = inputNeeded(info, fieldTargetRuntime)
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
    if info then
      local fmin, fmax, tempTarget, kp, behavior = mode_targets(currentMode)

      if currentMode == MODE_CHARGE then
        outputGate.setSignalLowFlow(0); currentOutFlow = 0
      elseif currentMode == MODE_COOL then
        outputGate.setSignalLowFlow(OUTFLOW_MAX); currentOutFlow = OUTFLOW_MAX
      elseif info.status ~= "offline" then
        local err = (info.temperature or 0) - tempTarget
        local newOut = clamp(currentOutFlow + err*(kp or 1200), 0, OUTFLOW_MAX)
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
    end
    sleep(TEMP_DT)
  end
end

local function optimizerLoop()
  local lastProbe = os.clock()
  fieldTargetRuntime = 50
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
      sleep(0.2)
    end

    -- extra safety
    local info = reactor.getReactorInfo()
    if info then
      local fp = percentField(info)
      if fp < (lowestFieldPercent + 5) then
        fieldTargetRuntime = math.max(fieldTargetRuntime, lowestFieldPercent + 12)
      end
      if info.status == "charged" and currentMode == MODE_CHARGE then
        action = "Charged"
      end
      if info.status == "online" and (info.temperature or 0) > maxTemperature then
        reactor.stopReactor(); action = "Overtemp -> STOP"
      end
      if (info.fuelConversion and info.maxFuelConversion and info.maxFuelConversion > 0) then
        local fuelPercent = 100 - (info.fuelConversion / info.maxFuelConversion * 100)
        if fuelPercent <= 10 then reactor.stopReactor(); action = "Low fuel -> STOP" end
      end
    end
  end
end

-- ===== Input (touch) =====
local function buttons()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")
    for _, b in ipairs(Buttons) do
      if inside(b, x, y) then
        currentMode = b.mode
        save_pilot_cfg()
        action = "Mode -> "..currentMode
        drawUI()
        break
      end
    end
  end
end

-- ===== Main =====
local function main()
  load_pilot_cfg()
  read_main_config()
  ensure_peripherals()
  ensure_monitor()
  make_buttons()
  drawUI()

  parallel.waitForAny(inputLoop, outputLoop, optimizerLoop, buttons,
    function() while true do drawUI() sleep(0.15) end end)
end

local ok, err = pcall(main)
if not ok then printError("pilot: "..tostring(err)) end
