-- /startup.lua
-- Draconic Reactor Controller – bottom buttons, stable loops (no goto)

-- ===== User settings =====
local REACTOR_SIDE        = "back"
local DEFAULT_TARGET      = 50
local MAX_TEMPERATURE     = 8000
local SAFE_TEMPERATURE    = 3000
local LOWEST_FIELD_PCT    = 15
local ACTIVATE_ON_CHARGED = 1

-- ===== Load lib/f =====
local function load_api(path)
  local ok, err = pcall(os.loadAPI, path)
  if not ok then error("Failed to load API '"..path.."': "..tostring(err)) end
end
if fs.exists("lib/f") then load_api("lib/f")
elseif fs.exists("lib/f.lua") then load_api("lib/f.lua")
else error("Missing lib/f.lua. Run installer.") end

-- ===== Theme (optional) =====
local Theme = {
  bg=colors.black, text=colors.white, muted=colors.lightGray, card=colors.black,
  good=colors.green, warn=colors.orange, bad=colors.red, accent=colors.blue,
  accent2=colors.lime, btnOn=colors.green, btnOff=colors.gray,
}
if fs.exists("ui/theme") or fs.exists("ui/theme.lua") then
  local ok = pcall(os.loadAPI, fs.exists("ui/theme") and "ui/theme" or "ui/theme.lua")
  if ok and theme and theme.colors then Theme = theme.colors end
end

-- ===== State =====
local VERSION        = "1.11-no-goto"
local autoInputGate  = 1
local curInputGate   = 222000

local reactor, inputGate, outputGate
local monPeriph, monitor, monX, monY
local mon = {}

local ri, action = nil, "None since reboot"
local emergencyCharge, emergencyTemp = false, false

local savedInputGateName, savedOutputGateName = nil, nil

-- Modes
local MODE_AUTO, MODE_MAX, MODE_STABLE, MODE_ECO, MODE_CHARGE, MODE_COOL =
      "AUTO","MAX","STABLE","ECO","CHARGE","COOL"
local currentMode = MODE_STABLE

-- Control params
local fieldTargetRuntime = DEFAULT_TARGET
local autoFieldMin, autoFieldMax = 30, 65
local fieldStep, abPeriod, abWindow = 5, 25, 4
local tempTarget, tempKp, outputFlowMax = 7000, 1200, 20000000
local lastInputSet, lastInputFlow, currentOutFlow = nil, 0, 0
local smoothAlpha = 0.30

-- ===== Config I/O =====
local function save_config()
  local w = fs.open("config.txt","w")
  w.writeLine(VERSION)
  w.writeLine(autoInputGate)
  w.writeLine(curInputGate)
  w.writeLine(DEFAULT_TARGET)
  w.writeLine(savedInputGateName or "")
  w.writeLine(savedOutputGateName or "")
  w.writeLine(currentMode)
  w.close()
end
local function load_config()
  if not fs.exists("config.txt") then return end
  local r = fs.open("config.txt","r"); if not r then return end
  VERSION = r.readLine() or VERSION
  autoInputGate = tonumber(r.readLine() or "") or autoInputGate
  curInputGate  = tonumber(r.readLine() or "") or curInputGate
  local ts      = tonumber(r.readLine() or ""); if ts then DEFAULT_TARGET = ts end
  local inN     = r.readLine() or ""; if inN~="" then savedInputGateName=inN end
  local outN    = r.readLine() or ""; if outN~="" then savedOutputGateName=outN end
  local m       = r.readLine() or ""
  if m==MODE_AUTO or m==MODE_MAX or m==MODE_STABLE or m==MODE_ECO or m==MODE_CHARGE or m==MODE_COOL then
    currentMode = m
  end
  r.close()
end

-- ===== Peripherals =====
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
local function pick(title, opts, pre)
  term.clear(); term.setCursorPos(1,1); print("==== "..title.." ====")
  for i,v in ipairs(opts) do print(("[%d] %s%s"):format(i, v, (pre and v==pre) and "  *" or "")) end
  while true do write("> #: "); local s=read(); local i=tonumber(s); if i and opts[i] then return opts[i] end print("Invalid.") end
