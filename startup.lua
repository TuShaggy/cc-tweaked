-- ============================================
-- Draconic Reactor Controller + Bottom Mode Buttons (Fixed & Working)
-- - Field input flow: fieldDrainRate / (1 - target/100) (smoothed)
-- - Output flow auto-regulates temperature per mode
-- - Big mode buttons ANCHORED AT THE BOTTOM (with bottom margin)
-- - Continuous updates (timed control loops + frequent UI refresh)
-- ============================================

-- === User settings ===
local reactorSide        = "back"
local targetStrength     = 50    -- used for STABLE (and as default manual target)
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
local version       = "0.95-bottom-fixed"
local autoInputGate = 1           -- 1=AUTO field control, 0=MANUAL
local curInputGate  = 222000      -- manual input gate (rf/t)

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

-- ====== Layout (BOTTOM buttons) ======
local layout = {
  contentTopY   = 1,  -- computed later
  outArrowsY    = 0,
  inArrowsY     = 0,
  inToggleX1    = 10, -- AU/MA clickable area (wider)
  inToggleX2    = 18,
  inToggleY     = 0,
  btnsTopY      = 0,
  bottomMargin  = 1,  -- keep a free line at bottom
  btnRows       = 2,
  btnHeight     = 3,
  btnSpacingY   = 1,
  ModeButtons   = {}, -- filled by makeModeButtons()
}

-- ====== Config I/O ======
local function save_config()
  local sw = fs.open("config.txt", "w")
  sw.writeLine(tostring(version))
  sw.writeLine(tostring(autoInputGate))
  sw.writeLine(tostring(curInputGate))
  sw.writeLine(tostring(targetStrength))
  sw.writeLine(tostring(savedInputGateName or ""))
  sw.writeLine(tostring(savedOutputGateName or ""))
  sw.writeLine(tostring(currentMode)) -- persist mode
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

-- ====== Gate picker ======
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

-- ====== Mode params ======
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

-- ====== Layout & Buttons at BOTTOM (absolute) ======
local function makeModeButtons()
  layout.ModeButtons = {}

  -- Bottom block height: 2 rows of buttons + spacing + bottom margin
  local bottomBlockH = layout.btnRows*layout.btnHeight + (layout.btnRows-1)*layout.btnSpacingY + layout.bottomMargin
  -- Top Y of buttons area
  layout.btnsTopY = math.max(1, monY - bottomBlockH - 0 + 1)  -- keep last line as margin

  -- Content area: everything above buttons area minus 1 spacer line
  local spacer = 1
  layout.contentTopY = 1
  -- We'll place arrows/toggles relative to contentTopY later
  layout.outArrowsY = layout.btnsTopY - (spacer + 11)  -- ensure arrows are far above buttons
  layout.inArrowsY  = layout.outArrowsY + 2
  layout.inToggleY  = layout.inArrowsY

  if layout.outArrowsY < 6 then
    layout.outArrowsY = 6
    layout.inArrowsY  = 8
    layout.inToggleY  = 8
    layout.contentTopY = 1
  end

  -- 6 buttons in 2x3 grid centered horizontally
  local labels = {MODE_AUTO, MODE_MAX, MODE_STABLE, MODE_ECO, MODE_CHARGE, MODE_COOL}
  local cols, rows = 3, 2
  local spacingX = 2
  local totalColsWidth = monX - 4  -- side margin of 2 chars each side
  local bw = math.max(8, math.floor((totalColsWidth - spacingX*(cols-1)) / cols))
  local startX = math.floor((monX - (bw*cols + spacingX*(cols-1))) / 2) + 1
  if startX < 2 then startX = 2 end

  local bh = layout.btnHeight
  for i, label in ipairs(labels) do
    local col = ((i-1) % cols)
    local row = math.floor((i-1) / cols)
    local x = startX + col*(bw + spacingX)
    local y = layout.btnsTopY + row*(bh + layout.btnSpacingY)
    table.insert(layout.ModeButtons, {x=x, y=y, w=bw, h=bh, label=label})
  end
end

local function rect(x,y,w,h,color)
  for dy=0,h-1 do f.draw_line(mon, x, y+dy, w, color) end
end

