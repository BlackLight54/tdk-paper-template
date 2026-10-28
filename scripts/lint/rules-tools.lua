-- Rules that wrap the tools TeX Live and the CI container provide: chktex, lacheck, texcount,
-- checkcites, the BibTeX log, hunspell. All report; none is a gate, because each has its noise.
local C = require("lintcore")
local rule, fail, warn, note = C.rule, C.fail, C.warn, C.note

rule("chktex", "tools", "advice", "always", "chktex: typographic slips in the sources (dashes, quotes, spacing before citations, \\ldots, maths in text)", function()
  if not C.have("chktex") then C.skip("chktex not installed"); return end
  local n = 0
  -- off: 1 command terminated with space, 3 \( \) advice, 8 dash length, 13 \@ after a capital, 24 space before \label (the template puts it on its own line), 36 brace spacing, 44 user regex, 46 \( \)
  local out = C.run("chktex -q -I0 -n1 -n3 -n8 -n13 -n24 -n36 -n44 -n46 -f '%f:%l:%n:%m\n' " .. table.concat(C.MAIN, " ") .. " " .. (C.FILES.abstract or "")) or ""
  for l in out:gmatch("[^\n]+") do
    local f, ln, code, msg = l:match("^([^:]+):(%d+):(%d+):(.*)$")
    if f and code == "2" and (C.lines(f)[tonumber(ln)] or ""):match("&") then f = nil end -- ~ before \ref inside table cells
    if f then n = n + 1; if n <= 60 then warn(f, tonumber(ln), string.format("chktex %s: %s", code, msg)) end end
  end
  return string.format("findings=%d", n)
end)

rule("lacheck", "tools", "advice", "always", "lacheck: unmatched braces and environments, missing \\@ after capitals, double spaces", function()
  if not C.have("lacheck") then C.skip("lacheck not installed"); return end
  local n = 0
  for _, f in ipairs(C.MAIN) do
    local out = C.run("lacheck " .. f) or ""
    for l in out:gmatch("[^\n]+") do
      local file, ln, msg = l:match('^"([^"]+)", line (%d+): (.*)$')
      if file and msg:match('before "\\ref') and (C.lines(file)[tonumber(ln)] or ""):match("&") then file = nil end -- table cells
      if file then n = n + 1; if n <= 60 then warn(file, tonumber(ln), "lacheck: " .. msg) end end
    end
  end
  return string.format("findings=%d", n)
end)

