-- startup.lua
-- Clean layout: INFO & BARS at top/center, BIG ARROW BUTTONS at the bottom (full width)
-- AUTO keeps field at targetStrength; MANUAL lets you set input flow with arrows.

-------------------------
-- User settings
-------------------------
local reactorSide        = "back"
local targetStrength     = 50
local maxTemperature     = 8000
local safeTemperature    = 3000
local lowestFieldPercent = 15
local activateOnCharged  = 1

-------------------------
-- Load lib
-------------------------
os.loadAPI("lib/f")

-------------------------
-- State
-------------------------
local version       = "1.2-layout-fix"
local autoInputGate = 1          -- 1=AUTO, 0=MANUAL
local curInputGate  = 222000     -- rf/t when MANUAL

-- peripherals
local reactor
local fluxgate       -- OUTPUT (from reactor)
local inputfluxgate  -- INPUT  (to reactor)
local monitor_peripheral, monitor, monX, monY
local mon = {}

-- reactor info + state
local ri
local action = "None since reboot"
local emergencyCharge, emergencyTemp = false, false

-- dynamic button hitboxes (updated every draw)
local outHits, inHits, toggleHit = {}, {}, nil
local BTN_ROW_H     = 3
local BTN_ROWS      = 2
local BTN_SPACING   = 1
local BOTTOM_MARGIN = 1
local buttonsTopY   = 0
local contentTopY   = 1

-------------------------
-- Attach peripherals (edit your flow_gate IDs here if needed)
-------------------------
monitor_peripheral = f.periphSearch("monitor")
assert(monitor_peripheral, "No valid monitor was found")
monitor = window.create(monitor_peripheral, 1, 1, monitor_peripheral.getSize())

-- If your gates have different IDs, change these two lines:
inputfluxgate = peripheral.wrap("flow_gate_4")  -- INPUT to reactor (field)
fluxgate      = peripheral.wrap("flow_gate_5")  -- OUTPUT from reactor (energy)

reactor = peripheral.wrap(reactorSide)
assert(fluxgate,      "No valid output flow gate was found")
assert(inputfluxgate, "No valid input flow gate was found")
assert(reactor,       "No valid reactor was found")

monX, monY = monitor.getSize()
mon = { monitor = monitor, X = monX, Y = monY }

-------------------------
-- Config I/O
-------------------------
local function save_config()
  local sw = fs.open("config.txt","w")
  sw.writeLine(version)
  sw.writeLine(autoInputGate)
  sw.writeLine(curInputGate)
  sw.close()
end

local function load_config()
  if not fs.exists("config.txt") then return end
  local sr = fs.open("config.txt","r")
  version       = sr.readLine() or version
  autoInputGate = tonumber(sr.readLine() or "") or autoInputGate
  curInputGate  = tonumber(sr.readLine() or "") or curInputGate
  sr.close()
end

if not fs.exists("config.txt") then save_config() else load_config() end

-------------------------
-- Layout helpers
-------------------------
local function computeLayout()
  monX, monY = monitor.getSize()
  mon.X, mon.Y = monX, monY

  local bottomBlockH = BTN_ROWS*BTN_ROW_H + (BTN_ROWS-1)*BTN_SPACING + BOTTOM_MARGIN
  buttonsTopY = math.max(1, monY - bottomBlockH + 1)

  -- Put info block high and centered top; anchor classic 2..19 layout before buttons
  local needed = 19
  local topMargin = 2
  if buttonsTopY - 1 >= needed then
    contentTopY = topMargin
  else
    contentTopY = 1
  end
end

local function drawBottomRow(y)
  for dy=0,BTN_ROW_H-1 do f.draw_line(mon, 1, y+dy, mon.X, colors.gray) end
end

local function tokenDelta(tok)
  if tok == " < " then return -1000
  elseif tok == " <<" then return -10000
  elseif tok == "<<<" then return -100000
  elseif tok == " > " then return  1000
  elseif tok == ">> " then return  10000
  elseif tok == ">>>" then return  100000
  else return 0 end
end

