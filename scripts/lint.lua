#!/usr/bin/env texlua
-- Lint for the TDK paper: one rule per subcommand, so CI shows them one by one.
--
--   texlua scripts/lint.lua <rule>... [--dir <builddir>] [--doc <jobname>] [--profile tdk|thesis] [--phase <p>]
--   texlua scripts/lint.lua all | source | pdf | tools | overleaf     a family, in order
--   texlua scripts/lint.lua list [--tsv]                              the rules, their severity, phase and group
--   texlua scripts/lint.lua overleaf --tex > lint-checks.tex          the Checks page and the package warnings
--   texlua scripts/lint.lua essentials --guide > guide/essentials.tex the guide's reference of the essentials
--   texlua scripts/lint.lua essentials --json                         the essentials, for work/essentials-labels.py
--   texlua scripts/lint.lua fix [<rule>...] [--dry-run] [--review]    write the fixes the rules suggest (fixes.lua)
--
-- Severity: check (fails once its phase is reached), advice (warns, never fails), count (numbers).
-- Phase: the manual phase from \newcommand{\lintphase}{plan|draft|polish|final} in thesis.tex;
-- a check whose phase is not reached yet only reports. The essentials (scripts/lint/essentials.lua)
-- are one check whose level rises with the phase. Chapters are found by their labels (ch:intro,
-- ...), not by file name. "% lint-ignore: <rule> <reason>" silences one finding. A finding may
-- carry a fix, printed under it: safe, review or placeholder (lintcore.lua says what each means).
-- Needs texlua (TeX Live); the pdf family needs poppler-utils, the tools family what it names.

package.path = "scripts/lint/?.lua;" .. package.path
local C = require("lintcore")

local args, guide, passthrough = {}, false, {}
do
  local i = 1
  while i <= #arg do
    if arg[i] == "--dir" or arg[i] == "--doc" or arg[i] == "--profile" or arg[i] == "--phase" then
      C.opts[arg[i]:sub(3)] = arg[i + 1]
      passthrough[#passthrough + 1] = arg[i]; passthrough[#passthrough + 1] = arg[i + 1]
      i = i + 2
    elseif arg[i] == "--dry-run" then C.opts.dry = true; i = i + 1
    elseif arg[i] == "--review" then C.opts.review = true; i = i + 1
    elseif arg[i] == "--allow-dirty" then C.opts.allow_dirty = true; i = i + 1
    elseif arg[i] == "--pass" then C.opts.pass = arg[i + 1]; i = i + 2
    elseif arg[i] == "--applied" then C.opts.applied = arg[i + 1]; i = i + 2
    elseif arg[i] == "--tex" then C.opts.tex = true; i = i + 1
    elseif arg[i] == "--json" then C.opts.json = true; i = i + 1
    elseif arg[i] == "--guide" then guide = true; i = i + 1
    elseif arg[i] == "--tsv" then C.opts.tsv = true; i = i + 1
    else args[#args + 1] = arg[i]; i = i + 1 end
  end
end
-- the essentials first: they open the Checks page, the job summary and every list
require("rules-essentials"); require("rules-source"); require("rules-pdf"); require("rules-tools")
local P = require("pagemap")
local R = require("render")

-- the rules the Overleaf hook runs on every compile: the sources, and the page count from this
-- compile's aux files; not the log (Overleaf shows it), not the PDF (it does not exist yet)
local OVERLEAF_SKIP = { build = true, overfull = true, checkcites = true, ["bibtex-log"] = true, links = true, spelling = true, burndown = true, ["repo-hygiene"] = true }

local cmd = args[1]
if not cmd or cmd == "list" then
  if C.opts.tsv then
    for _, n in ipairs(C.ORDER) do
      local r = C.RULES[n]
      io.write(table.concat({ r.family, n, r.severity, r.phase, P.group(n), P.title(n) }, "\t"), "\n")
    end
    os.exit(0)
  end
  io.write(string.format("phase: %s (from \\lintphase in thesis.tex)\n", C.phase()))
  io.write("rules: severity check fails once its phase is reached; advice warns; count reports numbers\n")
  local fam
  for _, n in ipairs(C.ORDER) do
    local r = C.RULES[n]
    if r.family ~= fam then fam = r.family; io.write("\n[" .. fam .. "]\n") end
    io.write(string.format("  %-13s %-7s %-7s %s\n", n, r.severity, r.phase == "always" and "" or r.phase, r.desc))
  end
  os.exit(0)
end
if guide then io.write(R.guide()); os.exit(0) end
local todo = {}
local fixing = cmd == "fix"
local fixrules = {}
if fixing then
  C.opts.quiet = true
  table.remove(args, 1)
  for _, a in ipairs(args) do fixrules[#fixrules + 1] = a end
  cmd = args[1] or "source"
  if not args[1] then args[1] = "source" end
end
if cmd == "all" then for _, n in ipairs(C.ORDER) do todo[#todo + 1] = n end
elseif cmd == "overleaf" then for _, n in ipairs(C.ORDER) do if C.RULES[n].family ~= "pdf" and not OVERLEAF_SKIP[n] then todo[#todo + 1] = n end end
elseif cmd == "source" or cmd == "pdf" or cmd == "tools" then for _, n in ipairs(C.ORDER) do if C.RULES[n].family == cmd then todo[#todo + 1] = n end end
else for _, n in ipairs(args) do todo[#todo + 1] = n end end
local allok = true
local header = #todo <= 1
for _, name in ipairs(todo) do
  local r = C.RULES[name]
  if not r then io.stderr:write("unknown rule " .. name .. "; try: texlua scripts/lint.lua list\n"); os.exit(2) end
  -- the essentials write their own section of the job summary; the rules' table follows them
  if not header and r.summary ~= false and not fixing then C.summary_header("Lint: " .. cmd .. " (phase " .. C.phase() .. ", profile " .. C.opts.profile .. ")"); header = true end
  C.findings = {}; C.ignored = 0; C.current_rule = name
  local ok_call, counts = pcall(r.fn)
  if not ok_call then C.fail(nil, nil, "the rule itself failed: " .. tostring(counts)); counts = nil end
  if not C.report(name, r, counts) then allok = false end
end

if fixing then os.exit(require("fixes").main(C.results, fixrules, passthrough)) end
if C.opts.json then io.write(R.json())
elseif C.opts.tex then io.write(R.checks_page(C.results)) end
os.exit(allok and 0 or 1)
