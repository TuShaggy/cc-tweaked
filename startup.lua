-- startup.lua  (revert to the stable layout & behavior “as before”)
-- - Arrows for Output/Input
-- - AU/MA toggle for input gate
-- - Auto input = hold field at targetStrength using drain formula
-- - Manual input = fixed curInputGate
-- - Same on-screen info & layout (no extra mode buttons)

-- ===== User variables =====
local reactorSide = "back"       -- side where the reactor is wrapped
local targetStrength = 50        -- % field to hold in AUTO
local maxTemperature = 8000
local safeTemperature = 3000
local lowestFieldPercent = 15
local activateOnCharged = 1

-- ===== Please leave from here =====
os.loadAPI("lib/f")

local version = "0.25"
local autoInputGate = 1          -- 1=AUTO, 0=MANUAL
local curInputGate = 222000      -- rf/t when MANUAL

-- UI
local mon, monitor, monX, monY
-- Peripherals
local reactor
local fluxgate         -- OUTPUT (from reactor)
local inputfluxgate    -- INPUT  (to reactor field)
-- Reactor info
local ri
-- State
local action = "None since reboot"
local emergencyCharge = false
local emergencyTemp = false

-- Attach peripherals (same names/behavior as your working setup)
local monitor_peripheral = f.periphSearch("monitor")
if not monitor_peripheral then error("No valid monitor was found") end
monitor = window.create(monitor_peripheral, 1, 1, monitor_peripheral.getSize())

-- If you used different IDs, change these two lines to your flow gate IDs
inputfluxgate = peripheral.wrap("flow_gate_4")  -- INPUT gate (to reactor)
fluxgate      = peripheral.wrap("flow_gate_5")  -- OUTPUT gate (from reactor)

reactor = peripheral.wrap(reactorSide)

if not fluxgate then       error("No valid output flow gate was found") end
if not reactor then        error("No valid reactor was found") end
if not inputfluxgate then  error("No valid input flow gate was found") end

monX, monY = monitor.getSize()
mon = { monitor = monitor, X = monX, Y = monY }

-- ===== Config I/O =====
local function save_config()
  local sw = fs.open("config.txt", "w")
  sw.writeLine(version)
  sw.writeLine(autoInputGate)
  sw.writeLine(curInputGate)
  sw.close()
end

local function load_config()
  if not fs.exists("config.txt") then return end
  local sr = fs.open("config.txt", "r")
  version       = sr.readLine() or version
  autoInputGate = tonumber(sr.readLine() or "") or autoInputGate
  curInputGate  = tonumber(sr.readLine() or "") or curInputGate
  sr.close()
end

if not fs.exists("config.txt") then save_config() else load_config() end

-- ===== Buttons (same layout as before) =====
local function drawButtons(y)
  -- 2-4 = -1000, 6-9 = -10000, 10-12 = -100000
  -- 17-19 = +1000, 21-23 = +10000, 25-27 = +100000
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

    -- OUTPUT gate adjust (row 8)
    if yPos == 8 then
      local cFlow = fluxgate.getSignalLowFlow()
      if     xPos >=  2 and xPos <=  4 then cFlow = cFlow - 1000
      elseif xPos >=  6 and xPos <=  9 then cFlow = cFlow - 10000
      elseif xPos >= 10 and xPos <= 12 then cFlow = cFlow - 100000
      elseif xPos >= 17 and xPos <= 19 then cFlow = cFlow + 100000
      elseif xPos >= 21 and xPos <= 23 then cFlow = cFlow + 10000
      elseif xPos >= 25 and xPos <= 27 then cFlow = cFlow + 1000
      end
      if cFlow < 0 then cFlow = 0 end
      fluxgate.setSignalLowFlow(cFlow)
    end

    -- INPUT gate adjust (row 10) – only when MANUAL and not clicking toggle
    if yPos == 10 and autoInputGate == 0 and xPos ~= 14 and xPos ~= 15 then
      if     xPos >=  2 and xPos <=  4 then curInputGate = curInputGate - 1000
      elseif xPos >=  6 and xPos <=  9 then curInputGate = curInputGate - 10000
      elseif xPos >= 10 and xPos <= 12 then curInputGate = curInputGate - 100000
      elseif xPos >= 17 and xPos <= 19 then curInputGate = curInputGate + 100000
      elseif xPos >= 21 and xPos <= 23 then curInputGate = curInputGate + 10000
      elseif xPos >= 25 and xPos <= 27 then curInputGate = curInputGate + 1000
      end
      if curInputGate < 0 then curInputGate = 0 end
      inputfluxgate.setSignalLowFlow(curInputGate)
      save_config()
    end

    -- INPUT gate toggle AU/MA (center two chars at col 14–15)
    if yPos == 10 and (xPos == 14 or xPos == 15) then
      autoInputGate = 1 - autoInputGate
      save_config()
    end
  end
end

