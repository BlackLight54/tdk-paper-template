-- What lint.lua prints besides its findings: the Checks page of the draft PDF (--tex), the guide's
-- reference of the essentials (essentials --guide, `make essentials`) and the essentials as JSON
-- (essentials --json, for work/essentials-labels.py). The page and the reference are LaTeX in the
-- paper's own style: booktabs rules, small caps, black ink and one accent for what is below the
-- phase. Their output is the same on every run of a day, so latexmk converges.
local lfs = require("lfs")
local C = require("lintcore")
local P = require("pagemap")
local M = {}

function M.esc(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\1"):gsub("([#$%%&_{}])", "\\%1"):gsub("~", "\\textasciitilde{}"):gsub("%^", "\\textasciicircum{}"):gsub("\1", "\\textbackslash{}")
  return s
end
local esc = M.esc
-- a file:line in typewriter that may break at its slashes
local function loc(file, line)
  if not file then return "" end
  local s = file .. (line and (":" .. line) or "")
  if s:find("[{}%%#\\]") then return "\\texttt{" .. esc(s) .. "}" end
  return "\\path{" .. s .. "}"
end

-- the macros both outputs use; \providecommand, so the page and the guide may both define them
M.MACROS = {
  "\\definecolor{lintaccent}{RGB}{155,28,28}\\definecolor{lintmute}{gray}{0.38}",
  "\\providecommand{\\lintdisc}[3]{\\tikz[baseline=-.6ex]{\\draw[#2,line width=.45pt,fill=white] (0,0) circle (#1);\\ifcase#3\\relax\\or\\fill[#2] (0,0) -- (0,#1) arc[start angle=90,end angle=0,radius=#1] -- cycle;\\or\\fill[#2] (0,0) -- (0,#1) arc[start angle=90,end angle=-90,radius=#1] -- cycle;\\or\\fill[#2] (0,0) -- (0,#1) arc[start angle=90,end angle=-180,radius=#1] -- cycle;\\or\\fill[#2] (0,0) circle (#1);\\fi}}",
  "\\providecommand{\\lintball}[2][black]{\\lintdisc{.62ex}{#1}{#2}}",
  "\\providecommand{\\lintbigball}[2][black]{\\lintdisc{.8ex}{#1}{#2}}",
}

local function legend()
  local names = { [0] = "missing", "placeholder", "started", "written", "used where the argument needs it" }
  local t = {}
  for l = 0, 4 do t[#t + 1] = string.format("\\lintball[lintmute]{%d}\\,%s", l, names[l]) end
  return "{\\footnotesize\\color{lintmute}" .. table.concat(t, "\\quad ") .. "\\par}"
end

-- the phase line: the four phases on a rule, the current one filled, each phase's level beneath
local function phase_line(E)
  local cur = C.phase()
  local phases = { "plan", "draft", "polish", "final" }
  local out = {}
  out[#out + 1] = "{\\setlength{\\tabcolsep}{0pt}\\noindent\\begin{tikzpicture}[x=\\linewidth]"
  out[#out + 1] = "\\useasboundingbox (0,-1ex) rectangle (1,1ex);\\draw[lintmute,line width=.4pt] (.125,0) -- (.875,0);"
  for i, p in ipairs(phases) do
    out[#out + 1] = string.format("\\filldraw[draw=black,line width=.5pt,fill=%s] (%.3f,0) circle (.55ex);", p == cur and "black" or "white", (i - .5) / 4)
  end
  out[#out + 1] = "\\end{tikzpicture}\\par\\nointerlineskip\\vspace{.4ex}"
  out[#out + 1] = "\\noindent\\begin{tabular}{@{}*{4}{>{\\centering\\arraybackslash}p{.25\\linewidth}}@{}}"
  local names, targets = {}, {}
  for _, p in ipairs(phases) do
    names[#names + 1] = p == cur and ("\\textbf{\\textsc{" .. p .. "}}") or ("\\textsc{" .. p .. "}")
    local tgt = string.format("all \\lintball[lintmute]{%d}", E.TARGET[p])
    if p == "final" then tgt = tgt .. " and the form" end
    if p == cur then tgt = tgt .. " (now)" end
    targets[#targets + 1] = "{\\footnotesize\\color{lintmute}" .. tgt .. "}"
  end
  out[#out + 1] = table.concat(names, " & ") .. "\\\\"
  out[#out + 1] = table.concat(targets, " & ") .. "\\\\"
  out[#out + 1] = "\\end{tabular}\\par}"
  return table.concat(out, "\n")
end

local function by_role(E, rows)
  local groups = {}
  for _, role in ipairs(E.ROLE_ORDER) do
    local g = {}
    for _, r in ipairs(rows) do if r.row.role == role then g[#g + 1] = r end end
    groups[#groups + 1] = { role = role, rows = g }
  end
  return groups
end

-- the fingerprint: every essential as one mark, grouped by chapter, between two rules
local function fingerprint(E, rows, t)
  local groups = by_role(E, rows)
  local cols, marks, labels = {}, {}, {}
  for _, g in ipairs(groups) do
    cols[#cols + 1] = "c"
    local m = {}
    for _, r in ipairs(g.rows) do m[#m + 1] = string.format("\\lintbigball[%s]{%d}", r.level >= t and "black" or "lintaccent", r.level) end
    marks[#marks + 1] = table.concat(m, "\\hspace{.12em}")
    labels[#labels + 1] = "{\\scriptsize\\color{lintmute}\\textsc{" .. E.ROLE_SHORT[g.role] .. "}}"
  end
  return table.concat({
    "\\noindent\\begin{tabular*}{\\linewidth}{@{\\extracolsep{\\fill}}" .. table.concat(cols) .. "@{}}",
    "\\toprule",
    table.concat(marks, " & ") .. "\\\\[.3ex]",
    table.concat(labels, " & ") .. "\\\\",
    "\\bottomrule",
    "\\end{tabular*}\\par",
  }, "\n")
end

-- the index: every essential under its chapter, three columns
local function index(E, rows, t)
  local groups = by_role(E, rows)
  -- the front matter last: the chapters read first
  local order = { 2, 3, 4, 5, 6, 1 }
  local out = {}
  for k, gi in ipairs(order) do
    local g = groups[gi]
    local ok = 0
    for _, r in ipairs(g.rows) do if r.level >= t then ok = ok + 1 end end
    local lines = {}
    lines[#lines + 1] = string.format("{\\textsc{%s}\\hfill{\\footnotesize\\color{lintmute}%d of %d}}\\par\\vspace{-.5ex}\\rule{\\linewidth}{.4pt}\\par\\vspace{.2ex}", esc(E.ROLE_TITLE[g.role]), ok, #g.rows)
    for _, r in ipairs(g.rows) do
      if r.level >= t then lines[#lines + 1] = string.format("\\lintball{%d}\\enspace %s\\par", r.level, esc(r.row.title))
      else lines[#lines + 1] = string.format("{\\color{lintaccent}\\lintball[lintaccent]{%d}\\enspace %s}\\par", r.level, esc(r.row.title)) end
    end
    out[#out + 1] = "\\begin{minipage}[t]{.3\\linewidth}\\setlength{\\parindent}{0pt}\\small\n" .. table.concat(lines, "\n") .. "\n\\end{minipage}"
    if k == 3 then out[#out + 1] = "\\par\\medskip\\noindent" elseif k < #order then out[#out + 1] = "\\hfill" end
  end
  return "\\noindent" .. table.concat(out, "\n")
end

local function next_steps(E, rows, t)
  local out = {}
  local head = "& \\textbf{Essential} & \\textbf{Next step} & \\textbf{Where} \\\\"
  out[#out + 1] = "{\\small\\begin{xltabular}{\\linewidth}{@{}p{1.1em}>{\\raggedright\\arraybackslash}p{.21\\linewidth}>{\\raggedright\\arraybackslash}X>{\\raggedright\\arraybackslash}p{.27\\linewidth}@{}}"
  out[#out + 1] = "\\toprule " .. head .. " \\midrule \\endfirsthead"
  out[#out + 1] = "\\toprule " .. head .. " \\midrule \\endhead \\bottomrule \\endlastfoot"
  local any = false
  for _, g in ipairs(by_role(E, rows)) do
    local below = {}
    for _, r in ipairs(g.rows) do if r.level < t then below[#below + 1] = r end end
    if #below > 0 then
      out[#out + 1] = string.format("%s\\multicolumn{4}{@{}l}{\\textsc{%s}} \\\\", any and "\\addlinespace[.8ex]" or "", esc(E.ROLE_TITLE[g.role]))
      for _, r in ipairs(below) do
        any = true
        local file = r.where and r.where.file or r.home
        local w = file and ("\\leavevmode{\\footnotesize\\color{lintmute}" .. loc(file:gsub("^content/", ""), r.where and r.where.line) .. "}") or ""
        out[#out + 1] = string.format("\\leavevmode\\lintball[lintaccent]{%d} & %s & %s & %s \\\\", r.level, esc(r.row.title), esc(r.next), w)
      end
    end
  end
  if not any then out[#out + 1] = "\\multicolumn{4}{@{}l}{Every essential has reached the level of this phase.} \\\\" end
  out[#out + 1] = "\\end{xltabular}}"
  return table.concat(out, "\n")
end

local STATUS = {
  fix = "\\leavevmode\\textcolor{lintaccent}{\\textsc{fix}}",
  suggestion = "\\textit{suggestion}",
}
local function status_cell(s)
  if STATUS[s] then return STATUS[s] end
  local p = s:match("^due at (%a+)$")
  if p then return "\\leavevmode{\\color{lintmute}\\textsc{due at " .. p .. "}}" end
  return esc(s)
end

local function findings_cell(res)
  local shown, extra = {}, 0
  for _, f in ipairs(res.findings) do
    if f.level ~= "notice" then
      if #shown < 3 then
        local where = f.file and (loc(f.file, f.line) .. " ") or ""
        local msg = f.msg
        if #msg > 150 then msg = msg:sub(1, 147):gsub("[\128-\191]*$", "") .. "..." end
        shown[#shown + 1] = where .. esc(msg)
      else extra = extra + 1 end
    end
  end
  local s = table.concat(shown, "\\newline ")
  if extra > 0 then s = s .. string.format("\\newline and %d more", extra) end
  -- a cell must not open with \newline: xltabular has no line to end there
  if res.ignored > 0 then s = s .. (s ~= "" and "\\newline " or "") .. string.format("(%d ignored)", res.ignored) end
  return s
end

local function other_checks(results)
  local out = {}
  local head = "\\textbf{Status} & \\textbf{Check} & \\textbf{Rule} \\\\"
  out[#out + 1] = "{\\small\\begin{xltabular}{\\linewidth}{@{}>{\\raggedright\\arraybackslash}p{.14\\linewidth}>{\\raggedright\\arraybackslash}X>{\\raggedright\\arraybackslash}p{.14\\linewidth}@{}}"
  out[#out + 1] = "\\toprule " .. head .. " \\midrule \\endfirsthead"
  out[#out + 1] = "\\toprule " .. head .. " \\midrule \\endhead \\bottomrule \\endlastfoot"
  local first = true
  for _, g in ipairs(P.GROUPS) do
    local shown, passing, nfix = {}, {}, 0
    for _, res in ipairs(results) do
      if res.rule ~= "essentials" and res.severity ~= "count" and P.group(res.rule) == g.id then
        if res.status == "pass" then passing[#passing + 1] = esc(P.title(res.rule)):gsub("^%u", string.lower)
        else shown[#shown + 1] = res; if res.status == "fix" then nfix = nfix + 1 end end
      end
    end
    if #shown + #passing > 0 then
      out[#out + 1] = string.format("%s\\multicolumn{3}{@{}l}{\\textsc{%s}\\enspace{\\footnotesize\\color{lintmute}--- %s}} \\\\", first and "" or "\\addlinespace[.8ex]", esc(g.title), nfix > 0 and (nfix .. " to fix") or "nothing to fix")
      first = false
      for _, res in ipairs(shown) do
        local f = findings_cell(res)
        out[#out + 1] = string.format("%s & %s%s & \\leavevmode{\\footnotesize\\color{lintmute}\\texttt{%s}} \\\\", status_cell(res.status), esc(P.title(res.rule)), f ~= "" and ("\\newline{\\footnotesize " .. f .. "}") or "", esc(res.rule))
      end
      if #passing > 0 then out[#out + 1] = string.format(" & \\leavevmode{\\footnotesize\\itshape\\color{lintmute}Passing: %s.} & \\\\", table.concat(passing, ", ")) end
    end
  end
  out[#out + 1] = "\\end{xltabular}}"
  return table.concat(out, "\n")
end

-- the counts table: the numbers the count rules and the page count report, when they ran
local function counts_table(results)
  local kv = {}
  for _, res in ipairs(results) do
    for k, v in (res.counts or ""):gmatch("([%w%-]+)=(%d+)") do kv[res.rule .. "." .. k] = v end
  end
  local cols = {
    { "pages.pages", "Pages", "main text, 30--35" },
    { "words.main", "Words", "main text" },
    { "placeholders.todo", "TODO", "strings left" },
    { "placeholders.placeholders", "Placeholders", "floats and tables" },
    { "beats.beats", "Beats", "still printing" },
  }
  local h, v, d = {}, {}, {}
  for _, c in ipairs(cols) do
    if kv[c[1]] then h[#h + 1] = "\\textbf{" .. c[2] .. "}"; v[#v + 1] = "{\\large " .. kv[c[1]] .. "}"; d[#d + 1] = "{\\footnotesize\\color{lintmute}" .. c[3] .. "}" end
  end
  if #h == 0 then return "" end
  return table.concat({
    "\\section*{Counts}",
    "{\\setlength{\\tabcolsep}{0pt}\\noindent\\begin{tabular}{@{}*{" .. #h .. "}{>{\\centering\\arraybackslash}p{" .. string.format("%.3f", 1 / #h) .. "\\linewidth}}@{}}",
    "\\toprule " .. table.concat(h, " & ") .. " \\\\ \\midrule",
    table.concat(v, " & ") .. " \\\\",
    table.concat(d, " & ") .. " \\\\ \\bottomrule",
    "\\end{tabular}\\par}",
  }, "\n")
end

function M.checks_page(results)
  local E = C.ESS
  local rows = C.ESSENTIALS
  local out = {}
  local function w(s) out[#out + 1] = s end
  w("% generated by texlua scripts/lint.lua overleaf --tex; do not edit")
  for _, m in ipairs(M.MACROS) do w(m) end
  w("\\chapter*{Checks}\\addcontentsline{toc}{chapter}{Checks}")
  local count = rows and #rows or 0
  w("\\noindent This page is rebuilt from the sources on every compile. Its first part measures the paper against the \\emph{essentials}, the " .. count .. " elements every paper of this kind contains (\\ifcsname r@app:writing:essentials\\endcsname\\cref{app:writing:essentials}\\else the guide's section on the essentials\\fi{} explains each, and why the review sheet asks for it). Its second part lists the remaining checks of the lint, grouped by what they examine. The phase, set by \\texttt{\\textbackslash lintphase} in \\texttt{thesis.tex}, fixes the level every essential must reach.\\par\\bigskip")
  w(phase_line(E))
  if rows then
    local t = E.target()
    w("\\section*{Essentials}")
    w(fingerprint(E, rows, t))
    w(string.format("{\\small\\noindent\\textsc{The paper at a glance.} One mark per essential, in reading order; %d of %d have reached the level of the \\textsc{%s} phase%s.\\par}\\bigskip", E.at_target(rows), #rows, esc(C.phase()), E.at_target(rows) < #rows and ", the rest are set in red" or ""))
    w(index(E, rows, t))
    w("\\par\\medskip\\noindent" .. legend())
    w("\\clearpage\\section*{What the essentials need next}")
    w(next_steps(E, rows, t))
  end
  w("\\section*{Other checks}")
  w(other_checks(C.results))
  w(counts_table(C.results))
  w("\\par\\medskip\\noindent\\rule{.4\\linewidth}{.4pt}\\par")
  w(string.format("{\\footnotesize\\color{lintmute}\\noindent Generated %s by \\texttt{texlua scripts/lint.lua overleaf}. The build log's own warnings and the PDF rules are not here: Overleaf shows the first, CI runs the second. A finding judged and rejected is silenced by \\texttt{\\%% lint-ignore: <id> <reason>} on its line.\\par}", os.date("%Y-%m-%d")))
  -- failing checks as package warnings, for Overleaf's log panel
  for _, res in ipairs(C.results) do
    if res.severity == "check" and res.status == "fix" then
      for _, f in ipairs(res.findings) do
        if f.level == "error" then
          local where = f.file and (f.file .. (f.line and (":" .. f.line) or "") .. ": ") or ""
          w(string.format("\\PackageWarningNoLine{tdk-lint}{%s: %s%s}", res.rule, where, (f.msg:gsub("[%%#{}\\]", " "):gsub("\n", " "))))
        end
      end
    end
  end
  return table.concat(out, "\n") .. "\n"
end

-- the guide's reference: the ladder, the targets, and every essential with how it is found,
-- when it counts as written and when as used
function M.guide()
  local E = C.ESS
  local out = {}
  local function w(s) out[#out + 1] = s end
  -- every row links to its item in action in the guide; a label no guide file defines stops the
  -- page, so `make essentials` and the template's CI step fail instead of printing a dead link
  local defined = {}
  for f in lfs.dir("guide") do
    if f:match("%.tex$") and f ~= "essentials.tex" then
      for key in (C.readfile("guide/" .. f) or ""):gmatch("\\label{([^}]*)}") do defined[key] = true end
    end
  end
  local undefined = {}
  for _, row in ipairs(E.ROWS) do
    if not row.example or not defined[row.example] then undefined[#undefined + 1] = row.id .. " (" .. tostring(row.example) .. ")" end
  end
  if #undefined > 0 then
    io.stderr:write("essentials --guide: no guide file defines the example of " .. table.concat(undefined, ", ") .. "\n")
    os.exit(1)
  end
  w("% generated by texlua scripts/lint.lua essentials --guide (make essentials); do not edit")
  for _, m in ipairs(M.MACROS) do w(m) end
  w("The lint places each essential on a ladder of five levels: \\lintball{0} missing; \\lintball{1} a placeholder, only TODO or the template's own text; \\lintball{2} started, your own text but not enough of it; \\lintball{3} written; \\lintball{4} used where the argument needs it. An essential with no condition for its use is \\lintball{4} once written. The phase in \\texttt{thesis.tex} asks every essential for a level: \\textsc{plan} \\lintball{" .. E.TARGET.plan .. "}, \\textsc{draft} \\lintball{" .. E.TARGET.draft .. "}, \\textsc{polish} and \\textsc{final} \\lintball{" .. E.TARGET.polish .. "}. An essential is found by its label first, then by a heading that contains one of the words given. Text is your own when it is neither a TODO line nor a line of the template, and floats, tagged lists and example boxes count toward their own essentials, not toward the text around them.")
  w("")
  w("{\\small\\begin{xltabular}{\\linewidth}{@{}>{\\raggedright\\arraybackslash}p{.25\\linewidth}>{\\raggedright\\arraybackslash}X>{\\raggedright\\arraybackslash}p{.3\\linewidth}@{}}")
  local head = "\\textbf{Essential} & \\textbf{What it is, and why} & \\textbf{Written, and used} \\\\"
  w("\\toprule " .. head .. " \\midrule \\endfirsthead")
  w("\\toprule " .. head .. " \\midrule \\endhead \\bottomrule \\endlastfoot")
  local role
  for _, row in ipairs(E.ROWS) do
    if row.role ~= role then w(string.format("%s\\multicolumn{3}{@{}l}{\\textsc{%s}} \\\\", role and "\\addlinespace[.8ex]" or "", esc(E.ROLE_TITLE[row.role]))); role = row.role end
    local found
    if row.kind == "text" then
      local hs = {}
      for _, h in ipairs(row.headings) do hs[#hs + 1] = "\\emph{" .. esc(h) .. "}" end
      found = "\\texttt{" .. esc(row.label) .. "}, or a heading with " .. table.concat(hs, " or ")
    elseif row.kind == "tags" then found = "items labelled \\texttt{" .. esc(row.prefix) .. ":}"
    elseif row.kind == "float" then found = "\\texttt{" .. esc(row.label) .. "}"
    elseif row.kind == "example" then found = "\\texttt{\\textbackslash exname} and the example box"
    else found = "\\texttt{\\textbackslash chapter*\\{Kivonat\\}} and \\texttt{\\{Abstract\\}}" end
    local written
    if row.kind == "text" then written = row.words .. " own words."
    elseif row.kind == "tags" then written = "Every item in your own words."
    elseif row.kind == "float" then written = "Your own content, and a caption of at least a sentence."
    elseif row.kind == "example" then written = "Named, and the introduction's box in your own words."
    else written = row.words .. " own words in each." end
    local used = row.used and ("Used when " .. esc(row.used) .. ".") or "Written is enough."
    w(string.format("\\textbf{%s}\\newline{\\footnotesize\\color{lintmute}%s}\\newline{\\footnotesize In action: \\cref{%s}} & %s.\\hfill{\\footnotesize\\color{lintmute}(%s)} & %s\\newline %s \\\\", esc(row.title), found, row.example, esc(row.why:gsub("^%l", string.upper)), esc(row.criterion), written, used))
  end
  w("\\end{xltabular}}")
  return table.concat(out, "\n") .. "\n"
end

-- JSON, by hand: texlua has no JSON library
local function js(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      local m = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
      return m[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  if t == "table" then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for _, x in ipairs(v) do parts[#parts + 1] = js(x) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = js(tostring(k)) .. ":" .. js(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end
function M.json()
  local E = C.ESS
  local rows = {}
  for _, r in ipairs(C.ESSENTIALS or {}) do
    local row = r.row
    rows[#rows + 1] = { id = row.id, role = row.role, kind = row.kind, title = row.title, level = r.level, glyph = E.GLYPH[r.level],
      next = r.next, via = r.via, cmd = r.cmd, label = r.label or row.label, prefix = row.prefix, key = row.key,
      where = r.where, words = r.words }
  end
  local roles = {}
  for _, role in ipairs(E.ROLE_ORDER) do roles[role] = C.role_files(role) end
  return js({ phase = C.phase(), target = E.target(), fingerprint = E.fingerprint(C.ESSENTIALS or {}), rows = rows, roles = roles, example_box = C.example_box() }) .. "\n"
end

return M
