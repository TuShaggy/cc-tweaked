-- reactor/optimizer.lua
-- Headless optimizer focused on MAX net power:
--   net ≈ generationRate - inputFluxNeeded(targetField)
-- Controls:
--   - INPUT gate: keeps field ~= targetField using classic formula
--   - OUTPUT gate: PID-like (P) to keep temperature near TARGET_TEMP
--   - Periodic A/B test around current field target to improve efficiency
-- Uses gate names y ajustes guardados en config.txt (del controlador principal)

-- ---------- defaults (overridden by config.txt if present) ----------
local reactorSide        = "back"
local targetField        = 50     -- % (starting point)
local lowestFieldPercent = 15
local maxTemperature     = 8000
local safeTemperature    = 3000

-- Optimizer tuning
local TARGET_TEMP    = 7500       -- °C setpoint for temperature
local TEMP_KP        = 1500       -- proportional gain for output flow (rf/t per °C)
local OUTFLOW_MAX    = 20000000   -- cap output gate
local CONTROL_DT     = 0.10       -- seconds (input control rate)
local TEMP_DT        = 0.20       -- seconds (output control rate)
local AB_PERIOD      = 30         -- seconds between efficiency probes
local AB_WINDOW      = 5          -- seconds to average each candidate
local FIELD_STEP     = 5          -- % step for A/B (+/-)
local FIELD_MIN      =  math.max(lowestFieldPercent + 10, 25) -- safety lower bound
local FIELD_MAX      = 70

-- ---------- load config from the main controller if available ----------
local savedInputGateName, savedOutputGateName

local function load_config()
  if not fs.exists("config.txt") then return end
  local f = fs.open("config.txt","r"); if not f then return end
  -- version
  f.readLine()
  -- autoInputGate
  f.readLine()
  -- curInputGate
  f.readLine()
  -- targetStrength (if present in your version)
  local maybeTS = f.readLine()
  if maybeTS then
    local ts = tonumber(maybeTS)
    if ts then targetField = ts end
  end
  -- savedInputGateName / savedOutputGateName (if present)
  local inN  = f.readLine() or ""
  local outN = f.readLine() or ""
  if inN  ~= "" then savedInputGateName  = inN  end
  if outN ~= "" then savedOutputGateName = outN end
  f.close()
end

-- ---------- wrap peripherals ----------
local reactor, inputGate, outputGate

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
  if not reactor then error("No valid reactor on side '"..reactorSide.."'") end

  if savedInputGateName then inputGate  = peripheral.wrap(savedInputGateName) end
  if savedOutputGateName then outputGate = peripheral.wrap(savedOutputGateName) end

  if not inputGate or not outputGate then
    local gates = detectFlowGates()
    if #gates < 2 then error("Need at least 2 flow gates with get/setSignalLowFlow") end
    -- pick the first two by default if not saved
    if not inputGate  then savedInputGateName  = gates[1]; inputGate  = peripheral.wrap(savedInputGateName) end
    if not outputGate then
      local pick = (gates[2] == savedInputGateName) and gates[3] or gates[2]
      savedOutputGateName = pick; outputGate = peripheral.wrap(savedOutputGateName)
    end
  end
end

-- ---------- helpers ----------
local function clamp(x,a,b) if x<a then return a elseif x>b then return b else return x end end
local function round(x) return math.floor(x + 0.5) end

local function input_needed(info, fieldPct)
  -- classic formula used in tu controlador
  local denom = 1 - (fieldPct/100)
  if denom <= 0 then denom = 0.001 end
  local drain = info.fieldDrainRate or 0
  local flux  = drain / denom
  if flux < 0 then flux = 0 end
  return round(flux)
end

local function avg_net(fieldPct, seconds)
  local t0 = os.clock()
  local acc, n = 0, 0
  while os.clock() - t0 < seconds do
    local info = reactor.getReactorInfo()
    if info then
      local gen  = info.generationRate or 0
      local need = input_needed(info, fieldPct)
      acc = acc + (gen - need)
      n = n + 1
    end
    sleep(0.2)
  end
  if n == 0 then return -math.huge end
  return acc / n