local function distributeTokens(tokens, x1, x2, y, hitsTbl)
  if x2 <= x1 then return end
  local width = x2 - x1 + 1
  local total = 0
  for _,s in ipairs(tokens) do total = total + #s end
  local gaps = #tokens - 1
  local free = width - total - gaps
  if free < 0 then free = 0 end
  local pad  = math.floor(free / (#tokens + 1))
  local x = x1 + pad
  for _, s in ipairs(tokens) do
    f.draw_text(mon, x, y, s, colors.white, colors.gray)
    table.insert(hitsTbl, {x1=x, x2=x+#s-1, y=y, delta=tokenDelta(s)})
    x = x + #s + pad + 1
  end
end

-------------------------
-- Buttons (touch handler)
-------------------------
local function buttons()
  while true do
    local _,_,x,y = os.pullEvent("monitor_touch")
    local handled = false

    -- OUTPUT arrows hit test
    for _,h in ipairs(outHits) do
      if y==h.y and x>=h.x1 and x<=h.x2 then
        local v = fluxgate.getSignalLowFlow() + h.delta
        if v < 0 then v = 0 end
        fluxgate.setSignalLowFlow(v)
        handled = true
        break
      end
    end
    if handled then goto continue end

    -- Toggle hit test
    if toggleHit and y==toggleHit.y and x>=toggleHit.x1 and x<=toggleHit.x2 then
      autoInputGate = 1 - autoInputGate
      save_config()
      handled = true
    end
    if handled then goto continue end

    -- INPUT arrows (manual only)
    if autoInputGate == 0 then
      for _,h in ipairs(inHits) do
        if y==h.y and x>=h.x1 and x<=h.x2 then
          curInputGate = curInputGate + h.delta
          if curInputGate < 0 then curInputGate = 0 end
          inputfluxgate.setSignalLowFlow(curInputGate)
          save_config()
          break
        end
      end
    end

    ::continue::
  end
end

-------------------------
-- Drawing
-------------------------
local function drawTopInfo()
  local y = contentTopY

  -- Status
  ri = reactor.getReactorInfo()
  if not ri then error("reactor has an invalid setup") end

  local sCol = colors.red
  if ri.status=="online" or ri.status=="charged" then sCol=colors.green
  elseif ri.status=="offline" then sCol=colors.gray
  elseif ri.status=="charging" then sCol=colors.orange end
  f.draw_text_lr(mon, 2, y, 1, "Reactor Status", string.upper(ri.status), colors.white, sCol, colors.black); y=y+2

  -- Generation
  f.draw_text_lr(mon, 2, y, 1, "Generation", f.format_int(ri.generationRate or 0).." rf/t", colors.white, colors.lime, colors.black); y=y+2

  -- Temperature
  local tCol = colors.red
  if (ri.temperature or 0) <= 5000 then tCol=colors.green
  elseif (ri.temperature or 0) <= 6500 then tCol=colors.orange end
  f.draw_text_lr(mon, 2, y, 1, "Temperature", f.format_int(ri.temperature or 0).."C", colors.white, tCol, colors.black); y=y+2

  -- Output / Input values (text only here; arrows are at the bottom)
  f.draw_text_lr(mon, 2, y, 1, "Output Gate", f.format_int(fluxgate.getSignalLowFlow()).." rf/t", colors.white, colors.blue, colors.black); y=y+2
  f.draw_text_lr(mon, 2, y, 1, "Input Gate",  f.format_int(inputfluxgate.getSignalLowFlow()).." rf/t", colors.white, colors.blue, colors.black); y=y+2

  -- Energy bar
  local sat = 0
  if (ri.maxEnergySaturation or 0) > 0 then sat = math.ceil((ri.energySaturation or 0)/(ri.maxEnergySaturation)*10000)*0.01 end
  f.draw_text_lr(mon, 2, y, 1, "Energy Saturation", string.format("%.2f%%", sat), colors.white, colors.white, colors.black); y=y+1
  f.progress_bar(mon, 2, y, mon.X-2, sat, 100, colors.blue, colors.gray); y=y+2

  -- Field bar
  local fieldPct = 0
  if (ri.maxFieldStrength or 0) > 0 then fieldPct = math.ceil((ri.fieldStrength or 0)/(ri.maxFieldStrength)*10000)*0.01 end
  local fCol = colors.red; if fieldPct>=50 then fCol=colors.green elseif fieldPct>30 then fCol=colors.orange end
  local title = (autoInputGate==1) and ("Field Strength T:"..targetStrength) or "Field Strength"
  f.draw_text_lr(mon, 2, y, 1, title, string.format("%.2f%%", fieldPct), colors.white, fCol, colors.black); y=y+1
  f.progress_bar(mon, 2, y, mon.X-2, fieldPct, 100, fCol, colors.gray); y=y+2

  -- Fuel bar
  local fuelPct = 100
  if (ri.maxFuelConversion or 0) > 0 then
    fuelPct = 100 - math.ceil((ri.fuelConversion or 0)/(ri.maxFuelConversion)*10000)*0.01
  end
  local fuCol = colors.red; if fuelPct>=70 then fuCol=colors.green elseif fuelPct>30 then fuCol=colors.orange end
  f.draw_text_lr(mon, 2, y, 1, "Fuel", string.format("%.2f%%", fuelPct), colors.white, fuCol, colors.black); y=y+1
  f.progress_bar(mon, 2, y, mon.X-2, fuelPct, 100, fuCol, colors.gray); y=y+2

  -- Action
  f.draw_text_lr(mon, 2, y, 1, "Action", action, colors.lightGray, colors.lightGray, colors.black)

  -- Safeguards (same logic as your working code)
  if emergencyCharge then reactor.chargeReactor() end
  if ri.status=="charging" then inputfluxgate.setSignalLowFlow(900000); emergencyCharge=false end
  if emergencyTemp and ri.status=="stopping" and (ri.temperature or 0) < safeTemperature then reactor.activateReactor(); emergencyTemp=false end
  if ri.status=="charged" and activateOnCharged==1 then reactor.activateReactor() end

  if fuelPct <= 10 then reactor.stopReactor(); action = "Fuel below 10%, refuel" end
  if fieldPct <= lowestFieldPercent and ri.status=="online" then
    action="Field Str < "..lowestFieldPercent.."%"; reactor.stopReactor(); reactor.chargeReactor(); emergencyCharge=true
  end
  if (ri.temperature or 0) > maxTemperature then reactor.stopReactor(); action="Temp > "..maxTemperature; emergencyTemp=true end

  -- AUTO regulation with drop-back when field exceeds target
  if ri.status=="online" then
    if autoInputGate==1 then
      if fieldPct > targetStrength then
        -- Allow the field to drain until it returns to the target
        inputfluxgate.setSignalLowFlow(0)
      else
        local denom = 1 - (targetStrength/100)
        if denom <= 0 then denom = 0.001 end
        local fluxval = math.floor((ri.fieldDrainRate or 0) / denom + 0.5)
        if fluxval < 0 then fluxval = 0 end
        inputfluxgate.setSignalLowFlow(fluxval)
      end
    else
      inputfluxgate.setSignalLowFlow(curInputGate)
    end
  end
end

local function drawBottomButtons()
  -- OUTPUT row (full-width stripes)
  drawBottomRow(buttonsTopY)
  outHits = {}
  local yMidOut = buttonsTopY + math.floor(BTN_ROW_H/2)
  distributeTokens({ "<<<"," <<"," < "," > ",">> ",">>>" }, 2, monX-1, yMidOut, outHits)

  -- INPUT row (toggle centered; arrows split left/right)
  drawBottomRow(buttonsTopY + BTN_ROW_H + BTN_SPACING)
  inHits = {}
  local yMidIn = buttonsTopY + BTN_ROW_H + BTN_SPACING + math.floor(BTN_ROW_H/2)

  local toggleText = (autoInputGate==1) and "[ AUTO ]" or "[ MANUAL ]"
  local tx = math.max(2, math.floor(monX/2 - #toggleText/2))
  toggleHit = {x1=tx, x2=tx+#toggleText-1, y=yMidIn}
  f.draw_text(mon, tx, yMidIn, toggleText, colors.white, colors.gray)

  local gap = 2
  distributeTokens({ "<<<"," <<"," < " }, 2, math.max(2, tx - gap), yMidIn, inHits)
  distributeTokens({ " > ",">> ",">>>" }, math.min(monX-1, toggleHit.x2 + gap), monX-1, yMidIn, inHits)
end

-------------------------
-- Main update loop
-------------------------
local function update()
  while true do
    monitor.setVisible(false)
    f.clear(mon)

    computeLayout()
    drawTopInfo()
    drawBottomButtons()

    monitor.setVisible(true)
    sleep(0.05)
  end
end

parallel.waitForAny(buttons, update)
