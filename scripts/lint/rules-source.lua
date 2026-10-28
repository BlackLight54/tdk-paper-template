-- Rules on the LaTeX sources: the template's structures, the argument's traceability, and the
-- conventions the guide asks for. When a structure is absent the rule says so instead of
-- passing on nothing.
local C = require("lintcore")
local lfs = require("lfs")
local rule, fail, warn, note = C.rule, C.fail, C.warn, C.note
local MAIN, CONTENT = C.MAIN, C.CONTENT

-- template structure --------------------------------------------------------------------
rule("frame", "source", "check", "always", "the template's frame is still there: its files, the chapter roles the essentials need, the preamble's macros, the packages, the class options, the spacing, the phase and the running example's name; what a paper must contain is the essentials' job", function()
  -- the files thesis.tex includes are named NN-name.tex, numbered in reading order (00-abstract,
  -- 01-introduction, ...); the glossary, loaded by the preamble, has no number
  local last = -1
  for _, f in ipairs(CONTENT) do
    if f ~= C.FILES.glossary then
      local nn = f:match("([^/]+)%.tex$"):match("^(%d%d)%-")
      if not nn then warn(f, nil, "content files are named NN-name.tex in reading order, " .. string.format("%02d", last + 1) .. "-<name>.tex here")
      elseif tonumber(nn) <= last then warn(f, nil, "numbered " .. nn .. " but included after " .. string.format("%02d", last) .. ": number the files in reading order")
      else last = tonumber(nn) end
    end
  end
  if not C.roles_ok({ "approach", "conclusion", "evaluation", "intro", "related" }) then return end
  for _, f in ipairs({ "thesis.tex", "reviewer.tex", "include/packages.tex", "include/preamble.tex", "include/thesis-en.tex", "include/titlepage-tdk.tex", "include/macros.tex", C.FILES.glossary or "content/glossary.tex", C.FILES.abstract, C.FILES.aidecl, "scripts/lint.lua", "docs/TDK2025_biralati_pontozolap_hallgatoi.pdf" }) do
    if not C.exists(f) then fail(nil, nil, "missing from the template: " .. f) end
  end
  for _, b in ipairs(C.BIB) do if not C.exists(b) then fail("thesis.tex", nil, "\\bibliography names " .. b .. ", which does not exist") end end
  if #MAIN == 0 then fail(nil, nil, "no chapter files: no file thesis.tex includes has a numbered \\chapter"); return end
  if not C.FILES.abstract then fail(nil, nil, "no abstract file (a content file with \\chapter*{Abstract})") end
  if not C.FILES.aidecl then fail(nil, nil, "no AI declaration file (\\label{aidecl})") end
  if not C.FILES.glossary then fail(nil, nil, "no glossary file (\\newabbreviation or \\newglossaryentry in a file thesis.tex loads)") end
  if not (C.readfile("thesis.tex") or ""):match("\\newcommand{\\lintphase}{%a+}") then fail("thesis.tex", nil, "no \\lintphase in thesis.tex: the lint needs the phase (plan, draft, polish, final)") end
  local pre = C.readfile("include/preamble.tex") or ""
  for _, m in ipairs({ "runningexample", "NewTagList", "beat", "gapyes", "atodo" }) do
    if not pre:find(m, 1, true) then fail("include/preamble.tex", nil, "the preamble no longer defines " .. m) end
  end
  local pk = C.readfile("include/packages.tex") or ""
  for _, m in ipairs({ "TeX Gyre Termes", "cleveref", "natbib", "todonotes", "glossaries-extra", "minted", "booktabs", "pgfplots" }) do
    if not pk:find(m, 1, true) then fail("include/packages.tex", nil, "packages.tex no longer sets up " .. m) end
  end
  local th = C.readfile("thesis.tex") or ""
  if not th:match("\\documentclass%[[^%]]*12pt") then fail("thesis.tex", 1, "the class options no longer say 12pt") end
  if not th:match("\\documentclass%[[^%]]*a4paper") then fail("thesis.tex", 1, "the class options no longer say a4paper") end
  if not th:find("\\singlespacing", 1, true) then fail("thesis.tex", nil, "\\singlespacing is gone") end
  if not th:match("\\marginsize{15mm}{15mm}{15mm}{15mm}") then warn("thesis.tex", nil, "the margins are not the template's 15 mm; the call allows 1.5-3.5 cm, pdf-margins measures the result") end
  if not th:find("\\exname", 1, true) then fail("thesis.tex", nil, "\\exname (the running example's name) is not defined") end
end)

-- build log ------------------------------------------------------------------------------
-- the paper's shape --------------------------------------------------------------------
local main_chapters = C.main_chapters
local function prose_words(f, skip_todo)
  local n = 0
  for _, l in ipairs(C.prose_lines(f)) do
    if not (skip_todo and l:match("TODO")) then for _ in C.prose(l):gmatch("%a%a+") do n = n + 1 end end
  end
  return n
end

rule("roles", "source", "check", "draft", "every chapter has a role: its label is ch:<role> or ch:<role>:<name>, the role one of intro, background, approach, implementation, evaluation, related, conclusion; a role may span several chapters, and a chapter may have two", function()
  local n = 0
  for _, f in ipairs(main_chapters()) do
    n = n + 1
    if not C.ROLES_OF[f] then
      local lab = ((C.readfile(f) or ""):gsub("%%[^\n]*", "")):match("\\label{(ch:[^}]*)}")
      if lab then fail(f, 1, "the chapter label " .. lab .. " names no role: use ch:<role> or ch:<role>:<name> (intro, background, approach, implementation, evaluation, related, conclusion)")
      else fail(f, 1, "no role label: give the chapter \\label{ch:<role>} or \\label{ch:<role>:<name>}") end
    end
  end
  return string.format("chapters=%d", n)
end)

-- a gap is a \tbd or \citeneeded marker, which the draft shows and the todo list counts; typed
-- markers (TBD, [CITE: ...], [?], [forrás?], [link?], XXX, FIXME) print in the reviewer PDF
local TYPED = { { "%f[%w]TBD%f[%W]", "TBD" }, { "%[[Cc][Ii][Tt][Ee]", "[CITE" }, { "%[%?%]", "[?]" },
  { "%[forrás%?%]", "[forrás?]" }, { "%[link%?%]", "[link?]" }, { "%f[%w]XXX+%f[%W]", "XXX" }, { "%f[%w]FIXME%f[%W]", "FIXME" } }
rule("markers", "source", "check", "draft", "gaps are marked with \\tbd{...} or \\citeneeded[...], which the draft shows and the reviewer build hides: never typed as TBD, [CITE], [?] or XXX; at the final phase no marker is left", function()
  local final = C.phase_reached("final")
  local gaps = 0
  for _, f in ipairs(CONTENT) do
    for n, l in ipairs(C.prose_lines(f)) do
      for _, t in ipairs(TYPED) do
        if l:find(t[1]) then fail(f, n, "a typed " .. t[2] .. " prints in the reviewer PDF: write \\tbd{what is missing} or \\citeneeded[which source] instead") end
      end
      for m in l:gmatch("\\(%a+)") do
        if m == "tbd" or m == "citeneeded" then
          gaps = gaps + 1
          if final then fail(f, n, "\\" .. m .. " is still here: fill the gap before the final version") end
        end
      end
    end
  end
  return string.format("gaps=%d", gaps)
end)