end
local function ensureGates()
  if savedInputGateName  then inputGate  = peripheral.wrap(savedInputGateName) end
  if savedOutputGateName then outputGate = peripheral.wrap(savedOutputGateName) end
  if inputGate and outputGate then return end
  local gates = detectFlowGates(); if #gates<2 then error("Need at least 2 Flow Gates.") end
  print("\nPick gate that FEEDS the reactor field (INPUT to reactor).")
  local inName = pick("INPUT Flow Gate", gates, savedInputGateName)
  local rest = {}; for _,n in ipairs(gates) do if n~=inName then table.insert(rest,n) end end
  print("\nPick gate that EXTRACTS energy FROM the reactor (OUTPUT).")
  local outName = pick("OUTPUT Flow Gate", rest, savedOutputGateName)
  savedInputGateName, savedOutputGateName = inName, outName
  save_config()
  inputGate  = peripheral.wrap(savedInputGateName)  or error("Wrap INPUT failed")
  outputGate = peripheral.wrap(savedOutputGateName) or error("Wrap OUTPUT failed")
end

-- ===== Init =====
monPeriph = f.periphSearch("monitor") or error("No monitor found")
monitor = window.create(monPeriph, 1, 1, monPeriph.getSize())
reactor = peripheral.wrap(REACTOR_SIDE) or error("No reactor on '"..REACTOR_SIDE.."'")
monX, monY = monitor.getSize(); mon = {monitor=monitor, X=monX, Y=monY}
load_config(); ensureGates()

-- ===== Mode params =====
local function applyMode()
  if currentMode==MODE_AUTO then autoFieldMin,autoFieldMax,tempTarget,tempKp = 30,65,7400,1200
  elseif currentMode==MODE_MAX then fieldTargetRuntime,tempTarget,tempKp = 48,7800,1600
  elseif currentMode==MODE_STABLE then fieldTargetRuntime,tempTarget,tempKp = 50,7000,1200
  elseif currentMode==MODE_ECO then fieldTargetRuntime,tempTarget,tempKp = 60,6500,1000
  elseif currentMode==MODE_CHARGE or currentMode==MODE_COOL then tempTarget,tempKp = 0,0 end
end
applyMode()

-- ===== Helpers =====
local function clamp(x,a,b) if x<a then return a elseif x>b then return b else return x end end
local function round(x) return math.floor(x+0.5) end
local function pctField(info) if not info or not info.maxFieldStrength or info.maxFieldStrength==0 then return 0 end return (info.fieldStrength/info.maxFieldStrength)*100 end
local function inputNeeded(info, fieldPct) local d=1-(fieldPct/100); if d<=0 then d=0.001 end local flux=(info.fieldDrainRate or 0)/d; if flux<0 then flux=0 end return round(flux) end
local function avg_net(pct, seconds)
  local t0=os.clock(); local acc,n=0,0
  while os.clock()-t0<seconds do local i=reactor.getReactorInfo(); if i then acc=acc+((i.generationRate or 0)-inputNeeded(i,pct)); n=n+1 end sleep(0.2) end
  if n==0 then return -math.huge end; return acc/n
end

-- ===== Layout / hitboxes =====
local layout = {btnH=3, btnRows=2, btnSpacing=1, marginB=1, btnTopY=0, outRowY=0, inRowY=0}
local ModeButtons, outHits, inHits = {}, {}, {}
local toggleHit = nil
local function buildLayout()
  ModeButtons, outHits, inHits = {}, {}, {}
  local bottomH = layout.btnRows*layout.btnH + (layout.btnRows-1)*layout.btnSpacing + layout.marginB
  layout.btnTopY = math.max(1, monY - bottomH + 1)
  layout.outRowY = layout.btnTopY - 11
  layout.inRowY  = layout.outRowY + 2
  if layout.outRowY < 6 then layout.outRowY=6; layout.inRowY=8 end
  local labels = {MODE_AUTO,MODE_MAX,MODE_STABLE,MODE_ECO,MODE_CHARGE,MODE_COOL}
  local cols, spacingX = 3, 3
  local avail = monX - 4
  local bw = math.max(9, math.floor((avail - spacingX*(cols-1))/cols))
  local startX = math.floor((monX - (bw*cols+spacingX*(cols-1)))/2)+1; if startX<2 then startX=2 end
  for i,label in ipairs(labels) do local c=(i-1)%cols; local r=math.floor((i-1)/cols)
    table.insert(ModeButtons,{x=startX+c*(bw+spacingX), y=layout.btnTopY+r*(layout.btnH+layout.btnSpacing), w=bw, h=layout.btnH, label=label})
  end
