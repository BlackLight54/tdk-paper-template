-- Shared helpers for the lint rules: files, findings, reporting, the rule registry.
local lfs = require("lfs")
local M = {}

M.opts = { dir = ".", doc = "thesis", profile = os.getenv("LINT_PROFILE") or "tdk", tex = false, json = false }
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

-- the content files are the ones thesis.tex reaches through \include, \input and
-- \loadglsentries, in the order it reaches them; the frame under include/ is followed but not
-- counted, the guide is skipped, and commented-out lines do not count. M.BIB holds the .bib
-- files of \bibliography. A paper without a thesis.tex that includes anything falls back to the
-- files in content/. The main-text chapters are the ones with a numbered \chapter; chapters are
-- found by role through their label, never by file name or folder, so a student may rename,
-- move or merge files. A chapter has role R if it carries \label{ch:R} or \label{ch:R:<name>}:
-- a role may span several chapters, and a chapter may have two roles. M.ROLES[R] lists the
-- chapters of R in reading order, M.ROLES_OF[file] is the set of a file's roles, and M.ROLE[R] is
-- the first chapter of R
M.CONTENT, M.MAIN, M.ROLE, M.ROLES, M.ROLES_OF, M.FILES, M.BIB = {}, {}, {}, {}, {}, {}, {}
M.ROLE_LABEL = { intro = "ch:intro", background = "ch:background", approach = "ch:approach", implementation = "ch:implementation", evaluation = "ch:evaluation", related = "ch:related", conclusion = "ch:conclusion" }
M.ROLE_NAME = { intro = "introduction", background = "background chapter", approach = "approach chapter", implementation = "implementation chapter", evaluation = "evaluation chapter", related = "related-work chapter", conclusion = "conclusion" }
M.MANDATORY = { "intro", "approach", "evaluation", "related", "conclusion" }
do
  local seen = {}
  local function under(p, dir) return p:sub(1, #dir) == dir end
  local function follow(f)
    if seen[f] then return end
    seen[f] = true
    local s = M.readfile(f)
    if not s then return end
    if f ~= "thesis.tex" and not under(f, "include/") then M.CONTENT[#M.CONTENT + 1] = f end
    for l in s:gmatch("[^\n]*") do
      for cmd, arg in M.strip_comment(l):gmatch("\\(%a+)%s*(%b{})") do
        arg = M.trim(arg:sub(2, -2))
        if cmd == "bibliography" then
          for b in arg:gmatch("[^,%s]+") do M.BIB[#M.BIB + 1] = b:match("%.bib$") and b or b .. ".bib" end
        elseif (cmd == "include" or cmd == "input" or cmd == "loadglsentries") and arg ~= "" and not arg:find("\\", 1, true) then
          local p = arg:match("%.tex$") and arg or arg .. ".tex"
          if not under(p, "guide/") then follow(p) end
        end
      end
    end
  end
  follow("thesis.tex")
  if #M.CONTENT == 0 and M.exists("content") then
    for f in lfs.dir("content") do if f:match("%.tex$") then M.CONTENT[#M.CONTENT + 1] = "content/" .. f end end
    table.sort(M.CONTENT)
  end
  if #M.BIB == 0 then M.BIB = { "bib/references.bib", "bib/zotero.bib" } end
  for _, f in ipairs(M.CONTENT) do
    local s = M.readfile(f) or ""
    local body = s:gsub("%%[^\n]*", "")
    if body:match("\\chapter{") then M.MAIN[#M.MAIN + 1] = f end
    for lab in body:gmatch("\\label{(ch:[^}]*)}") do
      local role = lab:match("^ch:([%a]+)$") or lab:match("^ch:([%a]+):.+$")
      if role and M.ROLE_LABEL[role] and not (M.ROLES_OF[f] and M.ROLES_OF[f][role]) then
        M.ROLES_OF[f] = M.ROLES_OF[f] or {}
        M.ROLES_OF[f][role] = true
        M.ROLES[role] = M.ROLES[role] or {}
        table.insert(M.ROLES[role], f)
        M.ROLE[role] = M.ROLE[role] or f
      end
    end
    if body:match("\\chapter%*{Abstract}") then M.FILES.abstract = f end
    if body:find("\\label{aidecl}", 1, true) then M.FILES.aidecl = f end
    if body:match("\\DeclareAcronym") or body:match("\\newabbreviation") or body:match("\\newglossaryentry") then M.FILES.glossary = f end
  end
end
-- the chapters of a role, in reading order; empty when no chapter has it
function M.role_files(r) return M.ROLES[r] or {} end
-- the text of all chapters of a role, joined in reading order
function M.role_text(r)
  local t = {}
  for _, f in ipairs(M.role_files(r)) do t[#t + 1] = M.readfile(f) or "" end
  return table.concat(t, "\n")
end
-- the main text's chapter files: the numbered chapters up to the appendix
function M.main_chapters()
  local out = {}
  for _, f in ipairs(M.MAIN) do
    if M.file_has(f, "\\appendix") then break end
    out[#out + 1] = f
  end
  return out
end
-- the environment of the running example's boxes: \lintexamplebox in thesis.tex, or the template's
function M.example_box() return (M.readfile("thesis.tex") or ""):match("\\newcommand{\\lintexamplebox}{(%a+)}") or "runningexample" end
-- the bibliography's entries by key: { type, body }, read once
local bib_cache
function M.bib_entries()
  if bib_cache then return bib_cache end
  bib_cache = {}
  for _, b in ipairs(M.BIB) do
    for typ, body in (M.readfile(b) or ""):gmatch("@(%a+)%s*(%b{})") do
      local key = body:match("^{%s*([^,%s]+)%s*,")
      if key then bib_cache[key] = { type = typ:lower(), body = body, file = b } end
    end
  end
  return bib_cache
end
-- every call of a command whose name passes want(name) in the printed text of the files (no
-- comments, commented-out environments, code, todo notes or beats: M.printed_lines), with up to
-- two optional [..] arguments and its first {..} argument, which may each be preceded by spaces
-- or a line break and may span lines, as TeX reads them: fn(file, line of the command, name, arg)
function M.each_call(files, want, fn)
  for _, f in ipairs(files) do
    local text = table.concat(M.printed_lines(f), "\n")
    local pos, line, counted = 1, 1, 1
    while true do
      local s, e, name = text:find("\\(%a+%*?)", pos)
      if not s then break end
      pos = e + 1
      if want(name) then
        local i = text:match("^%s*()", pos)
        for _ = 1, 2 do
          local _, be = text:find("^%b[]", i)
          if not be then break end
          i = text:match("^%s*()", be + 1)
        end
        local _, be = text:find("^%b{}", i)
        if be then
          line = line + M.count(text:sub(counted, s - 1), "\n"); counted = s
          fn(f, line, name, text:sub(i + 1, be - 1))
          pos = be + 1
        end
      end
    end
  end
end
-- every key cited by \cite, \citet, \citep, \citeauthor, \Citet and the rest of the family (not
-- \nocite, not the \citeneeded marker), as fn(file, line, key)
local function is_cite(name) return name:match("^[cC]ite%a*%*?$") ~= nil and name ~= "citeneeded" end
function M.each_cite(files, fn)
  M.each_call(files, is_cite, function(f, n, _, arg) for k in arg:gmatch("[^,%s]+") do fn(f, n, k) end end)
end
-- a rule that needs chapters by role calls this first; it fails with the right message and returns false
function M.roles_ok(list)
  local ok = true
  for _, r in ipairs(list) do
    if not M.ROLE[r] then M.fail(nil, nil, string.format("no %s: no chapter file carries \\label{%s} or \\label{%s:<name>}", M.ROLE_NAME[r], M.ROLE_LABEL[r], M.ROLE_LABEL[r])); ok = false end
  end
  return ok
end

-- a \newcommand in thesis.tex that the lint reads as its setting (\lintphase):
-- its body, trimmed, or nil when thesis.tex does not define it or defines it only in a comment
function M.setting(name)
  for _, l in ipairs(M.lines("thesis.tex")) do
    local v = M.strip_comment(l):match("\\%a*newcommand%s*{?%s*\\" .. name .. "%s*}?%s*(%b{})")
    if v then return M.trim(v:sub(2, -2)) end
  end
end
-- the manual phase: --phase, else LINT_PHASE, else \lintphase in thesis.tex, else plan. A value
-- that is none of the four is an error, never read as plan: lint.lua stops on it before any rule
function M.resolve_phase()
  local p, src = M.opts.phase, "--phase"
  if not p then
    p, src = os.getenv("LINT_PHASE"), "LINT_PHASE"
    if p == "" then p = nil end -- an empty variable is an unset one
  end
  if not p then p, src = M.setting("lintphase"), "\\lintphase in thesis.tex" end
  if not p then p, src = "plan", "the default" end
  M.opts.phase, M.opts.phase_source = p, src
  if not M.PHASES[p] then return nil, string.format("unknown phase '%s' from %s: use plan, draft, polish or final", p, src) end
  return p
end
function M.phase()
  if not M.opts.phase_source then M.resolve_phase() end
  return M.opts.phase
end
function M.phase_reached(due) if due == "always" then return true end; return M.PHASES[M.phase()] >= M.PHASES[due] end

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
end
-- findings are printed by M.report, after sorting, so the output is the same on every run
local function print_finding(f)
  if gh then
    local loc = f.file and ("file=" .. f.file .. (f.line and (",line=" .. f.line) or "")) or ""
    io.write(string.format("::%s %s::%s\n", f.level, loc, f.msg))
  else
    local tag = ({ error = " FAIL", warning = " warn", notice = "     " })[f.level]
    io.write(string.format("%s%s %s\n", f.file and (f.file .. (f.line and (":" .. f.line) or "") .. ":") or "", tag, f.msg))
  end
end
function M.fail(file, line, msg) finding("error", file, line, msg) end
-- the rule cannot run here (a tool is missing, the profile excludes it): its status is skipped,
-- not pass, and the reason is its one finding
M.skipped = nil
function M.skip(reason) M.skipped = reason; finding("notice", nil, nil, reason .. ": skipped") end
function M.warn(file, line, msg) finding("warning", file, line, msg) end
function M.note(file, line, msg) finding("notice", file, line, msg) end

M.results = {}
-- severity: check (fails on errors once its phase is reached), advice (warns, never fails), count (numbers)
-- status, in the words the Checks page and the job summary use: pass, fix (a check that fails now),
-- due at <phase> (a check that fails, but not yet), suggestion (advice with findings), count,
-- skipped (the rule did not run, M.skip)
function M.status(r, errors, warnings)
  if M.skipped then return "skipped" end
  if r.severity == "check" then
    if errors == 0 then return "pass" end
    return M.phase_reached(r.phase) and "fix" or ("due at " .. r.phase)
  elseif r.severity == "advice" then return (errors + warnings == 0) and "pass" or "suggestion" end
  return "count"
end
local ICON = { pass = ":white_check_mark:", fix = ":x:", suggestion = ":information_source:", count = ":1234:", skipped = ":fast_forward:" }
function M.report(rule, r, counts)
  -- a stable order: pairs() differs between runs, and the Checks page that lists these findings
  -- is input by the build, so an unstable order kept latexmk recompiling
  table.sort(M.findings, function(a, b)
    if (a.file or "") ~= (b.file or "") then return (a.file or "") < (b.file or "") end
    if (a.line or 0) ~= (b.line or 0) then return (a.line or 0) < (b.line or 0) end
    return a.msg < b.msg
  end)
  local quiet = M.opts.tex or M.opts.json
  if not quiet then for _, f in ipairs(M.findings) do print_finding(f) end end
  local errors, warnings = 0, 0
  for _, f in ipairs(M.findings) do
    if f.level == "error" then errors = errors + 1 elseif f.level == "warning" then warnings = warnings + 1 end
  end
  local gate = r.severity == "check" and M.phase_reached(r.phase) and not M.skipped -- a rule that did not run gates nothing
  local ok = errors == 0
  local status = M.status(r, errors, warnings)
  M.results[#M.results + 1] = { rule = rule, family = r.family, severity = r.severity, phase = r.phase, status = status, errors = errors, warnings = warnings, counts = counts, findings = M.findings, ignored = M.ignored }
  if not quiet then
    io.write(string.format("%s %-13s %-7s %-18s %d error(s), %d warning(s)%s%s\n", gate and (ok and "ok  " or "FAIL") or "    ", rule, r.severity, status, errors, warnings, counts and (" " .. counts) or "", M.ignored > 0 and (" ignored=" .. M.ignored) or ""))
  end
  if summary and r.summary ~= false then
    local h = io.open(summary, "a")
    if h then
      local P = require("pagemap")
      local found = r.severity == "count" and (counts or "") or ((errors + warnings == 0) and "" or string.format("%d error(s), %d warning(s)", errors, warnings))
      h:write(string.format("| %s | %s %s | %s | `%s` | %s |\n", P.group_title(P.group(rule)), ICON[status] or ":hourglass:", status, (P.title(rule):gsub("%-%-", "–")), rule, (found:gsub("|", "\\|"))))
      h:close()
    end
  end
  return not gate or ok
end
M.SUMMARY_HEADER = "| Group | Status | Check | Rule | Findings |\n|---|---|---|---|---|\n"
function M.summary_header(title)
  if not summary then return end
  local h = io.open(summary, "a"); if h then h:write("\n## " .. title .. "\n\n" .. M.SUMMARY_HEADER); h:close() end
end

-- rule registry ------------------------------------------------------------------------
M.RULES, M.ORDER = {}, {}
-- opts.summary = false: the rule writes its own section of the job summary instead of a table row
function M.rule(name, family, severity, phase, desc, fn, opts)
  M.RULES[name] = { family = family, severity = severity, phase = phase, desc = desc, fn = fn, summary = (opts or {}).summary }; M.ORDER[#M.ORDER + 1] = name
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
-- environments that hold no prose: commented-out text, pictures, code and display maths
M.NONPROSE = { "comment", "tikzpicture", "lstlisting", "minted", "forest", "equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*", "displaymath" }
-- environments whose text never prints as text: commented-out text and code. M.printed_lines
-- keeps pictures and maths, where a \cite or \url prints like anywhere else
M.UNPRINTED = { "comment", "lstlisting", "minted" }
function M.printed_lines(file) return M.prose_lines(file, M.UNPRINTED) end
function M.prose_lines(file, skip)
  local out, depth, intodo, inblock = {}, 0, false, nil
  for _, raw in ipairs(M.lines(file)) do
    local l = M.strip_comment(raw)
    local keep = {}
    local i = 1
    while i <= #l do
      if not intodo and not inblock then
        local s, e, name = l:find("\\(%a*todo)%s*%[?", i)
        local bs = l:find("\\beat{", i, true)
        local blk, bstart
        for _, b in ipairs(skip or M.NONPROSE) do
          local p = l:find("\\begin{" .. b .. "}", i, true)
          if p and (not bstart or p < bstart) then blk, bstart = "\\end{" .. b .. "}", p end
        end
        local dm = l:find("\\[", i, true) -- display maths \[ ... \], but not the line break \\[2pt]
        if dm and not skip and l:sub(dm - 1, dm - 1) ~= "\\" and (not bstart or dm < bstart) then blk, bstart = "\\]", dm end
        local first = math.min(s or math.huge, bs or math.huge, bstart or math.huge)
        if first == math.huge then keep[#keep + 1] = l:sub(i); break end
        keep[#keep + 1] = l:sub(i, first - 1)
        if first == bstart then inblock = blk; i = first + 1
        else intodo = true; depth = 0; i = first + 1 end
      elseif inblock then
        local e = l:find(inblock, i, true)
        if e then i = e + #inblock; inblock = nil else break end
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
  l = l:gsub("\\[cC]?ref%b{}", " "):gsub("\\[aA]utoref%b{}", " "):gsub("\\pageref%b{}", " "):gsub("\\nameref%b{}", " "):gsub("\\label%b{}", " ")
  l = l:gsub("\\includegraphics%b[]%b{}", " "):gsub("\\includegraphics%b{}", " "):gsub("\\includesvg%b[]%b{}", " "):gsub("\\includesvg%b{}", " "):gsub("\\input%b{}", " "):gsub("\\cite[tp]?%*?%b[]?%b{}", " "):gsub("\\cite[tp]?%*?%b{}", " ")
  l = l:gsub("\\texttt%b{}", " "):gsub("\\verb(.)(.-)%1", " "):gsub("\\lstinline%b[]%b{}", " "):gsub("\\lstinline%b{}", " "):gsub("\\mintinline%b{}%b{}", " ")
  l = l:gsub("\\ac[slpf]*%*?%b{}", " "):gsub("\\[Gg]ls[%a]*%*?%b{}", " "):gsub("\\begin{tabularx}%b{}%b{}", " "):gsub("\\begin{xltabular}%b{}%b{}", " "):gsub("\\begin{tabular%*}%b{}%b{}", " "):gsub("\\begin{tabular}%b[]%b{}", " "):gsub("\\begin{tabular}%b{}", " "):gsub("\\begin{longtable}%b{}", " ")
  l = l:gsub("\\begin%b{}%b[]", " "):gsub("\\begin%b{}", " "):gsub("\\end%b{}", " ")
  l = l:gsub("\\[%a@]+%*?", " ")
  return l
end

-- the template's skeleton chapters, copied into scripts/lint/skeleton by `make skeleton`: a line of
-- theirs is the template's, not the paper's, however long the skeleton chapter is
M.SKELETON = "scripts/lint/skeleton"
function M.skeleton_files()
  local out = {}
  if not M.exists(M.SKELETON) then return out end
  for e in lfs.dir(M.SKELETON) do if e:match("%.tex$") then out[#out + 1] = M.SKELETON .. "/" .. e end end
  table.sort(out)
  return out
end
function M.prose_key(l) return M.trim((M.prose(l):gsub("%s+", " "))) end
local skel_cache
function M.skeleton_lines()
  if skel_cache then return skel_cache end
  skel_cache = {}
  for _, f in ipairs(M.skeleton_files()) do
    for _, l in ipairs(M.prose_lines(f)) do
      local k = M.prose_key(l)
      if k ~= "" then skel_cache[k] = true end
    end
  end
  return skel_cache
end
-- own words of a prose line: not a TODO line, not a line of the template's skeleton
function M.own_words(l)
  if l:match("TODO") or M.skeleton_lines()[M.prose_key(l)] then return 0 end
  local n = 0
  for _ in M.prose(l):gmatch("%a%a+") do n = n + 1 end
  return n
end

return M
