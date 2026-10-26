-- Rules on the PDF itself: the form requirements of the call, checked on the output so they
-- hold whatever the sources look like. Need poppler-utils (pdfinfo, pdffonts, pdftohtml,
-- pdftotext). Profiles: tdk (the call), thesis (the faculty's thesis guide).
local C = require("lintcore")
local rule, fail, warn, note = C.rule, C.fail, C.warn, C.note
local MM = 72 / 25.4
local lfs = require("lfs")

local PROFILES = {
  tdk = { name = "TDK call", size = { 11.5, 12.5 }, pitch = { 1.0, 1.35 }, margin = { 15, 35 }, pages = { 30, 35 }, pages_gate = true,
    needs = { "Abstract", "Kivonat|Összefoglaló|Tartalmi összefoglaló", "generatív mesterséges intelligencia|generatív MI" }, forbids = { "HALLGATÓI NYILATKOZAT" } },
  thesis = { name = "faculty thesis guide", size = { 10.5, 12.5 }, pitch = { 1.4, 2.0 }, margin = { 24, 40 }, pages = { 30, 90 }, pages_gate = false,
    needs = { "Abstract", "Kivonat|Összefoglaló", "HALLGATÓI NYILATKOZAT", "generatív mesterséges intelligencia|generatív MI" }, forbids = {} },
}
local function profile() return PROFILES[C.opts.profile] or PROFILES.tdk end
local function pdf() return C.bpath(C.opts.doc .. ".pdf") end

-- parsed pdftohtml XML, cached
local parsed
local function doc()
  if parsed then return parsed end
  if not C.have("pdftohtml") then return nil end
  local xml = C.run(string.format("pdftohtml -xml -i -q -zoom 1 -stdout %q", pdf())) or ""
  local d = { pages = {}, fonts = {}, outline = {} }
  local page
  local depth = 0
  for line in xml:gmatch("[^\n]+") do
    local num, h, w = line:match('<page number="(%d+)"[^>]-height="(%d+)" width="(%d+)"')
    if num then page = { n = tonumber(num), h = tonumber(h), w = tonumber(w), texts = {} }; d.pages[#d.pages + 1] = page end
    local id, size, family = line:match('<fontspec id="(%d+)" size="(%d+)" family="([^"]*)"')
    if id then d.fonts[id] = { size = tonumber(size), family = family:gsub("^%u%u%u%u%u%u%+", ""), chars = 0 } end
    local top, left, width, height, font, text = line:match('<text top="(%d+)" left="(%d+)" width="(%d+)" height="(%d+)" font="(%d+)">(.*)</text>')
    if top and page then
      text = text:gsub("<[^>]+>", "")
      page.texts[#page.texts + 1] = { top = tonumber(top), left = tonumber(left), w = tonumber(width), h = tonumber(height), font = font, text = text }
      if d.fonts[font] then d.fonts[font].chars = d.fonts[font].chars + #text end
    end
    if line:match("<outline>") then depth = depth + 1 elseif line:match("</outline>") then depth = depth - 1 end
    local ip, it = line:match('<item page="(%d+)">(.*)</item>')
    if ip then d.outline[#d.outline + 1] = { page = tonumber(ip), title = it:gsub("<[^>]+>", ""), depth = depth } end
  end
  parsed = d
  return d
end
local function body_font(d)
  local best
  for id, f in pairs(d.fonts) do if not best or f.chars > best.chars then best = f; best.id = id end end
  return best
end
local function is_serif(fam)
  fam = fam:lower()
  for _, p in ipairs({ "times", "termes", "nimbus", "libertin", "garamond", "palatino", "pagella", "charter", "minion", "cambria", "georgia", "stix", "crimson", "baskerville", "caslon", "lmroman", "cmr", "latin modern roman", "computer modern", "utopia", "erewhon", "source serif", "noto serif", "dejavu serif", "liberation serif", "gentium", "alegreya", "merriweather", "charis", "bookman", "century", "schola", "bonum", "newtx", "txfonts", "tex gyre termes" }) do
    if fam:find(p, 1, true) then return true end
  end
  return false
end
local function is_times(fam) fam = fam:lower(); return fam:find("times", 1, true) or fam:find("termes", 1, true) or fam:find("nimbus", 1, true) or fam:find("newtx", 1, true) or fam:find("liberation serif", 1, true) end

rule("pdf-file", "pdf", "check", "polish", "the PDF exists, is A4, under the faculty's 15 MB, with title and author metadata, all fonts embedded and none Type 3", function()
  if not C.exists(pdf()) then fail(nil, nil, "no " .. pdf() .. ": build first"); return end
  if not C.have("pdfinfo") then warn(nil, nil, "pdfinfo not installed (poppler-utils): skipped"); return end
  local info = C.run(string.format("pdfinfo %q", pdf())) or ""
  local w, h = info:match("Page size:%s+([%d%.]+) x ([%d%.]+) pts")
  w, h = tonumber(w), tonumber(h)
  if not (w and math.abs(w - 595.3) < 3 and math.abs(h - 841.9) < 3) then fail(nil, nil, string.format("page size %s x %s pt is not A4", tostring(w), tostring(h))) end
  local title = C.trim(info:match("Title:%s*([^\n]*)") or "")
  local author = C.trim(info:match("Author:%s*([^\n]*)") or "")
  if title == "" or title:match("TODO") or title:match("Elektronikus terel") then fail("thesis.tex", nil, "PDF title metadata is empty or a placeholder: set \\vikcim") end
  if author == "" or author:match("Gipsz") then fail("thesis.tex", nil, "PDF author metadata is empty or the sample author") end
  local size = lfs.attributes(pdf(), "size") or 0
  if size > 15 * 1024 * 1024 then fail(nil, nil, string.format("PDF is %.1f MB; the faculty allows 15 MB", size / 1048576))
  elseif size > 10 * 1024 * 1024 then warn(nil, nil, string.format("PDF is %.1f MB; the faculty allows 15 MB", size / 1048576)) end
  local fonts = C.run(string.format("pdffonts %q", pdf())) or ""
  local n = 0
  for l in fonts:gmatch("[^\n]+") do
    n = n + 1
    if n > 2 then
      local name, typ, emb = l:match("^(%S+)%s+(.-)%s+%S+%s+(%a+)%s+%a+%s+%a+%s+%d+")
      if emb == "no" then fail(nil, nil, "font not embedded: " .. (name or l)) end
      if typ and typ:match("Type 3") then fail(nil, nil, "Type 3 font (bitmap): " .. (name or l)) end
    end
  end
  local pages = tonumber(info:match("Pages:%s*(%d+)")) or 0
  return string.format("pages=%d size=%.1fMB", pages, size / 1048576)
end)

rule("pdf-font", "pdf", "check", "polish", "the body font is a serif at 12 pt (Times New Roman or another readable serif, the call says)", function()
  local d = doc(); if not d then warn(nil, nil, "pdftohtml not installed: skipped"); return end
  local p = profile()
  local bf = body_font(d); if not bf then fail(nil, nil, "no text found in the PDF"); return end
  if not is_serif(bf.family) then fail("include/packages.tex", nil, string.format("body font %s is not a serif; the %s asks for Times New Roman or another readable serif", bf.family, p.name))
  elseif not is_times(bf.family) then warn("include/packages.tex", nil, string.format("body font is %s, a serif but not Times; the call names Times New Roman, and Times sets about seven percent more text per page", bf.family)) end
  if bf.size < p.size[1] or bf.size > p.size[2] then fail("thesis.tex", nil, string.format("body font size is %d pt; the %s asks for %s", bf.size, p.name, C.opts.profile == "tdk" and "12 pt" or "11-12 pt")) end
  return string.format("font=%s size=%dpt", bf.family, bf.size)
end)

rule("pdf-spacing", "pdf", "check", "polish", "line spacing of the body text is single (the call) or one-and-a-half (a thesis), measured from the line pitch", function()
  local d = doc(); if not d then warn(nil, nil, "pdftohtml not installed: skipped"); return end
  local p = profile(); local bf = body_font(d); if not bf then return end
  local deltas = {}
  for _, page in ipairs(d.pages) do
    local prev
    for _, t in ipairs(page.texts) do
      if t.font == bf.id and t.w > page.w * 0.5 then -- full lines of body text only
        if prev and t.top > prev.top then local dt = t.top - prev.top; if dt < bf.size * 3 then deltas[#deltas + 1] = dt end end
        prev = t
      end
    end
  end
  local pitch = C.median(deltas); if not pitch then warn(nil, nil, "not enough body text lines to measure"); return end
  local ratio = pitch / bf.size
  if ratio < p.pitch[1] or ratio > p.pitch[2] then
    fail("thesis.tex", nil, string.format("line pitch is %.1f pt at %d pt, %.2f times the font size; the %s asks for %s", pitch, bf.size, ratio, p.name, C.opts.profile == "tdk" and "single spacing (about 1.2)" or "one-and-a-half spacing (about 1.8)"))
  end
  return string.format("pitch=%.1fpt ratio=%.2f", pitch, ratio)
end)

rule("pdf-margins", "pdf", "check", "polish", "margins on every text page are within the call's 1.5-3.5 cm (a thesis: 2.5 cm plus binding), measured from the text", function()
  local d = doc(); if not d then warn(nil, nil, "pdftohtml not installed: skipped"); return end
  local p = profile(); local bf = body_font(d); if not bf then return end
  local worst = { left = 1e9, right = 1e9, top = 1e9, bottom = 1e9 }; local worstpage = {}
  local typical = { left = {}, right = {}, top = {}, bottom = {} }
  for _, page in ipairs(d.pages) do
    local body = 0; for _, t in ipairs(page.texts) do if t.font == bf.id then body = body + 1 end end
    if body >= 10 then
      local l, r, tp, b = 1e9, 0, 1e9, 0
      for _, t in ipairs(page.texts) do
        local f = d.fonts[t.font]
        local pagenum = t.text:match("^%s*%d+%s*$") and t.top > page.h * 0.9
        if f and f.size >= 9 and not pagenum then
          l = math.min(l, t.left); r = math.max(r, t.left + t.w); tp = math.min(tp, t.top); b = math.max(b, t.top + t.h)
        end
      end
      local m = { left = l / MM, right = (page.w - r) / MM, top = tp / MM, bottom = (page.h - b) / MM }
      for k, v in pairs(m) do
        typical[k][#typical[k] + 1] = v
        if v < worst[k] then worst[k] = v; worstpage[k] = page.n end
      end
    end
  end
  if #typical.left == 0 then warn(nil, nil, "no text pages found"); return end
  for _, k in ipairs({ "left", "right", "top", "bottom" }) do
    -- the smallest margin over the text pages: chapter openings and short last pages leave more room, which is not a wide margin
    if worst[k] < p.margin[1] - 1.5 then fail(nil, nil, string.format("%s margin is %.1f mm on page %d; the %s asks for at least %d mm", k, worst[k], worstpage[k], p.name, p.margin[1])) end
    if worst[k] > p.margin[2] + 1 then fail(nil, nil, string.format("%s margin is at least %.1f mm on every page; the %s allows at most %d mm", k, worst[k], p.name, p.margin[2])) end
  end
  return string.format("min l/r/t/b=%.0f/%.0f/%.0f/%.0f mm", worst.left, worst.right, worst.top, worst.bottom)
end)

rule("pdf-smalltext", "pdf", "advice", "polish", "text below 10 pt, which the call forbids in figures and tables (labels included); listings and footnotes show up here too", function()
  local d = doc(); if not d then warn(nil, nil, "pdftohtml not installed: skipped"); return end
  local perpage, total, smallest = {}, 0, 99
  for _, page in ipairs(d.pages) do
    for _, t in ipairs(page.texts) do
      local f = d.fonts[t.font]
      if f and f.size < 10 and #C.trim(t.text) > 0 then perpage[page.n] = (perpage[page.n] or 0) + 1; total = total + 1; smallest = math.min(smallest, f.size) end
    end
  end
  local pages = {}
  for n, c in pairs(perpage) do pages[#pages + 1] = n end
  table.sort(pages)
  if total > 0 then
    local list = {}
    for i, n in ipairs(pages) do if i <= 12 then list[#list + 1] = string.format("%d (%d)", n, perpage[n]) end end
    warn(nil, nil, string.format("%d text runs below 10 pt, smallest %d pt, on pages %s%s: figure labels and table text must be readable in print", total, smallest, table.concat(list, ", "), #pages > 12 and ", ..." or ""))
  end
  return string.format("runs<10pt=%d pages=%d", total, #pages)
end)

rule("pdf-pages", "pdf", "check", "final", "main text pages counted from the PDF outline, first chapter to the page before the back matter: 30-35 for the TDK", function()
  local d = doc(); if not d then warn(nil, nil, "pdftohtml not installed: skipped"); return end
  local p = profile()
  local start, stop
  for _, it in ipairs(d.outline) do
    if it.depth == 1 then
      local t = it.title
      if not start and (t:match("^1%s") or t:match("^Chapter 1") or t:match("^Introduction") or t:match("^Bevezet")) then start = it.page
      elseif start and not stop and (t:match("Acknowledg") or t:match("Köszönet") or t:match("List of Figures") or t:match("Ábrák") or t:match("Bibliograph") or t:match("References") or t:match("Irodalom") or t:match("Appendi") or t:match("Függelék") or t:match("Hallgatói nyilatkozat") or t:match("Acronyms")) then stop = it.page - 1 end
    end
  end
  if not start then fail(nil, nil, "no Introduction in the PDF outline: cannot count the main text (hyperref bookmarks missing?)"); return end
  stop = stop or #d.pages
  local n = stop - start + 1
  local msg = string.format("main text is %d PDF pages (%d-%d by the outline); the %s asks for %d-%d", n, start, stop, p.name, p.pages[1], p.pages[2])
  if n < p.pages[1] or n > p.pages[2] then if p.pages_gate then fail(nil, nil, msg) else warn(nil, nil, msg) end else note(nil, nil, msg) end
  return string.format("pages=%d", n)
end)

rule("pdf-parts", "pdf", "check", "final", "the parts the form requires are in the PDF: abstracts in both languages, the AI declaration, the table of contents; and the parts it forbids are not", function()
  if not C.have("pdftotext") then warn(nil, nil, "pdftotext not installed: skipped"); return end
  local p = profile()
  local text = C.run(string.format("pdftotext -layout %q -", pdf())) or ""
  for _, alt in ipairs(p.needs) do
    local found = false
    for a in alt:gmatch("[^|]+") do if text:find(a, 1, true) then found = true end end
    if not found then fail(nil, nil, "missing from the PDF: " .. alt:gsub("|", " or ")) end
  end
  for _, f in ipairs(p.forbids) do if text:find(f, 1, true) then warn(nil, nil, f .. " is in the PDF; the TDK call says to leave the student declaration out") end end
  if not (text:find("Contents", 1, true) or text:find("Tartalomjegyzék", 1, true)) then fail(nil, nil, "no table of contents") end
  if not (text:find("Budapest University of Technology", 1, true) or text:find("Budapesti Műszaki", 1, true)) then fail(nil, nil, "the title page does not name the university") end
  if text:find("TODO", 1, true) then
    local n = C.count(text, "TODO"); fail(nil, nil, n .. " TODO still printed in the PDF")
  end
  if text:find("Beat%.") or text:find("Establishes:") then fail(nil, nil, "beats are printed: this is the draft, not the reviewer build") end
end)