end

-- ---------- controllers (run in parallel) ----------
local currentOut = 0
local lastInput  = 0
local fieldTarget = clamp(targetField, FIELD_MIN, FIELD_MAX)

local function inputLoop()
  while true do
    local info = reactor.getReactorInfo()
    if info and info.status == "online" then
      lastInput = input_needed(info, fieldTarget)
      inputGate.setSignalLowFlow(lastInput)
    elseif info and info.status == "charging" then
      inputGate.setSignalLowFlow(900000)
      lastInput = 900000
    end
    sleep(CONTROL_DT)
  end
end

local function outputLoop()
  -- simple P controller to hold temperature near TARGET_TEMP
  currentOut = outputGate.getSignalLowFlow()
  while true do
    local info = reactor.getReactorInfo()
    if info and info.status ~= "offline" then
      local err = (info.temperature or 0) - TARGET_TEMP
      local adjust = err * TEMP_KP
      local newOut = clamp(currentOut + adjust, 0, OUTFLOW_MAX)
      newOut = round(newOut)
      if newOut ~= currentOut then
        outputGate.setSignalLowFlow(newOut)
        currentOut = newOut
      end
      -- safety assist: if too hot, open hard
      if info.temperature and info.temperature > maxTemperature then
        outputGate.setSignalLowFlow(OUTFLOW_MAX)
        currentOut = OUTFLOW_MAX
      end
    end
    sleep(TEMP_DT)
  end
end

local function optimizerLoop()
  local lastProbe = os.clock()
  while true do
    local now = os.clock()
    if now - lastProbe >= AB_PERIOD then
      local a = clamp(fieldTarget - FIELD_STEP, FIELD_MIN, FIELD_MAX)
      local b = clamp(fieldTarget + FIELD_STEP, FIELD_MIN, FIELD_MAX)

      -- do quick A/B around current target
      local bestTarget = fieldTarget
      local bestScore  = -math.huge

      -- A
      fieldTarget = a
      sleep(0.5) -- let input settle
      local scoreA = avg_net(a, AB_WINDOW)

      -- B
      fieldTarget = b
      sleep(0.5)
      local scoreB = avg_net(b, AB_WINDOW)

      if scoreA > bestScore then bestScore = scoreA; bestTarget = a end
      if scoreB > bestScore then bestScore = scoreB; bestTarget = b end

      -- adopt better target, but never go below safety margin
      fieldTarget = clamp(bestTarget, FIELD_MIN, FIELD_MAX)
      lastProbe = now
    end

    -- additional safety: if field dangerously low, bias up
    local info = reactor.getReactorInfo()
    if info then
      local fieldPct = (info.maxFieldStrength and info.maxFieldStrength > 0)
        and (info.fieldStrength / info.maxFieldStrength * 100) or 0
      if fieldPct < (lowestFieldPercent + 5) then
        fieldTarget = clamp(math.max(fieldTarget, lowestFieldPercent + 12), FIELD_MIN, FIELD_MAX)
      end
      if info.status == "charged" then reactor.activateReactor() end
      if info.status == "online" and (info.temperature or 0) > maxTemperature then
        reactor.stopReactor()
      end
      if (info.fuelConversion and info.maxFuelConversion and info.maxFuelConversion > 0) then
        local fuelPercent = 100 - (info.fuelConversion / info.maxFuelConversion * 100)
        if fuelPercent <= 10 then
          reactor.stopReactor()
        end
      end
    end

    sleep(0.5)
  end
end

-- ---------- boot ----------
load_config()
ensure_peripherals()

print("Optimizer started.")
print("INPUT:  "..tostring(savedInputGateName))
print("OUTPUT: "..tostring(savedOutputGateName))
print("Target temp: "..TARGET_TEMP.."C  Field start: "..fieldTarget.."%")

parallel.waitForAny(inputLoop, outputLoop, optimizerLoop)
