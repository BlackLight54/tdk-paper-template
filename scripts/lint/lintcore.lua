-- Shared helpers for the lint rules: files, findings, reporting, the rule registry.
local lfs = require("lfs")
local M = {}

M.opts = { dir = ".", doc = "thesis", profile = os.getenv("LINT_PROFILE") or "tdk", tex = false }
M.PHASES = { plan = 1, draft = 2, polish = 3, final = 4 } -- the order of the manual phase in thesis.tex

function M.readfile(p) local h = io.open(p, "r"); if not h then return nil end; local s = h:read("a"); h:close(); return s end
function M.lines(p)
  local t = {}
  for l in (M.readfile(p) or ""):gmatch("([^\n]*)\n?") do t[#t + 1] = l end
  if t[#t] == "" then t[#t] = nil end
  return t
end
function M.exists(p) return lfs.attributes(p) ~= nil end
function M.bpath(p) return M.opts.dir .. "/" .. p end
function M.strip_comment(l) return (l:gsub("\\%%", "\1"):gsub("%%.*$", ""):gsub("\1", "\\%%")) end
function M.each_line(files, fn) for _, f in ipairs(files) do for n, l in ipairs(M.lines(f)) do fn(f, n, M.strip_comment(l)) end end end
function M.file_has(file, pattern) return (M.readfile(file) or ""):find(pattern) ~= nil end
function M.run(cmd) local h = io.popen(cmd .. " 2>&1"); if not h then return nil end; local s = h:read("a"); local ok = h:close(); return s, ok end
function M.run_quiet(cmd) local h = io.popen(cmd .. " 2>/dev/null"); if not h then return nil end; local s = h:read("a"); h:close(); return s end
function M.have(tool) local s = M.run("command -v " .. tool); return s ~= nil and s:match("%S") ~= nil end
function M.escape(s) return (s:gsub("%p", "%%%0")) end
function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function M.median(t) if #t == 0 then return nil end; table.sort(t); return t[math.ceil(#t / 2)] end
function M.count(s, pat) return select(2, s:gsub(pat, "")) end

-- the content files; the main-text chapters are the ones with a numbered \chapter; chapters are
-- found by role through their label (chap:intro, chap:approach, ...), never by file name, so a
-- student may rename or merge files
M.CONTENT, M.MAIN, M.ROLE, M.FILES = {}, {}, {}, {}
M.ROLE_LABEL = { intro = "chap:intro", background = "chap:background", approach = "chap:approach", implementation = "chap:implementation", evaluation = "chap:evaluation", related = "chap:related", conclusion = "chap:conclusion" }
M.ROLE_NAME = { intro = "introduction", background = "background chapter", approach = "approach chapter", implementation = "implementation chapter", evaluation = "evaluation chapter", related = "related-work chapter", conclusion = "conclusion" }
M.MANDATORY = { "intro", "approach", "evaluation", "related", "conclusion" }
if M.exists("content") then
  for f in lfs.dir("content") do if f:match("%.tex$") then M.CONTENT[#M.CONTENT + 1] = "content/" .. f end end
  table.sort(M.CONTENT)
  for _, f in ipairs(M.CONTENT) do
    local s = M.readfile(f) or ""
    local body = s:gsub("%%[^\n]*", "")
    if body:match("\\chapter{") then M.MAIN[#M.MAIN + 1] = f end
    for role, lab in pairs(M.ROLE_LABEL) do if body:find("\\label{" .. lab .. "}", 1, true) then M.ROLE[role] = f end end
    if body:match("\\chapter%*{Abstract}") then M.FILES.abstract = f end
    if body:find("\\label{aidecl}", 1, true) then M.FILES.aidecl = f end
    if body:match("\\DeclareAcronym") or body:match("\\newabbreviation") or body:match("\\newglossaryentry") then M.FILES.glossary = f end
  end
end
-- a rule that needs chapters by role calls this first; it fails with the right message and returns false
function M.roles_ok(list)
  local ok = true
  for _, r in ipairs(list) do
    if not M.ROLE[r] then M.fail(nil, nil, string.format("no %s: no chapter file carries \\label{%s}", M.ROLE_NAME[r], M.ROLE_LABEL[r])); ok = false end
  end
  return ok
end

-- the manual phase, from \newcommand{\lintphase}{...} in thesis.tex (or --phase / LINT_PHASE)
function M.phase()
  if M.opts.phase then return M.opts.phase end
  local p = os.getenv("LINT_PHASE")
  if not p then p = (M.readfile("thesis.tex") or ""):match("\\newcommand{\\lintphase}{(%a+)}") end
  M.opts.phase = p or "plan"
  return M.opts.phase
end
function M.phase_reached(due) if due == "always" then return true end; return (M.PHASES[M.phase()] or 1) >= (M.PHASES[due] or 1) end

-- findings and reporting -------------------------------------------------------------
local gh = os.getenv("GITHUB_ACTIONS") ~= nil
local summary = os.getenv("GITHUB_STEP_SUMMARY")
M.findings = {}
M.ignored = 0
M.current_rule = nil
-- "% lint-ignore: <rule> <reason>" on the line or the line above silences a finding; the reason is required
local function ignored(file, line)
  if not (file and line and M.current_rule) then return false end
  local ls = M.lines(file)
  for _, l in ipairs({ ls[line] or "", ls[line - 1] or "" }) do
    local rule, reason = l:match("%%%s*lint%-ignore:%s*([%w%-]+)%s*(.*)$")
    if rule == M.current_rule or rule == "all" then
      if not reason or #M.trim(reason) < 3 then
        M.findings[#M.findings + 1] = { level = "warning", file = file, line = line, msg = "lint-ignore without a reason: say why" }
        return false
      end
      M.ignored = M.ignored + 1
      return true
    end
  end
  return false
end
local function finding(level, file, line, msg)
  if ignored(file, line) then return end
  M.findings[#M.findings + 1] = { level = level, file = file, line = line, msg = msg }
  if M.opts.tex then return end
  if gh then
    local loc = file and ("file=" .. file .. (line and (",line=" .. line) or "")) or ""
    io.write(string.format("::%s %s::%s\n", level, loc, msg))
  else
    local tag = ({ error = " FAIL", warning = " warn", notice = "     " })[level]
    io.write(string.format("%s%s %s\n", file and (file .. (line and (":" .. line) or "") .. ":") or "", tag, msg))
  end
end
function M.fail(file, line, msg) finding("error", file, line, msg) end
function M.warn(file, line, msg) finding("warning", file, line, msg) end
function M.note(file, line, msg) finding("notice", file, line, msg) end

M.results = {}
-- severity: check (fails on errors once its phase is reached), advice (warns, never fails), count (numbers)
function M.report(rule, r, counts)
  local errors, warnings = 0, 0
  for _, f in ipairs(M.findings) do
    if f.level == "error" then errors = errors + 1 elseif f.level == "warning" then warnings = warnings + 1 end
  end
  local due = M.phase_reached(r.phase)
  local gate = r.severity == "check" and due
  local ok = errors == 0
  local status
  if r.severity == "check" then status = (not due) and ("report until " .. r.phase) or (ok and "ok" or "FAIL")
  elseif r.severity == "advice" then status = (errors + warnings == 0) and "clean" or "advice"
  else status = "count" end
  M.results[#M.results + 1] = { rule = rule, severity = r.severity, phase = r.phase, status = status, errors = errors, warnings = warnings, counts = counts, findings = M.findings, ignored = M.ignored }
  if not M.opts.tex then
    io.write(string.format("%s %-13s %-7s %-18s %d error(s), %d warning(s)%s%s\n", gate and (ok and "ok  " or "FAIL") or "    ", rule, r.severity, status, errors, warnings, counts and (" " .. counts) or "", M.ignored > 0 and (" ignored=" .. M.ignored) or ""))
  end
  if summary then
    local h = io.open(summary, "a")
    if h then
      local icon = gate and (ok and ":white_check_mark:" or ":x:") or (r.severity == "check" and ":hourglass:" or ((errors + warnings == 0) and ":white_check_mark:" or ":information_source:"))
      h:write(string.format("| %s | %s | %s | %s | %d | %d | %s |\n", rule, r.severity, r.phase == "always" and "" or r.phase, icon, errors, warnings, (counts or ""):gsub("|", "\\|")))
      h:close()
    end
  end
  return not gate or ok
end
function M.summary_header(title)
  if not summary then return end
  local h = io.open(summary, "a"); if h then h:write("\n## " .. title .. "\n\n| Rule | Severity | Due | Status | Errors | Warnings | Counts |\n|---|---|---|---|---|---|---|\n"); h:close() end
end

-- rule registry ------------------------------------------------------------------------
M.RULES, M.ORDER = {}, {}
function M.rule(name, family, severity, phase, desc, fn)
  M.RULES[name] = { family = family, severity = severity, phase = phase, desc = desc, fn = fn }; M.ORDER[#M.ORDER + 1] = name
end

-- label and reference index over the main chapters -------------------------------------
function M.collect_labels_and_refs(files)
  local labels, refs = {}, {}
  local depth = 0
  M.each_line(files, function(f, n, l)
    for key in l:gmatch("\\label{([^}]*)}") do labels[key] = { file = f, line = n, sub = depth > 0 } end
    depth = depth + M.count(l, "\\begin{sub[a-z]+}") - M.count(l, "\\end{sub[a-z]+}")
    for keys in l:gmatch("\\[Cc]ref{([^}]*)}") do for key in keys:gmatch("[^,%s]+") do refs[key] = (refs[key] or 0) + 1 end end
    for keys in l:gmatch("\\ref{([^}]*)}") do for key in keys:gmatch("[^,%s]+") do refs[key] = (refs[key] or 0) + 1 end end
    for key in l:gmatch("\\[Tt]plref{([^}]*)}") do refs[key] = (refs[key] or 0) + 1 end
  end)
  return labels, refs
end
function M.refs_in(file, pattern)
  local n = 0
  M.each_line({ file }, function(_, _, l)
    for keys in l:gmatch("\\[Cc]?ref{([^}]*)}") do for key in keys:gmatch("[^,%s]+") do if key:match(pattern) then n = n + 1 end end end
  end)
  return n
end

-- the prose lines of a file: comments, todo/beat/advisor notes (brace-balanced, across lines),
-- tikzpicture and axis blocks, and listings removed; line numbers preserved as empty lines
function M.prose_lines(file)
  local out, depth, intodo, inblock = {}, 0, false, nil
  for _, raw in ipairs(M.lines(file)) do
    local l = M.strip_comment(raw)
    local keep = {}
    local i = 1
    while i <= #l do
      if not intodo and not inblock then
        local s, e, name = l:find("\\(%a*todo)%s*%[?", i)
        local bs = l:find("\\beat{", i, true)
        local blk = l:match("\\begin{(tikzpicture)}", i) or l:match("\\begin{(lstlisting)}", i) or l:match("\\begin{(minted)}", i) or l:match("\\begin{(forest)}", i)
        local bstart = blk and l:find("\\begin{" .. blk .. "}", i, true)
        local first = math.min(s or math.huge, bs or math.huge, bstart or math.huge)
        if first == math.huge then keep[#keep + 1] = l:sub(i); break end
        keep[#keep + 1] = l:sub(i, first - 1)
        if first == bstart then inblock = blk; i = first + 1
        else intodo = true; depth = 0; i = first + 1 end
      elseif inblock then
        local e = l:find("\\end{" .. inblock .. "}", i, true)
        if e then i = e + #("\\end{" .. inblock .. "}"); inblock = nil else break end
      else -- inside a todo or beat: skip until its braces close (the optional [..] and 1-4 {..} groups)
        local c = l:sub(i, i)
        if c == "{" or c == "[" then depth = depth + 1 elseif c == "}" or c == "]" then depth = depth - 1 end
        i = i + 1
        if depth == 0 and (c == "}" or c == "]") then
          local nxt = l:sub(i, i)
          if nxt ~= "{" and nxt ~= "[" then intodo = false end
        end
      end
    end
    out[#out + 1] = table.concat(keep)
  end
  return out
end
function M.each_prose_line(files, fn) for _, f in ipairs(files) do for n, l in ipairs(M.prose_lines(f)) do if l:match("%S") then fn(f, n, l) end end end end

-- prose of a line: macros, math, labels, citations and urls removed, for word-level rules
function M.prose(l)
  l = l:gsub("%$[^$]*%$", " ")
  l = l:gsub("\\url%b{}", " "):gsub("\\href%b{}", " "):gsub("\\path%b{}", " ")
  l = l:gsub("\\[cC]?ref%b{}", " "):gsub("\\label%b{}", " "):gsub("\\cite[tp]?%*?%b[]?%b{}", " "):gsub("\\cite[tp]?%*?%b{}", " ")
  l = l:gsub("\\texttt%b{}", " "):gsub("\\verb(.)(.-)%1", " "):gsub("\\lstinline%b[]%b{}", " "):gsub("\\lstinline%b{}", " "):gsub("\\mintinline%b{}%b{}", " ")
  l = l:gsub("\\ac[slpf]*%*?%b{}", " "):gsub("\\[Gg]ls[%a]*%*?%b{}", " "):gsub("\\begin%b{}", " "):gsub("\\end%b{}", " ")
  l = l:gsub("\\[%a@]+%*?", " ")
  return l
end

return M
