-- ============================================
-- Draconic Reactor Controller (stable) + Bottom Mode Buttons
-- - Buttons anchored at the BOTTOM (no overlap)
-- - Buttons now WORK reliably: control loops listen ONLY to "timer" events
-- - Field input flow = fieldDrainRate / (1 - target/100) (with smoothing)
-- - Output gate auto-regulates temperature per mode
-- - Continual recalculation (UI ~20 FPS, control loops 0.1s/0.2s)
-- ============================================

-- ===== User settings =====
local reactorSide        = "back"
local targetStrength     = 50    -- used in STABLE (and when manual input control)
local maxTemperature     = 8000
local safeTemperature    = 3000
local lowestFieldPercent = 15
local activateOnCharged  = 1

-- ===== Load lib/f (robust) =====
local function loadF()
  if fs.exists("lib/f") then
    local ok, err = pcall(os.loadAPI, "lib/f"); if not ok then error(err) end
  elseif fs.exists("lib/f.lua") then
    local ok, err = pcall(os.loadAPI, "lib/f.lua"); if not ok then error(err) end
  else
    error("Missing lib/f (or lib/f.lua). Run installer first.")
  end
end
loadF()

-- ===== State / config =====
local version       = "1.00-bottom-fix"
local autoInputGate = 1           -- 1=AUTO field control, 0=MANUAL
local curInputGate  = 222000      -- manual input gate (rf/t)

-- Peripherals / UI
local reactor, inputGate, outputGate
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

-- ===== Modes =====
local MODE_AUTO   = "AUTO"
local MODE_MAX    = "MAX"
local MODE_STABLE = "STABLE"
local MODE_ECO    = "ECO"
local MODE_CHARGE = "CHARGE"
local MODE_COOL   = "COOL"

local currentMode = MODE_STABLE

-- Runtime control params
local fieldTargetRuntime = targetStrength
local autoFieldMin, autoFieldMax = 30, 65   -- for AUTO A/B
local fieldStep       = 5
local abPeriod        = 25
local abWindow        = 4

-- Output control tuning per-mode
local tempTarget      = 7000
local tempKp          = 1200
local outputFlowMax   = 20000000

-- Smooth input flow
local lastInputSet    = nil
local lastInputFlow   = 0
local currentOutFlow  = 0
local smoothAlpha     = 0.30

-- ===== Layout & hitboxes =====
local layout = {
  contentTopY   = 1,
  outArrowsY    = 0,
  inArrowsY     = 0,
  btnsTopY      = 0,
  bottomMargin  = 1,  -- keep a free line at bottom
  btnRows       = 2,
  btnHeight     = 3,
  btnSpacingY   = 1,
}
local ModeButtons = {}     -- {x,y,w,h,label}
local outArrowsHits = {}   -- { {x1,x2,y,delta}, ... }
local inArrowsHits  = {}   -- same
local toggleHit     = nil  -- {x1,x2,y}

-- ===== Config I/O =====
local function save_config()
  local sw = fs.open("config.txt", "w")
  sw.writeLine(version)
  sw.writeLine(autoInputGate)
  sw.writeLine(curInputGate)
  sw.writeLine(targetStrength)
  sw.writeLine(savedInputGateName or "")
  sw.writeLine(savedOutputGateName or "")
  sw.writeLine(currentMode)
  sw.close()
end

local function load_config()
  if not fs.exists("config.txt") then return end
  local sr = fs.open("config.txt", "r"); if not sr then return end
  local v   = sr.readLine(); if v and v~="" then version = v end
  local a   = tonumber(sr.readLine() or ""); if a~=nil then autoInputGate = a end
  local c   = tonumber(sr.readLine() or ""); if c~=nil then curInputGate  = c end
  local ts  = tonumber(sr.readLine() or ""); if ts~=nil then targetStrength = ts end
  local inN = sr.readLine() or ""; if inN~="" then savedInputGateName  = inN end
  local ouN = sr.readLine() or ""; if ouN~="" then savedOutputGateName = ouN end
  local m   = sr.readLine() or ""
  if m==MODE_AUTO or m==MODE_MAX or m==MODE_STABLE or m==MODE_ECO or m==MODE_CHARGE or m==MODE_COOL then
    currentMode = m
  end
  sr.close()
end