local function drawModeButton(b, active)
  rect(b.x, b.y, b.w, b.h, active and colors.green or colors.gray)
  local lx = b.x + math.floor((b.w - #b.label)/2)
  local ly = b.y + math.floor(b.h/2)
  f.draw_text(mon, lx, ly, b.label, colors.white, colors.black)
end

local function pointIn(b, x, y) return x>=b.x and x<=b.x+b.w-1 and y>=b.y and y<=b.y+b.h-1 end

local function drawArrows(y)
  -- center the arrows region relative to screen width
  local blocks = {" < ", " <<", "<<<", ">>>", ">> ", " > "}
  local totalW = 0
  for _,s in ipairs(blocks) do totalW = totalW + #s end
  local gaps = 5
  totalW = totalW + gaps -- single space between each
  local startX = math.max(2, math.floor((monX - totalW)/2))

  local x = startX
  for i,s in ipairs(blocks) do
    f.draw_text(mon, x, y, s, colors.white, colors.gray)
    x = x + #s + 1
  end
end

makeModeButtons() -- initial build

-- ====== Buttons handler (touch) ======
local function buttons()
  while true do
    local _, _, xPos, yPos = os.pullEvent("monitor_touch")

    -- Mode buttons at bottom
    for _, b in ipairs(layout.ModeButtons) do
      if pointIn(b, xPos, yPos) then
        currentMode = b.label
        applyModeParams()
        action = "Mode -> "..currentMode
        save_config()
        goto NEXT_TOUCH_DONE
      end
    end

    -- OUTPUT gate controls (arrow row)
    if yPos == layout.outArrowsY then
      local c = outputGate.getSignalLowFlow()
      local s = monX -- compute centered arrow x ranges again for touch
      -- Recreate same layout math to detect which arrow was pressed
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
      for _,bk in ipairs(blocks) do
        local x1, x2 = x, x + #bk.label - 1
        if xPos >= x1 and xPos <= x2 then
          c = c + bk.delta
          break
        end
        x = x2 + 2
      end
      if c < 0 then c = 0 end
      outputGate.setSignalLowFlow(c)
      goto NEXT_TOUCH_DONE
    end

    -- INPUT gate controls (manual only)
    if yPos == layout.inArrowsY and autoInputGate == 0 and not (xPos >= layout.inToggleX1 and xPos <= layout.inToggleX2) then
      local s = monX
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
      for _,bk in ipairs(blocks) do
        local x1, x2 = x, x + #bk.label - 1
        if xPos >= x1 and xPos <= x2 then
          curInputGate = curInputGate + bk.delta
          break
        end
        x = x2 + 2
      end
      if curInputGate < 0 then curInputGate = 0 end
      inputGate.setSignalLowFlow(curInputGate)
      lastInputFlow = curInputGate
      save_config()
      goto NEXT_TOUCH_DONE
    end

    -- INPUT AUTO/MANUAL toggle (wide area centered)
    if yPos == layout.inToggleY and xPos >= layout.inToggleX1 and xPos <= layout.inToggleX2 then
      autoInputGate = 1 - autoInputGate
      if autoInputGate == 0 then inputGate.setSignalLowFlow(curInputGate) end
      save_config()
      goto NEXT_TOUCH_DONE
    end

    ::NEXT_TOUCH_DONE::
  end
end

-- ====== Helpers ======
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

-- ====== Control loops ======
local CONTROL_INTERVAL = 0.10
local OUTPUT_INTERVAL  = 0.20

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
          lastInputSet  = nil
          lastInputFlow = 900000
        elseif currentMode == MODE_COOL then
          local base = inputNeeded(info, 65)
          inputGate.setSignalLowFlow(base)
          lastInputSet  = base
          lastInputFlow = base
        elseif info.status == "online" then
          local target = fieldTargetRuntime
          if autoInputGate == 0 then target = targetStrength end
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

-- Output (temperature) controller
local function outputLoop()
  currentOutFlow = outputGate.getSignalLowFlow()
  local tt = os.startTimer(OUTPUT_INTERVAL)
  while true do
    local ev, id = os.pullEvent()
    if ev == "timer" and id == tt then
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

-- ====== UI update (flicker-free & bottom buttons) ======
local function drawArrowsCentered(y)
  drawArrows(y)
end

local function drawUI()
  monitor.setVisible(false)
  f.clear(mon)

  -- draw mode buttons at bottom
  for _, b in ipairs(layout.ModeButtons) do
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

  local y = layout.contentTopY

  f.draw_text_lr(mon, 2, y+0, 1, "Reactor Status", string.upper(ri.status), colors.white, statusColor, colors.black)
  f.draw_text_lr(mon, 2, y+2, 1, "Generation", f.format_int(ri.generationRate or 0) .. " rf/t", colors.white, colors.lime, colors.black)

  local tempColor = colors.red
  if ri.temperature <= 5000 then tempColor = colors.green
  elseif ri.temperature <= 6500 then tempColor = colors.orange end
  f.draw_text_lr(mon, 2, y+4, 1, "Temperature", f.format_int(ri.temperature or 0) .. "C", colors.white, tempColor, colors.black)

  -- Output gate row
  f.draw_text_lr(mon, 2, y+5, 1, "Output Gate", f.format_int(outputGate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)
  drawArrowsCentered(layout.outArrowsY)

  -- Input gate row
  f.draw_text_lr(mon, 2, y+7, 1, "Input Gate", f.format_int(inputGate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)
  -- AU/MA toggle (centered wide area)
  local toggleText = (autoInputGate==1 and "AUTO" or "MANUAL")
  local tx = math.floor(monX/2 - #toggleText/2)
  if tx < layout.inToggleX1 then tx = layout.inToggleX1 + 1 end
  f.draw_text(mon, tx, layout.inToggleY, toggleText, colors.white, colors.gray)
  if autoInputGate == 0 then drawArrowsCentered(layout.inArrowsY) end

  -- Energy saturation
  local satPercent = math.ceil((ri.energySaturation or 0) / (ri.maxEnergySaturation or 1) * 10000) * 0.01
  f.draw_text_lr(mon, 2, y+9, 1, "Energy Saturation", string.format("%.2f%%", satPercent), colors.white, colors.white, colors.black)
  f.progress_bar(mon, 2, y+10, mon.X-2, satPercent, 100, colors.blue, colors.gray)

  -- Field %
  local fieldPct = math.ceil((ri.fieldStrength or 0) / (ri.maxFieldStrength or 1) * 10000) * 0.01
  local fieldColor = colors.red
  if fieldPct >= 50 then fieldColor = colors.green
  elseif fieldPct > 30 then fieldColor = colors.orange end

  local fieldTitle = (autoInputGate==1) and ("Field Strength ("..currentMode..")") or "Field Strength"
  f.draw_text_lr(mon, 2, y+12, 1, fieldTitle, string.format("%.2f%%", fieldPct), colors.white, fieldColor, colors.black)
  f.progress_bar(mon, 2, y+13, mon.X-2, fieldPct, 100, fieldColor, colors.gray)

  -- Fuel
  local fuelPercent = 100 - math.ceil((ri.fuelConversion or 0) / (ri.maxFuelConversion or 1) * 10000) * 0.01
  local fuelColor = colors.red
  if fuelPercent >= 70 then fuelColor = colors.green
  elseif fuelPercent > 30 then fuelColor = colors.orange end

  f.draw_text_lr(mon, 2, y+15, 1, "Fuel", string.format("%.2f%%", fuelPercent), colors.white, fuelColor, colors.black)
  f.progress_bar(mon, 2, y+16, mon.X-2, fuelPercent, 100, fuelColor, colors.gray)

  f.draw_text_lr(mon, 2, y+18, 1, "Action", action, colors.gray, colors.gray, colors.black)

  -- Safeguards (quick hooks here too)
  if emergencyCharge == true then reactor.chargeReactor() end
  if ri.status == "charging" then inputGate.setSignalLowFlow(900000); emergencyCharge = false end
  if emergencyTemp == true and ri.status == "stopping" and ri.temperature < safeTemperature then reactor.activateReactor(); emergencyTemp = false end
  if ri.status == "charged" and activateOnCharged == 1 and currentMode ~= MODE_COOL then reactor.activateReactor() end
  if fuelPercent <= 10 then reactor.stopReactor(); action = "Fuel below 10%, refuel" end
  if fieldPct <= lowestFieldPercent and ri.status == "online" then
    action = "Field Str < " .. lowestFieldPercent .. "%"
    reactor.stopReactor(); reactor.chargeReactor(); emergencyCharge = true
  end
  if ri.temperature > maxTemperature then reactor.stopReactor(); action = "Temp > " .. maxTemperature; emergencyTemp = true end

  monitor.setVisible(true)
end

local function update()
  while true do
    -- rebuild layout if monitor size changes
    local mx, my = monitor.getSize()
    if mx ~= monX or my ~= monY then
      monX, monY = mx, my
      mon.X, mon.Y = mx, my
      makeModeButtons()
    end
    drawUI()
    sleep(0.05)
  end
end

-- ====== Run ======
parallel.waitForAny(buttons, inputLoop, outputLoop, optimizerLoop, update)