rule("chapters", "source", "check", "always", "one chapter per file: no file holds two numbered chapters, and a chapter keeps its text in its own file instead of \\input pieces", function()
  for _, f in ipairs(main_chapters()) do
    local n = 0
    C.each_line({ f }, function(_, ln, l)
      if l:match("\\chapter{") then n = n + 1; if n == 2 then fail(f, ln, "a second chapter in one file: each chapter is its own content/NN-name.tex") end end
      for arg in l:gmatch("\\input%s*(%b{})") do
        local p = arg:sub(2, -2)
        if not p:match("^include/") then warn(f, ln, "\\input{" .. p .. "} pulls part of the chapter from another file: keep the chapter in one file") end
      end
    end)
  end
end)

rule("orphans", "source", "advice", "always", "every .tex file of the paper is included: a file thesis.tex never reaches is text no reader sees", function()
  local reached = {}
  for _, f in ipairs(CONTENT) do reached[f] = true end
  local skip = { include = true, guide = true, scripts = true, docs = true, ["svg-inkscape"] = true }
  local function walk(dir)
    for e in lfs.dir(dir) do
      if e ~= "." and e ~= ".." and not e:match("^%.") and not e:match("^_minted") then
        local p = dir == "." and e or (dir .. "/" .. e)
        local a = lfs.attributes(p)
        if a and a.mode == "directory" then
          if not (dir == "." and skip[e]) then walk(p) end
        elseif dir ~= "." and e:match("%.tex$") and not reached[p] and not C.file_has(p, "\\documentclass") then -- a standalone figure source is its own document
          local w = prose_words(p, false)
          if w > 0 then warn(p, nil, string.format("included nowhere: %d words no reader sees; include them in a chapter or delete the file", w)) end
        end
      end
    end
  end
  walk(".")
end)

-- the roles the essentials cover; a chapter with one of them is measured by the essentials instead
local ESSENTIAL_ROLES = {}
for _, row in ipairs(require("essentials")) do ESSENTIAL_ROLES[row.role] = true end
rule("stubs", "source", "check", "polish", "every main-text chapter the essentials do not cover (background, implementation, a chapter of your own) is written: one with fewer than 150 words of its own prose, beyond the template's skeleton text and TODO lines, is still an outline", function()
  for _, f in ipairs(main_chapters()) do
    local covered = false
    for r in pairs(C.ROLES_OF[f] or {}) do if ESSENTIAL_ROLES[r] then covered = true end end
    if not covered then
      local w = 0
      for _, l in ipairs(C.prose_lines(f)) do w = w + C.own_words(l) end
      if w < 150 then fail(f, 1, string.format("%d word%s of its own prose beyond the template's skeleton: the chapter is still an outline", w, w == 1 and "" or "s")) end
    end
  end
end)

-- sentences of the faculty's thesis template, which a paper copied from it may still carry
local STOCK = {
  "A bevezető tartalmazza a diplomaterv-kiírás elemzését",
  "A bevezető szokás szerint a diplomaterv felépítésével záródik",
  "Ez nem kötelező, akár törölhető is",
  "Jelen dokumentum egy diplomaterv sablon",
  "This document is a \\LaTeX-based skeleton",
  "A Pitagorasz-tételből levezetve",
  "A TeXstudio felülete",
}
rule("stock", "source", "check", "draft", "no text is the faculty template's own: the placeholder sentences of its introduction, abstract, acknowledgement and appendix", function()
  for _, f in ipairs(CONTENT) do
    local s = (C.readfile(f) or ""):gsub("\\%%", ""):gsub("%%[^\n]*", ""):gsub("%s+", " ")
    for _, phrase in ipairs(STOCK) do
      if s:find(phrase, 1, true) then fail(f, nil, "the faculty template's placeholder text is still here: " .. phrase .. " ...") end
    end
  end
end)

rule("spine", "source", "advice", "always", "the chapters follow the spine: the introduction first, nothing after the conclusion, the evaluation after the approach", function()
  local mains = main_chapters()
  local pos = {}
  for i, f in ipairs(mains) do pos[f] = i end
  local function at(r, pick) -- the position of the first or last chapter of a role
    local best
    for _, f in ipairs(C.role_files(r)) do if pos[f] and (not best or pick(pos[f], best)) then best = pos[f] end end
    return best
  end
  local first = function(a, b) return a < b end
  local last = function(a, b) return a > b end
  if C.ROLE.intro and mains[1] and not (C.ROLES_OF[mains[1]] or {}).intro then warn(C.ROLE.intro, 1, "the introduction is not the first chapter") end
  local concl = at("conclusion", last)
  if concl then
    for i = concl + 1, #mains do warn(mains[i], 1, "a chapter after the conclusion: future work and outlook belong in the conclusion, anything else before it") end
  end
  local appr, eval = at("approach", first), at("evaluation", first)
  if appr and eval and eval < appr then warn(mains[eval], 1, "the evaluation comes before the approach it evaluates") end
end)

rule("build", "source", "check", "always", "the build log: undefined references and citations, multiply defined labels, missing files, missing fonts, TeX errors", function()
  local log = C.bpath(C.opts.doc .. ".log")
  if not C.exists(log) then fail(nil, nil, "no " .. log .. ": build first"); return end
  local pats = {
    { "Reference `([^']*)' on page %d+ undefined", "undefined reference %s" },
    { "Citation `([^']*)' on page %d+ undefined", "undefined citation %s" },
    { "Label `([^']*)' multiply defined", "label %s multiply defined" },
    { "File `([^']*)' not found", "file %s not found" },
    { "Font ([^%s]*) not found", "font %s not found" },
  }
  local seen = {}
  for _, l in ipairs(C.lines(log)) do
    for _, p in ipairs(pats) do
      local m = l:match(p[1])
      if m and not seen[p[2] .. m] then seen[p[2] .. m] = true; fail(nil, nil, string.format(p[2], m)) end
    end
    if l:match("^! ") then fail(nil, nil, "TeX error: " .. l) end
  end
end)

rule("overfull", "source", "check", "always", "overfull boxes in the build log: text or tables running into the margin", function()
  local log = C.bpath(C.opts.doc .. ".log")
  if not C.exists(log) then fail(nil, nil, "no " .. log .. ": build first"); return end
  local ls = C.lines(log)
  for i, l in ipairs(ls) do
    local pt, from = l:match("^Overfull \\hbox %(([%d%.]+)pt too wide%) in paragraph at lines (%d+)")
    if pt then
      local sample = (ls[i + 1] or ""):gsub("\\[%w/%(%)%.]+%s*", ""):gsub("%s+", " ")
      fail(nil, nil, string.format("overfull by %spt near log line %d: %s", pt, i, sample:sub(1, 60)))
    elseif l:match("^Overfull \\hbox") then fail(nil, nil, l) end
  end
end)

-- the main text's pages, from the .toc of the last build: from the first numbered chapter to the
-- page before the first unnumbered chapter after it (the acknowledgements, the lists or the
-- bibliography, each of which starts a page); no labels to keep in the sources
local function main_pages()
  local first, stop, numbered
  for _, l in ipairs(C.lines(C.bpath(C.opts.doc .. ".toc"))) do
    local title, page = l:match("^\\contentsline%s*{chapter}(%b{})(%b{})")
    if title then
      local n = title:find("\\numberline", 1, true) ~= nil
      page = tonumber(page:sub(2, -2))
      if n and not first then first = page end
      if not n and numbered and not stop then stop = page end
      numbered = n
    end
  end
  if not (first and stop) then return nil end
  return stop - first, first, stop - 1
end