-- ===== Flow gate picker =====
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
  term.clear(); term.setCursorPos(1,1)
  print("==== "..title.." ====")
  for i,opt in ipairs(options) do
    local mark = (preselect and opt==preselect) and "  *" or ""
    print(("[%d] %s%s"):format(i,opt,mark))
  end
  while true do
    write("> #: "); local s = read(); local idx = tonumber(s)
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
end

-- ===== Peripherals =====
monitor_peripheral = f.periphSearch("monitor")
if not monitor_peripheral then error("No valid monitor was found") end
monitor = window.create(monitor_peripheral, 1, 1, monitor_peripheral.getSize())
local okR; okR, reactor = pcall(peripheral.wrap, reactorSide)
if not okR or not reactor then error("No valid reactor on side '"..tostring(reactorSide).."'") end

monX, monY = monitor.getSize()
mon = { monitor = monitor, X = monX, Y = monY }

load_config()
ensureGates()

-- ===== Mode -> params =====
local function applyModeParams()
  if currentMode == MODE_AUTO then
    autoFieldMin, autoFieldMax = 30, 65
    tempTarget = 7400; tempKp = 1200
  elseif currentMode == MODE_MAX then
    tempTarget = 7800; tempKp = 1600; fieldTargetRuntime = 48
  elseif currentMode == MODE_STABLE then
    tempTarget = 7000; tempKp = 1200; fieldTargetRuntime = 50
  elseif currentMode == MODE_ECO then
    tempTarget = 6500; tempKp = 1000; fieldTargetRuntime = 60
  elseif currentMode == MODE_CHARGE then
    tempTarget = 0;    tempKp = 0
  elseif currentMode == MODE_COOL then
    tempTarget = 0;    tempKp = 0
  end
end
applyModeParams()

-- ===== Helpers =====
local function clamp(x,a,b) if x<a then return a elseif x>b then return x end return x end
local function round(x) return math.floor(x + 0.5) end

local function inputNeeded(info, fieldPct)
  local denom = 1 - (fieldPct/100); if denom <= 0 then denom = 0.001 end
  local drain = info.fieldDrainRate or 0
  local flux  = drain / denom
  if flux < 0 then flux = 0 end
  return round(flux)
end

local function fieldPercent(info)
  if not info or not info.maxFieldStrength or info.maxFieldStrength == 0 then return 0 end
  return (info.fieldStrength / info.maxFieldStrength) * 100
end

local function avg_net(pct, seconds)
  local t0 = os.clock(); local acc, n = 0, 0
  while os.clock() - t0 < seconds do
    local info = reactor.getReactorInfo()
    if info then
      local gen  = info.generationRate or 0
      local need = inputNeeded(info, pct)
      acc = acc + (gen - need); n = n + 1
    end
    sleep(0.2)
  end
  if n == 0 then return -math.huge end
  return acc / n
end

-- ===== Layout builders (BOTTOM buttons) =====
local function buildModeButtons()
  ModeButtons = {}

  -- bottom block height: 2 rows buttons + spacing + bottom margin
  local bottomBlockH = layout.btnRows*layout.btnHeight + (layout.btnRows-1)*layout.btnSpacingY + layout.bottomMargin
  layout.btnsTopY = math.max(1, monY - bottomBlockH + 1)

  -- content area above buttons + 1 spacer line
  local spacer = 1
  layout.contentTopY = 1

  -- arrow/toggle rows (fixed distances above buttons so they never overlap)
  layout.outArrowsY = layout.btnsTopY - (spacer + 11)
  layout.inArrowsY  = layout.outArrowsY + 2
  if layout.outArrowsY < 6 then
    layout.outArrowsY = 6
    layout.inArrowsY  = 8
  end

  -- 6 buttons in 2x3 grid centered horizontally
  local labels = {MODE_AUTO, MODE_MAX, MODE_STABLE, MODE_ECO, MODE_CHARGE, MODE_COOL}
  local cols, rows = 3, 2
  local spacingX = 3
  local totalWidth = monX - 4
  local bw = math.max(9, math.floor((totalWidth - spacingX*(cols-1)) / cols))
  local startX = math.floor((monX - (bw*cols + spacingX*(cols-1))) / 2) + 1
  if startX < 2 then startX = 2 end

  local bh = layout.btnHeight
  for i, label in ipairs(labels) do
    local col = ((i-1) % cols)
    local row = math.floor((i-1) / cols)
    local x = startX + col*(bw + spacingX)
    local y = layout.btnsTopY + row*(bh + layout.btnSpacingY)
    table.insert(ModeButtons, {x=x, y=y, w=bw, h=bh, label=label})
  end
