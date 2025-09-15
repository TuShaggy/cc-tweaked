-- /lib/f.lua
-- Small drawing + peripheral helpers for CC:Tweaked

-- peripheral search by type (returns wrapped or nil)
function periphSearch(ptype)
  local names = peripheral.getNames()
  for _, n in ipairs(names) do
    if peripheral.getType(n) == ptype then
      return peripheral.wrap(n)
    end
  end
  return nil
end

-- int format with thousands separators
function format_int(n)
  if n == nil then n = 0 end
  local s = tostring(math.floor(n + 0.5))
  local neg = s:sub(1,1)=="-"
  if neg then s = s:sub(2) end
  local out = s:reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,","")
  return (neg and "-" or "")..out
end

-- monitor text helpers
function draw_text(mon, x, y, text, tc, bc)
  mon.monitor.setBackgroundColor(bc)
  mon.monitor.setTextColor(tc)
  mon.monitor.setCursorPos(x,y)
  mon.monitor.write(text)
end

function draw_text_right(mon, offset, y, text, tc, bc)
  mon.monitor.setBackgroundColor(bc)
  mon.monitor.setTextColor(tc)
  mon.monitor.setCursorPos(mon.X - string.len(tostring(text)) - offset, y)
  mon.monitor.write(text)
end

function draw_text_lr(mon, x, y, offset, left, right, ltc, rtc, bc)
  draw_text(mon, x, y, left, ltc, bc)
  draw_text_right(mon, offset, y, right, rtc, bc)
end

-- solid line (spaces)
function draw_line(mon, x, y, len, color)
  if len < 0 then len = 0 end
  mon.monitor.setBackgroundColor(color)
  mon.monitor.setCursorPos(x,y)
  mon.monitor.write(string.rep(" ", len))
end

-- progress bar
function progress_bar(mon, x, y, length, value, max, bar, bg)
  draw_line(mon, x, y, length, bg)
  local size = 0
  if max > 0 then size = math.floor((value/max) * length) end
  draw_line(mon, x, y, size, bar)
end

-- clear both term and monitor window
function clear(mon)
  term.clear(); term.setCursorPos(1,1)
  mon.monitor.setBackgroundColor(colors.black)
  mon.monitor.clear()
  mon.monitor.setCursorPos(1,1)
end
