#!/usr/bin/env texlua
-- Lint for the TDK paper: one rule per subcommand, so CI shows them one by one.
--
--   texlua scripts/lint.lua <rule> [--dir <builddir>] [--doc <jobname>]
--   texlua scripts/lint.lua all          every rule, gates first
--   texlua scripts/lint.lua list         the rules and what each checks
--
-- Rules read the sources (thesis.tex, content/*.tex, bib/*.bib) and, where noted, the build
-- log and aux files of <builddir>/<jobname> (default: ./thesis). Findings print as
-- "file:line: message"; under GitHub Actions they print as annotations and each rule appends
-- a row to the job summary. Exit status is 1 when a gate fails. "burndown" never fails:
-- it prints the counts a draft should drive to zero.
--
-- Needs only texlua, which ships with TeX Live, so it runs wherever the paper builds.

local lfs = require("lfs")

local opts = { dir = ".", doc = "thesis" }
local args = {}
do
  local i = 1
  while i <= #arg do
    if arg[i] == "--dir" then opts.dir = arg[i + 1]; i = i + 2
    elseif arg[i] == "--doc" then opts.doc = arg[i + 1]; i = i + 2
    else args[#args + 1] = arg[i]; i = i + 1 end
  end
end

local CONTENT = {}
for f in lfs.dir("content") do
  if f:match("^%d%d%-.*%.tex$") then CONTENT[#CONTENT + 1] = "content/" .. f end
end
table.sort(CONTENT)
local MAIN = {}  -- the main-text chapters, 01..07
for _, f in ipairs(CONTENT) do if f:match("content/0[1-7]") then MAIN[#MAIN + 1] = f end end

------------------------------------------------------------------------------- helpers
local function readfile(p)
  local h = io.open(p, "r"); if not h then return nil end
  local s = h:read("a"); h:close(); return s
end
local function lines(p)
  local t = {}
  for l in (readfile(p) or ""):gmatch("([^\n]*)\n?") do t[#t + 1] = l end
  if t[#t] == "" then t[#t] = nil end
  return t
end
local function strip_comment(l) return (l:gsub("\\%%", "\1"):gsub("%%.*$", ""):gsub("\1", "\\%%")) end
local function each_line(files, fn) -- fn(file, lineno, line_without_comments)
  for _, f in ipairs(files) do
    for n, l in ipairs(lines(f)) do fn(f, n, strip_comment(l)) end
  end
end
local function exists(p) return lfs.attributes(p) ~= nil end
local function bpath(p) return opts.dir .. "/" .. p end

local gh = os.getenv("GITHUB_ACTIONS") ~= nil
local summary = os.getenv("GITHUB_STEP_SUMMARY")
local findings = {}
local function finding(level, file, line, msg)
  findings[#findings + 1] = { level = level, file = file, line = line, msg = msg }
  if gh then
    local loc = file and ("file=" .. file .. (line and ("," .. "line=" .. line) or "")) or ""
    io.write(string.format("::%s %s::%s\n", level, loc, msg))
  else
    io.write(string.format("%s%s %s\n", file and (file .. (line and (":" .. line) or "") .. ":") or "", level == "error" and " FAIL" or "     ", msg))
  end
end
local function fail(file, line, msg) finding("error", file, line, msg) end
local function warn(file, line, msg) finding("warning", file, line, msg) end
local function note(file, line, msg) finding("notice", file, line, msg) end

local function report(rule, gate, counts)
  local errors, warnings = 0, 0
  for _, f in ipairs(findings) do
    if f.level == "error" then errors = errors + 1 elseif f.level == "warning" then warnings = warnings + 1 end
  end
  local ok = errors == 0
  local status = ok and "ok" or "FAIL"
  if not gate then status = errors == 0 and "clean" or "open" end
  io.write(string.format("%s %-13s %d error(s), %d warning(s)%s\n", ok and "ok  " or "FAIL", rule, errors, warnings, counts and (" " .. counts) or ""))
  if summary then
    local h = io.open(summary, "a")
    if h then
      local icon = gate and (ok and ":white_check_mark:" or ":x:") or ((errors + warnings == 0) and ":white_check_mark:" or ":hourglass:")
      h:write(string.format("| %s | %s | %d | %d | %s |\n", rule, icon, errors, warnings, counts or ""))
      h:close()
    end
  end
  return gate and ok
end

------------------------------------------------------------------------------- label index
local function collect_labels_and_refs(files)
  local labels, refs = {}, {} -- labels[key] = {file,line,sub}; refs[key] = count
  local depth = 0 -- inside subfigure/subtable: labels there are covered by the parent float
  each_line(files, function(f, n, l)
    for key in l:gmatch("\\label{([^}]*)}") do labels[key] = { file = f, line = n, sub = depth > 0 } end
    depth = depth + select(2, l:gsub("\\begin{sub[a-z]+}", "")) - select(2, l:gsub("\\end{sub[a-z]+}", ""))
    for keys in l:gmatch("\\[Cc]ref{([^}]*)}") do for key in keys:gmatch("[^,%s]+") do refs[key] = (refs[key] or 0) + 1 end end
    for keys in l:gmatch("\\ref{([^}]*)}") do for key in keys:gmatch("[^,%s]+") do refs[key] = (refs[key] or 0) + 1 end end
    for key in l:gmatch("\\[Tt]plref{([^}]*)}") do refs[key] = (refs[key] or 0) + 1 end
  end)
  return labels, refs
end
local function refs_in(file, pattern)
  local n = 0
  each_line({ file }, function(_, _, l)
    for keys in l:gmatch("\\[Cc]?ref{([^}]*)}") do for key in keys:gmatch("[^,%s]+") do if key:match(pattern) then n = n + 1 end end end
  end)
  return n
end
local function file_has(file, pattern) return (readfile(file) or ""):find(pattern) ~= nil end

------------------------------------------------------------------------------- rules
local RULES, ORDER = {}, {}
local function rule(name, gate, desc, fn) RULES[name] = { gate = gate, desc = desc, fn = fn }; ORDER[#ORDER + 1] = name end

rule("build", true, "the build log: undefined references and citations, multiply defined labels, missing files, missing fonts", function()
  local log = bpath(opts.doc .. ".log")
  if not exists(log) then fail(nil, nil, "no " .. log .. ": build first"); return end
  local pats = {
    { "Reference `([^']*)' on page %d+ undefined", "undefined reference %s" },
    { "Citation `([^']*)' on page %d+ undefined", "undefined citation %s" },
    { "Label `([^']*)' multiply defined", "label %s multiply defined" },
    { "File `([^']*)' not found", "file %s not found" },
    { "Font ([^%s]*) not found", "font %s not found" },
  }
  local seen = {}
  for _, l in ipairs(lines(log)) do
    for _, p in ipairs(pats) do
      local m = l:match(p[1])
      if m and not seen[p[2] .. m] then seen[p[2] .. m] = true; fail(nil, nil, string.format(p[2], m)) end
    end
    if l:match("^! ") then fail(nil, nil, "TeX error: " .. l) end
  end
end)

rule("overfull", true, "overfull boxes in the build log: text or tables running into the margin", function()
  local log = bpath(opts.doc .. ".log")
  if not exists(log) then fail(nil, nil, "no " .. log .. ": build first"); return end
  local ls = lines(log)
  for i, l in ipairs(ls) do
    local pt, from = l:match("^Overfull \\hbox %(([%d%.]+)pt too wide%) in paragraph at lines (%d+)")
    if pt then
      local sample = (ls[i + 1] or ""):gsub("\\[%w/%(%)%.]+%s*", ""):gsub("%s+", " ")
      fail(nil, nil, string.format("overfull by %spt near log line %d: %s", pt, i, sample:sub(1, 60)))
    elseif l:match("^Overfull \\hbox") then
      fail(nil, nil, l)
    end
  end
end)

rule("pages", true, "main text between the page:main:start and page:main:end labels is 30-35 pages", function()
  local s, e
  local auxes = { bpath(opts.doc .. ".aux") }
  for _, f in ipairs(MAIN) do auxes[#auxes + 1] = bpath(f:gsub("%.tex$", ".aux")) end
  for _, a in ipairs(auxes) do
    for _, l in ipairs(lines(a)) do
      s = s or tonumber(l:match("^\\newlabel{page:main:start}{{[^}]*}{(%d+)}"))
      e = e or tonumber(l:match("^\\newlabel{page:main:end}{{[^}]*}{(%d+)}"))
    end
  end
  if not (s and e) then fail(nil, nil, "page:main:start or page:main:end label missing (build first)"); return end
  local p = e - s + 1
  if p < 30 or p > 35 then fail("content/01-introduction.tex", 2, string.format("main text is %d pages (%d-%d); the call asks for 30-35, about 1 point off per 3 pages", p, s, e))
  else note(nil, nil, string.format("main text %d pages (%d-%d)", p, s, e)) end
  return string.format("pages=%d", p)
end)

rule("traceability", true, "every tagged item is used where the argument needs it: requirements in the gap matrix and the correctness table, threats answered by guarantees, guarantees proved or checked, contributions restated in the conclusion, research questions answered", function()
  local labels = collect_labels_and_refs(MAIN)
  local function need(prefix, where, pattern, what)
    for key, at in pairs(labels) do
      if key:match("^" .. prefix .. ":") and refs_in(where, "^" .. key:gsub("%p", "%%%0") .. "$") == 0 then
        fail(at.file, at.line, string.format("%s is never referenced in %s: %s", key, where, what))
      end
    end
  end
  need("req", "content/06-related-work.tex", nil, "every requirement is a row of the gap matrix")
  need("req", "content/05-evaluation.tex", nil, "every requirement is checked in the evaluation")
  need("c", "content/07-conclusion.tex", nil, "every contribution is restated with its evidence")
  need("rq", "content/05-evaluation.tex", nil, "every research question is answered")
  need("thr", "content/03-approach.tex", nil, "every threat is met by a guarantee or an assumption")
  need("g", "content/05-evaluation.tex", nil, "every guarantee has a row in the correctness table")
  need("asm", "content/03-approach.tex", nil, "every assumption is used by a guarantee or a proof")
  -- the conclusion must point back at the evaluation
  if refs_in("content/07-conclusion.tex", "^chap:evaluation$") + refs_in("content/07-conclusion.tex", "^rq:") + refs_in("content/07-conclusion.tex", "^fig:") + refs_in("content/07-conclusion.tex", "^tab:") == 0 then
    fail("content/07-conclusion.tex", 1, "the conclusion cites no evaluation result: restate each contribution with its evidence")
  end
end)

rule("outline", true, "the outline follows the spine: chapters renamed where the template says so, the running example in every chapter, a gap matrix, research questions, and the leading figure", function()
  for _, f in ipairs(MAIN) do
    if not file_has(f, "\\begin{runningexample}") then fail(f, 1, "no runningexample box: every chapter returns to the running example") end
  end
  if file_has("content/03-approach.tex", "\\chapter{Approach}") then warn("content/03-approach.tex", 2, "the chapter is still called Approach: rename it after your method") end
  for _, f in ipairs(MAIN) do
    each_line({ f }, function(file, n, l)
      local t = l:match("\\section{(.-)}") or l:match("\\chapter{(.-)}")
      if t and t:match("TODO") then fail(file, n, "heading still a TODO: " .. t) end
    end)
  end
  if not file_has("content/06-related-work.tex", "\\label{tab:related}") then fail("content/06-related-work.tex", 1, "no gap matrix (tab:related)") end
  if not file_has("content/05-evaluation.tex", "\\begin{rqlist}") then fail("content/05-evaluation.tex", 1, "no research questions (rqlist)") end
  if not file_has("content/01-introduction.tex", "\\label{fig:overview}") then fail("content/01-introduction.tex", 1, "no leading figure (fig:overview)") end
  local ex = (readfile("thesis.tex") or ""):match("\\newcommand{\\exname}{([^}]*)}") or ""
  if ex:match("TODO") then fail("thesis.tex", 1, "\\exname is still a TODO: name the running example") end
end)

rule("figures", true, "every figure, table, listing and algorithm is referenced from the text and has a caption; raster images are flagged", function()
  local labels, refs = collect_labels_and_refs(MAIN)
  for key, at in pairs(labels) do
    if key:match("^fig:") or key:match("^tab:") or key:match("^lst:") or key:match("^alg:") then
      if (refs[key] or 0) == 0 and not at.sub then fail(at.file, at.line, key .. " is never referenced from the text") end
    end
  end
  each_line(MAIN, function(f, n, l)
    local g = l:match("\\includegraphics%[?[^%]]*%]?{([^}]*)}")
    if g and (g:match("%.png$") or g:match("%.jpe?g$")) then warn(f, n, "raster image " .. g .. ": figures are vector unless there is a written reason") end
  end)
  -- a caption without a label, or a label before the caption, breaks references
  for _, f in ipairs(MAIN) do
    local ls = lines(f); local infloat, hascap, haslab, start = nil, false, false, 0
    for n, raw in ipairs(ls) do
      local l = strip_comment(raw)
      local b = l:match("\\begin{(figure%*?)}") or l:match("\\begin{(table%*?)}") or l:match("\\begin{(listing)}") or l:match("\\begin{(algorithm)}")
      if b then infloat, hascap, haslab, start = b, false, false, n end
      if infloat then
        if l:match("\\caption") then hascap = true end
        if l:match("\\label{") then haslab = true end
        if l:match("\\end{" .. infloat:gsub("%*", "%%*") .. "}") then
          if not hascap then fail(f, start, infloat .. " without a caption") end
          if not haslab then warn(f, start, infloat .. " without a label") end
          infloat = nil
        end
      end
    end
  end
end)

rule("acronyms", true, "every acronym used is declared, every declared one is used, and none is spelled out by hand", function()
  local declared, used = {}, {}
  each_line({ "content/acronyms.tex" }, function(f, n, l)
    local k = l:match("\\DeclareAcronym{([^}]*)}"); if k then declared[k] = { file = f, line = n } end
  end)
  each_line(MAIN, function(f, n, l)
    for k in l:gmatch("\\[Aa]c[slpf]*%*?{([^}]*)}") do
      used[k] = true
      if not declared[k] then fail(f, n, "acronym " .. k .. " is not declared in content/acronyms.tex") end
    end
  end)
  for k, at in pairs(declared) do if not used[k] then warn(at.file, at.line, "acronym " .. k .. " is declared but never used: remove it") end end
end)

rule("bib", true, "the bibliography: every cited key exists; entries have a title, a year and an author; DOIs are bare, not URLs", function()
  local keys = {}
  for _, b in ipairs({ "bib/references.bib", "bib/zotero.bib", "bib/guide.bib" }) do
    local s = readfile(b) or ""
    for entry in s:gmatch("\n@(%w+%b{})") do
      local kind, body = entry:match("^(%w+)(%b{})"); body = body:sub(2, -2)
      local key = body:match("^%s*([^,%s]+)")
      if key and kind:lower() ~= "comment" and kind:lower() ~= "string" and kind:lower() ~= "preamble" then
        keys[key] = true
        local function has(fld) return body:lower():match("\n%s*" .. fld .. "%s*=") ~= nil end
        if not has("title") then fail(b, nil, key .. ": no title") end
        if not has("year") and not has("date") then fail(b, nil, key .. ": no year") end
        if not (has("author") or has("editor") or kind:lower() == "misc" or kind:lower() == "manual") then fail(b, nil, key .. ": no author") end
        local doi = body:match("\n%s*[dD][oO][iI]%s*=%s*[{\"]([^}\"]*)")
        if doi and doi:match("^https?://") then warn(b, nil, key .. ": doi field is a URL; give the bare DOI") end
        if doi and doi:match("TODO") then warn(b, nil, key .. ": DOI still a TODO") end
      end
    end
  end
  each_line(MAIN, function(f, n, l)
    local pos = 1
    while true do
      local s, e = l:find("\\cite[tp]?%*?", pos); if not s then break end
      pos = e + 1
      if l:sub(pos, pos) == "[" then local _, be = l:find("%b[]", pos); pos = (be or pos) + 1 end
      if l:sub(pos, pos) == "[" then local _, be = l:find("%b[]", pos); pos = (be or pos) + 1 end
      local bs, be = l:find("%b{}", pos)
      if bs == pos then
        for k in l:sub(bs + 1, be - 1):gmatch("[^,%s]+") do if not keys[k] then fail(f, n, "cited key " .. k .. " is in no .bib file") end end
        pos = be + 1
      end
    end
  end)
end)

rule("placeholders", false, "what the template left for you: TODO strings, placeholder figures and tables, sample citations in the gap matrix, the Zenodo DOI", function()
  local todo, ph = 0, 0
  local files = {}
  for _, f in ipairs(CONTENT) do files[#files + 1] = f end
  files[#files + 1] = "thesis.tex"; files[#files + 1] = "bib/references.bib"
  for _, f in ipairs(files) do
    local t, p, first = 0, 0, nil
    each_line({ f }, function(_, n, l)
      local c = select(2, l:gsub("TODO", "")); if c > 0 then t = t + c; first = first or n end
      if l:match("[Pp]laceholder") then p = p + 1 end
      if l:match("lamport1978time") or l:match("w3c2025vcdm") then warn(f, n, "sample citation from the template still used") end
    end)
    todo, ph = todo + t, ph + p
    if t + p > 0 then warn(f, first, string.format("%d TODO, %d placeholder figure or table", t, p)) end
  end
  return string.format("todo=%d placeholders=%d", todo, ph)
end)

rule("beats", false, "beats and notes still printing: the skeleton is done when every beat has become prose", function()
  local beats, todos = 0, 0
  each_line(MAIN, function(f, n, l)
    if l:match("\\beat{") then beats = beats + 1; note(f, n, "beat") end
    if l:match("\\todo") or l:match("\\atodo") or l:match("\\advisortodo") then todos = todos + 1 end
  end)
  return string.format("beats=%d notes=%d", beats, todos)
end)

rule("burndown", false, "one line of JSON with the counts a draft drives to zero, for CI to collect over time", function()
  local function count(files, pat) local c = 0; each_line(files, function(_, _, l) c = c + select(2, l:gsub(pat, "")) end); return c end
  local pages = 0
  local auxes = {}
  for _, f in ipairs(MAIN) do auxes[#auxes + 1] = bpath(f:gsub("%.tex$", ".aux")) end
  local s, e
  for _, a in ipairs(auxes) do for _, l in ipairs(lines(a)) do
    s = s or tonumber(l:match("^\\newlabel{page:main:start}{{[^}]*}{(%d+)}")); e = e or tonumber(l:match("^\\newlabel{page:main:end}{{[^}]*}{(%d+)}")) end end
  if s and e then pages = e - s + 1 end
  local j = string.format('{"date":"%s","pages":%d,"todo":%d,"beats":%d,"notes":%d,"placeholders":%d,"citations":%d,"figures":%d}',
    os.date("!%Y-%m-%d"), pages, count(CONTENT, "TODO"), count(MAIN, "\\beat{"), count(MAIN, "\\a?d?v?i?s?o?r?todo%["),
    count(CONTENT, "[Pp]laceholder"), count(MAIN, "\\cite[tp]?{"), count(MAIN, "\\label{fig:"))
  io.write(j, "\n")
  return j
end)

------------------------------------------------------------------------------- main
local cmd = args[1]
if not cmd or cmd == "list" then
  io.write("rules (gates fail the build; the rest report):\n")
  for _, n in ipairs(ORDER) do io.write(string.format("  %-13s %s  %s\n", n, RULES[n].gate and "gate  " or "report", RULES[n].desc)) end
  os.exit(0)
end
local todo = cmd == "all" and ORDER or { cmd }
if summary and (cmd == "all" or os.getenv("LINT_SUMMARY_HEADER")) then
  local h = io.open(summary, "a"); if h then h:write("\n| Rule | Status | Errors | Warnings | Counts |\n|---|---|---|---|---|\n"); h:close() end
end
local allok = true
for _, name in ipairs(todo) do
  local r = RULES[name]
  if not r then io.stderr:write("unknown rule " .. name .. "; try: texlua scripts/lint.lua list\n"); os.exit(2) end
  findings = {}
  local counts = r.fn()
  local ok = report(name, r.gate, counts)
  if r.gate and not ok then allok = false end
end
os.exit(allok and 0 or 1)
