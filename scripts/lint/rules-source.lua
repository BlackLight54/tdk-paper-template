-- Rules on the LaTeX sources: the template's structures, the argument's traceability, and the
-- conventions the guide asks for. When a structure is absent the rule says so instead of
-- passing on nothing.
local C = require("lintcore")
local lfs = require("lfs")
local rule, fail, warn, note = C.rule, C.fail, C.warn, C.note
local MAIN, CONTENT = C.MAIN, C.CONTENT

-- template structure --------------------------------------------------------------------
-- a path for a shell command, quoted when it needs it
local function sh(x) return x:match("^[%w%._/%-]+$") and x or "'" .. x:gsub("'", "'\\''") .. "'" end
-- the fix of a content file that is not named NN-name.tex: git mv it to the number it has in the
-- reading order, and write the new name where thesis.tex includes it. It holds a command, so it is
-- shown and never written; no fix when thesis.tex does not include the file itself, or the new
-- name is taken
local function renumber_fix(f, num)
  local dir, base = f:match("^(.-)([^/]+)%.tex$")
  local name = base:gsub("^%d+[%-_ ]*", "")
  local new = dir .. string.format("%02d-", num) .. name .. ".tex"
  if name == "" or C.exists(new) then return nil end
  local stem = f:gsub("%.tex$", "")
  for n, raw in ipairs(C.raw_lines("thesis.tex")) do
    local code = C.strip_comment(raw)
    for _, arg in ipairs({ stem, f }) do
      local old = "{" .. arg .. "}"
      if code:find("\\include%s*" .. C.escape(old)) or code:find("\\input%s*" .. C.escape(old)) then
        local to = arg == stem and new:gsub("%.tex$", "") or new
        return C.fix("review", "number the file " .. string.format("%02d", num), C.command("git mv " .. sh(f) .. " " .. sh(new)), C.replace_at("thesis.tex", n, old, "{" .. to .. "}"))
      end
    end
  end
end

