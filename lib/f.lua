-- ============================================
-- lib/f.lua  (helpers for monitor/peripherals)
-- Safe nils (no 'null'), robust drawing + formatting
-- ============================================

-- Peripheral search: returns FIRST peripheral of a given type wrapped
function periphSearch(ptype)
  local names = peripheral.getNames()
  for _, name in ipairs(names) do
    if peripheral.getType(name) == ptype then
      return peripheral.wrap(name)
    end
  end
  return nil
end

-- 1,234,567 formatting (safe fallback)
function format_int(number)
  if number == nil then number = 0 end
  local s = tostring(number)
  local minus, int, fraction = s:match('^([-]?)(%d+)([.]?%d*)$')
  if not int then return s end
  int = int:reverse():gsub("(%d%d%d)", "%1,")
  return (minus or "") .. int:reverse():gsub("^,", "") .. (fraction or "")
end

-- ===== Monitor drawing =====
-- mon is a table: { monitor = <wrapped monitor>, X = width, Y = height }

function draw_text(mon, x, y, text, text_color, bg_color)
  mon.monitor.setBackgroundColor(bg_color or colors.black)
  mon.monitor.setTextColor(text_color or colors.white)
  mon.monitor.setCursorPos(x, y)
  mon.monitor.write(text or "")
end

function draw_text_right(mon, offset, y, text, text_color, bg_color)
  mon.monitor.setBackgroundColor(bg_color or colors.black)
  mon.monitor.setTextColor(text_color or colors.white)
  local s = tostring(text or "")
  mon.monitor.setCursorPos(mon.X - string.len(s) - (offset or 0), y)
  mon.monitor.write(s)
end

function draw_text_lr(mon, x, y, offset, text1, text2, text1_color, text2_color, bg_color)
  draw_text(mon, x, y, text1 or "", text1_color or colors.white, bg_color or colors.black)
  draw_text_right(mon, offset or 0, y, text2 or "", text2_color or colors.white, bg_color or colors.black)
end

function draw_line(mon, x, y, length, color)
  length = math.max(0, math.floor(length or 0))
  mon.monitor.setBackgroundColor(color or colors.black)
  mon.monitor.setCursorPos(x, y)
  mon.monitor.write(string.rep(" ", length))
end

-- progress bar: value in [0..maxVal]
function progress_bar(mon, x, y, length, value, maxVal, bar_color, bg_color)
  length = math.max(0, math.floor(length or 0))
  value  = math.max(0, math.min(value or 0, maxVal or 1))
  draw_line(mon, x, y, length, bg_color or colors.black) -- background
  local barSize = (maxVal and maxVal > 0) and math.floor((value / maxVal) * length + 0.5) or 0
  draw_line(mon, x, y, barSize, bar_color or colors.white)
end

function clear(mon)
  term.clear()
  term.setCursorPos(1,1)
  mon.monitor.setBackgroundColor(colors.black)
  mon.monitor.clear()
  mon.monitor.setCursorPos(1,1)
end