rule("words", "tools", "count", "polish", "texcount: words per chapter and in the abstract; there are no per-chapter budgets, this is for seeing where the paper is", function()
  if not C.have("texcount") then C.skip("texcount not installed"); return end
  local parts, total = {}, 0
  for _, f in ipairs(C.MAIN) do
    local out = C.run_quiet("texcount -q -1 -sum " .. f) or ""
    local w = tonumber(out:match("^%s*(%d+)")) or 0
    total = total + w
    local name = f:match("([^/]+)%.tex$") or f
    parts[#parts + 1] = (name:match("^%d%d%-(.+)$") or name) .. "=" .. w
  end
  -- the English abstract: the text after \chapter*{Abstract}, with the todo and the bracketed placeholders removed
  local abs = C.readfile(C.FILES.abstract or "content/00-abstract.tex") or ""
  local eng = abs:match("\\chapter%*{Abstract}(.*)$") or ""
  eng = eng:gsub("\\todo%b[]%b{}", ""):gsub("\\todo%b{}", ""):gsub("%%[^\n]*", ""):gsub("\\vfill.*$", "")
  local placeholders = C.count(eng, "%[%d ")
  local words = 0
  for _ in C.prose(eng):gmatch("%a[%a%-']+") do words = words + 1 end
  if placeholders > 0 then warn(C.FILES.abstract, nil, placeholders .. " of the seven placeholders of the abstract are still there")
  elseif words < 150 then warn(C.FILES.abstract, nil, string.format("the abstract is %d words: too short to say the problem, the approach and the result", words)) end
  return string.format("main=%d abstract=%d %s", total, words, table.concat(parts, " "))
end)

rule("checkcites", "tools", "count", "always", "checkcites: bibliography entries never cited (your reading list that has not reached the paper) and citations with no entry", function()
  if not C.have("checkcites") then C.skip("checkcites not installed"); return end
  local aux = C.bpath(C.opts.doc .. ".aux")
  if not C.exists(aux) then warn(nil, nil, "no " .. aux .. ": build first"); return end
  local out = C.run("checkcites --backend bibtex " .. aux) or ""
  local unused, undefined, mode = 0, 0, nil
  for l in out:gmatch("[^\n]+") do
    if l:match("Unused references") then mode = "unused" elseif l:match("Undefined references") then mode = "undefined" end
    local key = l:match("^%s*=>%s*(%S+)")
    if key then
      if mode == "unused" then unused = unused + 1; if unused <= 40 then note(nil, nil, "not cited: " .. key) end
      elseif mode == "undefined" then undefined = undefined + 1; warn(nil, nil, "cited but not in any .bib: " .. key) end
    end
  end
  return string.format("unused=%d undefined=%d", unused, undefined)
end)

rule("bibtex-log", "tools", "count", "always", "the BibTeX log: empty fields and other warnings BibTeX prints while building the bibliography", function()
  local blg = C.bpath(C.opts.doc .. ".blg")
  if not C.exists(blg) then warn(nil, nil, "no " .. blg .. ": build first"); return end
  local n = 0
  for _, l in ipairs(C.lines(blg)) do
    local msg = l:match("^Warning%-%-(.*)$")
    if msg then n = n + 1; if n <= 40 then warn(nil, nil, "bibtex: " .. msg) end end
  end
  return string.format("warnings=%d", n)
end)

rule("spelling", "tools", "advice", "always", "hunspell on the detexed chapters: unknown words, and whether British and American spellings are mixed", function()
  if not (C.have("hunspell") and C.have("detex")) then C.skip("hunspell or detex not installed"); return end
  local dicts = C.run("hunspell -D 2>&1 | grep -E '/en_(GB|US)$' | sed 's#.*/##' | sort -u") or ""
  local have_gb, have_us = dicts:match("en_GB") ~= nil, dicts:match("en_US") ~= nil
  if not (have_gb or have_us) then C.skip("no English hunspell dictionary"); return end
  local personal = C.exists("scripts/words.txt") and (" -p scripts/words.txt") or ""
  -- the prose only: todos, beats, pictures, code and maths removed, and the arguments that are not
  -- words (labels, references, citations, glossary keys, file names), written to a file for detex
  local tmp = os.tmpname()
  do
    local h = io.open(tmp, "w")
    for _, f in ipairs(C.MAIN) do h:write(C.prose(table.concat(C.prose_lines(f), "\n")), "\n") end
    -- the title and the English abstract, which the reviewer reads first
    local title = (C.readfile("thesis.tex") or ""):match("\\newcommand{\\vikcim}{([^}]*)}")
    if title then h:write(C.prose(title), "\n") end
    local abs = C.FILES.abstract and (C.readfile(C.FILES.abstract) or ""):match("\\chapter%*{Abstract}(.*)$")
    if abs then h:write(C.prose(table.concat((function() local t = {}; for l in abs:gmatch("[^\n]*") do t[#t + 1] = C.strip_comment(l) end; return t end)(), "\n")), "\n") end
    h:close()
  end
  local function unknown(dict)
    local out = C.run("detex " .. tmp .. " | tr -c \"[:alpha:]'\" '\\n' | grep -E \"^[A-Za-z][a-z']{3,}$\" | hunspell -d " .. dict .. personal .. " -l | sort | uniq -c | sort -rn") or ""
    local t, order = {}, {}
    for l in out:gmatch("[^\n]+") do local c, w = l:match("^%s*(%d+)%s+(%S+)"); if w then t[w] = tonumber(c); order[#order + 1] = w end end
    return t, order
  end
  local gb, gborder = {}, {}; local us, usorder = {}, {}
  if have_gb then gb, gborder = unknown("en_GB") end
  if have_us then us, usorder = unknown("en_US") end
  local american, british = {}, {}
  if have_gb and have_us then
    -- names (capitalised) are not spellings
    for w in pairs(gb) do if not us[w] and not w:match("^%u") then american[#american + 1] = w end end
    for w in pairs(us) do if not gb[w] and not w:match("^%u") then british[#british + 1] = w end end
    table.sort(american); table.sort(british)
    if #american >= 3 and #british >= 3 then
      note(nil, nil, string.format("words only one dictionary knows: American %s; British %s (the terms rule checks the known pairs)", table.concat(american, ", ", 1, math.min(8, #american)), table.concat(british, ", ", 1, math.min(8, #british))))
    end
  end
  local both, order = gb, gborder
  if have_gb and have_us then both = {}; order = {}; for w, c in pairs(gb) do if us[w] then both[w] = c; order[#order + 1] = w end end; table.sort(order, function(a, b) if both[a] ~= both[b] then return both[a] > both[b] end; return a < b end) end
  local shown = 0
  for _, w in ipairs(order) do
    if not w:match("^%u") then shown = shown + 1; if shown <= 40 then note(nil, nil, string.format("unknown word (%d): %s", both[w], w)) end end
  end
  os.remove(tmp)
  return string.format("unknown=%d american=%d british=%d (add project words to scripts/words.txt)", #order, #american, #british)
end)

rule("links", "tools", "advice", "always", "every \\url and \\href answers over the network; skipped when LINT_OFFLINE is set", function()
  if os.getenv("LINT_OFFLINE") or not C.have("curl") then C.skip("offline"); return end
  local urls, seen = {}, {}
  C.each_line(C.MAIN, function(f, n, l)
    for u in l:gmatch("\\url{([^}]*)}") do if not seen[u] then seen[u] = true; urls[#urls + 1] = { u = u, f = f, n = n } end end
    for u in l:gmatch("\\href{([^}]*)}") do if not seen[u] then seen[u] = true; urls[#urls + 1] = { u = u, f = f, n = n } end end
  end)
  local bad = 0
  for i, e in ipairs(urls) do
    if i > 60 then break end
    if e.u:match("^https?://") and not e.u:match("TODO") then
      local code = C.trim(C.run(string.format("curl -sS -o /dev/null -L --max-time 15 -A 'tdk-lint' -w '%%{http_code}' %q", (e.u:gsub("\\%%", "%%"):gsub("\\#", "#")))) or "000")
      if not code:match("^[23]%d%d$") and code ~= "405" then bad = bad + 1; warn(e.f, e.n, string.format("link answered %s: %s", code, e.u)) end
    end
  end
  return string.format("checked=%d broken=%d", math.min(#urls, 60), bad)
end)

-- tracked files no paper needs: build output (the CI publishes the PDFs as artifacts) and the
-- personal settings of an AI coding agent. git exists in CI and in a clone, not on Overleaf
local BUILD_OUTPUT = { "aux", "bbl", "blg", "fdb_latexmk", "fls", "lof", "lol", "lot", "out", "synctex.gz", "tdo", "thm", "toc", "xdv" }
rule("repo-hygiene", "tools", "check", "always", "the repository tracks no build output (aux, log, thesis.pdf, reviewer.pdf, minted caches, ...) and no personal agent settings", function()
  if not C.exists(".git") or not C.have("git") then C.skip("not a git checkout"); return end
  if not (C.run("git rev-parse --is-inside-work-tree 2>/dev/null") or ""):match("true") then C.skip("git cannot read this checkout"); return end
  local n = 0
  for f in (C.run_quiet("git ls-files") or ""):gmatch("[^\n]+") do
    local why
    for _, ext in ipairs(BUILD_OUTPUT) do if f:sub(-#ext - 1) == "." .. ext and f ~= "guide/guide.bbl" then why = "build output" end end
    if f:match("%.log$") or f == "thesis.pdf" or f == "reviewer.pdf" or f == "lint-checks.tex" or f:match("^_minted") or f:match("^svg%-inkscape/") then why = "build output" end
    if f:match("^%.claude/settings%.local%.json$") then why = "personal settings of an AI coding agent" end
    if why then
      -- a command, so the fix is shown and never written
      local q = f:match("^[%w%._/%-]+$") and f or "'" .. f:gsub("'", "'\\''") .. "'"
      n = n + 1; fail(f, nil, why .. " is tracked", "git rm --cached it (the .gitignore keeps it out afterwards)", C.fix("review", "stop tracking it", C.command("git rm --cached " .. q)))
    end
  end
  return string.format("tracked=%d", n)
end)
