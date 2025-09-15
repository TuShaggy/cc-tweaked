-- startup.lua
-- Clean layout: INFO + BARS at top/center, BIG ARROW BUTTONS at the bottom (full width)
-- Same behavior as your good version: AUTO holds field at targetStrength; MANUAL lets you set input flow.

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
local version       = "1.2-layout"
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

  -- Put info block high and centered top; we’ll anchor our old 2..19 layout to fit before buttons
  local needed = 19                -- last used line in the “old” layout
  local topMargin = 2
  if buttonsTopY - 1 >= needed then
    contentTopY = topMargin
  else
    -- not enough height: compress by shifting up
    contentTopY = 1
  end
end

local function drawBottomRow(y)
  for dy=0,BTN_ROW_H-1 do f.draw_line(mon, 1, y+dy, mon.X, colors.gray) end
end

local function buildArrows(y, withCenterGap)
  -- create 6 arrows spread to full width; optional center gap (for AUTO/MANUAL toggle)
  local left  = { "<<<", " <<", " < " }
  local right = { " > ", ">> ", ">>>"}
  local gapW  = withCenterGap and 9 or 0   -- room for [ AUTO ] / [ MANUAL ]
  local yMid  = y + math.floor(BTN_ROW_H/2)

  local function placeSide(tokens, x1, x2, hitsTbl, dir)
    local total = 0
    for _,s in ipairs(tokens) do total = total + #s end
    local spaces = #tokens - 1
    local width  = x2 - x1 + 1
    local free   = math.max(0, width - total - spaces)
    local pad    = math.floor(free / (#tokens + 1))  -- even padding
    local x = x1 + pad
    for _, s in ipairs(tokens) do
      f.draw_text(mon, x, yMid, s, colors.white, colors.gray)
      table.insert(hitsTbl, {x1=x, x2=x+#s-1, y=yMid, delta=
        (s==" < " and -1000) or (s==" <<" and -10000) or (s=="<<<" and -100000) or
        (s==" > " and  1000) or (s==">> " and  10000) or (s==">>>" and  100000) or 0})
      x = x + #s + pad + 1
    end
  end

  outHits, inHits = {}, {} -- cleared by caller right before using
  if withCenterGap then
    local leftEnd  = math.floor(monX/2) - math.floor(gapW/2) - 2
    local rightBeg = math.floor(monX/2) + math.floor(gapW/2) + 2
    return placeSide(left,  2, leftEnd,  inHits, -1),
           placeSide(right, rightBeg, monX-1, inHits, 1),
           yMid
  else
    placeSide(left,  2, math.floor(monX/2)-1, outHits, -1)
    placeSide(right, math.floor(monX/2)+1, monX-1, outHits, 1)
    return yMid
  end
end

-------------------------
-- Buttons (touch handler)
-------------------------
local function buttons()
  while true do
    local _,_,x,y = os.pullEvent("monitor_touch")

    -- OUTPUT arrows hit test
    for _,h in ipairs(outHits) do
      if y==h.y and x>=h.x1 and x<=h.x2 then
        local v = fluxgate.getSignalLowFlow() + h.delta
        if v < 0 then v = 0 end
        fluxgate.setSignalLowFlow(v)
        goto next_touch
      end
    end

    -- Toggle hit test
    if toggleHit and y==toggleHit.y and x>=toggleHit.x1 and x<=toggleHit.x2 then
      autoInputGate = 1 - autoInputGate
      save_config()
      goto next_touch
    end

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

    ::next_touch::
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

  -- AUTO regulation (as before)
  if ri.status=="online" then
    if autoInputGate==1 then
      local denom = 1 - (targetStrength/100)
      if denom <= 0 then denom = 0.001 end
      local fluxval = math.floor((ri.fieldDrainRate or 0) / denom + 0.5)
      if fluxval < 0 then fluxval = 0 end
      inputfluxgate.setSignalLowFlow(fluxval)
    else
      inputfluxgate.setSignalLowFlow(curInputGate)
    end
  end
end

local function drawBottomButtons()
  -- OUTPUT row
  drawBottomRow(buttonsTopY)
  outHits = {}
  local outY = buttonsTopY
  -- spread arrows full width
  local outMidY = (function() return (function() local blocks={"<<<"," <<"," < "," > ",">> ",">>>"} local total=0 for _,s in ipairs(blocks) do total=total+#s end total=total+(#blocks-1) local startX=2 local space=math.max(0, (monX-1 - startX +1 - total) // (#blocks+1)) local x=startX+space for _,s in ipairs(blocks) do f.draw_text(mon,x,outY+math.floor(BTN_ROW_H/2),s,colors.white,colors.gray) table.insert(outHits,{x1=x,x2=x+#s-1,y=outY+math.floor(BTN_ROW_H/2), delta=(s==" < " and -1000) or (s==" <<" and -10000) or (s=="<<<" and -100000) or (s==" > " and 1000) or (s==">> " and 10000) or (s==">>>" and 100000) or 0}) x=x+#s+space+1 end end)() end)()

  -- INPUT row (with AUTO/MANUAL toggle centered)
  drawBottomRow(buttonsTopY + BTN_ROW_H + BTN_SPACING)
  local inY = buttonsTopY + BTN_ROW_H + BTN_SPACING
  inHits = {}
  -- center toggle
  local toggleText = (autoInputGate==1) and "[ AUTO ]" or "[ MANUAL ]"
  local ty = inY + math.floor(BTN_ROW_H/2)
  local tx = math.max(2, math.floor(monX/2 - #toggleText/2))
  toggleHit = {x1=tx, x2=tx+#toggleText-1, y=ty}
  f.draw_text(mon, tx, ty, toggleText, colors.white, colors.gray)

  -- arrows split left/right around the toggle
  local left  = { "<<<", " <<", " < " }
  local right = { " > ", ">> ", ">>>"}
  local function place(tokens, x1, x2)
    if x2 - x1 < 6 then return end
    local total=0 for _,s in ipairs(tokens) do total=total+#s end
    local spaces = #tokens - 1
    local width  = x2 - x1 + 1
    local free   = math.max(0, width - total - spaces)
    local pad    = math.floor(free / (#tokens + 1))
    local x = x1 + pad
    for _,s in ipairs(tokens) do
      f.draw_text(mon, x, ty, s, colors.white, colors.gray)
      table.insert(inHits, {x1=x, x2=x+#s-1, y=ty,
        delta=(s==" < " and -1000) or (s==" <<" and -10000) or (s=="<<<" and -100000) or
              (s==" > " and  1000) or (s==">> " and  10000) or (s==">>>" and  100000) or 0})
      x = x + #s + pad + 1
    end
  end
  local gap = 2
  place(left, 2, tx - gap)
  place(right, toggleHit.x2 + gap, monX - 1)
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