rule("pages", "source", "check", "final", "main text, from the first numbered chapter to the page before the back matter (read from the .toc), is 30-35 pages", function()
  local p, s, e = main_pages()
  if not p then fail(nil, nil, "no numbered chapter followed by an unnumbered one in " .. C.opts.doc .. ".toc (build first; pdf-pages counts from the outline instead)"); return end
  if p < 30 or p > 35 then fail(C.ROLE.intro, 2, string.format("main text is %d pages (%d-%d); the call asks for 30-35, about 1 point off per 3 pages", p, s, e))
  else note(nil, nil, string.format("main text %d pages (%d-%d)", p, s, e)) end
  return string.format("pages=%d", p)
end)

-- the argument ---------------------------------------------------------------------------
-- what a paper must contain, and whether it is used where the argument needs it, is the
-- essentials rule (rules-essentials.lua); here only the outline's own conventions
rule("outline", "source", "check", "draft", "the outline is final: chapters renamed where the template says so, no TODO heading, no third level of headings, every chapter file has its \\chapter", function()
  if #MAIN == 0 then fail(nil, nil, "no chapter files"); return end
  for _, f in ipairs(MAIN) do
    if not C.file_has(f, "\\chapter") then fail(f, 1, "no \\chapter in a chapter file") end
  end
  for _, f in ipairs(C.role_files("approach")) do
    if C.file_has(f, "\\chapter{Approach}") then warn(f, 2, "the chapter is still called Approach: rename it after your method") end
  end
  C.each_line(MAIN, function(file, n, l)
    local t = l:match("\\section{(.-)}") or l:match("\\chapter{(.-)}") or l:match("\\subsection{(.-)}")
    if t and t:match("TODO") then fail(file, n, "heading still a TODO: " .. t) end
    if l:match("\\subsubsection") then warn(file, n, "a subsubsection: three levels of headings in 35 pages is one too many") end
  end)
end)

rule("figures", "source", "check", "always", "every figure, table, listing, algorithm and numbered equation is referenced from the text; floats have captions and labels; raster images are flagged", function()
  if #MAIN == 0 then fail(nil, nil, "no chapter files"); return end
  local labels, refs = C.collect_labels_and_refs(MAIN)
  for key, at in pairs(labels) do
    if key:match("^fig:") or key:match("^tab:") or key:match("^lst:") or key:match("^alg:") or key:match("^eq:") then
      if (refs[key] or 0) == 0 and not at.sub then fail(at.file, at.line, key .. " is never referenced from the text") end
    end
  end
  C.each_line(MAIN, function(f, n, l)
    local g = l:match("\\includegraphics%[?[^%]]*%]?{([^}]*)}")
    if g then
      if g:match("%.png$") or g:match("%.jpe?g$") then warn(f, n, "raster image " .. g .. ": figures are vector unless there is a written reason") end
      local found = false
      for _, ext in ipairs({ "", ".pdf", ".png", ".jpg", ".jpeg", ".eps" }) do if C.exists(g .. ext) then found = true end end
      if not found then fail(f, n, "image file not in the repository: " .. g) end
    end
    local sv = l:match("\\includesvg%[?[^%]]*%]?{([^}]*)}")
    if sv and not (C.exists(sv) or C.exists(sv .. ".svg")) then fail(f, n, "SVG file not in the repository: " .. sv) end
    if l:match("\\begin{figure}%[h%]") or l:match("\\begin{table}%[h%]") then warn(f, n, "[h] alone: use [!ht] or [tbp], LaTeX ignores a bare h") end
  end)
  for _, f in ipairs(MAIN) do
    local ls = C.lines(f); local infloat, hascap, haslab, hascenter, start = nil, false, false, false, 0
    for n, raw in ipairs(ls) do
      local l = C.strip_comment(raw)
      local b = l:match("\\begin{(figure%*?)}") or l:match("\\begin{(table%*?)}") or l:match("\\begin{(listing)}") or l:match("\\begin{(algorithm)}") or l:match("\\begin{(sidewaystable)}")
      if b then infloat, hascap, haslab, hascenter, start = b, false, false, false, n end
      if infloat then
        if l:match("\\caption") then hascap = true end
        if l:match("\\label{") then haslab = true end
        if l:match("\\centering") then hascenter = true end
        if l:match("\\end{" .. infloat:gsub("%*", "%%*") .. "}") then
          if not hascap then fail(f, start, infloat .. " without a caption") end
          if not haslab then warn(f, start, infloat .. " without a label") end
          if not hascenter and infloat ~= "algorithm" then warn(f, start, infloat .. " without \\centering") end
          infloat = nil
        end
      end
    end
  end
end)

rule("captions", "source", "advice", "polish", "captions explain, not describe: a caption is at least a sentence, a result figure's caption says what it shows, and none starts with 'Figure showing' or ends without a full stop", function()
  C.each_line(MAIN, function(f, n, l)
    local cap = l:match("\\caption%b[]%b{}") or l:match("\\caption%b{}")
    if cap and not l:match("\\caption%b{}%s*\\label") then end
    if cap then
      local text = cap:match("%b{}$"); text = text and text:sub(2, -2) or ""
      local plain = C.prose(text):gsub("%s+", " ")
      local words = 0; for _ in plain:gmatch("%a+") do words = words + 1 end
      if plain:match("^%s*[Ff]igure") or plain:match("^%s*[Tt]able") or plain:match("^%s*[Dd]iagram of") or plain:match("^%s*[Ss]creenshot") then warn(f, n, "caption starts by naming the figure; start with the claim it shows") end
      if words < 4 and not text:match("TODO") then warn(f, n, "caption is " .. words .. " words: a caption is the figure's own paragraph") end
      if not C.trim(text):match("[%.%?!]}?%)?$") and not text:match("TODO") then warn(f, n, "caption does not end with a full stop") end
      if (C.ROLES_OF[f] or {}).evaluation and words < 12 and not text:match("TODO") and not l:match("subfigure") and not text:match("^[^.]*%.$") then warn(f, n, "a result figure's caption should say what the result is and why, not only what is plotted") end
    end
  end)
end)

