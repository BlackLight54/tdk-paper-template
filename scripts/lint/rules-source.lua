-- Rules on the LaTeX sources: the template's structures, the argument's traceability, and the
-- conventions the guide asks for. When a structure is absent the rule says so instead of
-- passing on nothing.
local C = require("lintcore")
local rule, fail, warn, note = C.rule, C.fail, C.warn, C.note
local MAIN, CONTENT = C.MAIN, C.CONTENT

-- template structure --------------------------------------------------------------------
rule("structure", "source", true, "what the template provides is still there: the files, the tag lists, the running example, the gap matrix, the leading figure; a paper that replaced the template sees here what it lost", function()
  for _, f in ipairs({ "thesis.tex", "reviewer.tex", "include/packages.tex", "include/preamble.tex", "include/thesis-en.tex", "include/titlepage-tdk.tex", "content/acronyms.tex", "content/00-abstract.tex", "content/09-ai-declaration.tex", "bib/references.bib", "scripts/lint.lua", "docs/TDK2025_biralati_pontozolap_hallgatoi.pdf" }) do
    if not C.exists(f) then fail(nil, nil, "missing from the template: " .. f) end
  end
  if #MAIN == 0 then fail(nil, nil, "no chapter files content/01-...tex to content/07-...tex: the main text is not where the template keeps it"); return end
  local labels = C.collect_labels_and_refs(MAIN)
  local function atleast(prefix, what, where)
    local n = 0; for k in pairs(labels) do if k:match("^" .. prefix .. ":") then n = n + 1 end end
    if n == 0 then fail(where, nil, string.format("no %s (labels %s:...): the template's list is gone", what, prefix)) end
    return n
  end
  atleast("req", "requirements", "content/01-introduction.tex"); atleast("c", "contributions", "content/01-introduction.tex")
  atleast("rq", "research questions", "content/05-evaluation.tex"); atleast("thr", "threats", "content/03-approach.tex")
  atleast("g", "guarantees", "content/03-approach.tex"); atleast("lim", "limitations", "content/07-conclusion.tex")
  if not labels["fig:overview"] then fail("content/01-introduction.tex", nil, "no leading figure (fig:overview)") end
  if not labels["tab:related"] then fail("content/06-related-work.tex", nil, "no gap matrix (tab:related)") end
  if not labels["tab:correctness"] then fail("content/05-evaluation.tex", nil, "no correctness table (tab:correctness)") end
  if not (labels["page:main:start"] and labels["page:main:end"]) then fail(nil, nil, "page:main:start or page:main:end label missing: the page count cannot be measured from the sources") end
  local pre = C.readfile("include/preamble.tex") or ""
  for _, m in ipairs({ "runningexample", "NewTagList", "beat", "gapyes", "atodo" }) do
    if not pre:find(m, 1, true) then fail("include/preamble.tex", nil, "the preamble no longer defines " .. m) end
  end
  local pk = C.readfile("include/packages.tex") or ""
  for _, m in ipairs({ "TeX Gyre Termes", "cleveref", "natbib", "todonotes", "acro", "minted", "booktabs", "pgfplots" }) do
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
rule("build", "source", true, "the build log: undefined references and citations, multiply defined labels, missing files, missing fonts, TeX errors", function()
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

rule("overfull", "source", true, "overfull boxes in the build log: text or tables running into the margin", function()
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

rule("pages", "source", true, "main text between the page:main:start and page:main:end labels is 30-35 pages", function()
  local s, e
  local auxes = { C.bpath(C.opts.doc .. ".aux") }
  for _, f in ipairs(MAIN) do auxes[#auxes + 1] = C.bpath(f:gsub("%.tex$", ".aux")) end
  for _, a in ipairs(auxes) do
    for _, l in ipairs(C.lines(a)) do
      s = s or tonumber(l:match("^\\newlabel{page:main:start}{{[^}]*}{(%d+)}"))
      e = e or tonumber(l:match("^\\newlabel{page:main:end}{{[^}]*}{(%d+)}"))
    end
  end
  if not (s and e) then fail(nil, nil, "page:main:start or page:main:end label missing (build first; pdf-pages counts from the outline instead)"); return end
  local p = e - s + 1
  if p < 30 or p > 35 then fail("content/01-introduction.tex", 2, string.format("main text is %d pages (%d-%d); the call asks for 30-35, about 1 point off per 3 pages", p, s, e))
  else note(nil, nil, string.format("main text %d pages (%d-%d)", p, s, e)) end
  return string.format("pages=%d", p)
end)

-- the argument ---------------------------------------------------------------------------
rule("traceability", "source", true, "every tagged item is used where the argument needs it: requirements in the gap matrix and the correctness table, threats met in the approach, guarantees checked in the evaluation, contributions restated in the conclusion, research questions answered", function()
  if #MAIN == 0 then fail(nil, nil, "no chapter files"); return end
  local labels = C.collect_labels_and_refs(MAIN)
  local function need(prefix, where, what)
    local any = false
    for key, at in pairs(labels) do
      if key:match("^" .. prefix .. ":") then
        any = true
        if C.refs_in(where, "^" .. C.escape(key) .. "$") == 0 then fail(at.file, at.line, string.format("%s is never referenced in %s: %s", key, where, what)) end
      end
    end
    if not any then fail(nil, nil, string.format("no %s: labels: %s", prefix, what)) end
  end
  need("req", "content/06-related-work.tex", "every requirement is a row of the gap matrix")
  need("req", "content/05-evaluation.tex", "every requirement is checked in the evaluation")
  need("c", "content/07-conclusion.tex", "every contribution is restated with its evidence")
  need("rq", "content/05-evaluation.tex", "every research question is answered")
  need("thr", "content/03-approach.tex", "every threat is met by a guarantee or an assumption")
  need("g", "content/05-evaluation.tex", "every guarantee has a row in the correctness table")
  need("asm", "content/03-approach.tex", "every assumption is used by a guarantee or a proof")
  if C.refs_in("content/07-conclusion.tex", "^chap:evaluation$") + C.refs_in("content/07-conclusion.tex", "^rq:") + C.refs_in("content/07-conclusion.tex", "^fig:") + C.refs_in("content/07-conclusion.tex", "^tab:") + C.refs_in("content/07-conclusion.tex", "^thm:") == 0 then
    fail("content/07-conclusion.tex", 1, "the conclusion cites no evaluation result: restate each contribution with its evidence")
  end
  -- every contribution points at the chapter that delivers it
  C.each_line({ "content/01-introduction.tex" }, function(f, n, l)
    if l:match("\\label{c:") and not l:match("\\[cC]ref{chap:") then warn(f, n, "a contribution without a pointer to the chapter that delivers it") end
  end)
end)

rule("gapmatrix", "source", true, "the gap matrix argues the gap: rows are requirements, this work's column is all met with a pointer to the result, and every other approach misses something", function()
  local s = C.readfile("content/06-related-work.tex") or ""
  local tab = s:match("\\label{tab:related}(.-)\\end{tabularx}") or s:match("\\label{tab:related}(.-)\\end{tabular}")
  if not tab then fail("content/06-related-work.tex", nil, "no gap matrix table labelled tab:related"); return end
  local rows, ncols = {}, nil
  for line in tab:gmatch("[^\n]+") do
    line = C.strip_comment(line)
    if line:match("\\ref{req:") and line:match("\\\\") then
      local cells = {}
      for cell in (line:gsub("\\\\.*$", "") .. "&"):gmatch("(.-)&") do cells[#cells + 1] = C.trim(cell) end
      rows[#rows + 1] = cells; ncols = ncols or #cells
      if #cells ~= ncols then fail("content/06-related-work.tex", nil, "gap matrix rows have different numbers of cells") end
    end
  end
  if #rows == 0 then fail("content/06-related-work.tex", nil, "the gap matrix has no rows starting with \\ref{req:...}"); return end
  local labels = C.collect_labels_and_refs(MAIN)
  local nreq = 0; for k in pairs(labels) do if k:match("^req:") then nreq = nreq + 1 end end
  if #rows < nreq then fail("content/06-related-work.tex", nil, string.format("the gap matrix has %d rows but there are %d requirements", #rows, nreq)) end
  local approaches = ncols - 3 -- tag, name, approaches..., this work
  if approaches < 2 then warn("content/06-related-work.tex", nil, "fewer than two other approaches in the gap matrix: the gap is argued against the closest existing work, plural") end
  local allmet = {}
  for _, r in ipairs(rows) do
    local last = r[#r]
    if not last:match("\\gapyes") then fail("content/06-related-work.tex", nil, string.format("row %s: this work does not meet its own requirement; if a requirement is not met, say so in the text and the limitations", r[1]))
    elseif not last:match("\\[cC]ref{") and not last:match("\\ref{") then warn("content/06-related-work.tex", nil, string.format("row %s: this work's cell points at no evaluation result", r[1])) end
    if r[2]:match("TODO") then warn("content/06-related-work.tex", nil, string.format("row %s: the requirement's short name is a TODO", r[1])) end
    for c = 3, #r - 1 do allmet[c] = (allmet[c] == nil or allmet[c]) and r[c]:match("\\gapyes") ~= nil end
  end
  for c, met in pairs(allmet) do if met then fail("content/06-related-work.tex", nil, string.format("approach in column %d meets every requirement: then there is no gap, or a requirement is missing", c - 2)) end end
  return string.format("rows=%d approaches=%d", #rows, approaches)
end)

rule("outline", "source", true, "the outline follows the spine: chapters renamed where the template says so, no TODO heading, the running example named and in every chapter", function()
  if #MAIN == 0 then fail(nil, nil, "no chapter files"); return end
  for _, f in ipairs(MAIN) do
    if not C.file_has(f, "\\begin{runningexample}") then fail(f, 1, "no runningexample box: every chapter returns to the running example") end
    if not C.file_has(f, "\\chapter") then fail(f, 1, "no \\chapter in a chapter file") end
  end
  if C.file_has("content/03-approach.tex", "\\chapter{Approach}") then warn("content/03-approach.tex", 2, "the chapter is still called Approach: rename it after your method") end
  C.each_line(MAIN, function(file, n, l)
    local t = l:match("\\section{(.-)}") or l:match("\\chapter{(.-)}") or l:match("\\subsection{(.-)}")
    if t and t:match("TODO") then fail(file, n, "heading still a TODO: " .. t) end
    if l:match("\\subsubsection") then warn(file, n, "a subsubsection: three levels of headings in 35 pages is one too many") end
  end)
  local ex = (C.readfile("thesis.tex") or ""):match("\\newcommand{\\exname}{([^}]*)}") or ""
  if ex:match("TODO") then fail("thesis.tex", 1, "\\exname is still a TODO: name the running example") end
  -- the introduction's paragraphs in the template's order are a reporting aid, not a rule
  local intro = C.readfile("content/01-introduction.tex") or ""
  local have = {}
  for _, p in ipairs({ "Context", "Problem", "Requirements", "Gap", "Contributions", "Structure" }) do if intro:find("\\paragraph{" .. p, 1, true) then have[#have + 1] = p end end
  return "intro=" .. table.concat(have, ",")
end)

rule("figures", "source", true, "every figure, table, listing, algorithm and numbered equation is referenced from the text; floats have captions and labels; raster images are flagged", function()
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

rule("captions", "source", true, "captions explain, not describe: a caption is at least a sentence, a result figure's caption says what it shows, and none starts with 'Figure showing' or ends without a full stop", function()
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
      if f:match("05%-evaluation") and words < 12 and not text:match("TODO") and not l:match("subfigure") and not text:match("^[^.]*%.$") then warn(f, n, "a result figure's caption should say what the result is and why, not only what is plotted") end
    end
  end)
end)

rule("axes", "source", true, "every pgfplots axis label carries a unit in brackets, or is a count, and both axes are labelled", function()
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

rule("tables", "source", true, "tables use booktabs rules, no vertical lines, no \\hline, and fit the text width", function()
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

rule("labels", "source", true, "label prefixes match their environments (fig:, tab:, lst:, alg:, eq:, def:, thm:, lem:, chap:, sec:), so references read right and the lint can trace them", function()
  local envpref = { figure = "fig", table = "tab", sidewaystable = "tab", listing = "lst", lstlisting = "lst", algorithm = "alg", equation = "eq", align = "eq", definition = "def", theorem = "thm", lemma = "lem", proposition = "prop", corollary = "cor", invariant = "inv", property = "prty", claim = "claim", remark = "rem", notation = "not", example = "ex", subfigure = "fig", subtable = "tab" }
  local listpref = { contributions = "c", requirements = "req", assumptions = "asm", guarantees = "g", threats = "thr", limitations = "lim", rqlist = "rq" }
  for _, f in ipairs(MAIN) do
    local stack = {}
    local lastheading
    for n, raw in ipairs(C.lines(f)) do
      local l = C.strip_comment(raw)
      for e in l:gmatch("\\begin{([%a%*]+)}") do stack[#stack + 1] = e:gsub("%*", "") end
      if l:match("\\chapter") then lastheading = "chap" elseif l:match("\\section") or l:match("\\subsection") then lastheading = "sec" end
      local lab = l:match("\\lstlisting%[.-label%s*=%s*{?([^},%]]+)") ; if lab and not lab:match("^lst:") then warn(f, n, "listing label should start with lst: " .. lab) end
      for key in l:gmatch("\\label{([^}]*)}") do
        local expect
        local top = stack[#stack]
        if top and envpref[top] then expect = envpref[top] elseif top and listpref[top] then expect = listpref[top] elseif l:match("\\caption") then expect = nil elseif #stack == 0 and lastheading then expect = lastheading end
        local pref = key:match("^([^:]+):")
        if key:match("^page:") then expect = nil end
        if expect and pref ~= expect then
          if not (expect == "sec" and pref == "chap") and not (expect == "fig" and pref == "fig") then warn(f, n, string.format("label %s inside %s: expected prefix %s:", key, top or lastheading, expect)) end
        elseif not pref then warn(f, n, "label without a prefix: " .. key) end
      end
      for e in l:gmatch("\\end{([%a%*]+)}") do e = e:gsub("%*", ""); for i = #stack, 1, -1 do if stack[i] == e then table.remove(stack, i); break end end end
    end
  end
end)

rule("crefs", "source", true, "references go through \\cref: no 'Figure~\\ref', no \\autoref, \\Cref at the start of a sentence, and no bare \\ref outside table cells", function()
  C.each_line(MAIN, function(f, n, l)
    if l:match("[Ff]igure~?\\ref") or l:match("[Tt]able~?\\ref") or l:match("[Ss]ection~?\\ref") or l:match("[Cc]hapter~?\\ref") or l:match("[Ll]isting~?\\ref") then fail(f, n, "a typed reference with \\ref: write \\cref{...}") end
    if l:match("\\autoref") then fail(f, n, "\\autoref: the template uses cleveref, write \\cref") end
    if l:match("\\figref") or l:match("\\tabref") or l:match("\\sectref") or l:match("\\listref") then fail(f, n, "the faculty template's \\figref family: write \\cref") end
    if l:match("^%s*\\cref") or l:match("[%.%?!]%s+\\cref") then warn(f, n, "\\cref at the start of a sentence: use \\Cref") end
    if l:match("\\ref{") and not l:match("&") and not l:match("\\ref{req:") and not l:match("\\ref{g:") and not l:match("\\ref{c:") and not l:match("\\ref{asm:") and not l:match("\\ref{thr:") then warn(f, n, "bare \\ref in prose: \\cref names the kind of thing for you") end
    if l:match("\\pageref") then note(f, n, "\\pageref: rarely needed with hyperlinks") end
  end)
end)

rule("acronyms", "source", true, "every acronym used is declared, every declared one is used, and none is typed by hand where \\ac would expand it", function()
  local declared, short, used = {}, {}, {}
  C.each_line({ "content/acronyms.tex" }, function(f, n, l)
    local k = l:match("\\DeclareAcronym{([^}]*)}"); if k then declared[k] = { file = f, line = n } end
  end)
  -- short forms: the "short = X," lines, in order of declaration
  do
    local keys = {}
    local s = C.readfile("content/acronyms.tex") or ""
    for k, body in s:gmatch("\\DeclareAcronym{([^}]*)}%s*(%b{})") do
      local sh = body:match("short%s*=%s*([^,\n}]+)"); if sh then short[C.trim(sh)] = k end
    end
  end
  if next(declared) == nil then fail("content/acronyms.tex", nil, "no acronyms declared: content/acronyms.tex is missing or empty") end
  C.each_line(MAIN, function(f, n, l)
    for k in l:gmatch("\\[Aa]c[slpf]*%*?{([^}]*)}") do
      used[k] = true
      if not declared[k] then fail(f, n, "acronym " .. k .. " is not declared in content/acronyms.tex") end
    end
    local p = C.prose(l)
    for w in p:gmatch("%f[%w][%u][%u%d]+[%u]%f[%W]") do
      if short[w] and not l:match("\\ac[slpf]*%*?{" .. C.escape(short[w]) .. "}") then fail(f, n, string.format("%s typed by hand: write \\ac{%s}", w, short[w])) end
    end
  end)
  for k, at in pairs(declared) do if not used[k] then warn(at.file, at.line, "acronym " .. k .. " is declared but never used: remove it") end end
  -- undeclared all-caps words that look like acronyms, counted once each
  local seen = {}
  C.each_line(MAIN, function(f, n, l)
    for w in C.prose(l):gmatch("%f[%w][%u][%u%d]+[%u]%f[%W]") do
      if not short[w] and not seen[w] and #w >= 2 and #w <= 6 and not w:match("^RQ") and not w:match("^TODO") and not w:match("^[IVXLC]+$") then seen[w] = true; note(f, n, "possible acronym not declared: " .. w) end
    end
  end)
end)

rule("code", "source", true, "listings: \\lstinline is ASCII (XeLaTeX fails on Unicode there), every listing has a caption and a label, minted sits in a listing float", function()
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

rule("typography", "source", true, "the small things the reviewer sees: number ranges with --, a thin space before units, no straight quotes, no doubled words, \\eg and \\ie macros, no manual line breaks in prose", function()
  C.each_prose_line(MAIN, function(f, n, l)
    local p = C.prose(l)
    for a, b in p:gmatch("%f[%d](%d+)%-(%d+)%f[%D]") do if not l:match("\\label") and not l:match("label=") then warn(f, n, string.format("range %s-%s with a hyphen: write %s--%s", a, b, a, b)) end end
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
    if l:match("\\cite") and not l:match("~\\cite") and not l:match("{\\cite") and not l:match("\\citet") and not l:match("\\cite[tp]") and not l:match("^%s*\\cite") and not l:match("&%s*\\cite") then warn(f, n, "\\cite without a tie: write text~\\cite{...} so the number cannot start a line") end
  end)
end)

rule("terms", "source", true, "one name per concept: hyphenated, open and closed forms of the same compound do not coexist, and British and American spellings of the known pairs are not mixed", function()
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

rule("numbers", "source", true, "the headline numbers of the abstract and the conclusion appear in the evaluation, so the paper agrees with itself", function()
  local eval = C.prose(C.readfile("content/05-evaluation.tex") or "")
  local function nums(file)
    local out = {}
    local p = C.prose(table.concat(C.prose_lines(file), "\n"))
    for num in p:gmatch("%f[%d](%d+%.?%d*)%s*[%%×x]") do out[#out + 1] = num end
    for num in p:gmatch("%f[%d](%d+%.?%d*)%s*\\?,?%s*%a?%a?%a?%f[%W]") do if tonumber(num) and (tonumber(num) >= 20 or num:match("%.")) then out[#out + 1] = num end end
    return out
  end
  local missing = 0
  for _, f in ipairs({ "content/00-abstract.tex", "content/01-introduction.tex", "content/07-conclusion.tex" }) do
    for _, num in ipairs(nums(f)) do
      if not eval:find(num, 1, true) and not num:match("^20%d%d$") and not num:match("^19%d%d$") then missing = missing + 1; warn(f, nil, "number " .. num .. " does not occur in the evaluation chapter") end
    end
  end
  return string.format("missing=%d", missing)
end)

rule("aidecl", "source", true, "the AI declaration is filled in: exactly one box marked, and if AI was used, at least one row, the overall share and its justification", function()
  local f = "content/09-ai-declaration.tex"
  local s = C.readfile(f); if not s then fail(nil, nil, "no " .. f); return end
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

rule("titlepage", "source", true, "the title page variables are filled in: title, author, year, the second author where there is one", function()
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
rule("placeholders", "source", false, "what the template left for you: TODO strings, placeholder figures and tables, sample citations in the gap matrix, the Zenodo DOI", function()
  local todo, ph = 0, 0
  local files = {}
  for _, f in ipairs(CONTENT) do files[#files + 1] = f end
  files[#files + 1] = "thesis.tex"; files[#files + 1] = "bib/references.bib"
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

rule("beats", "source", false, "beats and notes still printing: the skeleton is done when every beat has become prose", function()
  local beats, todos = 0, 0
  C.each_line(MAIN, function(f, n, l)
    if l:match("\\beat{") then beats = beats + 1; note(f, n, "beat") end
    if l:match("\\todo") or l:match("\\atodo") or l:match("\\advisortodo") then todos = todos + 1 end
  end)
  return string.format("beats=%d notes=%d", beats, todos)
end)

rule("burndown", "source", false, "one line of JSON with the counts a draft drives to zero, for CI to collect over time", function()
  local function count(files, pat) local c = 0; C.each_line(files, function(_, _, l) c = c + C.count(l, pat) end); return c end
  local s, e
  for _, f in ipairs(MAIN) do for _, l in ipairs(C.lines(C.bpath(f:gsub("%.tex$", ".aux")))) do
    s = s or tonumber(l:match("^\\newlabel{page:main:start}{{[^}]*}{(%d+)}")); e = e or tonumber(l:match("^\\newlabel{page:main:end}{{[^}]*}{(%d+)}")) end end
  local j = string.format('{"date":"%s","pages":%d,"todo":%d,"beats":%d,"notes":%d,"placeholders":%d,"citations":%d,"figures":%d}',
    os.date("!%Y-%m-%d"), (s and e) and (e - s + 1) or 0, count(CONTENT, "TODO"), count(MAIN, "\\beat{"), count(MAIN, "\\a?d?v?i?s?o?r?todo%["),
    count(CONTENT, "[Pp]laceholder"), count(MAIN, "\\cite[tp]?{"), count(MAIN, "\\label{fig:"))
  io.write(j, "\n")
  return j
end)