end
buildLayout()
local function drawButton(b, active) for dy=0,b.h-1 do f.draw_line(mon,b.x,b.y+dy,b.w, active and Theme.btnOn or Theme.btnOff) end local cx=b.x+math.floor((b.w-#b.label)/2); local cy=b.y+math.floor(b.h/2); f.draw_text(mon,cx,cy,b.label,Theme.text,Theme.card) end
local function pointIn(b,x,y) return x>=b.x and x<=b.x+b.w-1 and y>=b.y and y<=b.y+b.h-1 end
local function makeArrowHits(y, hits)
  local blocks = { " < ", " <<", "<<<", ">>>", ">> ", " > " }
  local deltas = { -1000, -10000, -100000, 100000, 10000, 1000 }
  local totalW = 0; for _,s in ipairs(blocks) do totalW = totalW + #s end; totalW = totalW + (#blocks-1)
  local x = math.max(2, math.floor((monX - totalW)/2))
  local cur=x
  for i,s in ipairs(blocks) do local x1,x2=cur,cur+#s-1; hits[i]={x1=x1,x2=x2,y=y,delta=deltas[i],label=s}; cur=x2+2 end
end

-- ===== Touch handling (no goto) =====
local function buttons()
  while true do
    local _,_,x,y = os.pullEvent("monitor_touch")
    local handled=false

    for _,b in ipairs(ModeButtons) do
      if pointIn(b,x,y) then currentMode=b.label; applyMode(); action="Mode -> "..currentMode; save_config(); handled=true; break end
    end
    if handled then goto cont end

    for _,h in ipairs(outHits) do
      if y==h.y and x>=h.x1 and x<=h.x2 then local c=outputGate.getSignalLowFlow()+h.delta; if c<0 then c=0 end; outputGate.setSignalLowFlow(c); handled=true; break end
    end
    if handled then goto cont end

    if toggleHit and y==toggleHit.y and x>=toggleHit.x1 and x<=toggleHit.x2 then
      autoInputGate = 1 - autoInputGate; if autoInputGate==0 then inputGate.setSignalLowFlow(curInputGate) end; save_config(); handled=true
    end
    if handled then goto cont end

    if autoInputGate==0 then
      for _,h in ipairs(inHits) do
        if y==h.y and x>=h.x1 and x<=h.x2 then curInputGate=curInputGate+h.delta; if curInputGate<0 then curInputGate=0 end; inputGate.setSignalLowFlow(curInputGate); lastInputFlow=curInputGate; save_config(); break end
      end
    end
    ::cont::
  end
end

-- ===== Control loops (NO goto) =====
local CONTROL_DT, OUTPUT_DT = 0.10, 0.20

local function inputLoop()
  local timer = os.startTimer(CONTROL_DT)
  while true do
    local _, id = os.pullEvent("timer")
    if id == timer then
      local info = reactor.getReactorInfo()
      if info then
        if info.status=="charging" or currentMode==MODE_CHARGE then
          inputGate.setSignalLowFlow(900000); lastInputSet=nil; lastInputFlow=900000
        elseif currentMode==MODE_COOL then
          local base=inputNeeded(info,65); inputGate.setSignalLowFlow(base); lastInputSet=base; lastInputFlow=base
        elseif info.status=="online" then
          local tgt=(autoInputGate==1) and fieldTargetRuntime or DEFAULT_TARGET
          local base=inputNeeded(info,tgt); if lastInputSet then base=lastInputSet*(1-smoothAlpha)+base*smoothAlpha end
          base=round(base); inputGate.setSignalLowFlow(base); lastInputSet=base; lastInputFlow=base
        end
      end
      timer = os.startTimer(CONTROL_DT)
    end
  end
end

local function outputLoop()
  currentOutFlow = outputGate.getSignalLowFlow()
  local timer = os.startTimer(OUTPUT_DT)
  while true do
    local _, id = os.pullEvent("timer")
    if id == timer then
      local info = reactor.getReactorInfo()
      if info then
        if currentMode==MODE_CHARGE then
          outputGate.setSignalLowFlow(0); currentOutFlow=0
        elseif currentMode==MODE_COOL then
          outputGate.setSignalLowFlow(outputFlowMax); currentOutFlow=outputFlowMax
        elseif info.status~="offline" then
          local err=(info.temperature or 0)-tempTarget
          local newOut=clamp((currentOutFlow or 0)+err*tempKp,0,outputFlowMax); newOut=round(newOut)
          if newOut~=currentOutFlow then outputGate.setSignalLowFlow(newOut); currentOutFlow=newOut end
          if (info.temperature or 0) > MAX_TEMPERATURE then outputGate.setSignalLowFlow(outputFlowMax); currentOutFlow=outputFlowMax end
        end
      end
      timer = os.startTimer(OUTPUT_DT)
    end
  end
end

local function optimizerLoop()
  local lastProbe = os.clock(); fieldTargetRuntime = DEFAULT_TARGET
  while true do
    if currentMode==MODE_AUTO then
      local now=os.clock()
      if now-lastProbe>=abPeriod then
        local a=clamp(fieldTargetRuntime-fieldStep,autoFieldMin,autoFieldMax)
        local b=clamp(fieldTargetRuntime+fieldStep,autoFieldMin,autoFieldMax)
        fieldTargetRuntime=a; sleep(0.5); local scoreA=avg_net(a,abWindow)
        fieldTargetRuntime=b; sleep(0.5); local scoreB=avg_net(b,abWindow)
        fieldTargetRuntime=(scoreA>=scoreB) and a or b; lastProbe=now
      else fieldTargetRuntime=clamp(fieldTargetRuntime,autoFieldMin,autoFieldMax) end
    else
      if currentMode==MODE_MAX then fieldTargetRuntime=48
      elseif currentMode==MODE_STABLE then fieldTargetRuntime=50
      elseif currentMode==MODE_ECO then fieldTargetRuntime=60 end
      sleep(0.2)
    end
    local info=reactor.getReactorInfo()
    if info then
      local fp=pctField(info); if fp<(LOWEST_FIELD_PCT+5) then fieldTargetRuntime=math.max(fieldTargetRuntime,LOWEST_FIELD_PCT+12) end
      if info.status=="charged" and ACTIVATE_ON_CHARGED==1 and currentMode~=MODE_COOL then reactor.activateReactor() end
      if info.status=="online" and (info.temperature or 0)>MAX_TEMPERATURE then reactor.stopReactor(); action="Overtemp -> STOP" end
      if (info.fuelConversion and info.maxFuelConversion and info.maxFuelConversion>0) then
        local fuelPct=100-(info.fuelConversion/info.maxFuelConversion*100); if fuelPct<=10 then reactor.stopReactor(); action="Low fuel -> STOP" end
      end
    end
  end
end

-- ===== UI =====
local function drawArrowsFromHits(hits)
  for _,h in ipairs(hits) do f.draw_text(mon,h.x1,h.y,h.label,Theme.text,Theme.btnOff) end
end
local function updateUI()
  monitor.setVisible(false); f.clear(mon)
  local mx,my=monitor.getSize(); if mx~=monX or my~=monY then monX,monY=mx,my; mon.X,mon.Y=mx,my; buildLayout() end

  for _,b in ipairs(ModeButtons) do drawButton(b, b.label==currentMode) end

  ri=reactor.getReactorInfo(); if not ri then error("Reactor invalid") end
  local sCol=Theme.bad; if ri.status=="online" or ri.status=="charged" then sCol=Theme.good elseif ri.status=="offline" then sCol=Theme.muted elseif ri.status=="charging" then sCol=Theme.warn end
  local headerY=layout.outRowY-5; if headerY<1 then headerY=1 end
  f.draw_text_lr(mon,2,headerY+0,1,"Reactor Status",string.upper(ri.status or "unknown"),Theme.text,sCol,Theme.bg)
  f.draw_text_lr(mon,2,headerY+2,1,"Generation",f.format_int(ri.generationRate or 0).." rf/t",Theme.text,Theme.accent2,Theme.bg)
  local tCol=Theme.bad; if (ri.temperature or 0)<=5000 then tCol=Theme.good elseif (ri.temperature or 0)<=6500 then tCol=Theme.warn end
  f.draw_text_lr(mon,2,headerY+4,1,"Temperature",f.format_int(ri.temperature or 0).." C",Theme.text,tCol,Theme.bg)

  f.draw_text_lr(mon,2,layout.outRowY-1,1,"Output Gate",f.format_int(outputGate.getSignalLowFlow()).." rf/t",Theme.text,Theme.accent,Theme.bg)
  outHits={}; makeArrowHits(layout.outRowY,outHits); drawArrowsFromHits(outHits)

  f.draw_text_lr(mon,2,layout.inRowY-1,1,"Input Gate",f.format_int(inputGate.getSignalLowFlow()).." rf/t",Theme.text,Theme.accent,Theme.bg)
  local tText=(autoInputGate==1) and "[ AUTO ]" or "[ MANUAL ]"
  local tx=math.max(2, math.floor(monX/2 - #tText/2)); toggleHit={x1=tx,x2=tx+#tText-1,y=layout.inRowY}; f.draw_text(mon,tx,layout.inRowY,tText,Theme.text,Theme.btnOff)
  if autoInputGate==0 then inHits={}; makeArrowHits(layout.inRowY+1,inHits); drawArrowsFromHits(inHits) else inHits={} end

  local satPct=0; if (ri.maxEnergySaturation or 0)>0 then satPct=math.ceil((ri.energySaturation or 0)/ri.maxEnergySaturation*10000)*0.01 end
  f.draw_text_lr(mon,2,layout.inRowY+3,1,"Energy Saturation",string.format("%.2f%%",satPct),Theme.text,Theme.text,Theme.bg)
  f.progress_bar(mon,2,layout.inRowY+4,mon.X-2,satPct,100,Theme.accent,Theme.muted)

  local fieldPct=0; if (ri.maxFieldStrength or 0)>0 then fieldPct=math.ceil((ri.fieldStrength or 0)/ri.maxFieldStrength*10000)*0.01 end
  local fCol=(fieldPct>=50) and Theme.good or ((fieldPct>30) and Theme.warn or Theme.bad)
  local title=(autoInputGate==1) and ("Field Strength ("..currentMode..")") or "Field Strength"
  f.draw_text_lr(mon,2,layout.inRowY+6,1,title,string.format("%.2f%%",fieldPct),Theme.text,fCol,Theme.bg)
  f.progress_bar(mon,2,layout.inRowY+7,mon.X-2,fieldPct,100,fCol,Theme.muted)

  local fuelPct=100; if (ri.maxFuelConversion or 0)>0 then fuelPct=100-math.ceil((ri.fuelConversion or 0)/ri.maxFuelConversion*10000)*0.01 end
  local fuCol=(fuelPct>=70) and Theme.good or ((fuelPct>30) and Theme.warn or Theme.bad)
  f.draw_text_lr(mon,2,layout.inRowY+9,1,"Fuel",string.format("%.2f%%",fuelPct),Theme.text,fuCol,Theme.bg)
  f.progress_bar(mon,2,layout.inRowY+10,mon.X-2,fuelPct,100,fuCol,Theme.muted)

  f.draw_text_lr(mon,2,layout.inRowY+12,1,"Action",action,Theme.muted,Theme.muted,Theme.bg)

  if emergencyCharge then reactor.chargeReactor() end
  if ri.status=="charging" then inputGate.setSignalLowFlow(900000); emergencyCharge=false end
  if emergencyTemp and ri.status=="stopping" and (ri.temperature or 0)<SAFE_TEMPERATURE then reactor.activateReactor(); emergencyTemp=false end
  if ri.status=="charged" and ACTIVATE_ON_CHARGED==1 and currentMode~=MODE_COOL then reactor.activateReactor() end
  if fuelPct<=10 then reactor.stopReactor(); action="Fuel below 10%, refuel" end
  if fieldPct<=LOWEST_FIELD_PCT and ri.status=="online" then action="Field Str < "..LOWEST_FIELD_PCT.."%" reactor.stopReactor() reactor.chargeReactor() emergencyCharge=true end
  if (ri.temperature or 0) > MAX_TEMPERATURE then reactor.stopReactor(); action="Temp > "..MAX_TEMPERATURE emergencyTemp=true end

  monitor.setVisible(true)
end
local function uiLoop() while true do updateUI() sleep(0.05) end end

-- ===== Run =====
parallel.waitForAny(buttons, inputLoop, outputLoop, optimizerLoop, uiLoop)