rule("axes", "source", "advice", "polish", "every pgfplots axis label carries a unit in brackets, or is a count, and both axes are labelled", function()
  C.each_line(MAIN, function(f, n, l)
    if l:match("\\begin{axis}") or l:match("\\nextgroupplot") then
      for _, k in ipairs({ "xlabel", "ylabel" }) do
        local v = l:match(k .. "%s*=%s*%b{}")
        if not v then
          if l:match("\\begin{axis}") and not (l:match("symbolic x coords") and k == "xlabel") then warn(f, n, "axis without " .. k) end
        else
          v = v:sub(#k + 1):gsub("^%s*=%s*", ""):sub(2, -2)
          local dimensionless = v:match("[Cc]ount") or v:match("[Nn]umber") or v:match("[Rr]ate") or v:match("%%") or v:match("[Ss]ize") or v:match("[Ss]essions") or v:match("[Ii]ssuers") or v:match("%$n%$") or v:match("[Rr]atio") or v:match("[Ss]core")
          if not v:match("%[.+%]") and not dimensionless then warn(f, n, k .. " without a unit in brackets: " .. v) end
        end
      end
    end
  end)
end)

rule("tables", "source", "advice", "polish", "tables use booktabs rules, no vertical lines, no \\hline, and fit the text width", function()
  for _, f in ipairs(MAIN) do
    local ls = C.lines(f); local intab, start, hasrule = false, 0, false
    for n, raw in ipairs(ls) do
      local l = C.strip_comment(raw)
      local spec = l:match("\\begin{tabularx?}{[^}]*}(%b{})") or l:match("\\begin{tabular}(%b{})") or l:match("\\begin{longtable}(%b{})") or l:match("\\begin{xltabular}{[^}]*}(%b{})")
      if spec then
        intab, start, hasrule = true, n, false
        if spec:match("|") then fail(f, n, "vertical lines in a table: booktabs tables have none") end
      end
      if intab then
        if l:match("\\hline") then warn(f, n, "\\hline: use \\toprule, \\midrule, \\bottomrule") end
        if l:match("\\toprule") then hasrule = true end
        if l:match("\\end{tabularx?}") or l:match("\\end{longtable}") or l:match("\\end{xltabular}") then
          if not hasrule then warn(f, start, "table without \\toprule: use the booktabs rules") end
          intab = false
        end
      end
      if l:match("\\begin{tabular}") and not l:match("\\begin{tabularx}") and (raw:match("X") == nil) then
        local cols = l:match("\\begin{tabular}(%b{})") or ""
        local nc = C.count(cols, "[lcrp]"); if nc >= 6 then warn(f, n, "a wide tabular: use tabularx with \\linewidth so it cannot overflow") end
      end
    end
  end
end)

rule("labels", "source", "check", "always", "label prefixes match their environments (fig:, tab:, lst:, alg:, eq:, def:, thm:, lem:, ch:, sec:, subsec: or par:), so references read right and the lint can trace them", function()
  local envpref = { figure = "fig", table = "tab", sidewaystable = "tab", listing = "lst", lstlisting = "lst", algorithm = "alg", equation = "eq", align = "eq", definition = "def", theorem = "thm", lemma = "lem", proposition = "prop", corollary = "cor", invariant = "inv", property = "prty", claim = "claim", remark = "rem", notation = "not", example = "ex", subfigure = "fig", subtable = "tab" }
  local listpref = { contributions = "c", requirements = "req", derivedrequirements = "dr", assumptions = "asm", guarantees = "g", threats = "thr", limitations = "lim", rqlist = "rq" }
  for _, f in ipairs(MAIN) do
    local stack = {}
    local lastheading
    for n, raw in ipairs(C.lines(f)) do
      local l = C.strip_comment(raw)
      for e in l:gmatch("\\begin{([%a%*]+)}") do stack[#stack + 1] = e:gsub("%*", "") end
      if l:match("\\chapter") then lastheading = "ch" elseif l:match("\\section") or l:match("\\subsection") then lastheading = "sec" elseif l:match("\\paragraph") then lastheading = "par" end
      local lab = l:match("\\lstlisting%[.-label%s*=%s*{?([^},%]]+)") ; if lab and not lab:match("^lst:") then warn(f, n, "listing label should start with lst: " .. lab) end
      for key in l:gmatch("\\label{([^}]*)}") do
        if key:match(":%d+[%.%d]*$") then warn(f, n, "label " .. key .. " encodes a number, which lies once chapters move: name it after what it labels") end
        local expect
        local top = stack[#stack]
        if top and envpref[top] then expect = envpref[top] elseif top and listpref[top] then expect = listpref[top] elseif l:match("\\caption") then expect = nil elseif #stack == 0 and lastheading then expect = lastheading end
        local pref = key:match("^([^:]+):")
        if key:match("^page:") then expect = nil end
        if expect and pref ~= expect then
          -- subsec: and subsubsec: are common enough for subsections to count as sec:
          if not (expect == "sec" and (pref == "ch" or pref == "subsec" or pref == "subsubsec")) and not (expect == "fig" and pref == "fig") then warn(f, n, string.format("label %s inside %s: expected prefix %s:", key, top or lastheading, expect)) end
        elseif not pref then warn(f, n, "label without a prefix: " .. key) end
      end
      for e in l:gmatch("\\end{([%a%*]+)}") do e = e:gsub("%*", ""); for i = #stack, 1, -1 do if stack[i] == e then table.remove(stack, i); break end end end
    end
  end
end)

rule("crefs", "source", "check", "always", "references go through \\cref: no 'Figure~\\ref', no \\autoref, \\Cref at the start of a sentence, and no bare \\ref outside table cells", function()
  C.each_line(MAIN, function(f, n, l)
    if l:match("[Ff]igure~?\\ref") or l:match("[Tt]able~?\\ref") or l:match("[Ss]ection~?\\ref") or l:match("[Cc]hapter~?\\ref") or l:match("[Ll]isting~?\\ref") then fail(f, n, "a typed reference with \\ref: write \\cref{...}") end
    if l:match("\\autoref") then fail(f, n, "\\autoref: the template uses cleveref, write \\cref") end
    if l:match("\\figref") or l:match("\\tabref") or l:match("\\sectref") or l:match("\\listref") then fail(f, n, "the faculty template's \\figref family: write \\cref") end
    if l:match("^%s*\\cref") or l:match("[%.%?!]%s+\\cref") then warn(f, n, "\\cref at the start of a sentence: use \\Cref") end
    if l:match("\\ref{") and not l:match("&") and not l:match("\\ref{req:") and not l:match("\\ref{g:") and not l:match("\\ref{c:") and not l:match("\\ref{asm:") and not l:match("\\ref{thr:") and not l:match("\\ref{dr:") then warn(f, n, "bare \\ref in prose: \\cref names the kind of thing for you") end
    if l:match("\\pageref") then note(f, n, "\\pageref: rarely needed with hyperlinks") end
  end)
end)

rule("acronyms", "source", "check", "polish", "glossary entries: every \\gls key is declared in content/glossary.tex, every abbreviation declared is used, none is typed by hand, every all-caps word is declared, and every symbol of a definition has a notation entry", function()
  local G = C.FILES.glossary or "content/glossary.tex"
  local declared, short, used, kind = {}, {}, {}, {}
  C.each_line({ G }, function(f, n, l)
    local k, sh = l:match("\\newabbreviation%b[]{([^}]*)}{([^}]*)}")
    if not k then k, sh = l:match("\\newabbreviation{([^}]*)}{([^}]*)}") end
    if k then declared[k] = { file = f, line = n }; kind[k] = "abbreviation"; short[sh] = k end
    local s1 = l:match("\\glsxtrnewsymbol%b[]{([^}]*)}") or l:match("\\glsxtrnewsymbol{([^}]*)}")
    if s1 then declared[s1] = { file = f, line = n }; kind[s1] = "symbol" end
    local t1 = l:match("\\newglossaryentry{([^}]*)}")
    if t1 then declared[t1] = { file = f, line = n }; kind[t1] = "term" end
  end)
  if next(declared) == nil then fail(G, nil, "no glossary entries: content/glossary.tex is missing or empty") end
  -- every declared short form as a word, and its plural: VC, VCs and VC-based, not VCS
  local forms = {}
  for sh, k in pairs(short) do
    if not sh:find("[\\{}]") then
      local pat = C.escape(sh)
      if sh:match("^%w") then pat = "%f[%w]" .. pat end
      if sh:match("%w$") then pat = pat .. "s?%f[%W]" end
      forms[#forms + 1] = { pat = pat, short = sh, key = k }
    end
  end
  table.sort(forms, function(a, b) return a.short < b.short end)
  C.each_prose_line(MAIN, function(f, n, l)
    for k in l:gmatch("\\[Gg]ls[%a]*%*?{([^}]*)}") do
      used[k] = true
      if not declared[k] then fail(f, n, "glossary key " .. k .. " is not declared in " .. G) end
    end
    local p = C.prose(l)
    for _, fm in ipairs(forms) do
      if p:find(fm.pat) then fail(f, n, string.format("%s typed by hand: write \\gls{%s}", fm.short, fm.key)) end
    end
  end)
  for k, at in pairs(declared) do
    if not used[k] and kind[k] == "abbreviation" then warn(at.file, at.line, "abbreviation " .. k .. " is declared but never used: remove it") end
    if not used[k] and kind[k] ~= "abbreviation" then note(at.file, at.line, kind[k] .. " " .. k .. " is declared but never used with \\gls, so it will not print") end
  end
  -- a definition that introduces a symbol should have a notation entry: look for $...$ in definition environments
  for _, f in ipairs(MAIN) do
    local indef = false
    for n, raw in ipairs(C.lines(f)) do
      local l = C.strip_comment(raw)
      if l:match("\\begin{definition}") or l:match("\\begin{notation}") then indef = true end
      if indef and l:match("%$") and not l:match("\\gls") and not l:match("TODO") then note(f, n, "a definition with math and no \\gls: does it introduce a symbol that belongs in the notation table?") end
      if l:match("\\end{definition}") or l:match("\\end{notation}") then indef = false end
    end
  end
  -- undeclared all-caps words that look like acronyms, counted once each
  local seen = {}
  C.each_prose_line(MAIN, function(f, n, l)
    for w in C.prose(l):gmatch("%f[%w][%u][%u%d]+[%u]%f[%W]") do
      if not short[w] and not seen[w] and #w >= 2 and #w <= 6 and not w:match("^RQ") and not w:match("^TODO") and not w:match("^[IVXLC]+$") then seen[w] = true; warn(f, n, w .. " is not in the glossary: declare it, or lint-ignore it if it is a name") end
    end
  end)
end)

rule("bib", "source", "check", "always", "the bibliography: every cited key exists; entries have a title, a year and an author; a web source has its access date; DOIs are bare", function()
  local keys = {}
  for _, b in ipairs(C.BIB) do
    local s = C.readfile(b) or ""
    for entry in ("\n" .. s):gmatch("\n@(%w+%b{})") do
      local kind, body = entry:match("^(%w+)(%b{})"); body = body:sub(2, -2)
      local key = body:match("^%s*([^,%s]+)")
      local k = kind:lower()
      if key and k ~= "comment" and k ~= "string" and k ~= "preamble" then
        keys[key] = true
        local function has(fld) return body:lower():match("\n%s*" .. fld .. "%s*=") ~= nil end
        if not has("title") then fail(b, nil, key .. ": no title") end
        if not has("year") and not has("date") then fail(b, nil, key .. ": no year") end
        if not (has("author") or has("editor") or k == "misc" or k == "manual" or k == "online") then fail(b, nil, key .. ": no author") end
        local hasdate = has("urldate") or (body:match("\n%s*note%s*=%s*[{\"][^}\"]*[Aa]ccessed") ~= nil)
        if has("url") and not has("doi") and not hasdate then warn(b, nil, key .. ": a web source needs its access date (urldate); Zotero records it, the faculty's guideline asks for it") end
        if (k == "misc" or k == "online") and has("url") and not has("author") then warn(b, nil, key .. ": a web source names the page's owner as author, in double braces") end
        local doi = body:match("\n%s*[dD][oO][iI]%s*=%s*[{\"]([^}\"]*)")
        if doi and doi:match("^https?://") then warn(b, nil, key .. ": doi field is a URL; give the bare DOI") end
        if doi and doi:match("TODO") then warn(b, nil, key .. ": DOI still a TODO") end
        -- BibTeX is not UTF-8 aware: an abbreviated first name that starts with an accented letter
        -- (Ádám, Éva, Ödön) loses a byte unless the letter is written as a LaTeX accent in braces,
        -- {\'A}d{\'a}m, which is how Zotero exports it; a plain {Á} does not help
        local names = body:match("\n%s*[aA][uU][tT][hH][oO][rR]%s*=%s*(%b{})") or body:match("\n%s*[eE][dD][iI][tT][oO][rR]%s*=%s*(%b{})")
        if names then
          for given in names:gmatch(",%s*([^,}]+)") do
            for word in given:gmatch("%S+") do
              if word:match("^[\195-\197][\128-\191]") then warn(b, nil, key .. ": the given name " .. word .. " starts with an accented letter; write it as a LaTeX accent in braces, like {\\'A}d{\\'a}m, or BibTeX breaks the initial"); break end
            end
          end
        end
        local title = body:match("\n%s*[tT][iI][tT][lL][eE]%s*=%s*(%b{})")
        if title then
          local inner = title:sub(2, -2):gsub("%b{}", "")
          for w in inner:gmatch("%S+") do
            if w:match("^%a") and (w:match("^%u%u") or w:match("%l%u")) then warn(b, nil, key .. ": " .. w .. " in the title is not protected with braces; BibTeX lowercases it") ; break end
          end
        end
      end
    end
  end
  C.each_cite(MAIN, function(f, n, k) if not keys[k] then fail(f, n, "cited key " .. k .. " is in no .bib file") end end)
end)

-- Two papers submitted to the same year's TDK, by one student or by two on neighbouring topics,
-- are each other's companion paper. Each is reviewed on its own while the other is unpublished,
-- so neither cites or links the other: the text says "a companion paper", and what this paper
-- needs from it is restated in the background, or as a last resort in an appendix (the guide's
-- app:tdk:companion). A TDK paper of an earlier year is on the portal and is cited like any
-- other source; so is this year's once a thesis builds on it (LINT_PROFILE=thesis).
local TDK_NAMES = { "%f[%a]o?tdk%f[%A]", "tudom%S*nyos%s+di%S*kk%S*ri", "scientific%s+students?%f[%A]",
  "students?%S*%s+scientific%s+conference", "students?%S*%s+scientific%s+association" }
-- the github.com/<owner>/<name> a URL or bib entry points into, lower case, without .git
local function github_repo(s)
  local r = s:lower():match("github%.com/[^/%s{}\",]+/[^/%s{}\",?#]+")
  return r and (r:gsub("%.git$", ""))
end
-- this paper's own repository: the first GitHub repository the implementation chapter cites or
-- links, as the template's overview does; its tdkYY name makes it no companion paper
local function own_repo(entries)
  local own
  C.each_call(C.role_files("implementation"), function(name) return name == "url" or name == "href" or name == "weblink" or (name:match("^[cC]ite") and name ~= "citeneeded") end, function(_, _, name, arg)
    if own then return end
    if name:match("^[cC]ite") then
      for k in arg:gmatch("[^,%s]+") do own = own or (entries[k] and github_repo(entries[k].body)) end
    else own = github_repo(arg) end
  end)
  return own
end
-- what a link points at, when it is a draft or a TDK paper of the given year, other than own
local function companion_link(url, year, own)
  local u = url:lower()
  if u:find("overleaf%.com/project/") or u:find("overleaf%.com/read/") then return "an Overleaf project, a draft no reviewer can open," end
  local y = u:match("tdk%.bme%.hu/conference/[^/]+/(%d%d%d%d)/sessions/")
  if y and tonumber(y) >= year then return "a paper of the " .. y .. " TDK on the portal" end
  if u:find("github%.com/[^/]+/[^/]*tdk" .. string.format("%02d", year % 100) .. "%f[%D]") and github_repo(u) ~= own then return "the repository of a " .. year .. " TDK paper" end
end
rule("companion", "source", "check", "always", "a TDK paper of the same year is a companion paper: never cited or linked (Overleaf, its portal page, its repository), and no citation or link is attached to the words companion paper; what this paper needs from it is restated in the background", function()
  if C.opts.profile == "thesis" then C.skip("a thesis may cite the TDK paper it grew from"); return end
  local year = tonumber((C.readfile("include/tdk-variables.tex") or ""):match("\\newcommand{\\tdkev}{%s*(%d%d%d%d)%s*}")) or tonumber(os.date("%Y"))
  local entries, first, times, flagged = C.bib_entries(), {}, {}, {}
  local own = own_repo(entries)
  local function flag(f, n, msg) flagged[f .. ":" .. n] = true; fail(f, n, msg) end
  C.each_cite(CONTENT, function(f, n, k)
    first[k] = first[k] or { f, n }; times[k] = (times[k] or 0) + 1
  end)
  for k, at in pairs(first) do
    local e = entries[k]
    if e and not (own and github_repo(e.body) == own) then
      -- Zotero writes accents as {\'a}: drop the commands and braces before matching the names
      local plain = e.body:lower():gsub("\\%p", ""):gsub("\\%a+%s?", ""):gsub("[{}]", "")
      local tdk = false
      for _, p in ipairs(TDK_NAMES) do if plain:find(p) then tdk = true end end
      local ey = tonumber(e.body:match("[,%s][yY][eE][aA][rR]%s*=%s*[{\"]?%s*(%d%d%d%d)") or e.body:match("[,%s][dD][aA][tT][eE]%s*=%s*[{\"]?%s*(%d%d%d%d)"))
      local cited = string.format("cited %d time%s", times[k], times[k] == 1 and "" or "s")
      if tdk and (not ey or ey >= year) then
        flag(at[1], at[2], string.format("%s is a TDK paper of %s, %s: a paper of the same TDK is a companion paper; write \"a companion paper\" instead of citing it, and restate what this paper needs from it in the background, or as a last resort in an appendix", k, ey or "unknown year", cited))
      else
        for url in e.body:gmatch("https?://[^%s{}\"]+") do
          local what = companion_link(url, year, own)
          if what then flag(at[1], at[2], string.format("%s, %s, points at %s: a TDK paper of the same year is a companion paper, named as one, never cited", k, cited, what)); break end
        end
      end
    end
  end
  for _, f in ipairs(CONTENT) do
    C.each_line({ f }, function(_, n, l)
      for cmd, arg in l:gmatch("\\(%a+)%s*(%b{})") do
        if cmd == "url" or cmd == "href" or cmd == "weblink" then
          local what = companion_link(arg:sub(2, -2), year, own)
          if what then flag(f, n, "links " .. what .. ": a TDK paper of the same year is a companion paper, named as one, never linked") end
        end
      end
    end)
    -- "a companion paper~\cite{...}" or a link whose text says companion; a citation later in the
    -- sentence ("a companion paper verifies it in Tamarin~\cite{...}") is another source's
    local text = table.concat(C.prose_lines(f), "\n")
    local pats = { "\\href%s*%b{}%s*{()[^}]*[Cc]ompanion", "\\weblink%s*%b{}%s*{()[^}]*[Cc]ompanion" }
    for _, cmd in ipairs({ "[cC]ite", "url", "href", "weblink" }) do pats[#pats + 1] = "()[Cc]ompanion%s*%a*[%s~,(%[]*\\" .. cmd end
    for _, p in ipairs(pats) do
      for at in text:gmatch(p) do
        local n = 1 + C.count(text:sub(1, at), "\n")
        if not flagged[f .. ":" .. n] then flag(f, n, "a citation or link attached to a companion paper: a companion paper is named, not cited") end
      end
    end
  end
end)

-- the reference list as BibTeX printed it: the \bibitem keys of the .bbl, so a citation counts
-- however it was written in the sources, and a \cite in a comment does not; each key is then
-- looked up in the .bib files to tell papers, arXiv preprints and web pages apart
rule("sources", "source", "advice", "always", "the reference list has the shape the guide asks for: no more than 50 references in a TDK paper, not web pages alone, and no arXiv preprint without a reason; the counts are references, web pages and preprints", function()
  local bbl = C.readfile(C.bpath(C.opts.doc .. ".bbl"))
  if not bbl then warn(nil, nil, C.opts.doc .. ".bbl not found: build the paper first, BibTeX writes it"); return end
  local cited, seen = {}, {}
  local pos = 1
  while true do
    local _, e = bbl:find("\\bibitem%f[^%a]", pos); if not e then break end
    pos = e + 1
    local _, oe = bbl:find("^%s*%b[]", pos); if oe then pos = oe + 1 end -- natbib's [label]
    local ks, ke = bbl:find("^%s*%b{}", pos)
    if ks then
      local key = C.trim(bbl:sub(ks, ke):match("{(.*)}"))
      if not seen[key] then seen[key] = true; cited[#cited + 1] = key end
      pos = ke + 1
    end
  end
  -- a field's value in lower case, from a lower-cased entry body; "" when the field is absent
  local function field(body, name)
    local v = body:match("[,%s]" .. name .. "%s*=%s*(%b{})") or body:match("[,%s]" .. name .. '%s*=%s*(%b"")')
    return v and v:sub(2, -2) or ""
  end
  local function entry_line(file, key)
    local s = C.readfile(file) or ""
    local at = s:find("@%a+%s*{%s*" .. C.escape(key) .. "%s*,")
    return at and (C.count(s:sub(1, at), "\n") + 1) or nil
  end
  local entries = C.bib_entries()
  local web, arxiv = 0, 0
  for _, key in ipairs(cited) do
    local en = entries[key]
    if en then
      local b = en.body:lower()
      local journal = field(b, "journal")
      local venue = field(b, "booktitle") ~= "" or (journal ~= "" and not journal:find("arxiv", 1, true) and journal ~= "corr")
      local marks = field(b, "archiveprefix") .. " " .. field(b, "eprinttype") .. " " .. journal .. " " .. field(b, "howpublished") .. " " .. field(b, "publisher") .. " " .. field(b, "note") .. " " .. field(b, "url") .. " " .. field(b, "doi")
      local scholarly = venue or field(b, "doi") ~= "" or field(b, "publisher") ~= "" or field(b, "institution") ~= "" or field(b, "school") ~= "" or field(b, "isbn") ~= ""
      local url = field(b, "url") ~= "" or b:find("\\url", 1, true) ~= nil or en.type == "online" or en.type == "electronic" or en.type == "www"
      if not venue and (marks:find("arxiv", 1, true) or marks:find("10.48550/", 1, true)) then
        arxiv = arxiv + 1
        warn(en.file, entry_line(en.file, key), key .. ": an arXiv preprint; search dblp for its title and cite the published version, unless the work is too recent to be published")
      elseif url and not scholarly then
        web = web + 1
      end
    end
  end
  local total = #cited
  if C.opts.profile ~= "thesis" and total > 50 then
    warn(nil, nil, string.format("%d references: a TDK paper typically needs no more than 50; cut the weakest first, starting with those another entry already covers", total))
  end
  if total > 0 and web == total then
    warn(nil, nil, "every reference is a web page, which the review sheet's B/2 places at step 1; cite the papers, standards and specifications behind them, and move links that back no claim to footnotes")
  end
  return string.format("references=%d web=%d arxiv=%d", total, web, arxiv)
end)

rule("code", "source", "check", "always", "listings: \\lstinline is ASCII (XeLaTeX fails on Unicode there), every listing has a caption and a label, minted sits in a listing float", function()
  C.each_line(MAIN, function(f, n, l)
    local inl = l:match("\\lstinline%b[]({.-})") or l:match("\\lstinline(%b{})")
    if inl and inl:match("[\128-\255]") then fail(f, n, "non-ASCII inside \\lstinline breaks under XeLaTeX; use a block listing or \\texttt") end
    if l:match("\\begin{lstlisting}") and not l:match("caption") then warn(f, n, "lstlisting without a caption") end
    if l:match("\\begin{lstlisting}") and not l:match("label") then warn(f, n, "lstlisting without a label") end
  end)
  for _, f in ipairs(MAIN) do
    local ls = C.lines(f); local inlisting = false
    for n, raw in ipairs(ls) do
      local l = C.strip_comment(raw)
      if l:match("\\begin{listing}") then inlisting = true end
      if l:match("\\begin{minted}") and not inlisting then warn(f, n, "minted outside a listing float: it gets no caption and no number") end
      if l:match("\\end{listing}") then inlisting = false end
    end
  end
end)

rule("preamble", "source", "check", "always", "include/macros.tex does not fight the template: no package it loads again with other options, no amssymb, amsfonts or amsthm, no second definition of its theorem environments", function()
  local M = "include/macros.tex"
  if not C.exists(M) then return end
  local loaded, thms = {}, {}
  for _, f in ipairs({ "include/packages.tex", "include/preamble.tex" }) do
    C.each_line({ f }, function(_, _, l)
      for opts, pk in l:gmatch("\\usepackage(%b[]){([^}]*)}") do for p in pk:gmatch("[^,%s]+") do loaded[p] = opts end end
      for pk in l:gmatch("\\usepackage{([^}]*)}") do for p in pk:gmatch("[^,%s]+") do loaded[p] = loaded[p] or "" end end
      for t in l:gmatch("\\newtheorem{([^}]*)}") do thms[t] = true end
    end)
  end
  C.each_line({ M }, function(f, n, l)
    local function check(opts, pk)
      for p in pk:gmatch("[^,%s]+") do
        if p == "amssymb" or p == "amsfonts" then fail(f, n, p .. " next to unicode-math redefines \\square and other symbols; the template's math font has them")
        elseif p == "amsthm" then fail(f, n, "amsthm clashes with ntheorem, which the template's theorem environments use")
        elseif loaded[p] then
          if opts ~= "" and opts ~= loaded[p] then fail(f, n, string.format("%s is loaded by the template%s: loading it again with %s is an option clash", p, loaded[p] ~= "" and (" with " .. loaded[p]) or "", opts))
          else warn(f, n, p .. " is loaded by the template already") end
        end
      end
    end
    for opts, pk in l:gmatch("\\usepackage(%b[]){([^}]*)}") do check(opts, pk) end
    for pk in l:gmatch("\\usepackage{([^}]*)}") do check("", pk) end
    for t in l:gmatch("\\newtheorem%*?{([^}]*)}") do if thms[t] then fail(f, n, "the template defines the " .. t .. " environment: use it, a second \\newtheorem stops the build") end end
  end)
end)

rule("typography", "source", "advice", "polish", "the small things the reviewer sees: number ranges with --, a thin space before units, no straight quotes, no doubled words, \\eg and \\ie macros, no manual line breaks in prose", function()
  C.each_prose_line(MAIN, function(f, n, l)
    local p = C.prose(l)
    -- a range stands alone: BLS12-381 and i7-9750H are names, not ranges
    for s, a, b, e in p:gmatch("()(%d+)%-(%d+)()") do
      local before, after = p:sub(s - 1, s - 1), p:sub(e, e)
      if not before:match("[%w%-%.]") and not after:match("[%w%-]") and not l:match("\\label") and not l:match("label=") then warn(f, n, string.format("range %s-%s with a hyphen: write %s--%s", a, b, a, b)) end end
    for num, unit in p:gmatch("(%d) (ms|s|MB|GB|KB|kB|Hz|MHz|GHz|mm|cm|pt|KiB|MiB|GiB|bytes|B)%f[%W]") do warn(f, n, string.format("'%s %s': use a thin space, %s\\,%s", num, unit, num, unit)) end
    if p:match('"') then warn(f, n, "straight double quote: use \\enquote{...}") end
    if p:match("%f[%a]e%.g%.") or p:match("%f[%a]i%.e%.") then warn(f, n, "e.g./i.e. typed out: use \\eg and \\ie, which get the spacing right") end
    if p:match("%f[%a]et al%.") and not l:match("\\etal") then warn(f, n, "et al. typed out: use \\etal") end
    for w in p:gmatch("%f[%a](%a+) %1%f[%A]") do if #w > 2 then warn(f, n, "doubled word: " .. w .. " " .. w) end end
    if l:match("[%w%)]%s+[,%.;:]%f[%s]") then warn(f, n, "space before punctuation") end
    if l:match("\\\\%s*$") and not l:match("&") and not l:match("\\\\%[") and not l:match("^%s*\\\\") then
      if not (l:match("\\end{") or l:match("\\hline") or l:match("rule")) then note(f, n, "manual line break at the end of a prose line") end
    end
    if p:match("%.%.%.") then warn(f, n, "three dots: use \\dots") end
    if l:match("\\footnote") and l:match("%s\\footnote") then warn(f, n, "space before \\footnote: the mark should sit on the word or the punctuation") end
    if l:match("\\cite") and not l:match("~\\cite") and not l:match("{\\cite") and not l:match("\\citet") and not l:match("\\cite[tp]") and not l:match("^%s*\\cite") and not l:match("&%s*\\cite") and not l:match("\\\\%s*\\cite") then warn(f, n, "\\cite without a tie: write text~\\cite{...} so the number cannot start a line") end
  end)
end)

rule("terms", "source", "advice", "polish", "one name per concept: hyphenated, open and closed forms of the same compound do not coexist, and British and American spellings of the known pairs are not mixed", function()
  local text = {}
  for _, f in ipairs(MAIN) do text[#text + 1] = C.prose(table.concat(C.prose_lines(f), "\n")) end
  local all = table.concat(text, "\n")
  local hyph = {}
  for a, b in all:gmatch("%f[%a](%l%l+)%-(%l%l+)%f[%A]") do hyph[a .. "-" .. b] = true end
  local n = 0
  for h in pairs(hyph) do
    local a, b = h:match("^(.-)%-(.*)$")
    local open = select(2, all:gsub("%f[%a]" .. a .. " " .. b .. "%f[%A]", ""))
    local closed = select(2, all:gsub("%f[%a]" .. a .. b .. "%f[%A]", ""))
    local hy = select(2, all:gsub("%f[%a]" .. a .. "%-" .. b .. "%f[%A]", ""))
    if open > 0 or closed > 0 then n = n + 1; warn(nil, nil, string.format("%s (%d) also appears as %s%s: pick one", h, hy, open > 0 and string.format("'%s %s' (%d)", a, b, open) or "", closed > 0 and string.format("%s'%s%s' (%d)", open > 0 and " and " or "", a, b, closed) or "")) end
  end
  -- British/American pairs that hunspell would not catch together
  local pairs_ = { { "modelling", "modeling" }, { "colour", "color" }, { "behaviour", "behavior" }, { "analyse", "analyze" }, { "optimise", "optimize" }, { "optimisation", "optimization" }, { "formalisation", "formalization" }, { "formalise", "formalize" }, { "centre", "center" }, { "licence", "license" }, { "catalogue", "catalog" }, { "parametrised", "parameterized" }, { "synchronise", "synchronize" }, { "realise", "realize" }, { "serialisation", "serialization" }, { "authorisation", "authorization" } }
  local brit, amer = 0, 0
  for _, pr in ipairs(pairs_) do
    local b = select(2, all:lower():gsub("%f[%a]" .. pr[1] .. "%w*", "")); local a = select(2, all:lower():gsub("%f[%a]" .. pr[2] .. "%w*", ""))
    brit, amer = brit + b, amer + a
    if b > 0 and a > 0 then warn(nil, nil, string.format("both %s (%d) and %s (%d): keep one spelling", pr[1], b, pr[2], a)) end
  end
  return string.format("variants=%d british=%d american=%d", n, brit, amer)
end)

-- function words of Hungarian, which an English sentence does not contain three of
local HU = {}
for w in ("és hogy nem egy az ez van vagy mint csak már ami amely amelyek illetve valamint szerint között alapján ezért mert ahol amit lesz volt"):gmatch("%S+") do HU[w] = true end
rule("language", "source", "advice", "polish", "the chapters are in English: a prose line with several Hungarian function words is a note or a draft left in the text", function()
  C.each_prose_line(main_chapters(), function(f, n, l)
    local hits = 0
    for w in C.prose(l):gmatch("[%a\128-\255]+") do if HU[w:lower()] then hits = hits + 1 end end
    if hits >= 3 then warn(f, n, "Hungarian prose in an English chapter: translate it, or make it a \\todo") end
  end)
end)

rule("numbers", "source", "advice", "polish", "the headline numbers of the abstract and the conclusion appear in the evaluation, so the paper agrees with itself", function()
  if not C.roles_ok({ "conclusion", "evaluation", "intro" }) then return end
  local eval = C.prose(C.role_text("evaluation"))
  local function nums(file)
    local out = {}
    local p = C.prose(table.concat(C.prose_lines(file), "\n"))
    for num in p:gmatch("%f[%d](%d+%.?%d*)%s*[%%×x]") do out[#out + 1] = num end
    for num in p:gmatch("%f[%d](%d+%.?%d*)%s*\\?,?%s*%a?%a?%a?%f[%W]") do if tonumber(num) and (tonumber(num) >= 20 or num:match("%.")) then out[#out + 1] = num end end
    return out
  end
  local missing = 0
  local files = { C.FILES.abstract }
  for _, r in ipairs({ "intro", "conclusion" }) do for _, f in ipairs(C.role_files(r)) do files[#files + 1] = f end end
  for _, f in ipairs(files) do
    for _, num in ipairs(nums(f)) do
      if not eval:find(num, 1, true) and not num:match("^20%d%d$") and not num:match("^19%d%d$") then missing = missing + 1; warn(f, nil, "number " .. num .. " does not occur in the evaluation chapter") end
    end
  end
  return string.format("missing=%d", missing)
end)

rule("aidecl", "source", "check", "final", "the AI declaration is filled in: exactly one box marked, and if AI was used, at least one row, the overall share and its justification", function()
  local f = C.FILES.aidecl
  local s = f and C.readfile(f); if not s then fail(nil, nil, "no AI declaration file (\\label{aidecl})"); return end
  local body = s:gsub("\\newcommand{\\aiboxmarked}[^\n]*", "")
  local marked = C.count(body, "\\aiboxmarked")
  if marked == 0 then fail(f, nil, "no box marked in the AI declaration: mark one with \\aiboxmarked")
  elseif marked > 1 then fail(f, nil, "two boxes marked in the AI declaration") end
  local used = body:match("\\aiboxmarked\\enspace Használtam") ~= nil
  if used then
    local blank = C.count(body, "\\aiuse{")
    if blank >= 9 then fail(f, nil, "AI use declared but every row is still the blank \\aiuse row") end
    if body:match("Összesített százalékos érték[^\n]*&%s*%-%-") then fail(f, nil, "the overall share is still --") end
    if body:match("indoklása:}%s*TODO") then fail(f, nil, "the justification of the overall share is still TODO") end
  end
  if s:match("\\todo") then warn(f, nil, "the declaration's instructions todo is still in the file") end
end)

rule("titlepage", "source", "check", "final", "the title page variables are filled in: title, author, year, the second author where there is one", function()
  local th = C.readfile("thesis.tex") or ""
  local title = th:match("\\newcommand{\\vikcim}{([^}]*)}") or ""
  if title == "" or title:match("TODO") then fail("thesis.tex", nil, "\\vikcim (the title) is not set") end
  if th:match("\\vikszerzoVezeteknev}{Gipsz}") then fail("thesis.tex", nil, "the author is still Gipsz Jakab") end
  local tv = C.readfile("include/tdk-variables.tex") or ""
  local second = tv:match("\\newcommand{\\tdkszerzoB}{([^}]*)}") or ""
  if second ~= "" and not th:match("\\szerzoMeta}{[^}]*\\tdkszerzoB") then warn("thesis.tex", nil, "there is a second author but \\szerzoMeta (the PDF metadata) names only the first") end
  local year = tv:match("\\newcommand{\\tdkev}{([^}]*)}") or ""
  if year ~= "" and not year:match("\\the\\year") and tonumber(year) and tonumber(year) ~= tonumber(os.date("%Y")) then warn("include/tdk-variables.tex", nil, "\\tdkev is " .. year .. ", not this year") end
  if th:match("\\vikdoktipus}{\\tdk}") and th:match("\n\\include{include/declaration}") then warn("thesis.tex", nil, "the student declaration is included; the TDK call says to leave it out") end
end)

-- burn-down --------------------------------------------------------------------------------
rule("placeholders", "source", "count", "final", "what the template left for you: TODO strings, placeholder figures and tables, sample citations in the gap matrix, the Zenodo DOI", function()
  local todo, ph = 0, 0
  local files = {}
  for _, f in ipairs(CONTENT) do files[#files + 1] = f end
  files[#files + 1] = "thesis.tex"
  for _, b in ipairs(C.BIB) do files[#files + 1] = b end
  for _, f in ipairs(files) do
    local t, p, first = 0, 0, nil
    C.each_line({ f }, function(_, n, l)
      local c = C.count(l, "TODO"); if c > 0 then t = t + c; first = first or n end
      if l:match("[Pp]laceholder") then p = p + 1 end
      if l:match("lamport1978time") or l:match("w3c2025vcdm") then warn(f, n, "sample citation from the template still used") end
    end)
    todo, ph = todo + t, ph + p
    if t + p > 0 then warn(f, first, string.format("%d TODO, %d placeholder figure or table", t, p)) end
  end
  return string.format("todo=%d placeholders=%d", todo, ph)
end)

rule("beats", "source", "count", "final", "beats and notes still printing: the skeleton is done when every beat has become prose", function()
  local beats, todos = 0, 0
  C.each_line(MAIN, function(f, n, l)
    if l:match("\\beat{") then beats = beats + 1; note(f, n, "beat") end
    if l:match("\\todo") or l:match("\\atodo") or l:match("\\advisortodo") or l:match("\\guidetodo") then todos = todos + 1 end
  end)
  return string.format("beats=%d notes=%d", beats, todos)
end)

rule("burndown", "source", "count", "always", "one line of JSON with the counts a draft drives to zero, for CI to collect over time", function()
  local function count(files, pat) local c = 0; C.each_line(files, function(_, _, l) c = c + C.count(l, pat) end); return c end
  local j = string.format('{"date":"%s","pages":%d,"todo":%d,"beats":%d,"notes":%d,"placeholders":%d,"citations":%d,"figures":%d}',
    os.date("!%Y-%m-%d"), main_pages() or 0, count(CONTENT, "TODO"), count(MAIN, "\\beat{"), count(MAIN, "\\a?d?v?i?s?o?r?todo%["),
    count(CONTENT, "[Pp]laceholder"), count(MAIN, "\\cite[tp]?{"), count(MAIN, "\\label{fig:"))
  if not C.opts.tex and not C.opts.json then io.write(j, "\n") end -- --json carries it as the counts
  return j
end)
