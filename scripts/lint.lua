#!/usr/bin/env texlua
-- Lint for the TDK paper: one rule per subcommand, so CI shows them one by one.
--
--   texlua scripts/lint.lua <rule> [--dir <builddir>] [--doc <jobname>] [--profile tdk|thesis]
--   texlua scripts/lint.lua all | source | pdf | tools     a family, gates first
--   texlua scripts/lint.lua list                           the rules and what each checks
--
-- Families:
--   source  the LaTeX sources and the build log: the template's structures, the argument's
--           traceability, the guide's conventions, and the burn-down counts
--   pdf     the output PDF: the form requirements of the call (or, with --profile thesis, of the
--           faculty's thesis guide), checked on the result so they hold whatever the sources are
--   tools   chktex, lacheck, texcount, checkcites, the BibTeX log, hunspell, link checking
--
-- Findings print as "file:line: message"; under GitHub Actions as annotations, and each rule
-- appends a row to the job summary. Exit status is 1 when a gate fails; report rules never fail.
-- Needs texlua (TeX Live); the pdf family needs poppler-utils, the tools family what it names.
-- The profile also comes from LINT_PROFILE; LINT_OFFLINE skips the link check.

package.path = "scripts/lint/?.lua;" .. package.path
local C = require("lintcore")

local args = {}
do
  local i = 1
  while i <= #arg do
    if arg[i] == "--dir" then C.opts.dir = arg[i + 1]; i = i + 2
    elseif arg[i] == "--doc" then C.opts.doc = arg[i + 1]; i = i + 2
    elseif arg[i] == "--profile" then C.opts.profile = arg[i + 1]; i = i + 2
    else args[#args + 1] = arg[i]; i = i + 1 end
  end
end
require("rules-source"); require("rules-pdf"); require("rules-tools")

local cmd = args[1]
if not cmd or cmd == "list" then
  io.write("rules (gates fail the build; the rest report):\n")
  local fam
  for _, n in ipairs(C.ORDER) do
    local r = C.RULES[n]
    if r.family ~= fam then fam = r.family; io.write("\n[" .. fam .. "]\n") end
    io.write(string.format("  %-13s %s  %s\n", n, r.gate and "gate  " or "report", r.desc))
  end
  os.exit(0)
end
local todo = {}
if cmd == "all" then for _, n in ipairs(C.ORDER) do todo[#todo + 1] = n end
elseif cmd == "source" or cmd == "pdf" or cmd == "tools" then for _, n in ipairs(C.ORDER) do if C.RULES[n].family == cmd then todo[#todo + 1] = n end end
else for _, n in ipairs(args) do todo[#todo + 1] = n end end
if #todo > 1 then C.summary_header("Lint: " .. cmd .. " (profile " .. C.opts.profile .. ")") end
local allok = true
for _, name in ipairs(todo) do
  local r = C.RULES[name]
  if not r then io.stderr:write("unknown rule " .. name .. "; try: texlua scripts/lint.lua list\n"); os.exit(2) end
  C.findings = {}
  local ok_call, counts = pcall(r.fn)
  if not ok_call then C.fail(nil, nil, "the rule itself failed: " .. tostring(counts)); counts = nil end
  local ok = C.report(name, r.gate, counts)
  if r.gate and not ok then allok = false end
end
os.exit(allok and 0 or 1)
