-- Shared helpers for the lint rules: files, findings, reporting, the rule registry.
local lfs = require("lfs")
local M = {}

M.opts = { dir = ".", doc = "thesis", profile = os.getenv("LINT_PROFILE") or "tdk" }

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

-- the content files, and the main-text chapters among them
M.CONTENT, M.MAIN = {}, {}
if M.exists("content") then
  for f in lfs.dir("content") do if f:match("^%d%d%-.*%.tex$") then M.CONTENT[#M.CONTENT + 1] = "content/" .. f end end
  table.sort(M.CONTENT)
  for _, f in ipairs(M.CONTENT) do if f:match("content/0[1-7]") then M.MAIN[#M.MAIN + 1] = f end end
end

-- findings and reporting -------------------------------------------------------------
local gh = os.getenv("GITHUB_ACTIONS") ~= nil
local summary = os.getenv("GITHUB_STEP_SUMMARY")
M.findings = {}
local function finding(level, file, line, msg)
  M.findings[#M.findings + 1] = { level = level, file = file, line = line, msg = msg }
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

function M.report(rule, gate, counts)
  local errors, warnings = 0, 0
  for _, f in ipairs(M.findings) do
    if f.level == "error" then errors = errors + 1 elseif f.level == "warning" then warnings = warnings + 1 end
  end
  local ok = errors == 0
  io.write(string.format("%s %-13s %d error(s), %d warning(s)%s\n", ok and "ok  " or "FAIL", rule, errors, warnings, counts and (" " .. counts) or ""))
  if summary then
    local h = io.open(summary, "a")
    if h then
      local icon = gate and (ok and ":white_check_mark:" or ":x:") or ((errors + warnings == 0) and ":white_check_mark:" or ":hourglass:")
      h:write(string.format("| %s | %s | %d | %d | %s |\n", rule, icon, errors, warnings, (counts or ""):gsub("|", "\\|")))
      h:close()
    end
  end
  return gate and ok
end
function M.summary_header(title)
  if not summary then return end
  local h = io.open(summary, "a"); if h then h:write("\n## " .. title .. "\n\n| Rule | Status | Errors | Warnings | Counts |\n|---|---|---|---|---|\n"); h:close() end
end

-- rule registry ------------------------------------------------------------------------
M.RULES, M.ORDER = {}, {}
function M.rule(name, family, gate, desc, fn)
  M.RULES[name] = { family = family, gate = gate, desc = desc, fn = fn }; M.ORDER[#M.ORDER + 1] = name
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