end

local function drawButton(b, active)
  for dy=0,b.h-1 do f.draw_line(mon, b.x, b.y+dy, b.w, active and colors.green or colors.gray) end
  local lx = b.x + math.floor((b.w - #b.label)/2)
  local ly = b.y + math.floor(b.h/2)
  f.draw_text(mon, lx, ly, b.label, colors.white, colors.black)
end

local function pointIn(b, x, y) return x>=b.x and x<=b.x+b.w-1 and y>=b.y and y<=b.y+b.h-1 end

local function layoutArrows(y, hitsTable)
  -- center the arrows and build hitboxes
  local blocks = {
    {label=" < ",  delta=-1000},
    {label=" <<",  delta=-10000},
    {label="<<<",  delta=-100000},
    {label=">>>",  delta= 100000},
    {label=">> ",  delta= 10000},
    {label=" > ",  delta= 1000},
  }
  local totalW = 0; for _,bk in ipairs(blocks) do totalW = totalW + #bk.label end; totalW = totalW + 5
  local startX = math.max(2, math.floor((monX - totalW)/2))
  local x = startX
  for i,bk in ipairs(blocks) do
    local x1, x2 = x, x + #bk.label - 1
    hitsTable[i] = {x1=x1, x2=x2, y=y, delta=bk.delta, label=bk.label}
    x = x2 + 2
  end
end

-- Build initial layout/hitboxes
buildModeButtons()
layoutArrows(0, outArrowsHits) -- will be overwritten in drawUI
layoutArrows(0, inArrowsHits)

-- ===== Buttons handler (listens ONLY to monitor_touch) =====
local function buttons()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")

    -- Mode buttons
    for _, b in ipairs(ModeButtons) do
      if pointIn(b, x, y) then
        currentMode = b.label
        applyModeParams()
        action = "Mode -> "..currentMode
        save_config()
        goto handled
      end
    end

    -- Output arrows
    for _, h in ipairs(outArrowsHits) do
      if y == h.y and x >= h.x1 and x <= h.x2 then
        local c = outputGate.getSignalLowFlow() + h.delta
        if c < 0 then c = 0 end
        outputGate.setSignalLowFlow(c)
        goto handled
      end
    end

    -- Input toggle
    if toggleHit and y == toggleHit.y and x >= toggleHit.x1 and x <= toggleHit.x2 then
      autoInputGate = 1 - autoInputGate
      if autoInputGate == 0 then inputGate.setSignalLowFlow(curInputGate) end
      save_config()
      goto handled
    end

    -- Input arrows (manual only)
    if autoInputGate == 0 then
      for _, h in ipairs(inArrowsHits) do
        if y == h.y and x >= h.x1 and x <= h.x2 then
          curInputGate = curInputGate + h.delta
          if curInputGate < 0 then curInputGate = 0 end
          inputGate.setSignalLowFlow(curInputGate)
          lastInputFlow = curInputGate
          save_config()
          goto handled
        end
      end
    end

    ::handled::
  end
end

-- ===== Control loops (listen ONLY to timer events!) =====
local CONTROL_INTERVAL = 0.10
local OUTPUT_INTERVAL  = 0.20

local function inputLoop()
  local t = os.startTimer(CONTROL_INTERVAL)
  while true do
    local _, id = os.pullEvent("timer")
    if id == t then
      local info = reactor.getReactorInfo()
      if info then
        if info.status == "charging" or currentMode == MODE_CHARGE then
          inputGate.setSignalLowFlow(900000)
          lastInputSet  = nil
          lastInputFlow = 900000
        elseif currentMode == MODE_COOL then
          local base = inputNeeded(info, 65)
          inputGate.setSignalLowFlow(base)
          lastInputSet  = base
          lastInputFlow = base
        elseif info.status == "online" then
          local target = (autoInputGate == 1) and fieldTargetRuntime or targetStrength
          local base = inputNeeded(info, target)
          if lastInputSet then base = lastInputSet*(1 - smoothAlpha) + base*smoothAlpha end
          base = round(base)
          inputGate.setSignalLowFlow(base)
          lastInputSet  = base
          lastInputFlow = base
        end
      end
      t = os.startTimer(CONTROL_INTERVAL)
    end
  end
end

local function outputLoop()
  currentOutFlow = outputGate.getSignalLowFlow()
  local tt = os.startTimer(OUTPUT_INTERVAL)
  while true do
    local _, id = os.pullEvent("timer")
    if id == tt then
      local info = reactor.getReactorInfo()
      if info then
        if currentMode == MODE_CHARGE then
          outputGate.setSignalLowFlow(0); currentOutFlow = 0
        elseif currentMode == MODE_COOL then
          outputGate.setSignalLowFlow(outputFlowMax); currentOutFlow = outputFlowMax
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

local function optimizerLoop()
  local lastProbe = os.clock()
  fieldTargetRuntime = targetStrength
  while true do
    if currentMode == MODE_AUTO then
      local now = os.clock()
      if now - lastProbe >= abPeriod then
        local a = math.max(autoFieldMin, math.min(autoFieldMax, fieldTargetRuntime - fieldStep))
        local b = math.max(autoFieldMin, math.min(autoFieldMax, fieldTargetRuntime + fieldStep))

        fieldTargetRuntime = a; sleep(0.5); local scoreA = avg_net(a, abWindow)
        fieldTargetRuntime = b; sleep(0.5); local scoreB = avg_net(b, abWindow)
        fieldTargetRuntime = (scoreA >= scoreB) and a or b
        lastProbe = now
      else
        fieldTargetRuntime = math.max(autoFieldMin, math.min(autoFieldMax, fieldTargetRuntime))
      end
    else
      if currentMode == MODE_MAX then       fieldTargetRuntime = 48
      elseif currentMode == MODE_STABLE then fieldTargetRuntime = 50
      elseif currentMode == MODE_ECO then    fieldTargetRuntime = 60
      end
      sleep(0.2)
    end

    -- safety nudges
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
        reactor.stopReactor(); action = "Overtemp -> STOP"
      end
      if (info.fuelConversion and info.maxFuelConversion and info.maxFuelConversion > 0) then
        local fuelPercent = 100 - (info.fuelConversion / info.maxFuelConversion * 100)
        if fuelPercent <= 10 then reactor.stopReactor(); action = "Low fuel -> STOP" end
      end
    end
  end
end

-- ===== UI drawing (recompute hitboxes EVERY frame) =====
local function drawUI()
  monitor.setVisible(false)
  f.clear(mon)

  -- rebuild bottom buttons (in case of resize)
  buildModeButtons()

  -- draw buttons
  for _, b in ipairs(ModeButtons) do drawButton(b, b.label == currentMode) end

  ri = reactor.getReactorInfo(); if not ri then error("reactor has an invalid setup") end

  -- status color
  local statusColor = colors.red
  if ri.status == "online" or ri.status == "charged" then statusColor = colors.green
  elseif ri.status == "offline" then statusColor = colors.gray
  elseif ri.status == "charging" then statusColor = colors.orange end

  local y = layout.outArrowsY - 5  -- place header a bit above arrows
  if y < 1 then y = 1 end

  f.draw_text_lr(mon, 2, y+0, 1, "Reactor Status", string.upper(ri.status), colors.white, statusColor, colors.black)
  f.draw_text_lr(mon, 2, y+2, 1, "Generation", f.format_int(ri.generationRate or 0).." rf/t", colors.white, colors.lime, colors.black)

  local tempColor = colors.red
  if (ri.temperature or 0) <= 5000 then tempColor = colors.green
  elseif (ri.temperature or 0) <= 6500 then tempColor = colors.orange end
  f.draw_text_lr(mon, 2, y+4, 1, "Temperature", f.format_int(ri.temperature or 0).."C", colors.white, tempColor, colors.black)

  -- Output gate row + arrows (build hitboxes for this row)
  f.draw_text_lr(mon, 2, layout.outArrowsY-1, 1, "Output Gate", f.format_int(outputGate.getSignalLowFlow()).." rf/t", colors.white, colors.blue, colors.black)
  layoutArrows(layout.outArrowsY, outArrowsHits)
  for _, h in ipairs(outArrowsHits) do f.draw_text(mon, h.x1, h.y, h.label, colors.white, colors.gray) end

  -- Input gate row + AU/MA + arrows/hitboxes
  f.draw_text_lr(mon, 2, layout.inArrowsY-1, 1, "Input Gate", f.format_int(inputGate.getSignalLowFlow()).." rf/t", colors.white, colors.blue, colors.black)
  local toggleText = (autoInputGate==1 and "[ AUTO ]" or "[ MANUAL ]")
  local tx = math.max(2, math.floor(monX/2 - #toggleText/2))
  toggleHit = {x1 = tx, x2 = tx + #toggleText - 1, y = layout.inArrowsY}
  f.draw_text(mon, tx, layout.inArrowsY, toggleText, colors.white, colors.gray)
  if autoInputGate == 0 then
    layoutArrows(layout.inArrowsY+1, inArrowsHits)
    for _, h in ipairs(inArrowsHits) do f.draw_text(mon, h.x1, h.y, h.label, colors.white, colors.gray) end
  else
    inArrowsHits = {} -- clear when not visible
  end

  -- Energy saturation
  local satPercent = 0
  if (ri.maxEnergySaturation or 0) > 0 then
    satPercent = math.ceil((ri.energySaturation or 0) / ri.maxEnergySaturation * 10000) * 0.01
  end
  f.draw_text_lr(mon, 2, layout.inArrowsY+3, 1, "Energy Saturation", string.format("%.2f%%", satPercent), colors.white, colors.white, colors.black)
  f.progress_bar(mon, 2, layout.inArrowsY+4, mon.X-2, satPercent, 100, colors.blue, colors.gray)

  -- Field %
  local fieldPct = 0
  if (ri.maxFieldStrength or 0) > 0 then
    fieldPct = math.ceil((ri.fieldStrength or 0) / ri.maxFieldStrength * 10000) * 0.01
  end
  local fieldColor = colors.red
  if fieldPct >= 50 then fieldColor = colors.green elseif fieldPct > 30 then fieldColor = colors.orange end
  local fieldTitle = (autoInputGate==1) and ("Field Strength ("..currentMode..")") or "Field Strength"
  f.draw_text_lr(mon, 2, layout.inArrowsY+6, 1, fieldTitle, string.format("%.2f%%", fieldPct), colors.white, fieldColor, colors.black)
  f.progress_bar(mon, 2, layout.inArrowsY+7, mon.X-2, fieldPct, 100, fieldColor, colors.gray)

  -- Fuel
  local fuelPercent = 100
  if (ri.maxFuelConversion or 0) > 0 then
    fuelPercent = 100 - math.ceil((ri.fuelConversion or 0) / ri.maxFuelConversion * 10000) * 0.01
  end
  local fuelColor = colors.red
  if fuelPercent >= 70 then fuelColor = colors.green elseif fuelPercent > 30 then fuelColor = colors.orange end
  f.draw_text_lr(mon, 2, layout.inArrowsY+9, 1, "Fuel", string.format("%.2f%%", fuelPercent), colors.white, fuelColor, colors.black)
  f.progress_bar(mon, 2, layout.inArrowsY+10, mon.X-2, fuelPercent, 100, fuelColor, colors.gray)

  -- Action
  f.draw_text_lr(mon, 2, layout.inArrowsY+12, 1, "Action", action, colors.gray, colors.gray, colors.black)

  -- Quick safeguards (also in loops)
  if emergencyCharge == true then reactor.chargeReactor() end
  if ri.status == "charging" then inputGate.setSignalLowFlow(900000); emergencyCharge = false end
  if emergencyTemp == true and ri.status == "stopping" and (ri.temperature or 0) < safeTemperature then reactor.activateReactor(); emergencyTemp = false end
  if ri.status == "charged" and activateOnCharged == 1 and currentMode ~= MODE_COOL then reactor.activateReactor() end
  if fuelPercent <= 10 then reactor.stopReactor(); action = "Fuel below 10%, refuel" end
  if fieldPct <= lowestFieldPercent and ri.status == "online" then
    action = "Field Str < "..lowestFieldPercent.."%"
    reactor.stopReactor(); reactor.chargeReactor(); emergencyCharge = true
  end
  if (ri.temperature or 0) > maxTemperature then reactor.stopReactor(); action = "Temp > "..maxTemperature; emergencyTemp = true end

  monitor.setVisible(true)
end

local function uiLoop()
  while true do
    -- rebuild if monitor resized
    local mx, my = monitor.getSize()
    if mx ~= monX or my ~= monY then
      monX, monY = mx, my; mon.X, mon.Y = mx, my
      buildModeButtons()
    end
    drawUI()
    sleep(0.05)
  end
end

-- ===== Run =====
parallel.waitForAny(buttons, inputLoop, outputLoop, optimizerLoop, uiLoop)