rule("frame", "source", "check", "always", "the template's frame is still there: its files, the chapter roles the essentials need, the preamble's macros, the packages, the class options, the spacing, the phase and the running example's name; what a paper must contain is the essentials' job", function()
  -- the files thesis.tex includes are named NN-name.tex, numbered in reading order (00-abstract,
  -- 01-introduction, ...); the glossary, loaded by the preamble, has no number
  -- the message names the number after the last numbered file, the same for a run of files
  -- without one; the fix numbers such a run one file after the other
  local last, want = -1, -1
  for _, f in ipairs(CONTENT) do
    if f ~= C.FILES.glossary then
      local nn = f:match("([^/]+)%.tex$"):match("^(%d%d)%-")
      if not nn then
        warn(f, nil, "content files are named NN-name.tex in reading order, " .. string.format("%02d", last + 1) .. "-<name>.tex here", renumber_fix(f, want + 1))
        want = want + 1
      elseif tonumber(nn) <= last then warn(f, nil, "numbered " .. nn .. " but included after " .. string.format("%02d", last), "number the files in reading order")
      else last = tonumber(nn) end
      want = math.max(want, last)
    end
  end
  if not C.roles_ok({ "approach", "conclusion", "evaluation", "intro", "related" }) then return end
  for _, f in ipairs({ "thesis.tex", "reviewer.tex", "include/packages.tex", "include/preamble.tex", "include/thesis-en.tex", "include/titlepage-tdk.tex", "include/macros.tex", C.FILES.glossary or "content/glossary.tex", "include/glossary-common.tex", C.FILES.abstract, C.FILES.aidecl, "scripts/lint.lua", "docs/TDK2025_biralati_pontozolap_hallgatoi.pdf" }) do
    if not C.exists(f) then fail(nil, nil, "missing from the template: " .. f) end
  end
  for _, b in ipairs(C.BIB) do if not C.exists(b) then fail("thesis.tex", nil, "\\bibliography names " .. b .. ", which does not exist") end end
  if #MAIN == 0 then fail(nil, nil, "no chapter files: no file thesis.tex includes has a numbered \\chapter"); return end
  if not C.FILES.abstract then fail(nil, nil, "no abstract file (a content file with \\chapter*{Abstract})") end
  if not C.FILES.aidecl then fail(nil, nil, "no AI declaration file (\\label{aidecl})") end
  if not C.FILES.glossary then fail(nil, nil, "no glossary file (\\newabbreviation or \\newglossaryentry in a file thesis.tex loads)") end
  if not C.setting("lintphase") then fail("thesis.tex", nil, "no \\lintphase in thesis.tex: the lint needs the phase (topic, setup, research, plan, draft, polish or submit)") end
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

-- renaming a label, for the labels and roles rules: the \label and every reference to it in the
-- content files, one edit per distinct command on a line. Only when the new key is free and the
-- old key stands nowhere else as an argument (a \hyperref, a \crefrange, a macro): such a reference
-- cannot be seen, and a rename that misses it breaks the build
local REF_CMDS = { ref = true, cref = true, Cref = true, autoref = true, pageref = true, nameref = true }
-- the places in a line where the text is a whole argument or list item: {key}, [key], {a, key}
local function occurrences(code, key)
  local n, init = 0, 1
  while true do
    local s, e = code:find(key, init, true)
    if not s then return n end
    if code:sub(1, s - 1):match("[{%[,]%s*$") and code:sub(e + 1):match("^%s*[}%],]") then n = n + 1 end
    init = e + 1
  end
end
local defined_cache
local function label_defined(key)
  if not defined_cache then
    defined_cache = {}
    for _, f in ipairs(CONTENT) do
      for _, raw in ipairs(C.raw_lines(f)) do for k in C.strip_comment(raw):gmatch("\\label{([^}]*)}") do defined_cache[C.trim(k)] = (defined_cache[C.trim(k)] or 0) + 1 end end
    end
  end
  return defined_cache[key]
end
local function rename_edits(old, new)
  if label_defined(new) or label_defined(old) ~= 1 then return nil end -- the new key is taken, or the old one is not one label's
  local edits = {}
  for _, f in ipairs(CONTENT) do
    for n, raw in ipairs(C.raw_lines(f)) do
      local code, hits, done, init = C.strip_comment(raw), 0, {}, 1
      while true do -- each command in turn, the ones inside another's argument too
        local s, e, cmd, star = code:find("\\(%a+)(%*?)", init)
        if not s then break end
        init = e + 1
        local arg = code:match("^%b{}", e + 1)
        if arg and (cmd == "label" or REF_CMDS[cmd]) then
          local changed = arg:sub(2, -2):gsub("[^,]+", function(tok)
            if C.trim(tok) ~= old then return nil end
            hits = hits + 1
            return (tok:gsub(C.escape(old), (new:gsub("%%", "%%%%")), 1))
          end)
          local text = "\\" .. cmd .. star .. arg
          if changed ~= arg:sub(2, -2) and not done[text] then
            done[text] = true
            edits[#edits + 1] = C.replace_at(f, n, text, "\\" .. cmd .. star .. "{" .. changed .. "}", true)
          end
        end
      end
      if occurrences(code, old) ~= hits then return nil end
    end
  end
  return #edits > 0 and edits or nil
end

-- the role a title or a label names: its lowercase words looked up here, when they name exactly one
local ROLE_WORDS = { introduction = "intro", background = "background", preliminaries = "background", approach = "approach", method = "approach", methods = "approach",
  design = "approach", implementation = "implementation", evaluation = "evaluation", results = "evaluation", result = "evaluation", experiments = "evaluation",
  experiment = "evaluation", related = "related", conclusion = "conclusion", conclusions = "conclusion", summary = "conclusion" }
local function role_of(text)
  local found, n = nil, 0
  for w in text:lower():gmatch("%a+") do
    local r = ROLE_WORDS[w]
    if r and r ~= found then found, n = r, n + 1 end
  end
  return n == 1 and found or nil
end
-- the first \chapter of a file that is not a comment: its line, its text, its title
local function chapter_line(f)
  for n, raw in ipairs(C.raw_lines(f)) do
    local cmd = C.strip_comment(raw):match("\\chapter%s*%b[]%s*%b{}") or C.strip_comment(raw):match("\\chapter%s*%b{}")
    if cmd then return n, cmd, cmd:match("%b{}$"):sub(2, -2) end
  end
end

rule("roles", "source", "check", "draft", "every chapter has a role: its label is ch:<role> or ch:<role>:<name>, the role one of intro, background, approach, implementation, evaluation, related, conclusion; a role may span several chapters, and a chapter may have two", function()
  local n = 0
  for _, f in ipairs(main_chapters()) do
    n = n + 1
    if not C.ROLES_OF[f] then
      local lab = ((C.readfile(f) or ""):gsub("%%[^\n]*", "")):match("\\label{(ch:[^}]*)}")
      if lab then
        local fix
        local role = role_of(lab:sub(4))
        local edits = role and rename_edits(lab, "ch:" .. role)
        if edits then fix = C.fix("review", "rename the label to ch:" .. role .. " and its references", table.unpack(edits)) end
        fail(f, 1, "the chapter label " .. lab .. " names no role", "use ch:<role> or ch:<role>:<name> (intro, background, approach, implementation, evaluation, related, conclusion)", fix)
      else
        -- the label goes right after the \chapter, which is not on line 1; a role guessed from the
        -- title is a review fix, a role the title does not name or a label already taken a placeholder
        local fix
        local ln, cmd, title = chapter_line(f)
        if ln then
          local role = role_of(title)
          if role and not label_defined("ch:" .. role) then
            fix = C.fix("review", "label the chapter ch:" .. role, C.replace_at(f, ln, cmd, cmd .. "\\label{ch:" .. role .. "}"))
          elseif role then
            fix = C.fix("placeholder", "ch:" .. role .. " is taken: name this chapter", C.replace_at(f, ln, cmd, cmd .. "\\label{ch:" .. role .. ":<name>}"))
          else
            fix = C.fix("placeholder", "label the chapter with its role", C.replace_at(f, ln, cmd, cmd .. "\\label{ch:<role>}"))
          end
        end
        fail(f, 1, "no role label", "give the chapter \\label{ch:<role>} or \\label{ch:<role>:<name>}", fix)
      end
    end
  end
  return string.format("chapters=%d", n)
end)

-- a gap is a \tbd or \citeneeded marker, which the draft shows and the todo list counts; typed
-- markers (TBD, [CITE: ...], [?], [forrás?], [link?], XXX, FIXME) print in the reviewer PDF
local TYPED = { { "%f[%w]TBD%f[%W]", "TBD" }, { "%[[Cc][Ii][Tt][Ee]", "[CITE" }, { "%[%?%]", "[?]" },
  { "%[forrás%?%]", "[forrás?]" }, { "%[link%?%]", "[link?]" }, { "%f[%w]XXX+%f[%W]", "XXX" }, { "%f[%w]FIXME%f[%W]", "FIXME" } }
-- the fix of a typed marker: \tbd{<what is missing>} or \citeneeded[<which source>] for the author
-- to fill (a placeholder), and for [CITE: text] the \citeneeded[text] that says the same (review).
-- It covers every marker of its kind on the line, and only when the raw line holds as many as the
-- prose does; a paper that does not define the macro gets none
local function marker_fix(f, n, l, t)
  local kind = t[2]
  local gap = (kind == "TBD" or kind == "XXX" or kind == "FIXME")
  if not C.defines(gap and "tbd" or "citeneeded") then return nil end
  local known, edits = true, nil
  if kind == "[CITE" then
    edits = C.matches(C.raw_lines(f)[n], "%b[]", function(m)
      local body = m:match("^%[[Cc][Ii][Tt][Ee]%f[%A](.*)%]$")
      if not body then return nil end
      local text = C.trim((body:gsub("^%s*:", "")))
      if text == "" or text:find("[%[%]]") then known, text = false, "<which source>" end
      return "\\citeneeded[" .. text .. "]"
    end)
  else
    edits = C.matches(C.raw_lines(f)[n], t[1], function() return gap and "\\tbd{<what is missing>}" or "\\citeneeded[<which source>]" end)
    known = false
  end
  if #edits ~= C.nmatch(l, t[1]) then return nil end
  return C.fix(known and "review" or "placeholder", gap and "write \\tbd" or "write \\citeneeded", table.unpack(edits))
end

rule("markers", "source", "check", "draft", "gaps are marked with \\tbd{...} or \\citeneeded[...], which the draft shows and the reviewer build hides: never typed as TBD, [CITE], [?] or XXX; at the submit phase no marker is left", function()
  local final = C.phase_reached("submit")
  local gaps = 0
  for _, f in ipairs(CONTENT) do
    for n, l in ipairs(C.prose_lines(f)) do
      for _, t in ipairs(TYPED) do
        if l:find(t[1]) then fail(f, n, "a typed " .. t[2] .. " prints in the reviewer PDF", "write \\tbd{what is missing} or \\citeneeded[which source] instead", marker_fix(f, n, l, t)) end
      end
      for m in l:gmatch("\\(%a+)") do
        if m == "tbd" or m == "citeneeded" then
          gaps = gaps + 1
          if final then fail(f, n, "\\" .. m .. " is still here", "fill the gap before you submit") end
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
      if l:match("\\chapter{") then n = n + 1; if n == 2 then fail(f, ln, "a second chapter in one file", "each chapter is its own content/NN-name.tex") end end
      for arg in l:gmatch("\\input%s*(%b{})") do
        local p = arg:sub(2, -2)
        if not p:match("^include/") then warn(f, ln, "\\input{" .. p .. "} pulls part of the chapter from another file", "keep the chapter in one file") end
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
    for i = concl + 1, #mains do warn(mains[i], 1, "a chapter after the conclusion", "future work and outlook belong in the conclusion, anything else before it") end
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

rule("pages", "source", "check", "submit", "main text, from the first numbered chapter to the page before the back matter (read from the .toc), is 30-35 pages", function()
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
    if C.file_has(f, "\\chapter{Approach}") then
      -- the fix is on the \chapter line, wherever it is, not on the finding's line 2
      local fix
      for ln, raw in ipairs(C.raw_lines(f)) do
        if C.strip_comment(raw):find("\\chapter{Approach}", 1, true) then
          fix = C.fix("placeholder", "name the chapter after your method", C.replace_at(f, ln, "\\chapter{Approach}", "\\chapter{<your method's name>}"))
          break
        end
      end
      warn(f, 2, "the chapter is still called Approach", "rename it after your method", fix)
    end
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
    if l:match("\\begin{figure}%[h%]") or l:match("\\begin{table}%[h%]") then
      warn(f, n, "[h] alone", "use [!ht] or [tbp], LaTeX ignores a bare h", C.fix("safe", "write [!ht]", table.unpack(C.matches(l, "\\begin{(%a+)}%[h%]", function(_, _, _, env)
        if env == "figure" or env == "table" then return "\\begin{" .. env .. "}[!ht]" end
      end))))
    end
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
      if words < 4 and not text:match("TODO") then warn(f, n, "caption is " .. words .. " words", "a caption is the figure's own paragraph") end
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
        if spec:match("|") then fail(f, n, "vertical lines in a table", "booktabs tables have none") end
      end
      if intab then
        if l:match("\\hline") then warn(f, n, "\\hline", "use \\toprule, \\midrule, \\bottomrule") end
        if l:match("\\toprule") then hasrule = true end
        if l:match("\\end{tabularx?}") or l:match("\\end{longtable}") or l:match("\\end{xltabular}") then
          if not hasrule then warn(f, start, "table without \\toprule", "use the booktabs rules") end
          intab = false
        end
      end
      if l:match("\\begin{tabular}") and not l:match("\\begin{tabularx}") and (raw:match("X") == nil) then
        local cols = l:match("\\begin{tabular}(%b{})") or ""
        local nc = C.count(cols, "[lcrp]"); if nc >= 6 then warn(f, n, "a wide tabular", "use tabularx with \\linewidth so it cannot overflow") end
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
        if key:match(":%d+[%.%d]*$") then warn(f, n, "label " .. key .. " encodes a number, which lies once chapters move", "name it after what it labels") end
        local expect
        local top = stack[#stack]
        if top and envpref[top] then expect = envpref[top] elseif top and listpref[top] then expect = listpref[top] elseif l:match("\\caption") then expect = nil elseif #stack == 0 and lastheading then expect = lastheading end
        local pref = key:match("^([^:]+):")
        if key:match("^page:") then expect = nil end
        if expect and pref ~= expect then
          -- subsec: and subsubsec: are common enough for subsections to count as sec:
          if not (expect == "sec" and (pref == "ch" or pref == "subsec" or pref == "subsubsec")) and not (expect == "fig" and pref == "fig") then
            -- the label gets the expected prefix on its own name (fig:x in a table is tab:x, x in a
            -- section is sec:x), and so does every reference to it
            local fix
            local rest = pref and key:sub(#pref + 2) or key
            local edits = rest ~= "" and rename_edits(key, expect .. ":" .. rest)
            if edits then fix = C.fix("review", "rename the label to " .. expect .. ":" .. rest .. " and its references", table.unpack(edits)) end
            warn(f, n, string.format("label %s inside %s", key, top or lastheading), string.format("expected prefix %s:", expect), fix)
          end
        elseif not pref then warn(f, n, "label without a prefix: " .. key) end -- no prefix is expected here: nothing to rename to
      end
      for e in l:gmatch("\\end{([%a%*]+)}") do e = e:gsub("%*", ""); for i = #stack, 1, -1 do if stack[i] == e then table.remove(stack, i); break end end end
    end
  end
end)

-- the fixes of the crefs rule: the \cref that prints what the typed reference printed (cleveref is
-- loaded with capitalise and noabbrev, so \cref{fig:x} prints "Figure 1.1"), \Cref where a
-- sentence starts; each covers every occurrence on the line
local function opens_sentence(code, s)
  local before = code:sub(1, s - 1)
  return before:match("^%s*$") ~= nil or before:match("[%.%?!]%s+$") ~= nil
end
local function cref(code, s, key) return (opens_sentence(code, s) and "\\Cref{" or "\\cref{") .. key .. "}" end
local TYPED_REF = { figure = true, table = true, section = true, chapter = true, listing = true }
local FACULTY_REF = { fig = true, tab = true, sect = true, list = true }
local function cref_fix(l, pattern, ok)
  if not C.loads("cleveref") then return nil end -- a paper without cleveref has no \cref
  return C.fix("safe", "write \\cref, or \\Cref where a sentence starts", table.unpack(C.matches(l, pattern, function(_, s, code, a, b)
    if ok(a) then return cref(code, s, b) end
  end)))
end
-- the words cleveref prints before a number: \cref{fig:x} is "Figure 1", so the typed word goes
local CLEVER = { figure = true, table = true, section = true, chapter = true, listing = true, appendix = true, algorithm = true, theorem = true, lemma = true, definition = true, equation = true }
-- and their abbreviations, typed with a full stop: Fig.~\ref{x} is \cref{x} too
local ABBREV = { ["fig."] = true, ["tab."] = true, ["sec."] = true, ["sect."] = true, ["ch."] = true, ["chap."] = true, ["eq."] = true, ["alg."] = true,
  ["thm."] = true, ["def."] = true, ["lem."] = true, ["app."] = true, ["lst."] = true }
local TAGGED = { "req:", "g:", "c:", "asm:", "thr:", "dr:" }
-- the fix of a bare \ref: \cref for it, with the word before it gone when that is a cleveref name
-- (Section~\ref{x} is \cref{x}). A \ref in a list or a range (Figures~\ref{a} and~\ref{b}, \ref{a},
-- \ref{b}, \ref{a}--\ref{b}) is left, since \cref would print the name again, and so is a tagged
-- one, which the rule exempts. Review, since \cref prints a name where \ref printed a number
local function ref_fix(l)
  if not C.loads("cleveref") then return nil end
  return C.fix("review", "write \\cref, and drop the word before it", table.unpack(C.matches(l, "(%a*%.?)([~ ]*)\\ref{([^}]*)}", function(_, s, code, word, sep, key)
    for _, tag in ipairs(TAGGED) do if key:sub(1, #tag) == tag then return nil end end
    local before, lw = code:sub(1, s - 1), word:lower()
    if before:match(",$") or before:match("%-$") then return nil end
    if lw == "and" or lw == "or" then return nil end
    if lw:sub(-1) == "s" and CLEVER[lw:sub(1, -2)] then return nil end
    if lw:match("s%.$") and ABBREV[lw:sub(1, -3) .. "."] then return nil end
    -- Eq.~(\ref{x}): the name stays outside the parenthesis, so \cref would print it twice
    local named = before:match("(%a+%.?)[~ ]*%($")
    if named and (CLEVER[named:lower()] or ABBREV[named:lower()]) then return nil end
    if CLEVER[lw] or ABBREV[lw] then
      if sep == "" then return nil end
      return cref(code, s, key)
    end
    return word .. sep .. cref(code, s + #word + #sep, key)
  end)))
end

-- the printed lines only, and nothing inside \verb, \lstinline or a link: a Figure~\ref in a code
-- listing is the program's text, and no fix touches it (lintcore.lua, M.literal_spans)
rule("crefs", "source", "check", "always", "references go through \\cref: no 'Figure~\\ref', no \\autoref, \\Cref at the start of a sentence, and no bare \\ref outside table cells", function()
  C.each_printed_line(MAIN, function(f, n, raw)
    local l = C.unliteral(raw)
    if l:match("[Ff]igure~?\\ref") or l:match("[Tt]able~?\\ref") or l:match("[Ss]ection~?\\ref") or l:match("[Cc]hapter~?\\ref") or l:match("[Ll]isting~?\\ref") then fail(f, n, "a typed reference with \\ref", "write \\cref{...}", cref_fix(l, "(%a+)~?\\ref{([^}]*)}", function(w) return TYPED_REF[w:lower()] end)) end
    if l:match("\\autoref") then fail(f, n, "\\autoref", "the template uses cleveref, write \\cref", cref_fix(l, "\\(auto)ref{([^}]*)}", function() return true end)) end
    if l:match("\\figref") or l:match("\\tabref") or l:match("\\sectref") or l:match("\\listref") then fail(f, n, "the faculty template's \\figref family", "write \\cref", cref_fix(l, "\\(%a+)ref{([^}]*)}", function(w) return FACULTY_REF[w] end)) end
    if l:match("^%s*\\cref") or l:match("[%.%?!]%s+\\cref") then
      warn(f, n, "\\cref at the start of a sentence", "use \\Cref", C.loads("cleveref") and C.fix("safe", "write \\Cref", table.unpack(C.matches(l, "\\cref{", function(_, s, code) if opens_sentence(code, s) then return "\\Cref{" end end))) or nil)
    end
    if l:match("\\ref{") and not l:match("&") and not l:match("\\ref{req:") and not l:match("\\ref{g:") and not l:match("\\ref{c:") and not l:match("\\ref{asm:") and not l:match("\\ref{thr:") and not l:match("\\ref{dr:") then warn(f, n, "bare \\ref in prose", "\\cref names the kind of thing for you", ref_fix(l)) end
    if l:match("\\pageref") then note(f, n, "\\pageref: rarely needed with hyperlinks") end
  end)
end)

rule("acronyms", "source", "check", "polish", "glossary entries: every \\gls key is declared in content/glossary.tex or the common glossary, every abbreviation the paper declares is used, none is typed by hand (common ones included), every all-caps word is declared, and every symbol of a definition has a notation entry", function()
  local G = C.FILES.glossary or "content/glossary.tex"
  local CG = C.FILES.common_glossary
  local declared, short, used, kind, lastabbr = {}, {}, {}, {}, nil
  -- the entries of one glossary file, in file order: key, short form (abbreviations), kind, line
  local function entries(file)
    local t = {}
    C.each_line({ file }, function(f, n, l)
      local k, sh = l:match("\\newabbreviation%b[]{([^}]*)}{([^}]*)}")
      if not k then k, sh = l:match("\\newabbreviation{([^}]*)}{([^}]*)}") end
      if k then t[#t + 1] = { key = k, short = sh, kind = "abbreviation", file = f, line = n } end
      local s1 = l:match("\\glsxtrnewsymbol%b[]{([^}]*)}") or l:match("\\glsxtrnewsymbol{([^}]*)}")
      if s1 then t[#t + 1] = { key = s1, kind = "symbol", file = f, line = n } end
      local t1 = l:match("\\newglossaryentry{([^}]*)}")
      if t1 then t[#t + 1] = { key = t1, kind = "term", file = f, line = n } end
    end)
    return t
  end
  -- the paper's own entries; a fix that declares an abbreviation goes after its last one
  for _, e in ipairs(entries(G)) do
    declared[e.key] = { file = e.file, line = e.line }; kind[e.key] = e.kind
    if e.short then short[e.short] = e.key; lastabbr = e.line end
  end
  -- the common glossary fills in what the paper has not declared; its entries need not be used
  local cshort = {}
  for _, e in ipairs(CG and entries(CG) or {}) do
    if e.short then cshort[e.short] = e.key end
    if not declared[e.key] then
      declared[e.key] = { file = e.file, line = e.line, common = true }; kind[e.key] = e.kind
      if e.short and not short[e.short] then short[e.short] = e.key end
    end
  end
  -- a paper entry with a common short form under another key prints the abbreviation twice
  -- once a chapter uses the common key
  for _, e in ipairs(entries(G)) do
    local ck = e.short and cshort[e.short]
    if ck and ck ~= e.key then warn(e.file, e.line, string.format("%s is also the common glossary's %s", e.short, ck), string.format("use \\gls{%s}, or declare your entry under the key %s to replace the common one", ck, ck)) end
  end
  if next(declared) == nil then fail(G, nil, "no glossary entries: content/glossary.tex and the common glossary are missing or empty") end
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
  local glossaries = C.loads("glossaries-extra") or C.loads("glossaries")
  C.each_prose_line(MAIN, function(f, n, l)
    for k in l:gmatch("\\[Gg]ls[%a]*%*?{([^}]*)}") do
      used[k] = true
      if not declared[k] then fail(f, n, "glossary key " .. k .. " is not declared in " .. G .. " or the common glossary") end
    end
    local p = C.prose(l)
    for _, fm in ipairs(forms) do
      if p:find(fm.pat) then
        -- \gls for the short form and \glspl for its plural, when the raw line holds as many as the
        -- prose does (a \texttt{VC} or a \url is not ours to change); a review fix, since \gls
        -- prints the long form at the first use
        local fix
        local raw = C.raw_lines(f)[n]
        if glossaries and C.nmatch(C.strip_comment(raw), fm.pat) == C.nmatch(p, fm.pat) then
          fix = C.fix("review", "write \\gls{" .. fm.key .. "}", table.unpack(C.matches(raw, fm.pat, function(m)
            return (#m > #fm.short and "\\glspl{" or "\\gls{") .. fm.key .. "}"
          end)))
        end
        fail(f, n, fm.short .. " typed by hand", "write \\gls{" .. fm.key .. "}", fix)
      end
    end
  end)
  for k, at in pairs(declared) do
    if not used[k] and not at.common then
      if kind[k] == "abbreviation" then warn(at.file, at.line, "abbreviation " .. k .. " is declared but never used", "remove it")
      else note(at.file, at.line, kind[k] .. " " .. k .. " is declared but never used with \\gls, so it will not print") end
    end
  end
  -- a definition that introduces a symbol should have a notation entry: look for $...$ in definition environments
  for _, f in ipairs(MAIN) do
    local indef = false
    for n, raw in ipairs(C.lines(f)) do
      local l = C.strip_comment(raw)
      if l:match("\\begin{definition}") or l:match("\\begin{notation}") then indef = true end
      if indef and l:match("%$") and not l:match("\\gls") and not l:match("TODO") then note(f, n, "a definition with math and no \\gls", "does it introduce a symbol that belongs in the notation table?") end
      if l:match("\\end{definition}") or l:match("\\end{notation}") then indef = false end
    end
  end
  -- undeclared all-caps words that look like acronyms, counted once each
  local seen = {}
  C.each_prose_line(MAIN, function(f, n, l)
    for w in C.prose(l):gmatch("%f[%w][%u][%u%d]+[%u]%f[%W]") do
      if not short[w] and not seen[w] and #w >= 2 and #w <= 6 and not w:match("^RQ") and not w:match("^TODO") and not w:match("^[IVXLC]+$") then
        seen[w] = true
        -- the entry goes after the last \newabbreviation, or at the end of the glossary file; its key
        -- and long form are the author's. Not after a line that opens a brace it does not close
        local fix
        local at = lastabbr or #C.raw_lines(G)
        local line = C.raw_lines(G)[at]
        if glossaries and line and C.count(C.strip_comment(line), "{") == C.count(C.strip_comment(line), "}") then
          fix = C.fix("placeholder", "declare the abbreviation", C.after_at(G, at, "\\newabbreviation{<key>}{" .. w .. "}{<long form>}"))
        end
        warn(f, n, w .. " is not in the glossary", "declare it, or lint-ignore it if it is a name", fix)
      end
    end
  end)
end)

-- BibTeX's accents for the Hungarian letters, which BibTeX does not read as UTF-8
local ACCENT = {}
for cp, tex in pairs({ [0xC1] = "{\\'A}", [0xE1] = "{\\'a}", [0xC9] = "{\\'E}", [0xE9] = "{\\'e}", [0xCD] = "{\\'I}", [0xED] = "{\\'i}", [0xD3] = "{\\'O}", [0xF3] = "{\\'o}",
  [0xD6] = '{\\"O}', [0xF6] = '{\\"o}', [0x150] = "{\\H O}", [0x151] = "{\\H o}", [0xDA] = "{\\'U}", [0xFA] = "{\\'u}", [0xDC] = '{\\"U}', [0xFC] = '{\\"u}',
  [0x170] = "{\\H U}", [0x171] = "{\\H u}" }) do ACCENT[utf8.char(cp)] = tex end
-- the word with its accented letters as BibTeX accents; nil when it has a letter that is not Hungarian
local function bibtex_accents(w)
  local out = w:gsub("[\195-\197][\128-\191]", function(c) return ACCENT[c] end)
  if not out:find("[\128-\255]") then return out end
end
-- the words of a {title} outside nested braces, as BibTeX reads them: { first, last, text, nested }
-- with the bytes of the title they span (nested: a brace group sits inside the word)
local function title_words(title)
  local words, cur, depth = {}, nil, 1
  for i = 2, #title - 1 do
    local c = title:sub(i, i)
    if c == "{" then
      if depth == 1 and cur then cur.nested = true end
      depth = depth + 1
    elseif c == "}" then depth = depth - 1
    elseif depth == 1 then
      if c:match("%s") then cur = nil
      else
        if not cur then cur = { first = i, text = "" }; words[#words + 1] = cur end
        cur.text, cur.last = cur.text .. c, i
      end
    end
  end
  return words
end
-- whether a text is in the code part of a line (apply_edit's rule), so an edit can be built on it
local function in_code(file, line, old)
  local l = C.raw_lines(file)[line]
  return l ~= nil and C.apply_edit(l, { old = old, new = old }) ~= nil
end

rule("bib", "source", "check", "always", "the bibliography: every cited key exists; entries have a title, a year and an author; a web source has its access date; DOIs are bare", function()
  local keys = {}
  -- bib/zotero.bib is the Zotero library as Overleaf's Refresh or Better BibTeX writes it: a fix
  -- written there is overwritten, so its findings carry none; the entry is fixed in Zotero
  local function generated(b) return b:match("zotero%.bib$") ~= nil end
  local function efail(b, ln, msg, fx) fail(b, ln, msg, not generated(b) and fx or nil) end
  local function ewarn(b, ln, msg, fx) warn(b, ln, msg, not generated(b) and fx or nil) end
  for _, b in ipairs(C.BIB) do
    local s = C.readfile(b) or ""
    local text, line, prev = "\n" .. s, 0, 1
    for pos, entry in text:gmatch("\n()@(%w+%b{})") do
      -- the line of the entry's @type{key, is the place of every finding about it; the fixes that add a
      -- field go right after it, which needs it to end there (not a one-line entry)
      line, prev = line + C.count(text:sub(prev, pos - 1), "\n"), pos
      local opens = (C.raw_lines(b)[line] or ""):match("^@%w+%s*{[^,]*,%s*$") ~= nil
      local function add(field, what) return opens and C.fix("placeholder", "add " .. what, C.after_at(b, line, field)) or nil end
      local kind, body = entry:match("^(%w+)(%b{})"); body = body:sub(2, -2)
      -- the line and column of byte i of the body, for the fixes that edit inside a field; the body
      -- starts after "@type{", and the entry starts at the beginning of its line
      local function locate(i)
        local before = body:sub(1, i - 1)
        local last = before:match(".*()\n")
        return line + C.count(before, "\n"), last and (i - last) or (#kind + 2 + i)
      end
      local key = body:match("^%s*([^,%s]+)")
      local k = kind:lower()
      if key and k ~= "comment" and k ~= "string" and k ~= "preamble" then
        keys[key] = true
        local function has(fld) return body:lower():match("\n%s*" .. fld .. "%s*=") ~= nil end
        if not has("title") then efail(b, line, key .. ": no title") end
        if not has("year") and not has("date") then efail(b, line, key .. ": no year", add("  year = {<year>},", "the year")) end
        if not (has("author") or has("editor") or k == "misc" or k == "manual" or k == "online") then efail(b, line, key .. ": no author") end
        local hasdate = has("urldate") or (body:match("\n%s*note%s*=%s*[{\"][^}\"]*[Aa]ccessed") ~= nil)
        if has("url") and not has("doi") and not hasdate then ewarn(b, line, key .. ": a web source needs its access date (urldate); Zotero records it, the faculty's guideline asks for it", add("  urldate = {<YYYY-MM-DD>},", "the day you read it")) end
        if (k == "misc" or k == "online") and has("url") and not has("author") then ewarn(b, line, key .. ": a web source names the page's owner as author, in double braces", add("  author = {{<the page's owner>}},", "the owner")) end
        local doi = body:match("\n%s*[dD][oO][iI]%s*=%s*[{\"]([^}\"]*)")
        -- the doi field's own line: the first line of the entry that starts it
        local doiline
        for i = line, line + C.count(entry, "\n") do
          if (C.raw_lines(b)[i] or ""):match("^%s*[dD][oO][iI]%s*=") then doiline = i; break end
        end
        if doi and doi:match("^https?://") then
          local fix
          for _, host in ipairs({ "https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "https://www.doi.org/", "http://www.doi.org/" }) do
            if doiline and doi:sub(1, #host):lower() == host and in_code(b, doiline, doi:sub(1, #host)) then
              fix = C.fix("safe", "keep the bare DOI", C.replace_at(b, doiline, doi:sub(1, #host), ""))
              break
            end
          end
          ewarn(b, line, key .. ": doi field is a URL; give the bare DOI", fix)
        end
        if doi and doi:match("TODO") then
          ewarn(b, line, key .. ": DOI still a TODO", doiline and in_code(b, doiline, "TODO") and C.fix("placeholder", "write the DOI", C.replace_at(b, doiline, "TODO", "<DOI>", true)) or nil)
        end
        -- BibTeX is not UTF-8 aware: an abbreviated first name that starts with an accented letter
        -- (Ádám, Éva, Ödön) loses a byte unless the letter is written as a LaTeX accent in braces,
        -- {\'A}d{\'a}m, which is how Zotero exports it; a plain {Á} does not help
        local npos, names = body:match("\n%s*[aA][uU][tT][hH][oO][rR]%s*=%s*()(%b{})")
        if not names then npos, names = body:match("\n%s*[eE][dD][iI][tT][oO][rR]%s*=%s*()(%b{})") end
        if names then
          for gpos, given in names:gmatch(",%s*()([^,}]+)") do
            for wpos, word in given:gmatch("()(%S+)") do
              if word:match("^[\195-\197][\128-\191]") then
                -- safe on the line where the field starts, review on a later line of it
                local fix
                local ln = locate(npos + gpos + wpos - 2)
                local new = bibtex_accents(word)
                if new and in_code(b, ln, word) then
                  fix = C.fix(ln == locate(npos) and "safe" or "review", "write the accents as BibTeX accents", C.replace_at(b, ln, word, new, true))
                end
                ewarn(b, line, key .. ": the given name " .. word .. " starts with an accented letter; write it as a LaTeX accent in braces, like {\\'A}d{\\'a}m, or BibTeX breaks the initial", fix)
                break
              end
            end
          end
        end
        local tpos, title = body:match("\n%s*[tT][iI][tT][lL][eE]%s*=%s*()(%b{})")
        if title then
          local inner = title:sub(2, -2):gsub("%b{}", "")
          for w in inner:gmatch("%S+") do
            if w:match("^%a") and (w:match("^%u%u") or w:match("%l%u")) then
              -- a word that BibTeX would lowercase is wrapped in braces, on the line of the first one:
              -- safe on the title's own line, review on a later one. A word with a brace group inside it
              -- is left, since it cannot be wrapped as it stands
              local first, edits, fix = nil, {}, nil
              for _, wd in ipairs(title_words(title)) do
                if wd.text:match("^%a") and (wd.text:match("^%u%u") or wd.text:match("%l%u")) then
                  local ln, col = locate(tpos + wd.first - 1)
                  first = first or ln
                  if ln == first and not wd.nested then
                    local trail = #wd.text:match("[%.,;:!%?%)]*$")
                    local old = wd.text:sub(1, #wd.text - trail)
                    edits[#edits + 1] = { file = b, line = ln, at = col, old = old, new = "{" .. old .. "}" }
                  end
                end
              end
              local ok = #edits > 0
              for _, e in ipairs(edits) do if not (C.raw_lines(b)[e.line] and C.apply_edit(C.raw_lines(b)[e.line], e)) then ok = false end end
              if ok then
                table.sort(edits, function(x, y) return x.at > y.at end) -- right to left, so each column still holds
                fix = C.fix(first == locate(tpos) and "safe" or "review", "protect the word with braces", table.unpack(edits))
              end
              ewarn(b, line, key .. ": " .. w .. " in the title is not protected with braces; BibTeX lowercases it", fix)
              break
            end
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
  -- links, read as citations are (C.each_call): across spaces and line breaks, in the printed text only
  C.each_call(CONTENT, function(name) return name == "url" or name == "href" or name == "weblink" end, function(f, n, _, arg)
    local what = companion_link(arg, year, own)
    if what then flag(f, n, "links " .. what .. ": a TDK paper of the same year is a companion paper, named as one, never linked") end
  end)
  for _, f in ipairs(CONTENT) do
    -- "a companion paper~\cite{...}" or a link whose text says companion; a citation later in the
    -- sentence ("a companion paper verifies it in Tamarin~\cite{...}") is another source's
    local text = table.concat(C.prose_lines(f), "\n")
    local pats = { "\\href%s*%b{}%s*{()[^}]*[Cc]ompanion", "\\weblink%s*%b{}%s*{()[^}]*[Cc]ompanion" }
    -- the words may close an \emph{} or \enquote{} before the citation
    for _, cmd in ipairs({ "[cC]ite", "url", "href", "weblink" }) do pats[#pats + 1] = "()[Cc]ompanion%s*%a*}?[%s~,(%[]*\\" .. cmd end
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
  if not bbl then C.skip(C.opts.doc .. ".bbl not found: build the paper first, BibTeX writes it"); return end
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
        warn(en.file, entry_line(en.file, key), key .. ": an arXiv preprint", "search dblp for its title and cite the published version, unless the work is too recent to be published")
      elseif url and not scholarly then
        web = web + 1
      end
    end
  end
  local total = #cited
  if C.opts.profile ~= "thesis" and total > 50 then
    warn(nil, nil, string.format("%d references: a TDK paper typically needs no more than 50", total), "cut the weakest first, starting with those another entry already covers")
  end
  if total > 0 and web == total then
    warn(nil, nil, "every reference is a web page, which the review sheet's B/2 places at step 1", "cite the papers, standards and specifications behind them, and move links that back no claim to footnotes")
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
      -- delete the \usepackage, when it loads that package alone; a review fix, since the options
      -- of an option clash go with it
      local fix
      if select(2, pk:gsub("[^,%s]+", "")) == 1 then fix = C.fix("review", "delete the \\usepackage", C.replace("\\usepackage" .. opts .. "{" .. pk .. "}", "", true)) end
      for p in pk:gmatch("[^,%s]+") do
        if p == "amssymb" or p == "amsfonts" then fail(f, n, p .. " next to unicode-math redefines \\square and other symbols; the template's math font has them", fix)
        elseif p == "amsthm" then fail(f, n, "amsthm clashes with ntheorem, which the template's theorem environments use", fix)
        elseif loaded[p] then
          if opts ~= "" and opts ~= loaded[p] then fail(f, n, string.format("%s is loaded by the template%s: loading it again with %s is an option clash", p, loaded[p] ~= "" and (" with " .. loaded[p]) or "", opts), fix)
          else warn(f, n, p .. " is loaded by the template already", fix) end
        end
      end
    end
    for opts, pk in l:gmatch("\\usepackage(%b[]){([^}]*)}") do check(opts, pk) end
    for pk in l:gmatch("\\usepackage{([^}]*)}") do check("", pk) end
    for t in l:gmatch("\\newtheorem%*?{([^}]*)}") do if thms[t] then fail(f, n, "the template defines the " .. t .. " environment", "use it, a second \\newtheorem stops the build") end end
  end)
end)

-- the units a number takes a thin space before; Lua patterns have no alternation, so a set
local UNITS = { ms = true, s = true, MB = true, GB = true, KB = true, kB = true, Hz = true, MHz = true, GHz = true, mm = true, cm = true, pt = true, KiB = true, MiB = true, GiB = true, bytes = true, B = true }

-- a typography fix covers every occurrence of its slip on the raw line, and goes with the line's
-- first finding of that slip; it is safe when the raw line holds exactly the occurrences the rule
-- saw in the prose, and review when it holds more (in a \todo, a \url, maths) or fewer. A line of
-- the template's skeleton gets none: the author replaces it, and a polished copy would no longer
-- be recognised as the template's text, so it would count as the author's own words. A slip that
-- can be meant (a doubled word, a quote, a line break) passes its tier, review
local function typo_fix(f, n, seen, kind, help, count, pattern, fn, tier)
  if seen[kind] then return nil end
  seen[kind] = true
  if C.skeleton_lines()[C.prose_key(C.prose_lines(f)[n] or "")] then return nil end
  local edits = C.matches(C.raw_lines(f)[n], pattern, fn)
  return C.fix(tier or (#edits == count and "safe" or "review"), help, table.unpack(edits))
end
-- a line with its inline maths and escaped dollars blanked to "#", column for column: TeX ignores
-- the spaces in $k : x$, so they are not a slip
local function mask_math(l)
  l = l:gsub("\\%$", "##")
  l = l:gsub("%$%$.-%$%$", function(m) return ("#"):rep(#m) end)
  return (l:gsub("%$[^$]*%$", function(m) return ("#"):rep(#m) end))
end
-- whether a line sits inside a table or an array, where \\ ends a row and not a line of prose
local GRID = { tabular = true, ["tabular*"] = true, tabularx = true, tabulary = true, longtable = true, xltabular = true, supertabular = true, array = true,
  tabbing = true, matrix = true, pmatrix = true, bmatrix = true, vmatrix = true, cases = true, aligned = true, split = true, gathered = true, eqnarray = true }
local grid_cache = {}
local function in_grid(f, n)
  if not grid_cache[f] then
    local inside, depth = {}, 0
    for i, raw in ipairs(C.raw_lines(f)) do
      local before = depth
      for kind, env in C.strip_comment(raw):gmatch("\\(%a+){([%a%*]+)}") do
        if GRID[env] then depth = math.max(0, depth + (kind == "begin" and 1 or kind == "end" and -1 or 0)) end
      end
      inside[i] = before > 0 or depth > 0
    end
    grid_cache[f] = inside
  end
  return grid_cache[f][n]
end
local function is_range(code, s, e) return not code:sub(s - 1, s - 1):match("[%w%-%.]") and not code:sub(e + 1, e + 1):match("[%w%-]") end
-- doubled words that are grammar, not a slip: "the protocol that that process uses", "had had"
local DOUBLED_OK = { that = true, had = true }

rule("typography", "source", "advice", "polish", "the small things the reviewer sees: number ranges with --, a thin space before units, no straight quotes, no doubled words, \\eg and \\ie macros, no manual line breaks in prose", function()
  C.each_prose_line(MAIN, function(f, n, l)
    local p = C.prose(l)
    local seen = {}
    -- a range stands alone: BLS12-381 and i7-9750H are names, not ranges
    local ranges = {}
    for s, a, b, e in p:gmatch("()(%d+)%-(%d+)()") do
      if is_range(p, s, e - 1) and not l:match("\\label") and not l:match("label=") then ranges[#ranges + 1] = { a, b } end
    end
    for _, r in ipairs(ranges) do
      warn(f, n, string.format("range %s-%s with a hyphen", r[1], r[2]), string.format("write %s--%s", r[1], r[2]), typo_fix(f, n, seen, "range", "write an en dash, --", #ranges, "(%d+)%-(%d+)", function(m, s, code, a, b)
        if is_range(code, s, s + #m - 1) then return a .. "--" .. b end
      end))
    end
    local units = 0
    for _, unit in p:gmatch("(%d) (%a+)%f[%A]") do if UNITS[unit] then units = units + 1 end end
    for num, unit in p:gmatch("(%d) (%a+)%f[%A]") do
      if UNITS[unit] then warn(f, n, string.format("'%s %s'", num, unit), string.format("use a thin space, %s\\,%s", num, unit), typo_fix(f, n, seen, "unit", "write a thin space, \\,", units, "(%d) (%a+)%f[%A]", function(_, _, _, d, u)
        if UNITS[u] then return d .. "\\," .. u end
      end)) end
    end
    if p:match('"') then
      warn(f, n, "straight double quote", "use \\enquote{...}", C.loads("csquotes") and typo_fix(f, n, seen, "quote", "write \\enquote", 1, '"([^"]*)"', function(_, _, code, x)
        if C.nmatch(code, '"') % 2 == 0 then return "\\enquote{" .. x .. "}" end
      end, "review") or nil)
    end
    if p:match("%f[%a]e%.g%.") or p:match("%f[%a]i%.e%.") then
      local eg, ie = C.defines("eg"), C.defines("ie") -- only the forms the paper defines
      warn(f, n, "e.g./i.e. typed out", "use \\eg and \\ie, which get the spacing right", typo_fix(f, n, seen, "eg", "write \\eg and \\ie", (eg and C.nmatch(p, "%f[%a]e%.g%.") or 0) + (ie and C.nmatch(p, "%f[%a]i%.e%.") or 0), "%f[%a]([ei])%.([ge])%.", function(_, _, _, a, b)
        if a .. b == "eg" and eg then return "\\eg" elseif a .. b == "ie" and ie then return "\\ie" end
      end))
    end
    if p:match("%f[%a]et al%.") and not l:match("\\etal") then
      warn(f, n, "et al. typed out", "use \\etal", typo_fix(f, n, seen, "etal", "write \\etal", C.nmatch(p, "%f[%a]et al%."), "%f[%a]et al%.", function() if C.defines("etal") then return "\\etal" end end))
    end
    for w in p:gmatch("%f[%a](%a+) %1%f[%A]") do
      if #w > 2 and not DOUBLED_OK[w:lower()] then
        warn(f, n, "doubled word: " .. w .. " " .. w, typo_fix(f, n, seen, "double", "keep one", 1, "%f[%a](%a+) %1%f[%A]", function(_, _, _, d)
          if #d > 2 and not DOUBLED_OK[d:lower()] then return d end
        end, "review"))
      end
    end
    local flat = mask_math(l)
    if flat:match("[%w%)]%s+[,%.;:]%f[%s]") then
      -- a ratio, 3 : 1, keeps its spaces
      warn(f, n, "space before punctuation", typo_fix(f, n, seen, "punct", "delete the space", C.nmatch(flat, "[%w%)]%s+[,%.;:]%f[%s]"), "([%w%)])%s+([,%.;:])%f[%s]", function(m, s, code, c, q)
        if mask_math(code):sub(s, s + #m - 1) == m and not (q == ":" and c:match("%d")) then return c .. q end
      end))
    end
    if l:match("\\\\%s*$") and not l:match("&") and not l:match("\\\\%[") and not l:match("^%s*\\\\") then
      if not (l:match("\\end{") or l:match("\\hline") or l:match("rule")) then
        note(f, n, "manual line break at the end of a prose line", not in_grid(f, n) and typo_fix(f, n, seen, "break", "delete the \\\\", 1, "%s*\\\\(%s*)$", function(_, _, _, trail) return trail end, "review") or nil)
      end
    end
    if p:match("%.%.%.") then
      -- \dots{} where text follows, since \dots takes the space after it
      warn(f, n, "three dots", "use \\dots", typo_fix(f, n, seen, "dots", "write \\dots", C.nmatch(p, "%.%.%."), "%.%.%.", function(m, s, code)
        return code:sub(s + 3, s + 3):match("[%w%s]") and "\\dots{}" or "\\dots"
      end))
    end
    if l:match("\\footnote") and l:match("%s\\footnote%f[^%a]") then -- not \footnotesize
      warn(f, n, "space before \\footnote", "the mark should sit on the word or the punctuation", typo_fix(f, n, seen, "footnote", "delete the space", C.nmatch(l, "%s+\\footnote%f[^%a]"), "%s+\\footnote%f[^%a]", function() return "\\footnote" end))
    end
    if l:match("\\cite") and not l:match("~\\cite") and not l:match("{\\cite") and not l:match("\\citet") and not l:match("\\cite[tp]") and not l:match("^%s*\\cite") and not l:match("&%s*\\cite") and not l:match("\\\\%s*\\cite") then
      warn(f, n, "\\cite without a tie", "write text~\\cite{...} so the number cannot start a line", typo_fix(f, n, seen, "cite", "write a tie, ~", C.nmatch(l, "%S%s+\\cite"), "(%S)%s+\\cite", function(_, _, _, c)
        if c ~= "&" then return c .. "~\\cite" end
      end))
    end
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
    if open > 0 or closed > 0 then n = n + 1; warn(nil, nil, string.format("%s (%d) also appears as %s%s", h, hy, open > 0 and string.format("'%s %s' (%d)", a, b, open) or "", closed > 0 and string.format("%s'%s%s' (%d)", open > 0 and " and " or "", a, b, closed) or ""), "pick one") end
  end
  -- British/American pairs that a spell checker would not catch together
  local pairs_ = { { "modelling", "modeling" }, { "colour", "color" }, { "behaviour", "behavior" }, { "analyse", "analyze" }, { "optimise", "optimize" }, { "optimisation", "optimization" }, { "formalisation", "formalization" }, { "formalise", "formalize" }, { "centre", "center" }, { "licence", "license" }, { "catalogue", "catalog" }, { "parametrised", "parameterized" }, { "synchronise", "synchronize" }, { "realise", "realize" }, { "serialisation", "serialization" }, { "authorisation", "authorization" } }
  local brit, amer = 0, 0
  for _, pr in ipairs(pairs_) do
    local b = select(2, all:lower():gsub("%f[%a]" .. pr[1] .. "%w*", "")); local a = select(2, all:lower():gsub("%f[%a]" .. pr[2] .. "%w*", ""))
    brit, amer = brit + b, amer + a
    if b > 0 and a > 0 then warn(nil, nil, string.format("both %s (%d) and %s (%d)", pr[1], b, pr[2], a), "keep one spelling") end
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
    if hits >= 3 then warn(f, n, "Hungarian prose in an English chapter", "translate it, or make it a \\todo") end
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

rule("aidecl", "source", "check", "submit", "the AI declaration is filled in: exactly one box marked, and if AI was used, at least one row, the overall share and its justification", function()
  local f = C.FILES.aidecl
  local s = f and C.readfile(f); if not s then fail(nil, nil, "no AI declaration file (\\label{aidecl})"); return end
  local body = s:gsub("\\newcommand{\\aiboxmarked}[^\n]*", "")
  local marked = C.count(body, "\\aiboxmarked")
  if marked == 0 then fail(f, nil, "no box marked in the AI declaration", "mark one with \\aiboxmarked")
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

rule("titlepage", "source", "check", "submit", "the title page variables are filled in: title, author, year, the second author where there is one", function()
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
rule("placeholders", "source", "count", "submit", "what the template left for you: TODO strings, placeholder figures and tables, sample citations in the gap matrix, the Zenodo DOI", function()
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

rule("beats", "source", "count", "submit", "beats and notes still printing: the skeleton is done when every beat has become prose", function()
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