-- ===== Main UI/update loop (same layout) =====
local function update()
  while true do
    monitor.setVisible(false)
    f.clear(mon)

    ri = reactor.getReactorInfo()
    if ri == nil then error("reactor has an invalid setup") end

    -- Terminal dump (like before)
    for k, v in pairs(ri) do print(k..": "..tostring(v)) end
    print("Output Gate: ", fluxgate.getSignalLowFlow())
    print("Input  Gate: ", inputfluxgate.getSignalLowFlow())

    -- Status
    local statusColor = colors.red
    if     ri.status == "online"  or ri.status == "charged" then statusColor = colors.green
    elseif ri.status == "offline"                          then statusColor = colors.gray
    elseif ri.status == "charging"                         then statusColor = colors.orange
    end
    f.draw_text_lr(mon, 2, 2, 1, "Reactor Status", string.upper(ri.status), colors.white, statusColor, colors.black)

    -- Generation
    f.draw_text_lr(mon, 2, 4, 1, "Generation", f.format_int(ri.generationRate or 0).." rf/t", colors.white, colors.lime, colors.black)

    -- Temperature
    local tempColor = colors.red
    if     (ri.temperature or 0) <= 5000 then tempColor = colors.green
    elseif (ri.temperature or 0) <= 6500 then tempColor = colors.orange end
    f.draw_text_lr(mon, 2, 6, 1, "Temperature", f.format_int(ri.temperature or 0).."C", colors.white, tempColor, colors.black)

    -- OUTPUT gate line + arrows row 8
    f.draw_text_lr(mon, 2, 7, 1, "Output Gate", f.format_int(fluxgate.getSignalLowFlow()).." rf/t", colors.white, colors.blue, colors.black)
    drawButtons(8)

    -- INPUT gate line + toggle + arrows (only in MANUAL) row 10
    f.draw_text_lr(mon, 2, 9, 1, "Input Gate", f.format_int(inputfluxgate.getSignalLowFlow()).." rf/t", colors.white, colors.blue, colors.black)
    if autoInputGate == 1 then
      f.draw_text(mon, 14, 10, "AU", colors.white, colors.gray)
    else
      f.draw_text(mon, 14, 10, "MA", colors.white, colors.gray)
      drawButtons(10)
    end

    -- Energy Saturation bar
    local satPercent = math.ceil(((ri.energySaturation or 0) / (ri.maxEnergySaturation or 1)) * 10000) * 0.01
    f.draw_text_lr(mon, 2, 11, 1, "Energy Saturation", satPercent.."%", colors.white, colors.white, colors.black)
    f.progress_bar(mon, 2, 12, mon.X-2, satPercent, 100, colors.blue, colors.gray)

    -- Field %
    local fieldPercent = math.ceil(((ri.fieldStrength or 0) / (ri.maxFieldStrength or 1)) * 10000) * 0.01
    local fieldColor = colors.red
    if fieldPercent >= 50 then fieldColor = colors.green
    elseif fieldPercent > 30 then fieldColor = colors.orange end

    if autoInputGate == 1 then
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength T:"..targetStrength, fieldPercent.."%", colors.white, fieldColor, colors.black)
    else
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength", fieldPercent.."%", colors.white, fieldColor, colors.black)
    end
    f.progress_bar(mon, 2, 15, mon.X-2, fieldPercent, 100, fieldColor, colors.gray)

    -- Fuel bar
    local fuelPercent = 100 - math.ceil(((ri.fuelConversion or 0) / (ri.maxFuelConversion or 1)) * 10000) * 0.01
    local fuelColor = colors.red
    if fuelPercent >= 70 then fuelColor = colors.green
    elseif fuelPercent > 30 then fuelColor = colors.orange end
    f.draw_text_lr(mon, 2, 17, 1, "Fuel ", fuelPercent.."%", colors.white, fuelColor, colors.black)
    f.progress_bar(mon, 2, 18, mon.X-2, fuelPercent, 100, fuelColor, colors.gray)

    -- Last action
    f.draw_text_lr(mon, 2, 19, 1, "Action ", action, colors.gray, colors.gray, colors.black)

    -- ===== Reactor interaction =====
    if emergencyCharge then reactor.chargeReactor() end

    -- While charging: open input
    if ri.status == "charging" then
      inputfluxgate.setSignalLowFlow(900000)
      emergencyCharge = false
    end

    -- Resume after cooling
    if emergencyTemp and ri.status == "stopping" and (ri.temperature or 0) < safeTemperature then
      reactor.activateReactor()
      emergencyTemp = false
    end

    -- Auto-activate on charged
    if ri.status == "charged" and activateOnCharged == 1 then
      reactor.activateReactor()
    end

    -- Regulate input gate
    if ri.status == "online" then
      if autoInputGate == 1 then
        local fluxval = (ri.fieldDrainRate or 0) / (1 - (targetStrength/100))
        if fluxval < 0 then fluxval = 0 end
        inputfluxgate.setSignalLowFlow(fluxval)
        print("Target Gate: "..fluxval)
      else
        inputfluxgate.setSignalLowFlow(curInputGate)
      end
    end

    -- ===== Safeguards =====
    if fuelPercent <= 10 then
      reactor.stopReactor()
      action = "Fuel below 10%, refuel"
    end

    if fieldPercent <= lowestFieldPercent and ri.status == "online" then
      action = "Field Str < "..lowestFieldPercent.."%"
      reactor.stopReactor()
      reactor.chargeReactor()
      emergencyCharge = true
    end

    if (ri.temperature or 0) > maxTemperature then
      reactor.stopReactor()
      action = "Temp > "..maxTemperature
      emergencyTemp = true
    end

    monitor.setVisible(true)
    sleep(0)
  end
end

parallel.waitForAny(buttons, update)
