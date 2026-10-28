#!/usr/bin/env texlua
-- Builds guide/guide.bbl, the guide's own reference list, from guide/guide.bib: the keys the guide
-- cites, in the order the guide cites them, formatted by BibTeX with tdkieee.bst. The .bbl is
-- committed, so no build of a paper runs BibTeX for the guide; run this after editing the guide's
-- citations or guide/guide.bib.
--   texlua scripts/guide-bib.lua        (or: make guide-bib)
local function readfile(p) local h = io.open(p, "r"); if not h then return nil end; local s = h:read("a"); h:close(); return s end
local thesis = readfile("thesis.tex") or error("run from the template's root: thesis.tex not found")
local keys, seen = {}, {}
for line in thesis:gmatch("[^\n]*") do
  local code = line:gsub("\\%%", ""):gsub("%%.*$", "")
  local f = code:match("\\include{(guide/[^}]+)}")
  if f then
    local s = readfile(f .. ".tex") or error("missing " .. f .. ".tex")
    for l in s:gmatch("[^\n]*") do
      l = l:gsub("\\%%", ""):gsub("%%.*$", "")
      l = l:gsub("(\\cite[tp]?%*?)%b[]", "%1") -- \cite[p.~3]{key}: the note is not a key
      for arg in l:gmatch("\\cite[tp]?%*?(%b{})") do
        for k in arg:sub(2, -2):gmatch("[^,%s]+") do
          if not seen[k] then seen[k] = true; keys[#keys + 1] = k end
        end
      end
    end
  end
end
if #keys == 0 then error("the guide cites nothing") end
local aux = io.open("guide/guide.aux", "w")
for _, k in ipairs(keys) do aux:write("\\citation{" .. k .. "}\n") end
aux:write("\\bibstyle{tdkieee}\n\\bibdata{guide/guide}\n"); aux:close()
local ok = os.execute("bibtex -terse guide/guide")
os.remove("guide/guide.aux"); os.remove("guide/guide.blg")
if ok ~= true and ok ~= 0 then error("bibtex failed on guide/guide.aux") end
io.write(string.format("guide/guide.bbl: %d references\n", #keys))
