-- modifiable variables
local reactorSide = "back"
local targetStrength = 50
local maxTemperature = 8000
local safeTemperature = 3000
local lowestFieldPercent = 15
local activateOnCharged = 1

-- please leave things untouched from here on
os.loadAPI("lib/f")

local version = "0.25"
local autoInputGate = 1
local curInputGate = 222000

local mon, monitor, monX, monY
local reactor
local fluxgate
local inputfluxgate
local ri
local action = "None since reboot"
local emergencyCharge = false
local emergencyTemp = false

-- wrap peripherals
monitor_peripheral = f.periphSearch("monitor")
monitor = window.create(monitor_peripheral, 1, 1, monitor_peripheral.getSize())
inputfluxgate = peripheral.wrap("flow_gate_4")   -- cambia a tu ID real
fluxgate = peripheral.wrap("flow_gate_5")        -- cambia a tu ID real
reactor = peripheral.wrap(reactorSide)

if monitor == nil then error("No valid monitor was found") end
if fluxgate == nil then error("No valid output fluxgate was found") end
if reactor == nil then error("No valid reactor was found") end
if inputfluxgate == nil then error("No valid input fluxgate was found") end

monX, monY = monitor.getSize()
mon = {monitor = monitor, X = monX, Y = monY}

-- config save/load
local function save_config()
  local sw = fs.open("config.txt", "w")
  sw.writeLine(version)
  sw.writeLine(autoInputGate)
  sw.writeLine(curInputGate)
  sw.close()
end

local function load_config()
  local sr = fs.open("config.txt", "r")
  version = sr.readLine()
  autoInputGate = tonumber(sr.readLine())
  curInputGate = tonumber(sr.readLine())
  sr.close()
end

if not fs.exists("config.txt") then save_config() else load_config() end

-- monitor buttons
local function buttons()
  while true do
    local event, side, xPos, yPos = os.pullEvent("monitor_touch")

    -- output gate controls
    if yPos == 8 then
      local cFlow = fluxgate.getSignalLowFlow()
      if xPos >= 2 and xPos <= 4 then cFlow = cFlow - 1000
      elseif xPos >= 6 and xPos <= 9 then cFlow = cFlow - 10000
      elseif xPos >= 10 and xPos <= 12 then cFlow = cFlow - 100000
      elseif xPos >= 17 and xPos <= 19 then cFlow = cFlow + 100000
      elseif xPos >= 21 and xPos <= 23 then cFlow = cFlow + 10000
      elseif xPos >= 25 and xPos <= 27 then cFlow = cFlow + 1000
      end
      fluxgate.setSignalLowFlow(cFlow)
    end

    -- input gate controls (manual only)
    if yPos == 10 and autoInputGate == 0 and xPos ~= 14 and xPos ~= 15 then
      if xPos >= 2 and xPos <= 4 then curInputGate = curInputGate - 1000
      elseif xPos >= 6 and xPos <= 9 then curInputGate = curInputGate - 10000
      elseif xPos >= 10 and xPos <= 12 then curInputGate = curInputGate - 100000
      elseif xPos >= 17 and xPos <= 19 then curInputGate = curInputGate + 100000
      elseif xPos >= 21 and xPos <= 23 then curInputGate = curInputGate + 10000
      elseif xPos >= 25 and xPos <= 27 then curInputGate = curInputGate + 1000
      end
      inputfluxgate.setSignalLowFlow(curInputGate)
      save_config()
    end

    -- toggle AUTO/MANUAL
    if yPos == 10 and (xPos == 14 or xPos == 15) then
      autoInputGate = 1 - autoInputGate
      save_config()
    end
  end
end

local function drawButtons(y)
  f.draw_text(mon, 2, y, " < ", colors.white, colors.gray)
  f.draw_text(mon, 6, y, " <<", colors.white, colors.gray)
  f.draw_text(mon, 10, y, "<<<", colors.white, colors.gray)
  f.draw_text(mon, 17, y, ">>>", colors.white, colors.gray)
  f.draw_text(mon, 21, y, ">> ", colors.white, colors.gray)
  f.draw_text(mon, 25, y, " > ", colors.white, colors.gray)
end

-- main loop
local function update()
  while true do
    monitor.setVisible(false)
    f.clear(mon)

    ri = reactor.getReactorInfo()
    if ri == nil then error("reactor has an invalid setup") end

    -- status
    local statusColor = colors.red
    if ri.status == "online" or ri.status == "charged" then statusColor = colors.green
    elseif ri.status == "offline" then statusColor = colors.gray
    elseif ri.status == "charging" then statusColor = colors.orange
    end

    f.draw_text_lr(mon, 2, 2, 1, "Reactor Status", string.upper(ri.status), colors.white, statusColor, colors.black)
    f.draw_text_lr(mon, 2, 4, 1, "Generation", f.format_int(ri.generationRate) .. " rf/t", colors.white, colors.lime, colors.black)

    local tempColor = colors.red
    if ri.temperature <= 5000 then tempColor = colors.green end
    if ri.temperature > 5000 and ri.temperature <= 6500 then tempColor = colors.orange end
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

    local satPercent = math.ceil(ri.energySaturation / ri.maxEnergySaturation * 10000)*.01
    f.draw_text_lr(mon, 2, 11, 1, "Energy Saturation", satPercent .. "%", colors.white, colors.white, colors.black)
    f.progress_bar(mon, 2, 12, mon.X-2, satPercent, 100, colors.blue, colors.gray)

    local fieldPercent = math.ceil(ri.fieldStrength / ri.maxFieldStrength * 10000)*.01
    local fieldColor = colors.red
    if fieldPercent >= 50 then fieldColor = colors.green end
    if fieldPercent < 50 and fieldPercent > 30 then fieldColor = colors.orange end

    if autoInputGate == 1 then
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength T:" .. targetStrength, fieldPercent .. "%", colors.white, fieldColor, colors.black)
      local fluxval = ri.fieldDrainRate / (1 - (targetStrength/100))
      if fluxval < 0 then fluxval = 0 end
      inputfluxgate.setSignalLowFlow(fluxval)
    else
      f.draw_text_lr(mon, 2, 14, 1, "Field Strength", fieldPercent .. "%", colors.white, fieldColor, colors.black)
      inputfluxgate.setSignalLowFlow(curInputGate)
    end
    f.progress_bar(mon, 2, 15, mon.X-2, fieldPercent, 100, fieldColor, colors.gray)

    local fuelPercent = 100 - math.ceil(ri.fuelConversion / ri.maxFuelConversion * 10000)*.01
    local fuelColor = colors.red
    if fuelPercent >= 70 then fuelColor = colors.green end
    if fuelPercent < 70 and fuelPercent > 30 then fuelColor = colors.orange end

    f.draw_text_lr(mon, 2, 17, 1, "Fuel ", fuelPercent .. "%", colors.white, fuelColor, colors.black)
    f.progress_bar(mon, 2, 18, mon.X-2, fuelPercent, 100, fuelColor, colors.gray)

    f.draw_text_lr(mon, 2, 19, 1, "Action ", action, colors.gray, colors.gray, colors.black)

    -- reactor logic
    if emergencyCharge then reactor.chargeReactor() end

    if ri.status == "charging" then
      inputfluxgate.setSignalLowFlow(900000)
      emergencyCharge = false
    end

    if emergencyTemp and ri.status == "stopping" and ri.temperature < safeTemperature then
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
    sleep(0)
  end
end

parallel.waitForAny(buttons, update)
