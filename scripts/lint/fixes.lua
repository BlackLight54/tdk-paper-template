-- `texlua scripts/lint.lua fix`: writes the fixes the rules suggest and prints what it changed.
--
--   texlua scripts/lint.lua fix [<rule>...] [--dry-run] [--review] [--allow-dirty]
--
-- It writes the safe fixes, and with --review the review fixes too; placeholders are never written,
-- the author fills their holes. Without rules it runs the source family. A file with uncommitted
-- changes is left alone unless --allow-dirty is given, so `git diff` shows exactly what the fixes
-- did. Two fixes on the same text cannot both be written in one pass, so after writing it runs
-- the lint again, up to three passes; a fix that is offered again after it was written did not
-- clear its finding, which is a bug in the lint, and stops the run with exit code 2.
local C = require("lintcore")
local M = {}

local function signature(rule, fx)
  local t = { rule }
  for _, e in ipairs(fx.edits) do t[#t + 1] = table.concat({ e.file, e.line, e.at or "", e.old or "", e.new or "", e.after or "" }, "\2") end
  return table.concat(t, "\1")
end

-- the fixes up to the given safety, in file and line order; a fix with a command is never written
local function collect(results, max)
  local out = {}
  for _, res in ipairs(results) do
    for _, f in ipairs(res.findings) do
      local fx = f.fix
      if fx and C.SAFETY[fx.safety] <= max then
        local writable = true
        for _, e in ipairs(fx.edits) do if e.cmd then writable = false end end
        if writable then out[#out + 1] = { rule = res.rule, finding = f, fix = fx } end
      end
    end
  end
  table.sort(out, function(a, b)
    if (a.finding.file or "") ~= (b.finding.file or "") then return (a.finding.file or "") < (b.finding.file or "") end
    return (a.finding.line or 0) < (b.finding.line or 0)
  end)
  return out
end

-- a file as its lines, split the way C.lines splits it, and whether it ends in a newline
local function load(path)
  local s = C.readfile(path) or ""
  local nl = s:sub(-1) == "\n"
  local body = nl and s:sub(1, -2) or s
  local t = {}
  for l in (body .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
  return { lines = t, orig = { table.unpack(t) }, after = {}, nl = nl }
end

-- every fix written into the files' new contents, in memory; a fix whose text an earlier fix has
-- already changed waits for the next pass, and a fix is written whole or not at all
local function plan(items)
  local files, written, waiting = {}, {}, 0
  for _, it in ipairs(items) do
    local tentative, inserts, ok = {}, {}, true
    for _, e in ipairs(it.fix.edits) do
      files[e.file] = files[e.file] or load(e.file)
      local k = e.file .. ":" .. e.line
      local cur = tentative[k] or files[e.file].lines[e.line]
      if cur == nil then ok = false; break end
      if e.old then
        local new = C.apply_edit(cur, e)
        if not new then ok = false; break end
        tentative[k] = new
      elseif e.after then
        inserts[#inserts + 1] = e
      end
    end
    if ok then
      for k, v in pairs(tentative) do
        local file, line = k:match("^(.*):(%d+)$")
        files[file].lines[tonumber(line)] = v
      end
      for _, e in ipairs(inserts) do
        local a = files[e.file].after
        a[e.line] = a[e.line] or {}
        local dup = false
        for _, x in ipairs(a[e.line]) do if x == e.after then dup = true end end
        if not dup then table.insert(a[e.line], e.after) end
      end
      written[#written + 1] = it
    else
      waiting = waiting + 1
    end
  end
  return files, written, waiting
end

local function text_of(fs)
  local out = {}
  for n, l in ipairs(fs.lines) do
    out[#out + 1] = l
    for _, x in ipairs(fs.after[n] or {}) do out[#out + 1] = x end
  end
  return table.concat(out, "\n") .. (fs.nl and "\n" or "")
end

local function diff(path, fs)
  for n, l in ipairs(fs.orig) do
    local changed, added = fs.lines[n] ~= l, fs.after[n]
    if changed or added then
      io.write(path, ":", n, "\n")
      if changed then io.write("    - ", l, "\n    + ", fs.lines[n], "\n") end
      for _, x in ipairs(added or {}) do io.write("    + ", x, "\n") end
    end
  end
end

-- the files git knows to have uncommitted changes; none outside a git checkout
local function dirty(paths)
  if not (C.exists(".git") and C.have("git")) or #paths == 0 then return {} end
  local q = {}
  for _, p in ipairs(paths) do q[#q + 1] = string.format("%q", p) end
  local out = C.run_quiet("git status --porcelain -- " .. table.concat(q, " ")) or ""
  local t = {}
  for l in out:gmatch("[^\n]+") do t[#t + 1] = l:sub(4) end
  return t
end

-- what is left once the safe fixes are written: review fixes and placeholders, by count
local function leftover(results, max)
  local n = { 0, 0, 0 }
  for _, res in ipairs(results) do
    for _, f in ipairs(res.findings) do if f.fix then local s = C.SAFETY[f.fix.safety]; n[s] = n[s] + 1 end end
  end
  if max < 2 and n[2] > 0 then io.write(string.format("%d review fix%s left: read them with `texlua scripts/lint.lua <rule>`, write them with `texlua scripts/lint.lua fix --review`\n", n[2], n[2] == 1 and "" or "es")) end
  if n[3] > 0 then io.write(string.format("%d placeholder%s left: the lint shows the text, you fill in its <holes>\n", n[3], n[3] == 1 and "" or "s")) end
end

-- rules: the rules that ran; passthrough: the options a next pass needs
function M.main(results, rules, passthrough)
  local o = C.opts
  local max = o.review and 2 or 1
  local pass = tonumber(o.pass or 1)
  local items = collect(results, max)
  if o.applied then
    local before = {}
    for l in (C.readfile(o.applied) or ""):gmatch("[^\n]+") do before[l] = true end
    os.remove(o.applied)
    for _, it in ipairs(items) do
      if before[(signature(it.rule, it.fix):gsub("\n", " "))] then
        io.stderr:write(string.format("%s:%s: the %s fix \"%s\" was written but its finding is still there: a bug in the lint\n", it.finding.file, it.finding.line, it.rule, it.fix.help))
        return 2
      end
    end
  end
  if #items == 0 then
    if pass == 1 then io.write("no fix to write\n") end
    leftover(results, max)
    return 0
  end
  local files, written, waiting = plan(items)
  local paths = {}
  for p, fs in pairs(files) do if text_of(fs) ~= table.concat(fs.orig, "\n") .. (fs.nl and "\n" or "") then paths[#paths + 1] = p end end
  table.sort(paths)
  if not o.dry and not o.allow_dirty then
    local d = dirty(paths)
    if #d > 0 then
      io.stderr:write("uncommitted changes in " .. table.concat(d, ", ") .. ": commit them first, so the fixes are a diff of their own, or pass --allow-dirty\n")
      return 1
    end
  end
  for _, p in ipairs(paths) do diff(p, files[p]) end
  if o.dry then
    io.write(string.format("dry run: %d fix%s would change %d file%s\n", #written, #written == 1 and "" or "es", #paths, #paths == 1 and "" or "s"))
    leftover(results, max)
    return 0
  end
  for _, p in ipairs(paths) do
    local h = assert(io.open(p, "w"))
    h:write(text_of(files[p]))
    h:close()
  end
  io.write(string.format("wrote %d fix%s in %d file%s\n", #written, #written == 1 and "" or "es", #paths, #paths == 1 and "" or "s"))
  if pass >= 3 then
    if waiting > 0 then io.write(waiting .. " fixes still wait after three passes: run it again\n") end
    return 0
  end
  -- the next pass, in a fresh process, since the rules read the files once
  local applied = os.tmpname()
  local h = assert(io.open(applied, "w"))
  for _, it in ipairs(written) do h:write((signature(it.rule, it.fix):gsub("\n", " ")), "\n") end
  h:close()
  local cmd = { "texlua scripts/lint.lua fix" }
  for _, r in ipairs(rules) do cmd[#cmd + 1] = r end
  for _, a in ipairs(passthrough) do cmd[#cmd + 1] = string.format("%q", a) end
  cmd[#cmd + 1] = "--allow-dirty --pass " .. (pass + 1) .. " --applied " .. string.format("%q", applied)
  if o.review then cmd[#cmd + 1] = "--review" end
  io.stdout:flush()
  -- texlua's os.execute returns the wait status (512 for exit 2), Lua 5.3's true, "exit", code
  local r, _, code = os.execute(table.concat(cmd, " "))
  if r == true or r == 0 then return 0 end
  if type(r) == "number" then return r >= 256 and r // 256 or r end
  return code or 1
end

return M
