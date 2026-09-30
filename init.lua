-- =====================================================================
--  ReactOS-OC v2.1  -  single-file OS for OpenComputers (Lua 5.2/5.3)
--
--  Runs in TWO environments (auto-detected):
--    BARE   : loaded as /init.lua by the EEPROM BIOS (no OpenOS)
--    HOSTED : started as a program inside OpenOS
--
--  INSTALL (from OpenOS):   <this-file-name> install      then   reboot
--                           (if you saved it as "init":   init install)
--  Inside ReactOS:          install              (same thing)
--  Check what boots next:   bootinfo
--  Go back to OpenOS:       openos  (one time)   |   uninstall  (permanent)
--  At boot press  O  to start the OpenOS backup instead.
-- =====================================================================
local BACKUP = "/openos-init.lua"
local CFGDIR = "/System32"

local function main(ARGS)

------------------------------------------------------------------
-- 0. Environment, event pump, log, drive letters
------------------------------------------------------------------
local HOSTED = type(require) == "function"
local component, computer, unicode
if HOSTED then
  component, computer, unicode = require("component"), require("computer"), require("unicode")
else
  component, computer, unicode = _ENV.component, _ENV.computer, _ENV.unicode
end
-- IMPORTANT: OpenComputers truncates read counts to 32 bits. math.maxinteger
-- becomes -1 there (reads nothing!), math.huge is what OpenOS itself uses.
local BIG = math.huge
local VERSION = "ReactOS-OC v2.4"
local function first(t) return component.list(t)() end

local gc = function() end
do
  local ok, f = pcall(function() return collectgarbage end)
  if ok and type(f) == "function" then gc = function() pcall(f) end end
end

local klogT, hooks = {}, {}
local function klog(m)
  klogT[#klogT + 1] = string.format("[%9.3f] %s", computer.uptime(), m)
  if #klogT > 300 then table.remove(klogT, 1) end
end

local drives, curDrive, cwds = {}, "C", {}
local LETTERS = "CDEFGHIJKLMNOPQRSTUVWXYZ"

local function driveAdd(a)
  for _, v in pairs(drives) do if v == a then return end end
  for i = 2, #LETTERS do
    local l = LETTERS:sub(i, i)
    if not drives[l] then
      drives[l] = a
      klog("drive " .. l .. ": = " .. a:sub(1, 8))
      return
    end
  end
end

local function driveDel(a)
  for l, v in pairs(drives) do
    if v == a and l ~= "C" then
      drives[l] = nil
      klog("drive " .. l .. ": removed")
      if curDrive == l then curDrive = "C" end
    end
  end
end

local function refreshDrives()
  drives = {}
  local boot = computer.getBootAddress()
  local list = {}
  for a in component.list("filesystem") do list[#list + 1] = a end
  table.sort(list)
  if not boot then boot = list[1] end
  if boot then drives.C = boot end
  for _, a in ipairs(list) do if a ~= boot then driveAdd(a) end end
  if not drives[curDrive] then curDrive = "C" end
end
refreshDrives()

local function letterOf(addr)
  for l, v in pairs(drives) do if v == addr then return l end end
  return "?"
end

local rawpull
if HOSTED then
  local event = require("event")
  rawpull = function(t) return event.pull(t) end
else
  rawpull = function(t) return computer.pullSignal(t) end
end

-- One signal-pull for everything: logs hardware events, keeps drives current,
-- and feeds background services registered with hook().
local function pull(t)
  local e, a, b, c, d = rawpull(t)
  if e then
    if e == "component_added" then
      klog("component_added " .. tostring(b) .. " " .. tostring(a))
      if b == "filesystem" then driveAdd(a) end
    elseif e == "component_removed" then
      klog("component_removed " .. tostring(b) .. " " .. tostring(a))
      if b == "filesystem" then driveDel(a) end
    end
    for i = 1, #hooks do pcall(hooks[i], e, a, b, c, d) end
  end
  return e, a, b, c, d
end

------------------------------------------------------------------
-- 1. Filesystem layer (raw component calls; works in both modes)
------------------------------------------------------------------
local function inv(a, m, ...) return pcall(component.invoke, a, m, ...) end

local function fsExists(a, p)
  local ok, r = inv(a, "exists", p)
  return (ok and r) and true or false
end

local function fsIsDir(a, p)
  local ok, r = inv(a, "isDirectory", p)
  return (ok and r) and true or false
end

local function base(p) return p:match("([^/]+)/*$") or "/" end
local function join(p, n) return (p == "/" and "" or p) .. "/" .. n end

-- returns sorted { {name, isDir}, ... } or nil, err
local function fsList(a, p)
  local ok, r = inv(a, "list", p)
  if not ok or type(r) ~= "table" then return nil, tostring(ok and "not a directory" or r) end
  local t = {}
  for i = 1, #r do
    local n = r[i]
    local dir = n:sub(-1) == "/"
    t[#t + 1] = { dir and n:sub(1, -2) or n, dir }
  end
  table.sort(t, function(x, y)
    if x[2] ~= y[2] then return x[2] end
    return x[1]:lower() < y[1]:lower()
  end)
  return t
end

local function fsRead(a, p)
  local ok, h, e = inv(a, "open", p, "r")
  if not ok or not h then return nil, tostring(ok and e or h or "cannot open") end
  local t = {}
  while true do
    local ok2, c = inv(a, "read", h, BIG)
    if not ok2 or not c or c == "" then break end
    t[#t + 1] = c
  end
  inv(a, "close", h)
  return table.concat(t)
end

local function fsWrite(a, p, data, append)
  local ok, h, e = inv(a, "open", p, append and "a" or "w")
  if not ok or not h then return nil, tostring(ok and e or h or "cannot open") end
  for i = 1, #data, 2048 do
    local ok2, r, e2 = inv(a, "write", h, data:sub(i, i + 2047))
    if not ok2 or not r then
      inv(a, "close", h)
      return nil, tostring(ok2 and e2 or r or "write failed")
    end
  end
  inv(a, "close", h)
  return true
end

local function fsMkdirs(a, p)
  local cur = ""
  for part in p:gmatch("[^/]+") do
    cur = cur .. "/" .. part
    if not fsIsDir(a, cur) then
      local ok, r = inv(a, "makeDirectory", cur)
      if not ok or not r then return nil, "cannot create " .. cur end
    end
  end
  return true
end

local function fsRemove(a, p)
  if fsIsDir(a, p) then
    for _, e in ipairs(fsList(a, p) or {}) do
      local ok, err = fsRemove(a, join(p, e[1]))
      if not ok then return nil, err end
    end
  end
  local ok, r = inv(a, "remove", p)
  if not ok or not r then return nil, "cannot remove " .. p end
  return true
end

local function fsCopy(a1, p1, a2, p2)
  if fsIsDir(a1, p1) then
    if a1 == a2 and (p2 == p1 or p2:sub(1, #p1 + 1) == p1 .. "/") then
      return nil, "cannot copy a directory into itself"
    end
    local ok, e = fsMkdirs(a2, p2)
    if not ok then return nil, e end
    for _, ent in ipairs(fsList(a1, p1) or {}) do
      local ok2, er = fsCopy(a1, join(p1, ent[1]), a2, join(p2, ent[1]))
      if not ok2 then return nil, er end
    end
    return true
  end
  local ok, h1 = inv(a1, "open", p1, "r")
  if not ok or not h1 then return nil, "cannot read " .. p1 end
  local ok2, h2 = inv(a2, "open", p2, "w")
  if not ok2 or not h2 then
    inv(a1, "close", h1)
    return nil, "cannot write " .. p2
  end
  local res, err = true, nil
  while true do
    local ok3, c = inv(a1, "read", h1, BIG)
    if not ok3 then res, err = nil, tostring(c); break end
    if not c or c == "" then break end
    local ok4, w, we = inv(a2, "write", h2, c)
    if not ok4 or not w then res, err = nil, tostring(ok4 and we or w or "write failed"); break end
  end
  inv(a1, "close", h1)
  inv(a2, "close", h2)
  return res, err
end

-- Safe overwrite: write temp file, verify, then swap into place.
local function fsReplace(a, p, data)
  local tmp = p .. ".new"
  local ok, e = fsWrite(a, tmp, data)
  if not ok then inv(a, "remove", tmp); return nil, e end
  if fsRead(a, tmp) ~= data then inv(a, "remove", tmp); return nil, "verification failed" end
  if fsExists(a, p) then
    local okr, rr = inv(a, "remove", p)
    if not okr or not rr then inv(a, "remove", tmp); return nil, "cannot replace " .. p end
  end
  local okm, rm = inv(a, "rename", tmp, p)
  if not okm or not rm then return nil, "rename failed (new file left at " .. tmp .. ")" end
  return true
end

local function splitPath(p)
  local t = {}
  for part in p:gmatch("[^/\\]+") do
    if part == ".." then t[#t] = nil
    elseif part ~= "." then t[#t + 1] = part end
  end
  return t
end

-- Returns address, absolute path, drive letter   |   nil, error message
local function resolve(p)
  p = p or ""
  local d, rest = p:match("^(%a):(.*)$")
  local L
  if d then
    L = d:upper()
    local c = rest:sub(1, 1)
    if c ~= "/" and c ~= "\\" then rest = (cwds[L] or "/") .. "/" .. rest end
  else
    L = curDrive
    local c = p:sub(1, 1)
    if c ~= "/" and c ~= "\\" then rest = (cwds[L] or "/") .. "/" .. p else rest = p end
  end
  if not drives[L] then return nil, "The system cannot find drive " .. L .. ":" end
  return drives[L], "/" .. table.concat(splitPath(rest), "/"), L
end

local function dispPath(L, p) return L .. ":" .. (p:gsub("/", "\\")) end

local function globToPat(g)
  local s = g:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".")
  return "^" .. s .. "$"
end

-- Expands * and ? in the last path component. Returns { {addr, path}, ... } | nil, err
local function glob(arg)
  local a, p = resolve(arg)
  if not a then return nil, p end
  local dir, name = p:match("^(.*)/([^/]*)$")
  if not name or not name:find("[%*%?]") then return { { a, p } } end
  local ents = fsList(a, dir == "" and "/" or dir)
  if not ents then return nil, "cannot read " .. dir end
  local pat, res = globToPat(name), {}
  for _, e in ipairs(ents) do
    if e[1]:match(pat) then res[#res + 1] = { a, dir .. "/" .. e[1] } end
  end
  if #res == 0 then return nil, "No files match: " .. arg end
  return res
end

------------------------------------------------------------------
-- 2. Text helpers
------------------------------------------------------------------
local function trim(s) return (s:match("^%s*(.-)%s*$")) end

local function tokenize(s)
  local t, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == '"' then
      local j = s:find('"', i + 1, true)
      if not j then t[#t + 1] = s:sub(i + 1); break end
      t[#t + 1] = s:sub(i + 1, j - 1)
      i = j + 1
    else
      local j = s:find("%s", i) or (n + 1)
      t[#t + 1] = s:sub(i, j - 1)
      i = j
    end
  end
  return t
end

local function splitOn(s, ch)
  local t, cur, q = {}, {}, false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then q = not q end
    if c == ch and not q then
      t[#t + 1] = table.concat(cur)
      cur = {}
    else
      cur[#cur + 1] = c
    end
  end
  t[#t + 1] = table.concat(cur)
  return t
end

local function findRedirect(s)
  local q = false
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == '"' then q = not q
    elseif c == ">" and not q then return i, s:sub(i + 1, i + 1) == ">" end
  end
end

local function parseFlags(a)
  local o, rest = {}, {}
  for _, x in ipairs(a) do
    if x:match("^%-%a+$") then
      for c in x:sub(2):gmatch(".") do o[c] = true end
    else
      rest[#rest + 1] = x
    end
  end
  return o, rest
end

local function linesOf(data)
  local t = {}
  data = data:gsub("\r", "")
  if data:sub(-1) == "\n" then data = data:sub(1, -2) end
  if data == "" then return t end
  for l in (data .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end
  return t
end

local function human(n)
  if n >= 1048576 then return string.format("%.1fM", n / 1048576) end
  if n >= 1024 then return string.format("%.1fK", n / 1024) end
  return tostring(math.floor(n))
end

local function ser(v, d)
  d = d or 0
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) ~= "table" or d > 2 then return tostring(v) end
  local t = {}
  for k, x in pairs(v) do
    t[#t + 1] = "[" .. ser(k, 9) .. "]=" .. ser(x, d + 1)
    if #t >= 24 then t[#t + 1] = "..."; break end
  end
  return "{" .. table.concat(t, ", ") .. "}"
end

------------------------------------------------------------------
-- 3. Config, environment variables, aliases
------------------------------------------------------------------
local cfg = {}
local ENV = { OS = "ReactOS-OC", PATH = "/System32;/ProgramFiles;/bin", HOME = "/Users" }
local ALIAS = {}

local function cfgLoad()
  if not drives.C then return end
  local s = fsRead(drives.C, CFGDIR .. "/reactos.cfg")
  if s then for k, v in s:gmatch("([%w_]+)=([^\n]*)") do cfg[k] = v end end
  ENV.HOSTNAME = cfg.hostname or "reactos"
end

local function cfgSave()
  if not drives.C then return nil, "no boot drive" end
  fsMkdirs(drives.C, CFGDIR)
  local t = {}
  for k, v in pairs(cfg) do t[#t + 1] = k .. "=" .. v end
  table.sort(t)
  return fsWrite(drives.C, CFGDIR .. "/reactos.cfg", table.concat(t, "\n") .. "\n")
end

------------------------------------------------------------------
-- 4. Installer (works from OpenOS or from a floppy-booted ReactOS)
------------------------------------------------------------------
local SELF
if HOSTED then
  -- Primary: OpenOS's own process registry knows the running program's path.
  local ok1, proc = pcall(require, "process")
  if ok1 and proc and proc.info then
    local ok2, info = pcall(proc.info)
    if ok2 and type(info) == "table" and type(info.path) == "string" and info.path ~= "" then
      SELF = info.path
    end
  end
  -- Fallback: debug.getinfo. Reject OpenComputers' internal sandbox chunk
  -- name "machine" (and "stdin"), which is NOT the user's script.
  if not SELF then
    local ok, src = pcall(function() return debug.getinfo(1, "S").source end)
    if ok and type(src) == "string" and (src:sub(1, 1) == "=" or src:sub(1, 1) == "@") then
      local raw = src:sub(2)
      if raw ~= "machine" and raw ~= "stdin" and raw ~= "" and raw:find("/", 1, true) then
        SELF = raw
      end
    end
  end
  if SELF then
    local ok2, sh = pcall(require, "shell")
    if ok2 and sh and sh.resolve then
      local ok3, r = pcall(sh.resolve, SELF)
      if ok3 and r and r ~= "" then SELF = r end
    end
  end
end

local function pickFs(t)
  if not t or t == "" then
    if drives.C then return drives.C end
    return nil, "no boot drive"
  end
  local l = t:match("^(%a):?$")
  if l and drives[l:upper()] then return drives[l:upper()] end
  for _, a in pairs(drives) do
    if a:sub(1, #t) == t then return a end
  end
  return nil, "no such drive: " .. t
end

-- Returns the running script's own source, or nil, err. `err` always says
-- exactly which path was tried, so a failure is actionable instead of a
-- mystery "(file not found)".
local function selfSource(srcPath)
  if srcPath then
    local a, p = resolve(srcPath)
    if not a then return nil, p end
    local d, e = fsRead(a, p)
    if not d then return nil, "cannot read " .. srcPath .. " (" .. tostring(e) .. ")" end
    return d
  end
  if HOSTED then
    if not SELF then
      return nil, "cannot determine this script's own path; run:  install [drive] <file>  (the exact file you launched, e.g. init)"
    end
    local f, e = io.open(SELF, "rb")
    if not f then
      return nil, "cannot open " .. tostring(SELF) .. " (" .. tostring(e)
        .. "); run:  install [drive] <file>  with the exact file you launched"
    end
    local d = f:read("*a")
    f:close()
    if not d or d == "" then
      return nil, tostring(SELF) .. " is empty; run:  install [drive] <file>"
    end
    return d
  end
  local d, e = fsRead(drives.C, "/init.lua")
  if not d then
    return nil, "cannot read " .. letterOf(drives.C) .. ":/init.lua (" .. tostring(e) .. ")"
  end
  return d
end

local function doInstall(say, target, srcPath)
  local T, err = pickFs(target)
  if not T then return nil, err end
  say("Target drive: " .. letterOf(T) .. ": (" .. T:sub(1, 8) .. "...)")
  if HOSTED and not srcPath then
    say("Detected running script at: " .. tostring(SELF))
  end
  local src, e = selfSource(srcPath)
  if not src then
    return nil, tostring(e)
  end
  if #src < 2000 or not src:find("ReactOS-OC", 1, true) then
    return nil, "the source file does not look like ReactOS-OC (unexpected content)"
  end
  say("Checking source (" .. #src .. " bytes)...")
  local okc, f, ce = pcall(load, src, "=init")
  if not okc or not f then return nil, "source does not compile: " .. tostring(okc and ce or f) end
  f = nil
  local okr, ro = inv(T, "isReadOnly")
  if okr and ro then return nil, "target drive is read-only" end
  local ok1, tot = inv(T, "spaceTotal")
  local ok2, used = inv(T, "spaceUsed")
  local cur = fsRead(T, "/init.lua")
  if ok1 and ok2 and tot - used < #src + #(cur or "") + 4096 then
    return nil, "not enough free space on the target drive"
  end
  local ee = first("eeprom")
  if ee then
    local ok3, code = pcall(component.invoke, ee, "get")
    if ok3 and not (code and code:find("init.lua", 1, true)) then
      say("Warning: the EEPROM does not look like a standard BIOS; it may not boot /init.lua.")
    end
  end
  if cur and not cur:find("ReactOS-OC", 1, true) then
    say("Backing up current /init.lua -> " .. BACKUP)
    local ok, we = fsReplace(T, BACKUP, cur)
    if not ok then return nil, "backup failed: " .. tostring(we) end
  elseif cur then
    say("ReactOS-OC is already installed here; updating it.")
  else
    say("No existing /init.lua found; no backup needed.")
  end
  fsMkdirs(T, CFGDIR .. "/rc.d")
  fsMkdirs(T, "/ProgramFiles")
  fsMkdirs(T, "/Users")
  say("Writing /init.lua ...")
  local ok, we = fsReplace(T, "/init.lua", src)
  if not ok then return nil, tostring(we) end
  local oks, sz = inv(T, "size", "/init.lua")
  if not oks or sz ~= #src then return nil, "written file has the wrong size (" .. tostring(sz) .. " vs " .. #src .. ")" end
  say(string.format("OK: %d bytes written to %s:/init.lua", #src, letterOf(T)))
  local ba = computer.getBootAddress()
  if ba and ba ~= T then
    say("Note: the computer booted from " .. ba:sub(1, 8) .. "..., NOT from the drive you installed to.")
    say("The BIOS may keep booting the other drive.")
  end
  say("Installed. Reboot to start ReactOS-OC (press O during boot for OpenOS).")
  return true
end

local function doUninstall(say, target)
  local T, err = pickFs(target)
  if not T then return nil, err end
  local cur = fsRead(T, "/init.lua")
  if not cur or not cur:find("ReactOS-OC", 1, true) then return nil, "ReactOS-OC is not installed on that drive" end
  local bak = fsRead(T, BACKUP)
  if not bak or bak == "" then return nil, "no OpenOS backup (" .. BACKUP .. ") found; nothing to restore" end
  say("Restoring original /init.lua ...")
  local ok, we = fsReplace(T, "/init.lua", bak)
  if not ok then return nil, tostring(we) end
  inv(T, "remove", BACKUP)
  say("Done. The original boot program is back; reboot to use it.")
  return true
end

------------------------------------------------------------------
-- 5. Palette and console
------------------------------------------------------------------
local BG    = 0x000080
local FG    = 0xFFFFFF
local GRAY  = 0xC0C0C0
local BLACK = 0x000000
local CYAN  = 0x87CEFA
local GREEN = 0x00C000
local RED   = 0xFF5555

local gpu, W, H, cx, cy = nil, 80, 25, 1, 1
local origW, origH
local meType = nil
local sink, STDIN = nil, nil        -- pipe capture / pipe input
local quitShell, wantOS = false, false

local function color(bg, fg)
  gpu.setBackground(bg)
  gpu.setForeground(fg)
end

local function cls()
  color(BG, FG)
  gpu.fill(1, 1, W, H, " ")
  cx, cy = 1, 1
end

local function nl()
  cx = 1
  cy = cy + 1
  if cy > H then
    gpu.copy(1, 2, W, H - 1, 0, -1)
    gpu.fill(1, H, W, 1, " ")
    cy = H
  end
end

local function out(s)
  s = tostring(s)
  if sink then sink[#sink + 1] = s; return end
  s = s:gsub("[\t\r]", function(c) return c == "\t" and "    " or "" end)
  for line, sep in s:gmatch("([^\n]*)(\n?)") do
    while unicode.len(line) > 0 do
      if cx > W then nl() end
      local chunk = unicode.sub(line, 1, W - cx + 1)
      gpu.set(cx, cy, chunk)
      cx = cx + unicode.len(chunk)
      line = unicode.sub(line, unicode.len(chunk) + 1)
    end
    if sep == "\n" then nl() end
  end
end

local function pad(s, n, right)
  s = tostring(s)
  local l = unicode.len(s)
  if l > n then return unicode.sub(s, 1, n) end
  local sp = string.rep(" ", n - l)
  return right and (sp .. s) or (s .. sp)
end

local function commas(n)
  local s = string.format("%.0f", tonumber(n) or 0)
  local r
  repeat s, r = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until r == 0
  return s
end

local function bar(y, text, bgc, fgc)
  color(bgc, fgc)
  gpu.fill(1, y, W, 1, " ")
  gpu.set(2, y, unicode.sub(text, 1, W - 2))
  color(BG, FG)
end

local function center(y, s)
  gpu.set(math.max(1, math.floor((W - unicode.len(s)) / 2) + 1), y, s)
end

local function waitKey()
  while true do
    local e, _, ch, code = pull()
    if e == "key_down" then return ch, code end
  end
end

local function confirm(msg)
  out(msg .. " (y/N) ")
  local ch = waitKey()
  local yes = (ch == 121 or ch == 89)
  out(yes and "y\n" or "n\n")
  return yes
end

local function report(err)
  err = tostring(err)
  if HOSTED and err:find("interrupted", 1, true) then error(err, 0) end
  color(BG, RED)
  out("Error: " .. err .. "\n")
  color(BG, FG)
end

-- Line editor: cursor keys, history, paste, Ctrl+C
local hist, HMAX = {}, 25

local function readline()
  local sx, sy = cx, cy
  local maxlen = math.max(1, W - sx)
  local buf, pos = "", 0
  local hi, saved = #hist + 1, ""

  local function draw(cursor)
    color(BG, FG)
    gpu.fill(sx, sy, W - sx + 1, 1, " ")
    gpu.set(sx, sy, buf)
    if cursor then
      local under = unicode.sub(buf, pos + 1, pos + 1)
      color(FG, BG)
      gpu.set(sx + pos, sy, under ~= "" and under or " ")
      color(BG, FG)
    end
  end

  local function insert(s)
    s = s:gsub("%c", "")
    local room = maxlen - unicode.len(buf)
    if room <= 0 or s == "" then return end
    s = unicode.sub(s, 1, room)
    buf = unicode.sub(buf, 1, pos) .. s .. unicode.sub(buf, pos + 1)
    pos = pos + unicode.len(s)
  end

  local function finish()
    draw(false)
    cx = sx + unicode.len(buf)
    nl()
  end

  while true do
    draw(true)
    local e, _, ch, code = pull()
    if e == "key_down" then
      if ch == 13 then
        finish()
        if buf ~= "" and hist[#hist] ~= buf then
          hist[#hist + 1] = buf
          if #hist > HMAX then table.remove(hist, 1) end
        end
        return buf
      elseif ch == 3 then
        buf = buf .. "^C"
        finish()
        return ""
      elseif ch == 8 then
        if pos > 0 then
          buf = unicode.sub(buf, 1, pos - 1) .. unicode.sub(buf, pos + 1)
          pos = pos - 1
        end
      elseif code == 211 then
        buf = unicode.sub(buf, 1, pos) .. unicode.sub(buf, pos + 2)
      elseif code == 203 then
        if pos > 0 then pos = pos - 1 end
      elseif code == 205 then
        if pos < unicode.len(buf) then pos = pos + 1 end
      elseif code == 199 then pos = 0
      elseif code == 207 then pos = unicode.len(buf)
      elseif code == 200 then
        if hi > 1 then
          if hi == #hist + 1 then saved = buf end
          hi = hi - 1
          buf = hist[hi]; pos = unicode.len(buf)
        end
      elseif code == 208 then
        if hi <= #hist then
          hi = hi + 1
          buf = (hi > #hist) and saved or hist[hi]
          pos = unicode.len(buf)
        end
      elseif ch and ch >= 32 then
        insert(unicode.char(ch))
      end
    elseif e == "clipboard" then
      local text = ch
      if type(text) == "string" then insert((text:match("^[^\r\n]*"))) end
    end
  end
end

-- Pager used by more / less / man / help / dmesg. lines = array of strings.
local function pager(lines, back)
  if sink then
    for _, l in ipairs(lines) do out(l .. "\n") end
    return
  end
  local w = {}
  for _, l in ipairs(lines) do
    l = (l:gsub("\t", "  "))
    if l == "" then w[#w + 1] = "" end
    while unicode.len(l) > 0 do
      w[#w + 1] = unicode.sub(l, 1, W)
      l = unicode.sub(l, W + 1)
    end
  end
  local n, page = #w, H - 1
  if n <= page then
    for _, l in ipairs(w) do out(l .. "\n") end
    return
  end
  local top = 1
  while true do
    color(BG, FG)
    gpu.fill(1, 1, W, H, " ")
    for r = 1, page do
      local l = w[top + r - 1]
      if not l then break end
      gpu.set(1, r, l)
    end
    local last = top + page - 1 >= n
    bar(H, string.format("%s (%d%%)  %s", back and "less" or "more",
        math.min(100, math.floor((top + page - 1) * 100 / n)),
        back and "space/PgDn next, b/PgUp back, arrows, q quit"
             or "space next page, enter next line, q quit"), GRAY, BLACK)
    local ch, code = waitKey()
    if ch == 113 or ch == 81 or ch == 3 then
      break
    elseif ch == 32 or code == 209 then
      if last and not back then break end
      top = math.min(top + page, math.max(1, n - page + 1))
    elseif ch == 13 or code == 208 then
      if last and not back then break end
      if not last then top = top + 1 end
    elseif back and (ch == 98 or code == 201) then
      top = math.max(1, top - page)
    elseif back and code == 200 then
      top = math.max(1, top - 1)
    elseif code == 199 then
      top = 1
    elseif code == 207 then
      top = math.max(1, n - page + 1)
    end
  end
  cls()
end

------------------------------------------------------------------
-- 6. Command registry, program runner, pipes
------------------------------------------------------------------
local cmds, aliasOf, helpInfo = {}, {}, {}

local function def(names, usage, desc, fn, long)
  local firstName
  for n in names:gmatch("[^|]+") do
    cmds[n] = fn
    if not firstName then firstName = n else aliasOf[n] = firstName end
  end
  helpInfo[firstName] = { usage = usage, desc = desc, names = names, long = long }
end

local function needArg(a, usage)
  if #a == 0 then out("Usage: " .. usage .. "\n"); return false end
  return true
end

-- Collect input texts from file args (wildcards ok) or from the pipe.
local function sources(a)
  if #a == 0 then
    if STDIN then return { { "(stdin)", STDIN } } end
    return nil
  end
  local res = {}
  for _, f in ipairs(a) do
    local list, err = glob(f)
    if not list then
      out(err .. "\n")
    else
      for _, r in ipairs(list) do
        local d, e = fsRead(r[1], r[2])
        if d then res[#res + 1] = { base(r[2]), d } else out("Cannot read " .. r[2] .. ": " .. tostring(e) .. "\n") end
      end
    end
  end
  return res
end

local ROS = {}
local runLine   -- forward declaration; assigned further below

-- ---- OpenOS-style io.open for programs (works in BARE and HOSTED mode) ----
local function mkReader(d)
  local pos = 1
  local f = {}
  local function rd(fmt)
    if fmt == nil then fmt = "l" end
    if type(fmt) == "number" then
      if pos > #d then return nil end
      local s = d:sub(pos, pos + fmt - 1)
      pos = pos + #s
      return s
    end
    fmt = tostring(fmt):gsub("^%*", "")
    if fmt == "a" then
      local s = d:sub(pos)
      pos = #d + 1
      return s
    elseif fmt == "l" or fmt == "L" then
      if pos > #d then return nil end
      local e = d:find("\n", pos, true)
      local line
      if e then
        line = d:sub(pos, fmt == "L" and e or (e - 1))
        pos = e + 1
      else
        line = d:sub(pos)
        pos = #d + 1
      end
      return line
    elseif fmt == "n" then
      local s, e2 = d:find("^%s*[%+%-]?%d+%.?%d*", pos)
      if not s then return nil end
      pos = e2 + 1
      return tonumber(d:sub(s, e2))
    end
    return nil
  end
  f.read = function(self, ...)
    local n = select("#", ...)
    if n == 0 then return rd("l") end
    local r = {}
    for i = 1, n do r[i] = rd((select(i, ...))) end
    return table.unpack(r, 1, n)
  end
  f.lines = function(self, fmt) return function() return rd(fmt or "l") end end
  f.seek = function(self, whence, off)
    whence, off = whence or "cur", off or 0
    if whence == "set" then pos = off + 1
    elseif whence == "cur" then pos = pos + off
    else pos = #d + off + 1 end
    return pos - 1
  end
  f.write = function() return nil, "file not open for writing" end
  f.close = function() return true end
  f.setvbuf = function() return true end
  return f
end

local function mkWriter(a, p)
  local buf, f = {}, {}
  local function flush()
    if #buf == 0 then return true end
    local ok, e = fsWrite(a, p, table.concat(buf), true)
    buf = {}
    return ok, e
  end
  f.write = function(self, ...)
    for i = 1, select("#", ...) do buf[#buf + 1] = tostring((select(i, ...))) end
    return self
  end
  f.flush = function(self) flush(); return self end
  f.close = function() return flush() end
  f.seek = function() return 0 end
  f.setvbuf = function() return true end
  f.read = function() return nil, "file not open for reading" end
  f.lines = function() error("file not open for reading", 2) end
  return f
end

local function ioOpen(path, mode)
  mode = tostring(mode or "r")
  path = tostring(path)
  local a, p = resolve(path)
  if not a then return nil, tostring(p), 2 end
  local m = mode:sub(1, 1)
  if m == "r" then
    if not fsExists(a, p) or fsIsDir(a, p) then return nil, path .. ": No such file or directory", 2 end
    local d, e = fsRead(a, p)
    if not d then return nil, path .. ": " .. tostring(e), 2 end
    return mkReader(d)
  elseif m == "w" or m == "a" then
    if m == "w" or not fsExists(a, p) then
      local ok, e = fsWrite(a, p, "")
      if not ok then return nil, path .. ": " .. tostring(e), 2 end
    end
    return mkWriter(a, p)
  end
  return nil, "invalid mode '" .. mode .. "'", 22
end

-- ---- require() for programs ----
local loadedMods, loadingMods, SHIMS = {}, {}, {}
local progEnv

local function requireFn(name)
  name = tostring(name)
  if loadedMods[name] ~= nil then return loadedMods[name] end
  if loadingMods[name] then error("loop or previous error loading module '" .. name .. "'", 0) end
  local mk = SHIMS[name]
  if mk then
    loadedMods[name] = mk()
    return loadedMods[name]
  end
  local rel = name:gsub("%.", "/")
  local cands = { rel .. ".lua" }
  for _, d in ipairs({ "/lib", "/usr/lib", "/home/lib", "/System32/lib", "/ProgramFiles/lib" }) do
    cands[#cands + 1] = "C:" .. d .. "/" .. rel .. ".lua"
    cands[#cands + 1] = "C:" .. d .. "/" .. rel .. "/init.lua"
  end
  for _, c in ipairs(cands) do
    local a, p = resolve(c)
    if a and fsExists(a, p) and not fsIsDir(a, p) then
      local src = fsRead(a, p)
      if src then
        loadingMods[name] = true
        local f, le = load(src, "=" .. p, "t", progEnv())
        if not f then loadingMods[name] = nil; error(tostring(le), 0) end
        local ok, r = pcall(f, name, p)
        loadingMods[name] = nil
        if not ok then error(tostring(r), 0) end
        if r == nil then r = true end
        loadedMods[name] = r
        return r
      end
    end
  end
  if HOSTED and _ENV.require then
    local ok, r = pcall(_ENV.require, name)
    if ok then loadedMods[name] = r; return r end
  end
  error("module '" .. name .. "' not found", 0)
end

SHIMS.component = function() return component end
SHIMS.computer  = function() return computer end
SHIMS.unicode   = function() return unicode end
SHIMS.bit32     = function() return _ENV.bit32 end
for n in ("string table math coroutine"):gmatch("%a+") do
  SHIMS[n] = function() return _ENV[n] end
end

SHIMS.event = function()
  local ev = {}
  ev.pull = function(a1, a2)
    local timeout, name
    if type(a1) == "number" then timeout, name = a1, a2 else name = a1 end
    local dl = timeout and (computer.uptime() + timeout) or nil
    while true do
      local left = dl and math.max(0, dl - computer.uptime()) or nil
      local e, a, b, c, d = pull(left)
      if e == "key_down" and b == 3 then error("__ctrlc__", 0) end
      if e and (not name or e == name) then return e, a, b, c, d end
      if dl and computer.uptime() >= dl then return nil end
    end
  end
  ev.push = computer.pushSignal
  return ev
end

SHIMS.term = function()
  return {
    clear = function() cls() end,
    isAvailable = function() return true end,
    read = function() return readline() .. "\n" end,
    write = function(s) out(s) end,
    getCursor = function() return cx, cy end,
    setCursor = function(x, y) cx, cy = x, y end,
    clearLine = function() gpu.fill(1, cy, W, 1, " "); cx = 1 end,
    getViewport = function() return W, H, 1, 1, 1, 1 end,
    gpu = function() return gpu end,
  }
end

SHIMS.filesystem = function()
  local fs = {}
  local function rp(p) return resolve(tostring(p)) end
  fs.exists = function(p) local a, q = rp(p); return (a and fsExists(a, q)) and true or false end
  fs.isDirectory = function(p) local a, q = rp(p); return (a and fsIsDir(a, q)) and true or false end
  fs.list = function(p)
    local a, q = rp(p)
    local l = a and fsList(a, q)
    if not l then return nil, "not a directory" end
    local i = 0
    return function()
      i = i + 1
      local e = l[i]
      if e then return e[1] .. (e[2] and "/" or "") end
    end
  end
  fs.makeDirectory = function(p) local a, q = rp(p); return (a and fsMkdirs(a, q)) and true or false end
  fs.remove = function(p) local a, q = rp(p); return (a and fsRemove(a, q)) and true or false end
  fs.size = function(p)
    local a, q = rp(p)
    if not a then return 0 end
    local ok, n = inv(a, "size", q)
    return ok and n or 0
  end
  fs.concat = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    return "/" .. table.concat(splitPath(table.concat(t, "/")), "/")
  end
  fs.name = function(p) return base(tostring(p)) end
  fs.open = ioOpen
  return fs
end

SHIMS.shell = function()
  return {
    resolve = function(p) local a, q = resolve(tostring(p)); return q or p end,
    getWorkingDirectory = function() return cwds[curDrive] or "/" end,
    setWorkingDirectory = function(p)
      local a, q, L = resolve(tostring(p))
      if a and fsIsDir(a, q) then cwds[L] = q; curDrive = L; return true end
      return nil, "invalid directory"
    end,
    execute = function(cmd) runLine(tostring(cmd)); return true end,
    parse = function(...)
      local args, opts = {}, {}
      for _, x in ipairs({ ... }) do
        x = tostring(x)
        if x:sub(1, 2) == "--" then
          local k, v = x:match("^%-%-([^=]+)=?(.*)$")
          if k then opts[k] = (v ~= "") and v or true end
        elseif x:match("^%-%a") then
          for c in x:sub(2):gmatch(".") do opts[c] = true end
        else
          args[#args + 1] = x
        end
      end
      return args, opts
    end,
  }
end

progEnv = function()
  local env = { ros = ROS, component = component, computer = computer, unicode = unicode }
  env._G = env
  env.print = function(...)
    local t = {}
    for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
    out(table.concat(t, "\t") .. "\n")
  end
  env.require = requireFn
  env.os = setmetatable({
    sleep = function(t)
      local dl = computer.uptime() + (tonumber(t) or 0)
      repeat
        local e, _, b = pull(math.max(0, dl - computer.uptime()))
        if e == "key_down" and b == 3 then error("__ctrlc__", 0) end
      until computer.uptime() >= dl
    end,
    exit = function() error("__exit__", 0) end,
    getenv = function(k) if k then return ENV[k] end return ENV end,
  }, { __index = _ENV.os })
  local wr = function(...)
    for i = 1, select("#", ...) do out(tostring((select(i, ...)))) end
  end
  env.io = setmetatable({
    write = wr,
    read = function(fmt)
      local l = readline()
      if fmt == "n" or fmt == "*n" then return tonumber(l) end
      return l
    end,
    open = ioOpen,
    lines = function(path, fmt)
      local f, e = ioOpen(path, "r")
      if not f then error(e, 2) end
      return f:lines(fmt)
    end,
  }, { __index = _ENV.io })
  env.io.stdout = { write = function(self, ...) wr(...); return self end, flush = function() end, close = function() end }
  env.io.stderr = env.io.stdout
  return setmetatable(env, { __index = _ENV })
end

local function runLua(src, name, args)
  local f, e = load(src, "=" .. name, "t", progEnv())
  if not f then report(e); return end
  local ok, err = pcall(f, table.unpack(args))
  if not ok then
    if err == "__exit__" then return end
    if err == "__ctrlc__" then out("^C\n"); return end
    report(err)
  end
end

local function execScript(a, p)
  local data = fsRead(a, p)
  if not data then out("Cannot read script.\n"); return end
  for _, l in ipairs(linesOf(data)) do
    local s = trim(l)
    if s ~= "" and s:sub(1, 1) ~= "#" and s:sub(1, 2) ~= "::" and s:lower():sub(1, 4) ~= "rem " then
      runLine(s)
    end
  end
end

local function findProgram(name)
  local dirs = { "" }
  if not name:find("[/\\:]") then
    for d in (ENV.PATH or ""):gmatch("[^;]+") do dirs[#dirs + 1] = d end
  end
  local ln = name:lower()
  local exts = (ln:match("%.lua$") or ln:match("%.cmd$")) and { "" } or { ".lua", ".cmd" }
  for _, d in ipairs(dirs) do
    for _, ext in ipairs(exts) do
      local a, p, L = resolve((d == "" and name or (d .. "/" .. name)) .. ext)
      if a and fsExists(a, p) and not fsIsDir(a, p) then return a, p, L end
    end
  end
end

local function runProgram(name, args)
  local a, p = findProgram(name)
  if not a then return false end
  if p:lower():match("%.cmd$") then
    execScript(a, p)
  else
    local src, e = fsRead(a, p)
    if not src then
      out("Error: " .. tostring(e) .. "\n")
    elseif src == "" then
      out("Error: " .. base(p) .. " is empty.\n")
    else
      runLua(src, base(p), args)
    end
  end
  return true
end

local function execOne(line)
  if line == "" then return end
  local name, raw = line:match("^(%S+)%s*(.*)$")
  local lname = name:lower()
  if ALIAS[lname] then
    line = ALIAS[lname] .. " " .. raw
    name, raw = line:match("^(%S+)%s*(.*)$")
    lname = name:lower()
  end
  local dl = name:match("^(%a):$")
  if dl and raw == "" then
    if drives[dl:upper()] then curDrive = dl:upper()
    else out("The system cannot find the drive specified.\n") end
    return
  end
  local f = cmds[lname]
  if f then f(raw, tokenize(raw)); return end
  if runProgram(name, tokenize(raw)) then return end
  out("'" .. name .. "' is not recognized as an internal or external command.\n")
end

runLine = function(line)
  line = line:gsub("%%([%w_]+)%%", function(k) return ENV[k] or ENV[k:upper()] or "" end)
  local segs = splitOn(line, "|")
  local target, append
  local cut, app = findRedirect(segs[#segs])
  if cut then
    local s = segs[#segs]
    target = trim(s:sub(cut + (app and 2 or 1)))
    append = app
    segs[#segs] = s:sub(1, cut - 1)
  end
  local data
  for i, seg in ipairs(segs) do
    STDIN = data
    if i < #segs or target then sink = {} end
    local ok, err = pcall(execOne, trim(seg))
    local got = sink
    sink = nil
    data = got and table.concat(got) or nil
    if not ok then STDIN = nil; report(err); return end
  end
  STDIN = nil
  if target and target ~= "" then
    local a, p = resolve(target)
    if not a then out(p .. "\n"); return end
    local ok, e = fsWrite(a, p, data or "", append)
    if not ok then out("Error: " .. tostring(e) .. "\n") end
  end
end

------------------------------------------------------------------
-- 7. Commands: files & navigation
------------------------------------------------------------------
def("cd", "cd [path]", "Change or show the current directory", function(raw, a)
  if not a[1] then out(dispPath(curDrive, cwds[curDrive] or "/") .. "\n"); return end
  local ad, p, L = resolve(table.concat(a, " "))
  if not ad then out(p .. "\n"); return end
  if not fsIsDir(ad, p) then out("The system cannot find the path specified.\n"); return end
  curDrive = L
  cwds[L] = p
end)

def("pwd", "pwd", "Print the current directory", function()
  out(dispPath(curDrive, cwds[curDrive] or "/") .. "\n")
end)

def("ls|dir", "ls [-l] [path|pattern]", "List directory contents", function(raw, a)
  local o, r = parseFlags(a)
  local path = r[1]
  local ad, p = resolve(path or "")
  if not ad then out(p .. "\n"); return end
  local ents = {}
  if path and path:find("[%*%?]") then
    local res, err = glob(path)
    if not res then out(err .. "\n"); return end
    for _, x in ipairs(res) do ents[#ents + 1] = { base(x[2]), fsIsDir(x[1], x[2]), x[2] } end
  else
    if not fsExists(ad, p) then out("File not found: " .. (path or p) .. "\n"); return end
    if not fsIsDir(ad, p) then
      ents[1] = { base(p), false, p }
    else
      for _, x in ipairs(fsList(ad, p) or {}) do ents[#ents + 1] = { x[1], x[2], join(p, x[1]) } end
    end
  end
  if o.l then
    for _, e in ipairs(ents) do
      local ds = "                 "
      local okd, t = inv(ad, "lastModified", e[3])
      if okd and type(t) == "number" and t > 0 then
        local okf, s = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(t / 1000))
        if okf and s then ds = s .. "  " end
      end
      local sz = "<DIR>"
      if not e[2] then
        local oks, n = inv(ad, "size", e[3])
        sz = commas(oks and n or 0)
      end
      if not sink then color(BG, e[2] and CYAN or FG) end
      out(ds .. pad(sz, 12, true) .. "  " .. e[1] .. "\n")
    end
    color(BG, FG)
    return
  end
  if sink then
    for _, e in ipairs(ents) do out(e[1] .. (e[2] and "\\" or "") .. "\n") end
    return
  end
  local maxl = 0
  for _, e in ipairs(ents) do maxl = math.max(maxl, unicode.len(e[1]) + (e[2] and 1 or 0)) end
  local cw = maxl + 2
  local cols = math.max(1, math.floor(W / cw))
  for i, e in ipairs(ents) do
    color(BG, e[2] and CYAN or FG)
    out(pad(e[1] .. (e[2] and "\\" or ""), cw))
    if i % cols == 0 or i == #ents then out("\n") end
  end
  color(BG, FG)
  if #ents == 0 then out("(empty)\n") end
end)

def("cp|copy", "cp [-r] <src> <dest>", "Copy files or directories", function(raw, a)
  local o, r = parseFlags(a)
  if #r < 2 then out("Usage: cp [-r] <src...> <dest>\n"); return end
  local dest = table.remove(r)
  local da, dp = resolve(dest)
  if not da then out(dp .. "\n"); return end
  local srcs = {}
  for _, s in ipairs(r) do
    local list, err = glob(s)
    if not list then out(err .. "\n") else for _, x in ipairs(list) do srcs[#srcs + 1] = x end end
  end
  local isDir = fsIsDir(da, dp)
  if #srcs > 1 and not isDir then out("cp: target must be an existing directory\n"); return end
  local n = 0
  for _, s in ipairs(srcs) do
    if not fsExists(s[1], s[2]) then
      out("cp: " .. s[2] .. ": no such file\n")
    elseif fsIsDir(s[1], s[2]) and not o.r then
      out("cp: " .. s[2] .. " is a directory (use -r)\n")
    else
      local ok, e = fsCopy(s[1], s[2], da, isDir and join(dp, base(s[2])) or dp)
      if ok then n = n + 1 else out("cp: " .. tostring(e) .. "\n") end
    end
  end
  out(n .. " item(s) copied.\n")
end)

def("mv|move|ren", "mv <src> <dest>", "Move or rename files or directories", function(raw, a)
  if #a < 2 then out("Usage: mv <src...> <dest>\n"); return end
  local dest = a[#a]
  local da, dp = resolve(dest)
  if not da then out(dp .. "\n"); return end
  local srcs = {}
  for i = 1, #a - 1 do
    local list, err = glob(a[i])
    if not list then out(err .. "\n") else for _, x in ipairs(list) do srcs[#srcs + 1] = x end end
  end
  local isDir = fsIsDir(da, dp)
  if #srcs > 1 and not isDir then out("mv: target must be an existing directory\n"); return end
  for _, s in ipairs(srcs) do
    local target = isDir and join(dp, base(s[2])) or dp
    if not fsExists(s[1], s[2]) then
      out("mv: " .. s[2] .. ": no such file\n")
    elseif s[1] == da and s[2] == target then
      -- nothing to do
    else
      if fsExists(da, target) and not fsIsDir(da, target) then fsRemove(da, target) end
      local ok, r2 = false, nil
      if s[1] == da then
        local okm, rm = inv(da, "rename", s[2], target)
        ok = okm and rm
      end
      if not ok then
        local okc, e = fsCopy(s[1], s[2], da, target)
        if okc then ok = fsRemove(s[1], s[2]) else r2 = e end
      end
      if not ok then out("mv: failed for " .. s[2] .. (r2 and (": " .. tostring(r2)) or "") .. "\n") end
    end
  end
end)

def("rm|del", "rm [-r] <path>", "Remove files or directories", function(raw, a)
  local o, r = parseFlags(a)
  if not needArg(r, "rm [-r] <path...>") then return end
  local n = 0
  for _, s in ipairs(r) do
    local list, err = glob(s)
    if not list then
      if not o.f then out(err .. "\n") end
    else
      for _, x in ipairs(list) do
        if x[2] == "/" then
          out("rm: refusing to remove the root directory\n")
        elseif not fsExists(x[1], x[2]) then
          if not o.f then out("rm: " .. x[2] .. ": no such file\n") end
        elseif fsIsDir(x[1], x[2]) and not o.r then
          out("rm: " .. x[2] .. " is a directory (use -r)\n")
        else
          local ok, e = fsRemove(x[1], x[2])
          if ok then n = n + 1 else out("rm: " .. tostring(e) .. "\n") end
        end
      end
    end
  end
  if n > 0 then out(n .. " item(s) removed.\n") end
end)

def("mkdir|md", "mkdir <dir>", "Create directories (parents included)", function(raw, a)
  if not needArg(a, "mkdir <dir...>") then return end
  for _, d in ipairs(a) do
    local ad, p = resolve(d)
    if not ad then out(p .. "\n")
    else
      local ok, e = fsMkdirs(ad, p)
      if not ok then out("mkdir: " .. tostring(e) .. "\n") end
    end
  end
end)

def("touch", "touch <file>", "Create an empty file if it does not exist", function(raw, a)
  if not needArg(a, "touch <file...>") then return end
  for _, f in ipairs(a) do
    local ad, p = resolve(f)
    if not ad then out(p .. "\n")
    elseif not fsExists(ad, p) then
      local ok, e = fsWrite(ad, p, "")
      if not ok then out("touch: " .. tostring(e) .. "\n") end
    end
  end
end)

local function driveInfo(a)
  local _, lbl = inv(a, "getLabel")
  local _, ro = inv(a, "isReadOnly")
  return lbl, ro
end

local function sortedLetters()
  local ls = {}
  for l in pairs(drives) do ls[#ls + 1] = l end
  table.sort(ls)
  return ls
end

def("mount", "mount [rescan | X: address]", "Show or change drive letter mappings", function(raw, a)
  if a[1] == "rescan" then
    refreshDrives()
    klog("drives rescanned")
  elseif a[1] and a[2] then
    local l = a[1]:match("^(%a):?$")
    if not l then out("Usage: mount X: <address-prefix>\n"); return end
    local addr
    for x in component.list("filesystem") do
      if x:sub(1, #a[2]) == a[2] then addr = x; break end
    end
    if not addr then out("No filesystem with that address.\n"); return end
    drives[l:upper()] = addr
    out(l:upper() .. ": -> " .. addr:sub(1, 8) .. "...\n")
    return
  end
  out(pad("Drive", 7) .. pad("Address", 13) .. pad("Label", 16) .. "Mode\n")
  for _, l in ipairs(sortedLetters()) do
    local a2 = drives[l]
    local lbl, ro = driveInfo(a2)
    local tmp = (a2 == computer.tmpAddress()) and " (tmp)" or ""
    out(pad(l .. ":", 7) .. pad(a2:sub(1, 8) .. "...", 13) .. pad(lbl or "-", 16)
        .. (ro and "ro" or "rw") .. tmp .. "\n")
  end
end)

def("umount", "umount X:", "Remove a drive letter mapping", function(raw, a)
  local l = (a[1] or ""):match("^(%a):?$")
  if not l then out("Usage: umount X:\n"); return end
  l = l:upper()
  if l == "C" then out("Cannot unmount the boot drive.\n"); return end
  if not drives[l] then out("Not mounted.\n"); return end
  drives[l] = nil
  if curDrive == l then curDrive = "C" end
end)

def("df", "df", "Show disk space usage per drive", function()
  out(pad("Drive", 7) .. pad("Label", 14) .. pad("Size", 9, true) .. pad("Used", 9, true)
      .. pad("Free", 9, true) .. "  Use%\n")
  for _, l in ipairs(sortedLetters()) do
    local a = drives[l]
    local _, tot = inv(a, "spaceTotal")
    local _, used = inv(a, "spaceUsed")
    local lbl = driveInfo(a)
    tot, used = tonumber(tot) or 0, tonumber(used) or 0
    out(pad(l .. ":", 7) .. pad(lbl or "-", 14) .. pad(human(tot), 9, true) .. pad(human(used), 9, true)
        .. pad(human(tot - used), 9, true) .. "  "
        .. (tot > 0 and (math.floor(used * 100 / tot) .. "%") or "-") .. "\n")
  end
end)

def("label", "label [X:] [new label]", "View or set a filesystem label", function(raw, a)
  local letter, rest = curDrive, a
  local l = a[1] and a[1]:match("^(%a):?$")
  if l and drives[l:upper()] then
    letter = l:upper()
    rest = {}
    for i = 2, #a do rest[#rest + 1] = a[i] end
  end
  local addr = drives[letter]
  if #rest == 0 then
    local lbl = driveInfo(addr)
    out(letter .. ": " .. (lbl and lbl ~= "" and lbl or "(no label)") .. "\n")
  else
    local ok, e = inv(addr, "setLabel", table.concat(rest, " "))
    if not ok then out("label: " .. tostring(e) .. "\n") end
  end
end)

------------------------------------------------------------------
-- 8. Commands: viewing & editing text
------------------------------------------------------------------
local sharedEditor   -- filled in below; lets the desktop's Notepad reuse this editor
def("cat|type", "cat <file>", "Print raw file contents", function(raw, a)
  if #a == 0 and not STDIN then out("Usage: cat <file...>\n"); return end
  local srcs = sources(a)
  for _, s in ipairs(srcs or {}) do
    local d = s[2]:gsub("[%z\1-\8\11\12\14-\31]", ".")
    out(d)
    if d:sub(-1) ~= "\n" then out("\n") end
  end
end)

def("grep", "grep [-invcF] <pattern> [file]", "Search text with a Lua pattern", function(raw, a)
  local o, r = parseFlags(a)
  local pat = table.remove(r, 1)
  if not pat then out("Usage: grep [-i] [-n] [-v] [-c] [-F] <pattern> [file...]\n"); return end
  local srcs = sources(r)
  if not srcs then out("grep: no input\n"); return end
  local needle = o.i and pat:lower() or pat
  for _, s in ipairs(srcs) do
    local n = 0
    for i, line in ipairs(linesOf(s[2])) do
      local hay = o.i and line:lower() or line
      local ok, hit = pcall(string.find, hay, needle, 1, o.F)
      if not ok then out("grep: bad pattern: " .. tostring(hit) .. "\n"); return end
      local m = (hit ~= nil)
      if o.v then m = not m end
      if m then
        n = n + 1
        if not o.c then
          out((#srcs > 1 and (s[1] .. ":") or "") .. (o.n and (i .. ":") or "") .. line .. "\n")
        end
      end
    end
    if o.c then out((#srcs > 1 and (s[1] .. ":") or "") .. n .. "\n") end
  end
end, "Uses Lua patterns (not POSIX regex). -F treats the pattern as plain text.\nFlags: -i ignore case, -n line numbers, -v invert, -c count, -F fixed string.")

local function textLines(a)
  local srcs = sources(a)
  if not srcs then return nil end
  local t = {}
  for _, s in ipairs(srcs) do for _, l in ipairs(linesOf(s[2])) do t[#t + 1] = l end end
  return t
end

def("more", "more [file]", "View text page by page", function(raw, a)
  if #a == 0 and not STDIN then out("Usage: more <file>  (or: cmd | more)\n"); return end
  local t = textLines(a)
  if t then pager(t, false) end
end)

def("less", "less [file]", "View text page by page (with backward scroll)", function(raw, a)
  if #a == 0 and not STDIN then out("Usage: less <file>  (or: cmd | less)\n"); return end
  local t = textLines(a)
  if t then pager(t, true) end
end)

do
  local KW = {}
  for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%a+") do
    KW[w] = true
  end
  local C_KW, C_STR, C_CMT, C_NUM = 0xFFFF55, 0x55FF55, 0xA0A0A0, 0xFF88FF

  local function lex(line)
    local t, i, n = {}, 1, #line
    while i <= n do
      local c = line:sub(i, i)
      local s, col
      if line:sub(i, i + 1) == "--" then
        s, col = line:sub(i), C_CMT
      elseif c == '"' or c == "'" then
        local j = i + 1
        while j <= n do
          local d = line:sub(j, j)
          if d == "\\" then j = j + 2
          elseif d == c then break
          else j = j + 1 end
        end
        s, col = line:sub(i, j), C_STR
      elseif c:match("%d") then
        s = line:match("^0[xX]%x+", i) or line:match("^%d+%.?%d*", i)
        col = C_NUM
      elseif c:match("[%a_]") then
        s = line:match("^[%w_]+", i)
        col = KW[s] and C_KW or FG
      else
        s, col = (line:match("^[\194-\244][\128-\191]*", i) or c), FG
      end
      t[#t + 1] = { s, col }
      i = i + #s
    end
    return t
  end

  def("hl", "hl <file>", "View a file with Lua syntax colors", function(raw, a)
    if not needArg(a, "hl <file>") then return end
    local srcs = sources(a)
    for _, s in ipairs(srcs or {}) do
      for _, line in ipairs(linesOf(s[2])) do
        if sink then
          out(line .. "\n")
        else
          for _, tk in ipairs(lex(line)) do color(BG, tk[2]); out(tk[1]) end
          color(BG, FG)
          out("\n")
        end
      end
    end
  end)

  -- Draw one (optionally highlighted) line at row y, horizontally scrolled by `left`.
  local function drawLine(y, ln, left, syn)
    gpu.fill(1, y, W, 1, " ")
    local x = 1 - left
    local segs = syn and lex(ln) or { { ln, FG } }
    for _, sg in ipairs(segs) do
      local s = sg[1]
      local l = unicode.len(s)
      local sa, sb = math.max(1, 2 - x), math.min(l, W - x + 1)
      if sa <= sb then
        gpu.setForeground(sg[2])
        gpu.set(x + sa - 1, y, unicode.sub(s, sa, sb))
      end
      x = x + l
    end
  end

  local function editor(path, syn)
    local ad, p, L = resolve(path)
    if not ad then out(p .. "\n"); return end
    if fsIsDir(ad, p) then out("Cannot edit a directory.\n"); return end
    local lines = { "" }
    if fsExists(ad, p) then
      local data, e = fsRead(ad, p)
      if not data then out("Error: " .. tostring(e) .. "\n"); return end
      if #data > 60000 then out("File too large for the editor (60 KB max).\n"); return end
      data = data:gsub("\r\n?", "\n"):gsub("\t", "  ")
      lines = {}
      for l in (data .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
      if #lines > 1 and lines[#lines] == "" then lines[#lines] = nil end
    end
    local row, col, top, left = 1, 1, 1, 0
    local dirty, msg, armed = false, "", false
    local vh = H - 2

    local function render()
      if row < top then top = row elseif row > top + vh - 1 then top = row - vh + 1 end
      if col - 1 < left then left = col - 1 elseif col - left > W then left = col - W end
      color(GRAY, BLACK)
      gpu.fill(1, 1, W, 1, " ")
      gpu.set(2, 1, unicode.sub((syn and "CEdit  " or "Edit  ") .. dispPath(L, p) .. (dirty and "  [modified]" or ""), 1, W - 2))
      color(BG, FG)
      for r = 0, vh - 1 do
        local ln = lines[top + r]
        if ln then drawLine(2 + r, ln, left, syn) else gpu.fill(1, 2 + r, W, 1, " ") end
        gpu.setForeground(FG)
      end
      color(GRAY, BLACK)
      gpu.fill(1, H, W, 1, " ")
      local st = msg ~= "" and msg or string.format("Ln %d/%d  Col %d    ^S save   ^Q quit   ^K delete line", row, #lines, col)
      gpu.set(2, H, unicode.sub(st, 1, W - 2))
      local under = unicode.sub(lines[row], col, col)
      color(FG, BG)
      gpu.set(col - left, 2 + row - top, under ~= "" and under or " ")
      color(BG, FG)
    end

    local function clampCol()
      local l = unicode.len(lines[row]) + 1
      if col > l then col = l end
    end
    local function ins(s)
      local ln = lines[row]
      lines[row] = unicode.sub(ln, 1, col - 1) .. s .. unicode.sub(ln, col)
      col = col + unicode.len(s)
      dirty = true
    end
    local function newline(indent)
      local ln = lines[row]
      local rest = unicode.sub(ln, col)
      lines[row] = unicode.sub(ln, 1, col - 1)
      table.insert(lines, row + 1, indent .. rest)
      row = row + 1
      col = #indent + 1
      dirty = true
    end

    while true do
      render()
      local e, _, ch, code = pull()
      if e == "key_down" then
        local was = armed
        armed, msg = false, ""
        if ch == 19 then
          local ok, err = fsWrite(ad, p, table.concat(lines, "\n") .. "\n")
          if ok then dirty = false; msg = "Saved (" .. #lines .. " lines)."
          else msg = "SAVE FAILED: " .. tostring(err) end
        elseif ch == 17 or ch == 24 then
          if dirty and not was then
            msg = "Unsaved changes! ^Q again to discard, ^S to save."
            armed = true
          else
            break
          end
        elseif ch == 11 then
          if #lines > 1 then table.remove(lines, row) else lines[1] = "" end
          if row > #lines then row = #lines end
          clampCol()
          dirty = true
        elseif ch == 13 then
          newline(syn and lines[row]:match("^%s*") or "")
        elseif ch == 8 then
          if col > 1 then
            local ln = lines[row]
            lines[row] = unicode.sub(ln, 1, col - 2) .. unicode.sub(ln, col)
            col = col - 1
            dirty = true
          elseif row > 1 then
            local prev = lines[row - 1]
            lines[row - 1] = prev .. lines[row]
            table.remove(lines, row)
            row = row - 1
            col = unicode.len(prev) + 1
            dirty = true
          end
        elseif code == 211 then
          local ln = lines[row]
          if col <= unicode.len(ln) then
            lines[row] = unicode.sub(ln, 1, col - 1) .. unicode.sub(ln, col + 1)
            dirty = true
          elseif row < #lines then
            lines[row] = ln .. lines[row + 1]
            table.remove(lines, row + 1)
            dirty = true
          end
        elseif code == 200 then
          if row > 1 then row = row - 1; clampCol() end
        elseif code == 208 then
          if row < #lines then row = row + 1; clampCol() end
        elseif code == 203 then
          if col > 1 then col = col - 1
          elseif row > 1 then row = row - 1; col = unicode.len(lines[row]) + 1 end
        elseif code == 205 then
          if col <= unicode.len(lines[row]) then col = col + 1
          elseif row < #lines then row = row + 1; col = 1 end
        elseif code == 199 then col = 1
        elseif code == 207 then col = unicode.len(lines[row]) + 1
        elseif code == 201 then row = math.max(1, row - vh); clampCol()
        elseif code == 209 then row = math.min(#lines, row + vh); clampCol()
        elseif ch == 9 then ins("  ")
        elseif ch and ch >= 32 and ch ~= 127 then ins(unicode.char(ch))
        end
      elseif e == "clipboard" and type(ch) == "string" then
        local firstSeg = true
        for seg in ((ch:gsub("\r", "")) .. "\n"):gmatch("(.-)\n") do
          if not firstSeg then newline("") end
          ins((seg:gsub("\t", "  ")))
          firstSeg = false
        end
      end
    end
    cls()
  end

  sharedEditor = editor

  local keys = "Keys: arrows/Home/End/PgUp/PgDn move, Enter, Backspace, Del, Tab (2 spaces),\n^S save, ^Q or ^X quit (asks if unsaved), ^K delete line, middle-click pastes."
  def("edit", "edit <file>", "Open the built-in text editor", function(raw, a)
    if needArg(a, "edit <file>") then editor(table.concat(a, " "), false) end
  end, keys)
  def("cedit", "cedit <file>", "Code editor with Lua highlighting", function(raw, a)
    if needArg(a, "cedit <file>") then editor(table.concat(a, " "), true) end
  end, keys .. "\nAuto-indents new lines and colors Lua keywords, strings, numbers, comments.")
end

------------------------------------------------------------------
-- 9. Commands: system & hardware
------------------------------------------------------------------
def("help", "help [command]", "List commands", function(raw, a)
  if a[1] then cmds.man(raw, a); return end
  local names = {}
  for n in pairs(helpInfo) do names[#names + 1] = n end
  table.sort(names)
  local t = { "Commands (use 'man <command>' for details):", "" }
  for _, n in ipairs(names) do
    local h = helpInfo[n]
    t[#t + 1] = h.usage .. string.rep(" ", math.max(1, 30 - unicode.len(h.usage))) .. h.desc
  end
  t[#t + 1] = ""
  t[#t + 1] = "Shell: cmd1 | cmd2   cmd > file   cmd >> file   %VAR%   wildcards * ?"
  t[#t + 1] = "Drives: type D: to switch drive.  Editing: arrows, Home/End, Del, Up/Down history, Ctrl+C."
  t[#t + 1] = "Programs: put name.lua in the current folder or on PATH and just type: name"
  pager(t, true)
end)

def("man", "man <command>", "Show the manual page for a command", function(raw, a)
  local n = (a[1] or ""):lower()
  n = aliasOf[n] or n
  local h = helpInfo[n]
  if not h then out("No manual entry for '" .. (a[1] or "") .. "'\n"); return end
  local t = { "NAME", "  " .. (h.names:gsub("|", ", ")) .. " - " .. h.desc, "", "USAGE", "  " .. h.usage }
  if h.long then
    t[#t + 1] = ""
    t[#t + 1] = "NOTES"
    for _, l in ipairs(linesOf(h.long)) do t[#t + 1] = "  " .. l end
  end
  pager(t, true)
end)

def("ver", "ver", "Show OS version", function()
  out("\n" .. VERSION .. (HOSTED and "  (hosted in OpenOS)" or "  (bare metal)") .. "\n\n")
end)

def("cls|clear", "cls", "Clear the screen", function() cls() end)

def("echo", "echo <text>", "Print text", function(raw) out(raw .. "\n") end)

def("mem", "mem", "Show memory, energy and uptime", function()
  gc()
  local free, total = computer.freeMemory(), computer.totalMemory()
  out(string.format("\nMemory : %d KiB free / %d KiB total\n", math.floor(free / 1024), math.floor(total / 1024)))
  out(string.format("Energy : %d / %d\n", math.floor(computer.energy()), math.floor(computer.maxEnergy())))
  out(string.format("Uptime : %d s\n\n", math.floor(computer.uptime())))
end)

def("comp", "comp", "List attached components", function()
  local names = {}
  for addr, t in component.list() do names[#names + 1] = pad(t, 18) .. addr:sub(1, 8) .. "..." end
  table.sort(names)
  out("\n" .. table.concat(names, "\n") .. "\n\n")
end)

def("reboot", "reboot", "Restart the computer", function() computer.shutdown(true) end)
def("shutdown", "shutdown", "Power off the computer", function() computer.shutdown() end)
def("exit", "exit", "Reboot the computer", function() computer.shutdown(true) end)

if HOSTED then
  def("quit", "quit", "Return to OpenOS", function() quitShell = true end)
end

def("openos", "openos", "Boot the backed-up OpenOS (this session only)", function()
  if HOSTED then out("You are already running inside OpenOS.\n"); return end
  if not (drives.C and fsExists(drives.C, BACKUP)) then
    out("No OpenOS backup found (C:" .. BACKUP .. "). Nothing to boot.\n")
    return
  end
  wantOS, quitShell = true, true
end, "ReactOS stays installed as /init.lua; the next reboot starts ReactOS again.\nUse 'uninstall' to restore OpenOS permanently.")

def("dmesg", "dmesg", "View the kernel/hardware event log", function()
  pager(klogT, true)
end)

def("uptime", "uptime", "Show how long the computer has been on", function()
  local s = math.floor(computer.uptime())
  out(string.format("up %dh %02dm %02ds\n", math.floor(s / 3600), math.floor(s / 60) % 60, s % 60))
end)

def("date", "date", "Show the in-game date and time", function()
  out(os.date("%Y-%m-%d %H:%M:%S") .. "\n")
end)

def("resolution", "resolution [w h|max]", "Show or set the screen resolution", function(raw, a)
  local mw, mh = gpu.maxResolution()
  if not a[1] then out(string.format("Current: %dx%d   Maximum: %dx%d\n", W, H, mw, mh)); return end
  local w, h
  if a[1] == "max" then w, h = mw, mh else w, h = tonumber(a[1]), tonumber(a[2]) end
  if not w or not h or w < 20 or h < 8 or w > mw or h > mh then
    out(string.format("Usage: resolution <w> <h>  (min 20x8, max %dx%d)\n", mw, mh))
    return
  end
  gpu.setResolution(math.floor(w), math.floor(h))
  W, H = gpu.getResolution()
  cls()
  out(string.format("Resolution set to %dx%d.\n", W, H))
end)

def("lua", "lua [file] [args]", "Lua interpreter / run a Lua file", function(raw, a)
  local env = progEnv()
  if a[1] then
    local ad, p = resolve(a[1])
    if not ad then out(p .. "\n"); return end
    local src, e = fsRead(ad, p)
    if not src then out("Error: " .. tostring(e) .. "\n"); return end
    local args = {}
    for i = 2, #a do args[#args + 1] = a[i] end
    runLua(src, a[1], args)
    return
  end
  out("Lua REPL (" .. tostring(_VERSION) .. "). Type 'exit' to leave.\n")
  while true do
    out("lua> ")
    local line = readline()
    if line == "exit" or line == "quit" then break end
    if line ~= "" then
      local f, e = load("return " .. line, "=stdin", "t", env)
      if not f then f, e = load(line, "=stdin", "t", env) end
      if not f then
        report(e)
      else
        local r = table.pack(pcall(f))
        if not r[1] then
          report(r[2])
        else
          for i = 2, r.n do out(ser(r[i]) .. (i < r.n and "\t" or "\n")) end
        end
      end
    end
  end
end)

def("which", "which <name>", "Show what a command name will run", function(raw, a)
  if not needArg(a, "which <name>") then return end
  local n = a[1]:lower()
  if ALIAS[n] then out(n .. ": alias for '" .. ALIAS[n] .. "'\n"); return end
  if cmds[n] then out(n .. ": built-in command\n"); return end
  local ad, p, L = findProgram(a[1])
  if ad then
    local d = fsRead(ad, p)
    out(a[1] .. ": " .. dispPath(L, p) .. "  (" .. (d and #d or "?") .. " bytes)\n")
  else
    out(a[1] .. ": not found. Searched the current folder (" .. dispPath(curDrive, cwds[curDrive] or "/")
        .. ") and PATH=" .. tostring(ENV.PATH) .. "\n")
  end
end)

def("bootinfo", "bootinfo", "Show what the computer will boot next", function()
  local ba = computer.getBootAddress()
  out("\nBoot address  : " .. tostring(ba) .. "\n")
  out("Boot drive    : " .. (ba and (letterOf(ba) .. ":") or "?") .. "\n")
  local T = ba or drives.C
  local cur = T and fsRead(T, "/init.lua")
  if not cur or cur == "" then
    out("/init.lua     : MISSING - this drive cannot boot!\n")
  elseif cur:find("ReactOS-OC", 1, true) then
    out("/init.lua     : ReactOS-OC (" .. #cur .. " bytes) -> the next boot starts ReactOS\n")
  else
    out("/init.lua     : another program (" .. #cur .. " bytes) -> the next boot starts THAT, not ReactOS\n"
      .. "                 Run 'install' to fix this.\n")
  end
  out("OpenOS backup : " .. ((T and fsExists(T, BACKUP)) and "present" or "none") .. " (" .. BACKUP .. ")\n")
  local n = 0
  for _ in component.list("filesystem") do n = n + 1 end
  out("Filesystems   : " .. n .. " (with several, the BIOS boots the one saved in the EEPROM)\n\n")
end)

def("flash", "flash [-r|-c] [-y] [file] [label]", "Write, read or verify the EEPROM", function(raw, a)
  local o, r = parseFlags(a)
  local ea = first("eeprom")
  if not ea then out("No EEPROM found.\n"); return end
  local ee = component.proxy(ea)
  local file = r[1]
  if not file then
    local code = ee.get() or ""
    out(string.format("EEPROM label   : %s\ncode size      : %d / %d bytes\ndata size      : %d bytes\nchecksum       : %s\n",
        tostring(ee.getLabel()), #code, ee.getSize(), ee.getDataSize(), tostring(ee.getChecksum())))
    return
  end
  local ad, p = resolve(file)
  if not ad then out(p .. "\n"); return end
  if o.r then
    local ok, e = fsWrite(ad, p, ee.get() or "")
    out(ok and ("EEPROM saved to " .. file .. "\n") or ("Error: " .. tostring(e) .. "\n"))
    return
  end
  local data = fsRead(ad, p)
  if not data then out("Error: cannot read " .. file .. "\n"); return end
  if o.c then
    out((ee.get() or "") == data and "EEPROM matches the file.\n" or "EEPROM DIFFERS from the file.\n")
    return
  end
  if #data > ee.getSize() then out("File too big for this EEPROM (" .. #data .. " > " .. ee.getSize() .. ").\n"); return end
  if not o.y and not confirm("Flash " .. #data .. " bytes to the EEPROM? A bad BIOS can stop the computer booting.") then return end
  ee.set(data)
  if r[2] then ee.setLabel(r[2]) end
  out("EEPROM flashed. Checksum: " .. tostring(ee.getChecksum()) .. "\n")
end, "flash                 show EEPROM info\nflash -r <file>       save the current EEPROM to a file (do this first!)\nflash -c <file>       compare the EEPROM with a file\nflash [-y] <file> [label]  write a file to the EEPROM (asks first)")

------------------------------------------------------------------
-- 10. Commands: administration
------------------------------------------------------------------
def("install", "install [drive|address] [file]", "Install ReactOS-OC as the boot OS", function(raw, a)
  local o, r = parseFlags(a)
  if not o.y then
    out("This makes ReactOS-OC the boot program (/init.lua) on the target drive.\n"
      .. "The current /init.lua is kept as " .. BACKUP .. ".\n")
    if not confirm("Continue?") then return end
  end
  local ok, err = doInstall(function(m) out(m .. "\n") end, r[1], r[2])
  if not ok then color(BG, RED); out("Install failed: " .. tostring(err) .. "\n"); color(BG, FG) end
end, "install [-y] [drive|address] [source-file]\n\nFrom OpenOS you can also run:  <this-file-name> install   (for example: init install)\nDefault target is the drive you booted from (C:). Give a drive letter (D:) or an\naddress prefix to install onto another drive. The source is this running script;\npass a file name if it cannot be detected.\n\nIt writes /init.lua safely (temp file, verify, swap) and also creates /System32,\n/ProgramFiles and /Users. Any standard EEPROM BIOS will then boot ReactOS.\nUse 'bootinfo' afterwards to confirm.")

def("uninstall", "uninstall [drive|address]", "Restore the original /init.lua (OpenOS)", function(raw, a)
  local o, r = parseFlags(a)
  if not o.y and not confirm("Restore the original boot program?") then return end
  local ok, err = doUninstall(function(m) out(m .. "\n") end, r[1])
  if not ok then color(BG, RED); out("Uninstall failed: " .. tostring(err) .. "\n"); color(BG, FG) end
end)

def("hostname", "hostname [name]", "View or change the computer's hostname", function(raw, a)
  if a[1] then
    cfg.hostname = a[1]:gsub("[^%w_%-%.]", "")
    ENV.HOSTNAME = cfg.hostname
    local ok, e = cfgSave()
    if not ok then out("Warning: could not save (" .. tostring(e) .. ")\n") end
  end
  out((cfg.hostname or "reactos") .. "\n")
end)

def("useradd", "useradd [name]", "Add a player to the computer's access list", function(raw, a)
  if not a[1] then
    local u = { computer.users() }
    out(#u == 0 and "No users registered (anyone may use this computer).\n" or ("Users: " .. table.concat(u, ", ") .. "\n"))
    return
  end
  local ok, e = computer.addUser(a[1])
  out(ok and ("Added " .. a[1] .. ".\n") or ("Error: " .. tostring(e) .. "\n"))
end)

def("userdel", "userdel <name>", "Remove a player from the access list", function(raw, a)
  if not needArg(a, "userdel <name>") then return end
  local ok, e = computer.removeUser(a[1])
  out(ok and ("Removed " .. a[1] .. ".\n") or ("Error: " .. tostring(e or "no such user") .. "\n"))
end)

local svcStart
do
  local running = {}
  local function spath(n) return CFGDIR .. "/rc.d/" .. n .. ".lua" end
  local function names()
    local t = {}
    for _, e in ipairs(drives.C and fsList(drives.C, CFGDIR .. "/rc.d") or {}) do
      local n = e[1]:match("^(.+)%.lua$")
      if n and not e[2] then t[#t + 1] = n end
    end
    return t
  end
  local function enabledSet()
    local s = {}
    for n in (cfg.services or ""):gmatch("[^,]+") do s[n] = true end
    return s
  end
  local function saveEnabled(s)
    local t = {}
    for n in pairs(s) do t[#t + 1] = n end
    table.sort(t)
    cfg.services = table.concat(t, ",")
    return cfgSave()
  end

  svcStart = function(n)
    if running[n] then return nil, "already running" end
    local src = drives.C and fsRead(drives.C, spath(n))
    if not src then return nil, "no such service" end
    local env = progEnv()
    local mine = {}
    env.hook = function(fn) hooks[#hooks + 1] = fn; mine[#mine + 1] = fn end
    local f, e = load(src, "=" .. n, "t", env)
    if not f then return nil, e end
    local ok, r = pcall(f)
    if not ok then return nil, r end
    running[n] = { stop = (type(r) == "table" and type(r.stop) == "function") and r.stop or nil, mine = mine }
    klog("service started: " .. n)
    return true
  end

  local function svcStop(n)
    local s = running[n]
    if not s then return nil, "not running" end
    if s.stop then pcall(s.stop) end
    for _, fn in ipairs(s.mine) do
      for i = #hooks, 1, -1 do if hooks[i] == fn then table.remove(hooks, i) end end
    end
    running[n] = nil
    klog("service stopped: " .. n)
    return true
  end

  def("rc", "rc [list|start|stop|restart|enable|disable] [name]", "Manage boot services", function(raw, a)
    local sub, n = (a[1] or "list"):lower(), a[2]
    if sub == "list" or sub == "status" then
      local en, all = enabledSet(), names()
      if #all == 0 then out("No services. Put Lua scripts in C:" .. CFGDIR:gsub("/", "\\") .. "\\rc.d\\ (see 'man rc').\n"); return end
      for _, s in ipairs(all) do
        out(pad(s, 20) .. pad(running[s] and "running" or "stopped", 10) .. (en[s] and "enabled" or "disabled") .. "\n")
      end
      return
    end
    if not n then out("Usage: rc " .. sub .. " <service>\n"); return end
    local ok, e
    if sub == "start" then ok, e = svcStart(n)
    elseif sub == "stop" then ok, e = svcStop(n)
    elseif sub == "restart" then svcStop(n); ok, e = svcStart(n)
    elseif sub == "enable" or sub == "disable" then
      if sub == "enable" and not (drives.C and fsExists(drives.C, spath(n))) then
        ok, e = nil, "no such service"
      else
        local s = enabledSet()
        s[n] = (sub == "enable") or nil
        ok, e = saveEnabled(s)
      end
    else
      out("Usage: rc [list|start|stop|restart|enable|disable] [name]\n")
      return
    end
    out(ok and "OK\n" or ("rc: " .. tostring(e) .. "\n"))
  end, "A service is a Lua script in C:\\System32\\rc.d\\<name>.lua. 'start' runs it.\nIt may return { stop = function() ... end } to clean up on 'stop'.\nInside a service, hook(function(event, ...) ... end) receives every system\nevent (modem_message, redstone_changed, ...) while ReactOS waits for input.\n'enable' makes it start automatically at boot.")
end

------------------------------------------------------------------
-- 11. Commands: environment, aliases, scripts
------------------------------------------------------------------
local function setVar(raw, needAssign)
  local k, v = raw:match("^([%w_]+)%s*=%s*(.*)$")
  if not k then k, v = raw:match("^([%w_]+)%s+(.+)$") end
  if not k then return false end
  ENV[k] = v:match('^"(.*)"$') or v
  return true
end

def("env|set", "env | set NAME=VALUE", "Show or set environment variables", function(raw)
  if raw ~= "" then
    if not setVar(raw) then out("Usage: set NAME=VALUE\n") end
    return
  end
  local t = {}
  for k, v in pairs(ENV) do t[#t + 1] = k .. "=" .. v end
  table.sort(t)
  out(table.concat(t, "\n") .. "\n")
end)

def("export", "export NAME=VALUE", "Set a shell environment variable", function(raw)
  if not setVar(raw) then out("Usage: export NAME=VALUE\n") end
end, "Variables are expanded as %NAME% anywhere in a command line.\nPut export/alias lines in C:\\System32\\startup.cmd to keep them across reboots.")

def("unset", "unset NAME", "Delete an environment variable", function(raw, a)
  if needArg(a, "unset NAME") then ENV[a[1]] = nil end
end)

def("alias", "alias [name=command]", "Map a shortcut to a command", function(raw, a)
  if raw == "" then
    local t = {}
    for k, v in pairs(ALIAS) do t[#t + 1] = k .. "=" .. v end
    table.sort(t)
    out(#t == 0 and "No aliases.\n" or (table.concat(t, "\n") .. "\n"))
    return
  end
  local k, v = raw:match("^([%w_%-%.]+)%s*=%s*(.+)$")
  if not k then k, v = raw:match("^([%w_%-%.]+)%s+(.+)$") end
  if not k then out("Usage: alias name=command\n"); return end
  ALIAS[k:lower()] = v:match('^"(.*)"$') or v
end)

def("unalias", "unalias name", "Remove an alias", function(raw, a)
  if needArg(a, "unalias name") then ALIAS[a[1]:lower()] = nil end
end)

def("exec", "exec <script.cmd>", "Run a batch file of commands", function(raw, a)
  if not needArg(a, "exec <script.cmd>") then return end
  local ad, p = resolve(table.concat(a, " "))
  if not ad then out(p .. "\n"); return end
  if not fsExists(ad, p) then out("Script not found.\n"); return end
  execScript(ad, p)
end, "One command per line. Lines starting with #, :: or REM are comments.\nProgram names ending in .lua or .cmd on the PATH run without 'lua' or 'exec'.")

------------------------------------------------------------------
-- 12. Commands: internet
------------------------------------------------------------------
local function httpGet(url, post, headers)
  local ia = first("internet")
  if not ia then return nil, "no Internet Card installed" end
  local inet = component.proxy(ia)
  local ok, req, why = pcall(inet.request, url, post, headers)
  if not ok or not req then return nil, tostring(ok and why or req) end
  local t, got, t0 = {}, 0, computer.uptime()
  local function fail(m) pcall(req.close); return nil, m end
  while true do
    local okr, d, why2 = pcall(req.read, BIG)
    if not okr then return fail(tostring(d)) end
    if d == nil then
      if why2 then return fail(tostring(why2)) end
      break
    end
    if #d > 0 then
      t[#t + 1] = d
      got = got + #d
      t0 = computer.uptime()
      if got > 400 * 1024 then return fail("response too large") end
    else
      if computer.uptime() - t0 > 30 then return fail("timed out") end
      local e, _, ch = pull(0.05)
      if e == "key_down" and ch == 3 then return fail("aborted") end
    end
  end
  pcall(req.close)
  return table.concat(t)
end

def("wget", "wget [-f] <url> [file]", "Download a file over HTTP/HTTPS", function(raw, a)
  local o, r = parseFlags(a)
  local url = r[1]
  if not url then out("Usage: wget [-f] <url> [file]\n"); return end
  local name = r[2] or (url:gsub("[?#].*$", ""):match("([^/]+)$")) or "index.html"
  local ad, p = resolve(name)
  if not ad then out(p .. "\n"); return end
  if fsExists(ad, p) and not o.f then out("wget: " .. name .. " exists (use -f to overwrite)\n"); return end
  out("Downloading " .. url .. " ...\n")
  local data, err = httpGet(url)
  if not data then out("wget: " .. tostring(err) .. "\n"); return end
  local ok, e = fsWrite(ad, p, data)
  out(ok and (#data .. " bytes saved to " .. name .. "\n") or ("wget: " .. tostring(e) .. "\n"))
end, "Needs an Internet Card and HTTP enabled in the OpenComputers config.\nCtrl+C aborts a slow download.")

def("pastebin", "pastebin get|put|run ...", "Download, upload or run Pastebin code", function(raw, a)
  local sub = (a[1] or ""):lower()
  if sub == "get" and a[2] and a[3] then
    local ad, p = resolve(a[3])
    if not ad then out(p .. "\n"); return end
    local data, err = httpGet("https://pastebin.com/raw/" .. a[2])
    if not data then out("pastebin: " .. tostring(err) .. "\n"); return end
    local ok, e = fsWrite(ad, p, data)
    out(ok and (#data .. " bytes saved to " .. a[3] .. "\n") or ("pastebin: " .. tostring(e) .. "\n"))
  elseif sub == "run" and a[2] then
    local data, err = httpGet("https://pastebin.com/raw/" .. a[2])
    if not data then out("pastebin: " .. tostring(err) .. "\n"); return end
    local args = {}
    for i = 3, #a do args[#args + 1] = a[i] end
    runLua(data, "pastebin:" .. a[2], args)
  elseif sub == "put" and a[2] then
    local key = ENV.PASTEBIN_KEY
    if not key then out("Set your developer key first:  export PASTEBIN_KEY=<key>\n(from pastebin.com/doc_api)\n"); return end
    local ad, p = resolve(a[2])
    local src = ad and fsRead(ad, p)
    if not src then out("pastebin: cannot read " .. a[2] .. "\n"); return end
    local function enc(s) return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end)) end
    local body = "api_option=paste&api_dev_key=" .. enc(key) .. "&api_paste_format=lua&api_paste_name="
        .. enc(base(p)) .. "&api_paste_code=" .. enc(src)
    local resp, err = httpGet("https://pastebin.com/api/api_post.php", body,
        { ["Content-Type"] = "application/x-www-form-urlencoded" })
    out(resp and (resp .. "\n") or ("pastebin: " .. tostring(err) .. "\n"))
  else
    out("Usage:\n  pastebin get <code> <file>\n  pastebin run <code> [args]\n  pastebin put <file>   (needs PASTEBIN_KEY)\n")
  end
end)

def("irc", "irc <host[:port]> [nick]", "Simple IRC client", function(raw, a)
  if not a[1] then out("Usage: irc <host[:port]> [nick]\n"); return end
  local ia = first("internet")
  if not ia then out("No Internet Card installed.\n"); return end
  local inet = component.proxy(ia)
  local host, port = a[1]:match("^([^:]+):?(%d*)$")
  port = tonumber(port) or 6667
  local nick = (a[2] or cfg.hostname or "reactos"):gsub("[^%w_%-]", "")
  local sock, e = inet.connect(host, port)
  if not sock then out("irc: " .. tostring(e) .. "\n"); return end
  local t0 = computer.uptime()
  while true do
    local ok, done = pcall(sock.finishConnect)
    if not ok then out("irc: " .. tostring(done) .. "\n"); return end
    if done then break end
    if computer.uptime() - t0 > 20 then out("irc: connection timed out\n"); pcall(sock.close); return end
    pull(0.05)
  end
  local log, input, chan, dirty = {}, "", nil, true
  local function add(s)
    s = s:gsub("[%c]", " ")
    repeat
      log[#log + 1] = unicode.sub(s, 1, W)
      s = unicode.sub(s, W + 1)
    until s == ""
    while #log > 200 do table.remove(log, 1) end
    dirty = true
  end
  local function send(s) pcall(sock.write, s .. "\r\n") end
  send("NICK " .. nick)
  send("USER " .. nick .. " 0 * :" .. nick)
  add("* connecting to " .. host .. ":" .. port .. " as " .. nick .. "  (/join #chan, /msg n t, /me t, /nick n, /quit)")
  local buf = ""
  local function handle(l)
    if l:sub(1, 4) == "PING" then send("PONG" .. l:sub(5)); return end
    local who, cmd, rest = l:match("^:(%S+) (%S+) ?(.*)$")
    if not cmd then add(l); return end
    local from = who:match("^([^!]+)") or who
    if cmd == "PRIVMSG" then
      local tgt, msg = rest:match("^(%S+) :(.*)$")
      local act = msg and msg:match("^\1ACTION (.-)\1?$")
      if act then add("* " .. from .. " " .. act)
      else add((tgt ~= chan and tgt:sub(1, 1) == "#" and (tgt .. " ") or "") .. "<" .. from .. "> " .. tostring(msg)) end
    elseif cmd == "JOIN" then add("* " .. from .. " joined " .. rest:gsub("^:", ""))
    elseif cmd == "PART" or cmd == "QUIT" then add("* " .. from .. " left")
    elseif cmd == "NOTICE" then add("-" .. from .. "- " .. (rest:match(":(.*)$") or rest))
    else add((rest:match(":(.*)$")) or (cmd .. " " .. rest)) end
  end
  local function command(line)
    if line:sub(1, 1) ~= "/" then
      if chan then send("PRIVMSG " .. chan .. " :" .. line); add("<" .. nick .. "> " .. line)
      else add("* not in a channel; use /join #channel") end
      return true
    end
    local c, arg = line:match("^/(%S+)%s*(.*)$")
    c = (c or ""):lower()
    if c == "join" then send("JOIN " .. arg); chan = arg:match("^(%S+)")
    elseif c == "part" then send("PART " .. (chan or "")); chan = nil
    elseif c == "msg" then
      local n2, t2 = arg:match("^(%S+)%s+(.*)$")
      if n2 then send("PRIVMSG " .. n2 .. " :" .. t2); add("-> " .. n2 .. ": " .. t2) end
    elseif c == "me" and chan then send("PRIVMSG " .. chan .. " :\1ACTION " .. arg .. "\1"); add("* " .. nick .. " " .. arg)
    elseif c == "nick" and arg ~= "" then send("NICK " .. arg); nick = arg
    elseif c == "quit" then send("QUIT :" .. (arg ~= "" and arg or "bye")); return false
    else add("* unknown command") end
    return true
  end
  local running = true
  while running do
    local okr, d = pcall(sock.read, BIG)
    if not okr or d == nil then add("* connection closed"); dirty = true; running = false end
    if okr and d and #d > 0 then
      buf = buf .. d
      while true do
        local l, restb = buf:match("^(.-)\r?\n(.*)$")
        if not l then break end
        buf = restb
        handle(l)
      end
    end
    if dirty or running then
      if dirty then
        color(BG, FG)
        gpu.fill(1, 1, W, H, " ")
        local vis = H - 2
        for r = 1, vis do
          local l = log[#log - vis + r]
          if l then gpu.set(1, r, l) end
        end
        bar(H - 1, (chan or "(no channel)") .. "  -  " .. nick .. "@" .. host, GRAY, BLACK)
        dirty = false
      end
      color(BG, FG)
      gpu.fill(1, H, W, 1, " ")
      gpu.set(1, H, unicode.sub("> " .. input, -(W - 1)))
    end
    if not running then break end
    local ev, _, ch, code = pull(0.1)
    if ev == "key_down" then
      if ch == 3 then send("QUIT :bye"); running = false
      elseif ch == 13 then
        local line = input
        input = ""
        if line ~= "" and not command(line) then running = false end
      elseif ch == 8 then input = unicode.sub(input, 1, -2)
      elseif ch and ch >= 32 and unicode.len(input) < 400 then input = input .. unicode.char(ch) end
      dirty = true
    elseif ev == "clipboard" and type(ch) == "string" then
      input = input .. (ch:match("^[^\r\n]*"))
    end
  end
  pcall(sock.close)
  cls()
end, "Commands: /join #chan  /part  /msg nick text  /me text  /nick new  /quit [reason]\nAnything else is sent to the current channel. Ctrl+C quits.")

------------------------------------------------------------------
-- 13. ME Storage Viewer
------------------------------------------------------------------
local sharedMeApp   -- filled in below; lets the desktop's ME icon reuse this
do
  local function meFetch(me, filter)
    local ok, res = pcall(me.getItemsInNetwork)
    if not ok then return nil, tostring(res) end
    if type(res) ~= "table" then return nil, "unexpected reply from adapter" end
    local list, n, sum = {}, 0, 0
    for _, it in pairs(res) do
      if type(it) == "table" then
        local label = tostring(it.label or it.name or "?")
        if filter == "" or label:lower():find(filter, 1, true) then
          local size = tonumber(it.size) or 0
          n = n + 1
          list[n] = { label, size }
          sum = sum + size
        end
      end
    end
    res = nil
    table.sort(list, function(x, y)
      if x[2] ~= y[2] then return x[2] > y[2] end
      return x[1] < y[1]
    end)
    return list, sum
  end

  local function meApp(filter)
    filter = (filter or ""):lower()
    local addr = first("me_controller") or first("me_interface")
    if not addr then
      out("Error: No ME Controller or Interface detected via Adapter.\n")
      return
    end
    local ctype = component.type(addr)
    local me = component.proxy(addr)
    out("Reading ME network...\n")
    local list, sum = meFetch(me, filter)
    if not list then
      out("Error: could not read the ME network (" .. tostring(sum) .. ")\n")
      return
    end
    local per   = math.max(1, H - 4)
    local nameW = math.max(8, W - 19)
    local p = 1
    while true do
      local total = #list
      local pages = math.max(1, math.ceil(total / per))
      if p > pages then p = pages end
      if p < 1 then p = 1 end
      cls()
      bar(1, "ME Storage Viewer - " .. ctype .. " - " .. commas(total) .. " types, " .. commas(sum) .. " items"
          .. (filter ~= "" and (" [filter: " .. filter .. "]") or ""), GRAY, BLACK)
      color(BG, CYAN)
      gpu.set(1, 2, pad("#", 4, true) .. " " .. pad("Item", nameW) .. " " .. pad("Count", 13, true))
      color(BG, FG)
      gpu.set(1, 3, string.rep("-", W))
      if total == 0 then
        gpu.set(2, 4, "No items to show.")
      else
        local b = (p - 1) * per
        for r = 1, per do
          local e = list[b + r]
          if not e then break end
          gpu.set(1, 3 + r, pad(b + r, 4, true) .. " " .. pad(e[1], nameW) .. " " .. pad(commas(e[2]), 13, true))
        end
      end
      local foot
      if p < pages then
        foot = "Page " .. p .. "/" .. pages .. " - Press any key for next page, or 'q' to quit (b=back, r=refresh)"
      else
        foot = "Page " .. p .. "/" .. pages .. " - End. Any key returns, 'q' quits (b=back, r=refresh)"
      end
      bar(H, foot, GRAY, BLACK)
      local ch, code = waitKey()
      if ch == 113 or ch == 81 then
        break
      elseif ch == 98 or ch == 66 or code == 200 or code == 203 then
        p = p - 1
      elseif ch == 114 or ch == 82 then
        local nl2, s2 = meFetch(me, filter)
        if nl2 then list, sum = nl2, s2 end
      else
        if p >= pages then break end
        p = p + 1
      end
    end
    list = nil
    gc()
    cls()
  end

  sharedMeApp = meApp

  def("me", "me [filter]", "AE2 ME Storage Viewer (optional name filter)", function(raw) meApp(raw) end)
end

------------------------------------------------------------------
-- 14. BMP viewer (1/4/8/24/32-bit, uncompressed) + test pattern
------------------------------------------------------------------
do
  local HALF = "\226\150\128"

  local function u16(s, i) local a, b = s:byte(i, i + 1); return a + b * 256 end
  local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
  end
  local function s32(s, i)
    local v = u32(s, i)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
  end

  local function readN(rd, n)
    local t, got = {}, 0
    while got < n do
      local c = rd.read(n - got)
      if not c or c == "" then break end
      t[#t + 1] = c
      got = got + #c
    end
    return table.concat(t)
  end

  local function stringReader(str)
    local p = 0
    return {
      seek  = function(pos) p = pos end,
      read  = function(n) local r = str:sub(p + 1, p + n); p = p + #r; return r end,
      close = function() end,
    }
  end

  local function fileReader(path)
    local a, p = resolve(path)
    if not a then return nil, p end
    local ok, h, e = inv(a, "open", p, "r")
    if not ok or not h then return nil, tostring(ok and e or h or "cannot open file") end
    return {
      seek  = function(pos) component.invoke(a, "seek", h, "set", pos) end,
      read  = function(n) return component.invoke(a, "read", h, n) or "" end,
      close = function() component.invoke(a, "close", h) end,
    }
  end

  local function bmpOpen(rd)
    local h = readN(rd, 54)
    if #h < 54 or h:sub(1, 2) ~= "BM" then return nil, "not a BMP file" end
    local img = {
      off = u32(h, 11), hsz = u32(h, 15), w = s32(h, 19), h = s32(h, 23),
      bpp = u16(h, 29), comp = u32(h, 31), ncol = u32(h, 47),
    }
    if img.hsz < 40 then return nil, "unsupported BMP header (OS/2 style)" end
    img.top = img.h < 0
    if img.top then img.h = -img.h end
    local b = img.bpp
    if not (b == 1 or b == 4 or b == 8 or b == 24 or b == 32) then return nil, "unsupported bit depth: " .. b end
    if not (img.comp == 0 or (img.comp == 3 and b == 32)) then return nil, "compressed BMP not supported" end
    if img.w < 1 or img.h < 1 or img.w > 4096 or img.h > 4096 then return nil, "bad image size" end
    img.row = math.floor((img.w * b + 31) / 32) * 4
    if b <= 8 then
      local maxc = math.floor(2 ^ b)
      local n = (img.ncol > 0 and img.ncol < maxc) and img.ncol or maxc
      rd.seek(14 + img.hsz)
      local data = readN(rd, n * 4)
      local pal = {}
      for i = 0, n - 1 do
        local bl, g, r = data:byte(i * 4 + 1, i * 4 + 3)
        pal[i] = (r or 0) * 65536 + (g or 0) * 256 + (bl or 0)
      end
      img.pal = pal
    end
    return img
  end

  local function bmpRow(rd, img, y)
    local fr = img.top and y or (img.h - 1 - y)
    rd.seek(img.off + fr * img.row)
    return readN(rd, img.row)
  end

  local function bmpPixel(row, x, img)
    local b = img.bpp
    if b == 24 or b == 32 then
      local i = x * math.floor(b / 8) + 1
      local bl, g, r = row:byte(i, i + 2)
      return (r or 0) * 65536 + (g or 0) * 256 + (bl or 0)
    elseif b == 8 then
      return img.pal[row:byte(x + 1) or 0] or 0
    elseif b == 4 then
      local v = row:byte(math.floor(x / 2) + 1) or 0
      if x % 2 == 0 then v = math.floor(v / 16) else v = v % 16 end
      return img.pal[v] or 0
    end
    local v = row:byte(math.floor(x / 8) + 1) or 0
    return img.pal[math.floor(v / 2 ^ (7 - x % 8)) % 2] or 0
  end

  local function bmpFlush(ox, oy, r, start, fg, bg, n)
    if n > 0 then
      gpu.setForeground(fg)
      gpu.setBackground(bg)
      gpu.set(ox + start, oy + r, string.rep(HALF, n))
    end
  end

  local function bmpShow(rd, label)
    local img, err = bmpOpen(rd)
    if not img then rd.close(); return nil, err end
    local scale = math.min(W / img.w, ((H - 1) * 2) / img.h)
    local dw   = math.max(1, math.min(W, math.floor(img.w * scale)))
    local rows = math.max(1, math.min(H - 1, math.ceil(img.h * scale / 2)))
    local dh   = rows * 2
    local ox   = math.floor((W - dw) / 2) + 1
    local oy   = math.floor((H - 1 - rows) / 2) + 1
    color(BLACK, BLACK)
    gpu.fill(1, 1, W, H, " ")
    local xmap = {}
    for x = 0, dw - 1 do xmap[x] = math.min(img.w - 1, math.floor(x * img.w / dw)) end
    local lastY, lastRow
    local function getRow(sy)
      if sy ~= lastY then lastRow = bmpRow(rd, img, sy); lastY = sy end
      return lastRow
    end
    for r = 0, rows - 1 do
      local top = getRow(math.min(img.h - 1, math.floor((r * 2) * img.h / dh)))
      local bot = getRow(math.min(img.h - 1, math.floor((r * 2 + 1) * img.h / dh)))
      local start, rfg, rbg, rn = 0, 0, 0, 0
      for x = 0, dw - 1 do
        local sx = xmap[x]
        local fg, bg = bmpPixel(top, sx, img), bmpPixel(bot, sx, img)
        if rn > 0 and fg == rfg and bg == rbg then
          rn = rn + 1
        else
          bmpFlush(ox, oy, r, start, rfg, rbg, rn)
          start, rfg, rbg, rn = x, fg, bg, 1
        end
      end
      bmpFlush(ox, oy, r, start, rfg, rbg, rn)
    end
    rd.close()
    bar(H, (label or "image") .. "  " .. img.w .. "x" .. img.h .. "  " .. img.bpp .. "-bit  -  press any key to return", GRAY, BLACK)
    waitKey()
    cls()
    return true
  end

  local BARS = { 0xFFFFFF, 0xFFFF00, 0x00FFFF, 0x00FF00, 0xFF00FF, 0xFF0000, 0x0000FF, 0x000000 }
  local function bmpPat(x, y, w, h)
    if x == 0 and y == 0 then return 0xFF0000 end
    if x == w - 1 and y == 0 then return 0x00FF00 end
    if x == 0 and y == h - 1 then return 0x0000FF end
    if x == w - 1 and y == h - 1 then return 0xFFFFFF end
    if x == 0 or y == 0 or x == w - 1 or y == h - 1 then return 0xC0C0C0 end
    if y <= 20 then
      return BARS[math.floor((x - 1) * 8 / (w - 2)) + 1]
    elseif y <= 28 then
      local v = math.floor(x * 255 / (w - 1))
      return v * 65536 + v * 256 + v
    elseif y <= 36 then
      local v = math.floor(x * 255 / (w - 1))
      return v * 65536 + (255 - v) * 256 + 128
    end
    return ((math.floor(x / 4) + math.floor(y / 4)) % 2 == 0) and 0xFFFFFF or 0x000000
  end

  local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
  end
  local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end

  local function bmpBuild()
    local w, h = 64, 48
    local rowSize = w * 3
    local parts = {
      "BM", le32(54 + rowSize * h), le32(0), le32(54),
      le32(40), le32(w), le32(h), le16(1), le16(24), le32(0),
      le32(rowSize * h), le32(2835), le32(2835), le32(0), le32(0),
    }
    for y = h - 1, 0, -1 do
      local row = {}
      for x = 0, w - 1 do
        local c = bmpPat(x, y, w, h)
        row[#row + 1] = string.char(c % 256, math.floor(c / 256) % 256, math.floor(c / 65536) % 256)
      end
      parts[#parts + 1] = table.concat(row)
    end
    return table.concat(parts)
  end

  def("bmp", "bmp <file>|debug|make [f]", "Show a BMP image or the test pattern", function(raw)
    local sub, rest = raw:match("^(%S*)%s*(.-)$")
    local lsub = sub:lower()
    if sub == "" then
      out("Usage:\n  bmp <file>     show a BMP image\n  bmp debug      show the built-in test pattern\n"
        .. "  bmp make [f]   write the test pattern to a file (default debug.bmp)\n")
      return
    end
    if lsub == "make" then
      local path = (rest ~= "") and rest or "debug.bmp"
      local a, p = resolve(path)
      if not a then out(p .. "\n"); return end
      local ok, err = fsWrite(a, p, bmpBuild())
      if ok then out("Wrote " .. path .. " (64x48, 24-bit). View it with: bmp " .. path .. "\n")
      else out("Error: " .. tostring(err) .. "\n") end
      return
    end
    local rd, label
    if lsub == "debug" then
      rd, label = stringReader(bmpBuild()), "built-in test pattern"
    else
      local err
      rd, err = fileReader(raw)
      if not rd then out("Error: cannot open '" .. raw .. "' (" .. tostring(err) .. ")\n"); return end
      label = raw
    end
    local ok, res, err = pcall(bmpShow, rd, label)
    if not ok then
      pcall(rd.close)
      cls()
      out("Error: " .. tostring(res) .. "\n")
    elseif not res then
      cls()
      out("Error: " .. tostring(err) .. "\n")
    end
  end)
end

------------------------------------------------------------------
-- 15. Desktop: touch/click GUI (ME app, Settings, Notepad, Terminal)
------------------------------------------------------------------
-- OpenComputers screens fire a "touch" event for a left-click anywhere in
-- the GUI (that's what "touchscreen" input means here; a real Touchscreen
-- upgrade is not required). Every app below responds to touch AND to a
-- keyboard fallback (digit keys / Esc), so it works either way.
local sharedDrawLogo   -- filled in below; lets boot() draw the real ReactOS logo
do
  cfgLoad()   -- so a saved background color is ready before boot() draws anything

  local function luma(c)
    local r, g, b = math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
    return 0.299 * r + 0.587 * g + 0.114 * b
  end

  -- Recolors the WHOLE theme (prompt, editor, desktop, everything uses BG/FG)
  -- and, unless save==false, persists it to C:\System32\reactos.cfg.
  local function applyTheme(newBG, save)
    BG = newBG
    FG = (luma(BG) > 150) and BLACK or 0xFFFFFF
    if save ~= false then
      cfg.bgcolor = tostring(BG)
      cfgSave()
    end
  end

  if cfg.bgcolor then
    local n = tonumber(cfg.bgcolor)
    if n then applyTheme(n, false) end
  end

  -- The real ReactOS logo, downscaled to 56x32 and stored as hex-encoded raw
  -- RGB bytes (hex, not raw bytes, so it survives being pasted through
  -- Pastebin or any other text-only transport unmangled).
  local LOGO_W, LOGO_H = 56, 32
  local LOGO_HEX = table.concat({
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefeffffffffffff",
    "fffffffffffffefefefffffffffffffffffffffffffffffffffffffffffffffffffefefefefefefffffffffffffffffffefefeffffffffffffffffff",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffcfcfcfafafafcfcfcffffffffffffffffff",
    "fdfdfdfefefefffffffffffffffffffefefefffffffffffffffffffdfdfdf9f9f9fbfbfbfffffffffffffefefeffffffffffffffffffffffffffffff",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffdfdfdfffffff3f3f3d2d2d2dadadadfdfdfdbdbdbdbdbdbdededff0f0f0fffffffffffffefefefefdfe",
    "fffffffffefeebebebd9d9d9d5d5d5dcdcdcddddddd2d2d2d1d1d1f1f1f1fffffffdfdfdffffffffffffffffffffffffffffffffffffffffffffffff",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffff6f6f6c4c4c4e3e3e3e6e6e6e9e8e8f0f0f0f8f7f7ecebebd4d4d3d1d1cfeaebeaf9fbfbfafbfbe9ebeacecfcfcdcecee9eaea",
    "f7f7f7eeeeeee1e1e1dfdfdfe1e1e1c3c3c3f4f4f4fffffffefefeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefefdfdfdfafafab4b4b4",
    "e1e1e1fdfdfdedecece7e5e6dddadbd8d6d7e3e6e5fffffffbfcf7e7e7e7f7f5faf6f4f9eae9ecfbfdfcffffffe4e3e5d1d0d1d4d4d4e1e1e1ebebeb",
    "fcfcfce3e3e3b0b0b0f3f3f3fefefeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefefefefed5d5d5c4c4c4fdfdfdffffffffffffffffff",
    "fffffffdfeffe4ececcdd8dbaab6bc81939c6a818c6d828d8297a0b8c3c6e2e7e8f0efeefcf9f9fffffffffffffffffffffffffcfcfcccccccd0d0d0",
    "fefefeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffff6f6f6d8d8d8dcdcdcf7f7f7fffffffdfffffcfdfdffffffe1e4e4adb9c06f838f",
    "314d5f143b4f12415414425513415527495c5e7484b4bfc9f4f6fafffffefdfdfdfffffffffffff8f8f8dcdcdcdadadaf4f4f4ffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffdfffefdfffefdfffffe",
    "fffffffffffffffffffffffffffffff0f0f0dfdfdfdcdcdcf1f1f1fffffffbfcfafcffffb6c2c7acb9bfcedfe8b9cfdd6d8b9d2f4e6725435f2e4c68",
    "3956733d617b3a5a72455c6f83929fdce6e9fefffffdfdfafffffef2f2f3dedededfdfdfebeaebfffffffefdfefefffefcfffcfdfffcfffffeffffff",
    "fffffffffffffffefffefffdfefffefdfffffdfffffffffffffffffffffffffffffdfdfcfdfdfafdfdfafdfcfafefefdffffffffffffffffffffffff",
    "fffffff5f5f5dfdfdfe7e7e7e4e4e5fefefeffffff91a1a8597282cde3efe6f9ffcde2ef829ba934506523405b3250693f5d774f6b82688397667c8e",
    "4f6576728697d3dee6fdfefcfffffee1e1e2e5e5e5dcdcdcedececfffffffffffffefefdfcfdfafefffcfefffdfffffefefefefefcfcfffefefefefd",
    "fefefdfefffffefffffffffffffffffefefefffffffffffffffffffffffffffffffffffffdfdfdfffffffffffffffffffefefefbfbfbd7d7d7f4f4f4",
    "d9dadaffffffb5c1c636505f627e90a5bac7c0d5e3aac3d2658294314f66294660314f6944627c5b768b8299ab9dafbd7486965d6e85b2bbcafbfbff",
    "fffeffd4d5d5f0f0f0dcdddcfffffffbfcfcf5f7f6fffffffffffffefdfefefffcfefdf8fffefafffffff8fbfcfffffffffefffffcfefffefeffffff",
    "fdfdfdffffffcdcdcd747576797c7f75777a838689dfdfe0fffffffefefefffffffdfdfdfafafafcfcfcd5d5d5f3f3f3dfdfdfe0dfde556a77476a81",
    "4c6c825e76846e87975e7b8d4464793b5b7436556f33526c3b59735a728593a7b79dadba8697a27e93a1a1acb39f9f9df8f6f5d2d2d2fefefed9d9d9",
    "98a8b07c8f9980929c80949eb8cacdfdfffffdfcf8fefdf9f0f6f59caab27f94a08d9faae3ecf0fefefefefefcfffffffdfdfdffffffb0b0b079797a",
    "c3c4c5bfc0c19496975c5e60e3e5e6fefefefafcfcfffffffffffffffffff3f3f3dddedff4f8fac1c7cc6c7e8c678092839aab7e92a26d81946c8295",
    "7d93a76b83975d768a5f788c6d869a798d9d95a5b2b8c5cfa7b2bacfd8dcbfc5c7858888fffffef1f2f0e3e9eb73828aa6afb5dfe6e9e6eef0cad3d7",
    "7c8e949ab0b4fdfffeffffffa0a9b096a3ace6eef2a4b5ba889ba3fdfefffefcfbfffffffdfdfdffffffb0b0b0a4a4a4ffffffffffffffffff999c9d",
    "94989bfefefeffffffd2d1d2969696999998cececfe9eceee0e7ea858f98cad3db9ca4ab848d947c858da3acb7c9d1dcafb7c1acb6c0a5b1bab7c2cb",
    "8b969f74838e8a98a2d6dfe6e7edf1dbdedf9da1a36f7377bebfbff2f5f5869399b3c3cafffffffffffffffffffffffff8fbfc7b9197c0c9cdfcffff",
    "85939cedf6f8fffffff8f5f9b0b4bef7f9fcfffefdfffffffcfcfcffffffafafaf9c9c9cfdfdfdf5f5f5fdfdfdc1c4c57d8184ffffff9fa2a4646464",
    "a0a0a0a0a0a069696a97999cdce3e78690999fa4a95d61647e83868b8f916b7070747879797e7fe5e8e9cccdcf6a6b6d8183858d98a0737d856c7175",
    "eef0f1b7bbbd6c70735c60638e8f8ebdc7ca889aa3fcfffffcfcfcfdfdfefefffffbfbfaffffffcedae0849299faffff84949bb8c6cbffffffffffff",
    "fffffffdfdfcfdfffffffffffcfcfcffffffafafaf9d9d9dfffffffffffffcfcfc6f7274a8acafd9ddde666a6cf8f8f8ffffffffffffffffff6e7072",
    "bec5c9c8d2d94c555cc4ccd3c0c8d0cad3d8e2ebed626b6d727b7dffffff767a7ea0a4a8e3e6eab8c1c8d3dbe18a8d8f929496ffffffcaced0808588",
    "ffffffa3b2baa5bac4fffffffdfcfbfffffffffffffffffcfefefcf0f5f97e929aedf4f0d9e0e0768b938ba0a6c1d3d4fafdf7fefef8fdfefeffffff",
    "fcfbfcffffffadafae9d9f9ff8f7f886888b6a7072747979f9fafa909494959999e4e5e5d5d8d7d4d7d6e0e0e095959586898ca3aaaf768088bbc5cd",
    "ccd6dec9d3dbf6fbffc0c4c77d8284e7eced707477f1f5f8d1d5d9bbc4ccc5cdd3ebeef2ededeefcfbfbb4b7b97c8287f3f6f899a9b5aec1cdfefefe",
    "fdfdfbfffffffffffffffefffffefdf3f9f67e959fe5ecebfffffff2f9fabfcacd73868d9babb2fcfefdfdfcf8fffffffcfbfcffffffaeb0af989a9a",
    "ffffff818387737b7dffffffffffff888c8b6e72718b8f8e858988858988868887848383adb0b2858c919fa7adb8c0c6bac2c8ecf3f7f8fbfcd2d5d7",
    "888c8ed4d8d97f8386fbfeffdee2e5d4dde5d4dde3eef2f5ffffffe0e0dfbec0c2777e83eaeff4aebbc597a7b3fffffffcfcfbfffffffffffffefdfe",
    "fefefee1eceb7e9197f5fdfdfefffff9fdfeffffffe8f3f6798a93e2eaebfffffefefefefcfbfdffffffaeb1b0999b9cffffffeaecee5c6466d7dcdc",
    "ffffff969a99aaadadfffffffcffffffffffffffffe6e5e5e3e6e890979c878b8ff5f9fccbcfd2cbcfd2ffffffbbbfc27b7f82ebeeef666a6ef6fafc",
    "ebeff2ced8e0ced7deebeef1cccccef4f3f4cbcdce797f84e0e5eaced5db7b8891e0eaeffffffffdfcfcfefdfdfffcfdffffff9eb3b7a5b2b4e7f0f2",
    "a6b1b5fdfffff3f9f9ffffff95a3aad4dfe3fffffffefefefcfbfdffffffaeb1b09a9b9cffffffffffffa5aaac707575ffffffdddfdf616564d9dcdb",
    "ffffffffffffd2d6d5616263babdbfb7bfc5585c5fbbbbbdfffffff3f4f5d8dcde5c6162777d7effffff7e8183939698ffffffeef6fce7eff47b8083",
    "989a9affffffb0b3b7788086c5ced3e4e7eabdc3ca798993e4eaedfffffffffffffdffffb8bfc6778d95eef4f5f0f7f977868dd8e2e4ffffffdfe7e9",
    "7f8e95ebf5f7fefffefffefffcfcfcffffffafafaf9b9b9bfffffffbfbfbf9f9f96a6a6abdbdbdffffffbcbcbc626b688a908e868d8a5a6263adb0b3",
    "e9eaeb9ca9b2afb8bf5e63667e7f808b8b8a646c697d8683828b88ffffffefefef7777777575758d8e8c717575788184dee7e7d1d4d5a0a7b46c7984",
    "b1c5c7e4e7ebf4eef5b5c2c4748b928ca0a794a6ac7f929c82919de5eaedfffffeffffffc2cacc77898c8ca3a7758894bdc9cffffffffdfdfbffffff",
    "fffffffefefef0f0f0ecececfffffffefefeffffffededede5e5e5fdfdfdffffffecf0efbcc1bfb0b3b2e8ecece1e2e2f6f6f69aa4abb0bbc3dce3e9",
    "b8bcbfa5a7a8e5e9e7f3f6f5c8cccbfbfdfcfffffffbfbfbc8c8c8a2a6a7b3babcd3dee3b8c5ca99a5ab9da7b78996a0b4c1c2fcfdfdd6d3d7fdffff",
    "d4e0e4bfcbcfbbc7cad1dcdff7fefffefffffefdfdfbfcfbfeffffe2eceec1cfd2e5e8edfffffffefbfdfffdfeffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffdfdfdfffffffdfdfde9e9e9f4f5f5d4d2d0ffffffd5dbdf8a97a1c3ced6edf4f9f0f3f7d6d6d6fcfcfc",
    "ebebebcececef8f8f8fafafaebebebd2d9dcd3dee1b8c6cc7f91998699a58492a57a8690e1e6e7ffffffe1e1e1e8e9e9e5e7e6f3f4f4ffffffffffff",
    "fffffefefefefffffffffffdfdfefbfffffffffffffffffffefcfdfefefffefffffffffffffffffffffffefefefefefefffffffffffffffffffefefe",
    "fefefefffffffefefefefefee0dfdfe5e4e5ddddddebe9e7fdfcfafcfeffb4bfc6a1adb5cbd5dbe7eef2e4e3e3d2d1d1fafaf9ecebebc8c8c9ededee",
    "e1e1e2c3cdd0bbcad07b8c98657a8b718d9e697b8babb5bbfffffffefefdf4f5f4e0dfdeeeececdddcdbfdfdfdfdfcfbfffefdfffffefefffffffffd",
    "fffffcfefdfefefcfdfefefcfdfffefcfffffdfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefeffffff",
    "dcdcdcecececdbdcdcfafbfbfdfdfefcfcfceff7f8b3bec0bac5c8d7e0e2f0f0efe7e7e7cecdcdf3f4f5e9eceebbbdc0d7d9dbcbd1d5929ea8728595",
    "6b849856728483959ef6f9fafefefdfffffffefefee2e2e2edeeeedededefffffffefefeffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefeffffffdededee2e2e2dededeffffff",
    "fefefefbfcfcf7fdfdecf3f3c0c7c8c1c7c8dfe2e4edf0f2d9dbddc2c7cadae1e4d3d9de9da4a9bdbcc4c8cfd88b9ea6576e797c8d95ecf2f5feffff",
    "fefefdfefeffffffffe4e4e4e7e7e7dadadafffffffefefeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffedededd4d4d4f7f7f7fffffffefefefffffffbfefcfdfffe",
    "fbfdfcdde0e0cfd6dab1b8bdc2c9cec8d1d7a5afb8c3cdd4bfc8d08b97a08c979fb5bdc4bbc0c5f8fdfdfffffffffffdfffffdfefefffefefefdfdfd",
    "d4d4d4e4e4e4fffffffefefeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffefefefefefed5d5d5d8d8d8fdfdfdfcfcfcfdfdfdf7f7f7e7e8e7d6d6d5d7d7d7dee0e2d3d5d8",
    "ccced0adb2b7959ea6899299a9b2b8c0c8cab7bcbee2e2e5dfddded6d6d6e7e8e7f7f7f6fdfdfcffffffffffffdadadac6c6c6fdfdfdfefefeffffff",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffdfdfdfefefec9c9c9c2c2c2dcdcdcd6d6d6dbdbdbdfdfdfecececf3f3f3e8e7e7d6d6d6dbdadaeaebede2e8ebe1e6e9",
    "e7ebeee1e0e0d8d7d7e5e5e4f6f6f6f0f0f0e2e2e3dbdbdbdadadaddddddc0c0c0bbbbbbfafafafcfcfcffffffffffffffffffffffffffffffffffff",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fefefeffffffffffffd6d6d6d4d4d4e2e2e2ececece6e6e6dbdbdbd3d3d3dededef5f5f5fffffffffffffffffffffffffffffffffffff8f8f8dfdfdf",
    "d2d2d2d5d5d5e0e0e0e8e8e8e1e1e1d1d1d1d1d1d1fcfcfcfffffffefefeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefeffffff",
    "efefefe1e1e1dfdfdfe6e6e6f2f2f2fefefefffffffffffffefefefefefefefefdfefefdfffffefefefefffffffffffffffffff5f5f5e6e6e6dedede",
    "e1e1e1eeeeeefffffffdfdfdfefefeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefeffffffffffffffffffffffff",
    "fffffffffffffefefefffffffffffffffffffffffffffffffffffffffffffffffffefefefefefefffffffffffffffffffffffffffffffefefefefefe",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefefefefefefefeffffffffffffffffffffffff",
    "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffefefefefefefefefeffffffffffffffffffffffffffffffffffffffffff",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
  })

  local function hexDecode(h)
    return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
  end
  local logoData = hexDecode(LOGO_HEX)
  local HALF = "\226\150\128"   -- U+2580 UPPER HALF BLOCK, 2 image rows per character cell

  -- Nearest-neighbour scaled blit of an RGB pixel buffer into a cw x ch
  -- character-cell box at (x0, y0). Used for both the boot-screen logo and
  -- the small Start-button icon; run-length coalesced so it stays cheap.
  local function drawImg(data, iw, ih, x0, y0, cw, ch)
    local function px(x, y)
      local i = (y * iw + x) * 3 + 1
      local r, g, b = data:byte(i, i + 2)
      return (r or 0) * 65536 + (g or 0) * 256 + (b or 0)
    end
    for cy = 0, ch - 1 do
      local start, rfg, rbg, rn = 0, 0, 0, 0
      for cx = 0, cw - 1 do
        local sx = math.min(iw - 1, math.floor(cx * iw / cw))
        local syT = math.min(ih - 1, math.floor((cy * 2) * ih / (ch * 2)))
        local syB = math.min(ih - 1, math.floor((cy * 2 + 1) * ih / (ch * 2)))
        local fg, bg = px(sx, syT), px(sx, syB)
        if rn > 0 and fg == rfg and bg == rbg then
          rn = rn + 1
        else
          if rn > 0 then
            gpu.setForeground(rfg); gpu.setBackground(rbg)
            gpu.set(x0 + start, y0 + cy, string.rep(HALF, rn))
          end
          start, rfg, rbg, rn = cx, fg, bg, 1
        end
      end
      if rn > 0 then
        gpu.setForeground(rfg); gpu.setBackground(rbg)
        gpu.set(x0 + start, y0 + cy, string.rep(HALF, rn))
      end
    end
    color(BG, FG)
  end

  sharedDrawLogo = function(x, y, cw, ch) drawImg(logoData, LOGO_W, LOGO_H, x, y, cw, ch) end

  -- Waits for the next click or key press.
  --   touch -> "touch", x, y
  --   key   -> "key", char, code
  local function waitInput()
    while true do
      local e, _, p1, p2 = pull()
      if e == "touch" then return "touch", p1, p2
      elseif e == "key_down" then return "key", p1, p2 end
    end
  end

  local PALETTE = {
    0x000080, 0x000000, 0x800000, 0x008000, 0x808000, 0x800080,
    0x008080, 0xC0C0C0, 0x0000FF, 0xFF0000, 0x00A000, 0xFFFF00,
    0xFF00FF, 0x00FFFF, 0xFFFFFF, 0x202020,
  }

  local function settingsApp()
    local hit, closeBtn = {}, nil
    local function draw()
      cls()
      bar(1, "Settings - Background Color", GRAY, BLACK)
      hit = {}
      local cols = math.max(4, math.min(8, math.floor((W - 4) / 8)))
      local x0, y0, sw, sh, gap = 3, 3, 6, 3, 2
      for i, c in ipairs(PALETTE) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local x, y = x0 + col * (sw + gap), y0 + row * (sh + 1)
        if y + sh <= H - 3 then
          gpu.setBackground(c)
          gpu.fill(x, y, sw, sh, " ")
          if c == BG then
            gpu.setForeground((luma(c) > 150) and BLACK or 0xFFFFFF)
            gpu.set(x + math.floor(sw / 2) - 1, y + 1, "[X]")
          end
          hit[#hit + 1] = { x, y, x + sw - 1, y + sh - 1, c }
        end
      end
      color(BG, FG)
      gpu.set(3, H - 2, string.format("Current: #%06X   (also: press 1-9/0 to pick, Esc to close)", BG))
      local cx = W - 9
      color(GRAY, BLACK)
      gpu.fill(cx, H, 8, 1, " ")
      gpu.set(cx, H, " Close ")
      closeBtn = { cx, H, cx + 7, H }
      color(BG, FG)
    end
    draw()
    while true do
      local kind, a, b = waitInput()
      if kind == "touch" then
        local x, y = a, b
        if x >= closeBtn[1] and x <= closeBtn[3] and y >= closeBtn[4] then break end
        for _, r in ipairs(hit) do
          if x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4] then
            applyTheme(r[5])
            draw()
            break
          end
        end
      elseif kind == "key" then
        if a == 13 or a == 27 or b == 1 then break end
        local n = tonumber(unicode.char(a or 0))
        if n == 0 then n = 10 end
        if n and PALETTE[n] then applyTheme(PALETTE[n]); draw() end
      end
    end
    cls()
  end

  local function notepadApp()
    cls()
    color(BG, FG)
    out("Notepad\n\nFile to edit (Enter for notes.txt): ")
    local name = trim(readline())
    if name == "" then name = "notes.txt" end
    sharedEditor(name, false)
  end

  -- Ported from the standalone RBMK console. It reuses ReactOS component,
  -- filesystem and event-pump adapters so the desktop can resume cleanly.
local function rbmkApp()
local component = component
local computer  = computer
local event = { pull = function(timeout, filter)
  local deadline = timeout and (computer.uptime() + math.max(0, timeout))
  while true do
    local remaining = deadline and math.max(0, deadline - computer.uptime()) or nil
    local e, a, b, c, d = pull(remaining)
    if not e or not filter or e == filter then return e, a, b, c, d end
    if deadline and computer.uptime() >= deadline then return nil end
  end
end }
local gpu       = gpu
local fs        = requireFn("filesystem")

local SCRAM_TEMP = 1000
local WARN_TEMP  = 500
local REFRESH    = 2
local FACT_TIMER = 150
local rodLevel   = 0.7

if not component.isAvailable("rbmk_console") then
  cls()
  color(BG, RED)
  out("RBMK Console component not found.\n")
  color(BG, FG)
  out("Connect an RBMK console and relaunch the app.\n")
  bar(H, "Press any key to return", GRAY, BLACK)
  waitKey()
  cls()
  return
end
local con = component.rbmk_console
local rs   = component.isAvailable("redstone")    and component.redstone    or nil
local wa   = component.isAvailable("WindAdapter") and component.WindAdapter or nil
local rsio  = component.isAvailable("rsio")          and component.rsio          or nil
local pwrG  = component.isAvailable("ntm_power_gauge") and component.ntm_power_gauge or nil
local fldG  = component.isAvailable("ntm_fluid_gauge") and component.ntm_fluid_gauge or nil

local scrammed          = false
local stormScram        = false
local stormScramEnabled = false
local autoTempScram     = false
local beepEnabled       = true
local weatherEnabled    = true
local prevView          = 1
local rsViewSide        = 0
local rsEnabled         = true
local rsOutEnabled      = true
local rsOutSide         = 3
local rsOutThreshold    = 700
local rsOutActive       = false
local rsioInPort        = 0    -- rsio input port for scram detection
local rsioOutPort       = 0    -- rsio output port for indicator
local rsioEnabled       = true -- use rsio if available
local gaugeEnabled      = true -- ntm power/fluid gauge display (CE/1.7.10 only)
local analogMode        = false  -- green phosphor CRT look
local scanlines         = false  -- scanline effect
local dimBackground     = false  -- dim background for old monitor look
local factIndex         = 1
local lastFact          = 0
local viewMode          = 1
local tempHistory       = {}
local waterHistory      = {}
local steamHistory      = {}
local cryoHistory       = {}
local powerHistory      = {}
local prevColCount      = -1
local prevColTypes      = {}
local logLines          = {}
local logScroll         = 0
local logFile           = nil
local logPath           = ""
local LOG_DIR           = "/home/rbmk_logs/"
local tempStatus        = 0
local seg7Anim          = 0  -- animation frame for 7seg idle
local histMax           = 50
local rodSyncEnabled    = true   -- sync rod level from HBM controller
local rsInputEnabled    = true   -- monitor redstone input to control rods
local rsInputSide       = 0      -- side to read rod control signal from
local rsInputMode       = 1      -- 1=rods follow signal, 2=scram on signal

local FACTS = {
  "AZ-5 was pressed at 01:23:40 on April 26, 1986 at Chernobyl.",
  "nicklysuffer was here",
  "nicklysuffer is an inflation artist from deviantart",
  "RBMK: Reaktor Bolshoy Moshchnosti Kanalnyy - High Power Channel Reactor.",
  "The Chernobyl reactor had a positive void coefficient - steam made it MORE reactive.",
  "Graphite rod tips caused a power surge when control rods were inserted. Oops.",
  "Xenon-135 poisoning can shut a reactor down hours after it stops - the Iodine Pit.",
  "The RBMK can be refueled while running at full power.",
  "Chernobyl exploded with the force of 500 nuclear bombs worth of steam.",
  "It takes 20,000 years for Pu-239 to decay to safe levels.",
  "Half-life of Cs-137 is 30 years. Chernobyl exclusion zone: still glowing.",
  "A SCRAM originally meant Safety Control Rod Axe Man - a guy with an axe.",
  "Natural uranium is 0.7pct U-235. Nuclear weapons need 90pct+.",
  "Chernobyl kept operating until reactor 3 was shut down in 2000.",
  "Never throttle an RBMK to 50pct and leave it - xenon poisoning will kill it.",
  "Outgassers remove xenon buildup - keep them working to prevent the Iodine Pit.",
  "Soviet operators disabled 6 of 7 safety systems before the Chernobyl test.",
  "Control rods take 18-20 seconds to fully insert. Every second counts.",
  "Fukushima used BWR reactors - water cooled but very different design.",
  "Xenon-135 peaks 6-12 hours after shutdown - the delayed killer.",
  "The RBMK has no containment building - unlike western PWR designs.",
  "Tritium has a half-life of only 12.3 years - short by nuclear standards.",
}
math.randomseed(computer.uptime() * 1000)
for i = #FACTS, 2, -1 do
  local j = math.random(i)
  FACTS[i], FACTS[j] = FACTS[j], FACTS[i]
end

local TYPESYM = {FUEL="F",CONTROL="C",REFLECTOR="R",COOLER="~",BOILER="B",OUTGASSER="O",STORAGE="S",MODERATOR="M"}
local TYPECOL = {FUEL=0xFFAA00,CONTROL=0x4488FF,REFLECTOR=0x555555,COOLER=0x00AAFF,BOILER=0x00FFFF,OUTGASSER=0x44FF44,STORAGE=0xAAAAAA,MODERATOR=0x888888}
local SIDE_NAMES = {"DOWN","UP","NORTH","SOUTH","WEST","EAST"}

-- ── Helpers ───────────────────────────────────────────────────
local function applyAnalog(col)
  if not analogMode then return col end
  -- Convert any color to green phosphor equivalent
  local r = math.floor(col/0x10000)
  local g = math.floor((col%0x10000)/0x100)
  local b = col%0x100
  -- Luminance to green channel
  local lum = math.floor(r*0.299 + g*0.587 + b*0.114)
  return math.floor(lum*0.3)*0x10000 + math.min(255,math.floor(lum*1.1))*0x100 + math.floor(lum*0.1)
end

local function px(x,y,fg,bg,txt)
  if not x or not y or not txt then return end
  local W,H = gpu.getResolution()
  if not W or not H then return end
  if x<1 or y<1 or y>H or x>W then return end
  gpu.setForeground(applyAnalog(fg or 0xFFFFFF))
  gpu.setBackground(analogMode and 0x000800 or (bg or 0x000000))
  local m=W-x+1
  if m<=0 then return end
  gpu.set(x,y,#txt>m and txt:sub(1,m) or txt)
end

local function minibar(val,max,len,hiCol,loCol)
  local p=math.max(0,math.min(val/max,1))
  local f=math.floor(p*len)
  return p>0.6 and hiCol or loCol, string.rep("|",f)..string.rep(".",len-f)
end

local function level(val,max)
  local p=math.max(0,math.min(val/max,1))
  local f=math.floor(p*3)
  return "["..string.rep("|",f)..string.rep(" ",3-f).."]"
end

-- ── Logging ───────────────────────────────────────────────────
local function writeLog(msg)
  if not msg then return end
  local line = os.date("%H:%M:%S").." "..tostring(msg)
  table.insert(logLines, line)
  if #logLines > 200 then table.remove(logLines, 1) end
  local W2,H2 = gpu.getResolution()
  if H2 then
    local maxS = math.max(0,#logLines-(H2-4))
    if logScroll >= maxS-1 then logScroll = maxS end
  end
  if logFile then
    local ok = pcall(function() logFile:write(line.."\n"); logFile:flush() end)
    if not ok then logFile = nil end
  end
end

local function initLog()
  local ok,err = pcall(function()
    local dir = LOG_DIR:gsub("/$","")
    if not fs.exists(dir) then fs.makeDirectory(dir) end
    local session=1
    while fs.exists(LOG_DIR.."RBMK-LOG-S"..session..".log") do session=session+1 end
    logPath = LOG_DIR.."RBMK-LOG-S"..session..".log"
    logFile = fs.open(logPath,"w")
    if logFile then
      logFile:write("RBMK CONTROL CONSOLE LOG\n")
      logFile:write("Session: "..session.."\n")
      logFile:write("Started: "..os.date("%Y-%m-%d %H:%M:%S").."\n")
      logFile:write(string.rep("-",40).."\n")
      logFile:flush()
    end
    writeLog("Session "..session.." started")
  end)
  if not ok then
    logPath = "(log unavailable)"
    table.insert(logLines, "Log init failed: "..(err or "unknown"))
  end
end

local function closeLog()
  if logFile then
    logFile:write(string.rep("-",40).."\n")
    logFile:write("Closed: "..os.date("%Y-%m-%d %H:%M:%S").."\n")
    logFile:close(); logFile=nil
  end
end

-- ── Core ──────────────────────────────────────────────────────
local function doScram(reason)
  scrammed=true; stormScram=(reason=="storm"); rodLevel=0
  con.pressAZ5(); con.setLevel(0)
  if beepEnabled then for _=1,3 do computer.beep(1000,0.2); computer.beep(800,0.1) end end
  local why=reason=="storm" and "STORM SCRAM" or (reason=="temp" and "AUTO TEMP SCRAM" or "MANUAL SCRAM (AZ-5)")
  writeLog("!!! "..why.." triggered")
end

local function setRods(lvl)
  local prev=rodLevel
  rodLevel=math.max(0,math.min(1,lvl))
  con.setLevel(rodLevel)
  writeLog(string.format("Rods %s: %.0f%% -> %.0f%%",rodLevel>prev and "raised" or "lowered",prev*100,rodLevel*100))
end

local function updateRsOutput(peakTemp)
  if not rsOutEnabled then rsOutActive=false; return end
  local should = peakTemp >= rsOutThreshold
  if should ~= rsOutActive then
    rsOutActive = should
    local sig = should and 15 or 0
    if rs  then pcall(rs.setOutput,  rsOutSide,   sig) end
    if rsio and rsioEnabled then pcall(rsio.setOutput, rsioOutPort, sig) end
    if should then writeLog(string.format("RS OUTPUT ON: %dC >= %dC (port %d)",peakTemp,rsOutThreshold,rsioOutPort))
    else writeLog(string.format("RS OUTPUT OFF: temp below %dC",rsOutThreshold)) end
  end
end

local function isStorming()
  if wa and weatherEnabled then
    local ok,v=pcall(wa.IsAStorm)
    if ok and v then
      local ok2,data=pcall(wa.ClosestStorm)
      if ok2 and type(data)=="table" then
        local s={} for i=1,#data,2 do s[data[i]]=data[i+1] end
        if s.name~="Cloud" and s.name~="" then return true end
      else return true end
    end
  end
  if rs and rsEnabled then
    for side=0,5 do local ok,v=pcall(rs.getInput,side) if ok and v and v>0 then return true end end
  end
  if rsio and rsioEnabled then
    local ok,v=pcall(rsio.getInput, rsioInPort)
    if ok and v and v>0 then return true end
  end
  return false
end

local function discoverGrid()
  local cols,maxX,maxY={},0,0
  for y=0,15 do for x=0,15 do
    local ok,d=pcall(con.getColumnData,x,y)
    if ok and type(d)=="table" and d.type then
      cols[y]=cols[y] or {}; cols[y][x]=d
      if x>maxX then maxX=x end; if y>maxY then maxY=y end
    end
  end end
  return cols,maxX,maxY
end

local function getWeather()
  if not wa or not weatherEnabled then return nil end
  local function g(fn,m) local ok,v=pcall(fn) return ok and v*(m or 1) or 0 end
  local okS,storm=pcall(wa.IsAStorm); local okR,rain=pcall(wa.IsRaining)
  return {storm=okS and storm or false,rain=okR and rain or false,
    tc=g(wa.GetCelsiusTemperature),spd=g(wa.GetWindSpeed,9.65),
    ang=g(wa.GetWindAngle),hum=g(wa.GetHumidity,100)}
end

local function collectData(cols,maxX,maxY)
  local d={peakTemp=0,minCryo=16000,cryoCount=0,
    boilers={},outgassers={},ctrlRods={},fuels={},
    totalWater=0,totalSteam=0,boilerCount=0}
  for y=0,maxY do for x=0,maxX do
    local col=cols[y] and cols[y][x]
    if col then
      local t=math.floor(col.hullTemp or 0)
      if t>d.peakTemp then d.peakTemp=t end
      if col.type=="COOLER" then
        local c=math.floor(col.cryogel or 0); d.cryoCount=d.cryoCount+1
        if c<d.minCryo then d.minCryo=c end
      elseif col.type=="BOILER" then
        local wmax=math.floor(col.realSimWater or 10000)
        local st=math.floor(col.steam or 0)
        table.insert(d.boilers,{x=x,y=y,wp=wmax>0 and math.floor((col.water or 0)/wmax*100) or 0,st=st,w=math.floor(col.water or 0),wmax=wmax})
        d.totalWater=d.totalWater+(col.water or 0); d.totalSteam=d.totalSteam+st; d.boilerCount=d.boilerCount+1
      elseif col.type=="OUTGASSER" then
        local req=col.requiredFlux or 10000; local prog=col.fluxProgress or 0
        table.insert(d.outgassers,{x=x,y=y,pct=req>0 and math.floor(math.min(prog/req,1)*100) or 0})
      elseif col.type=="CONTROL" then
        local rlvl = col.level or 0
        table.insert(d.ctrlRods,{x=x,y=y,lvl=rlvl})
      elseif col.type=="FUEL" then
        table.insert(d.fuels,{x=x,y=y,core=math.floor(col.coreTemp or 0),enr=col.enrichment or 0,xen=col.xenon or 0})
        if t>=SCRAM_TEMP and not scrammed and autoTempScram then doScram("temp") end
      end
    end
  end end
  return d
end


local function drawGraphicsSettings(W,H)
  local row=2
  px(2,row,0x00FF88,0x000000,"GRAPHICS SETTINGS"); row=row+2
  px(2,row,0x555555,0x000000,"!! EXPERIMENTAL - may affect performance !!"); row=row+2

  -- Analog mode
  px(2,row,0xCCCCCC,0x000000,"Analog Mode (Green CRT)  ")
  px(26,row,analogMode and 0x00FF88 or 0xFF4444,0x000000,analogMode and "[ON ]" or "[OFF]")
  px(32,row,0x555555,0x000000,"(a) toggle"); row=row+1
  if analogMode then
    px(4,row,0x004400,0x000000,"Classic green phosphor monitor look"); row=row+1
  end

  -- Scanlines
  px(2,row,0xCCCCCC,0x000000,"Scanlines                ")
  px(26,row,scanlines and 0x00FF88 or 0xFF4444,0x000000,scanlines and "[ON ]" or "[OFF]")
  px(32,row,0x555555,0x000000,"(l) toggle"); row=row+1
  if scanlines then
    px(4,row,0x333300,0x000000,"Alternating dark rows like old CRT"); row=row+1
  end

  -- Dim background
  px(2,row,0xCCCCCC,0x000000,"Dim Background           ")
  px(26,row,dimBackground and 0x00FF88 or 0xFF4444,0x000000,dimBackground and "[ON ]" or "[OFF]")
  px(32,row,0x555555,0x000000,"(d) toggle"); row=row+2

  -- Preview box
  px(2,row,0x888888,0x000000,"PREVIEW:"); row=row+1
  local previewBg = analogMode and 0x000800 or 0x000000
  local previewFg = analogMode and 0x00FF44 or 0x00FF88
  gpu.setBackground(previewBg)
  gpu.fill(2,row,40,3," ")
  gpu.setForeground(previewFg)
  gpu.set(4,row,  "RBMK CONTROL CONSOLE")
  gpu.set(4,row+1,"HEAT [|||] 651C ||||||||||||.")
  gpu.set(4,row+2,"NOMINAL")
  if scanlines then
    gpu.setBackground(0x000000)
    gpu.fill(2,row+1,40,1," ")
    gpu.setForeground(previewFg)
    gpu.set(4,row+1,"HEAT [|||] 651C ||||||||||||.")
  end
  gpu.setBackground(0x000000); row=row+4

  -- Seg7 speed
  px(2,row,0x888888,0x000000,"7-Seg Anim Speed: fast (hardcoded)"); row=row+2

  px(2,row,0x336633,0x000000,"(space) back to settings")
end

-- ── Views ─────────────────────────────────────────────────────
local function drawSettings(W,H)
  local row=2
  px(2,row,0x00FF88,0x000000,"SETTINGS"); row=row+2
  px(2,row,0xCCCCCC,0x000000,"Storm SCRAM      ")
  px(20,row,stormScramEnabled and 0x00FF88 or 0xFF4444,0x000000,stormScramEnabled and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(t) toggle"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"Auto Temp SCRAM  ")
  px(20,row,autoTempScram and 0x00FF88 or 0xFF4444,0x000000,autoTempScram and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(y) toggle  (at "..SCRAM_TEMP.."C)"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"Alarm Beep       ")
  px(20,row,beepEnabled and 0x00FF88 or 0xFF4444,0x000000,beepEnabled and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(b) toggle"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"Weather Radar    ")
  px(20,row,weatherEnabled and 0x00FF88 or 0xFF4444,0x000000,weatherEnabled and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(w) toggle"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"Rod Sync (HBM)   ")
  px(20,row,rodSyncEnabled and 0x00FF88 or 0xFF4444,0x000000,rodSyncEnabled and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(h) toggle"); row=row+2
  px(2,row,0x00FF88,0x000000,"REDSTONE INTERFACE"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"RS Detection     ")
  px(20,row,rsEnabled and 0x00FF88 or 0xFF4444,0x000000,rsEnabled and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(e) toggle"); row=row+1
  px(2,row,0x555555,0x000000,"Active side: ")
  local sx=15
  for i,name in ipairs(SIDE_NAMES) do
    local sel=(i-1)==rsViewSide
    px(sx,row,sel and 0x00FF88 or 0x555555,sel and 0x112211 or 0x000000,"["..name.."]")
    sx=sx+#name+3
  end
  px(sx+1,row,0x555555,0x000000,"(<>)cycle"); row=row+2
  local bw=9; local bh=4
  local bx=2; local by=row
  local tx=bx+bw+10; local ty=row
  local side=rsViewSide
  px(bx+2,by-1,0x888888,0x000000,"SIDE VIEW")
  px(tx+1,ty-1,0x888888,0x000000,"TOP/BOTTOM")
  local function cube(ox,oy)
    for iy=0,bh do for ix=0,bw do
      if iy==0 or iy==bh or ix==0 or ix==bw then px(ox+ix,oy+iy,0x334455,0x000000,"+") end
    end end
    px(ox+2,oy+bh//2,0x555555,0x000000,"COMPUTER")
  end
  cube(bx,by); cube(tx,ty)
  if side==2 then px(bx-3,by+bh//2,0xFF4444,0x000000,"RS<")
  elseif side==3 then px(bx+bw+1,by+bh//2,0xFF4444,0x000000,">RS")
  elseif side==4 then px(bx-3,by+bh//2,0xFF4444,0x000000,"RS<")
  elseif side==5 then px(bx+bw+1,by+bh//2,0xFF4444,0x000000,">RS")
  else px(bx+2,by+bh-1,0x444444,0x000000,"(N/S/E/W)") end
  if side==0 then px(tx+2,ty+bh-1,0xFF4444,0x000000,"RS BOTTOM")
  elseif side==1 then px(tx+3,ty+1,0xFF4444,0x000000,"RS TOP")
  else px(tx+2,ty+bh-1,0x444444,0x000000,"(UP/DOWN)") end
  row=by+bh+1
  local rodFg=rodLevel<0.3 and 0xFF4444 or (rodLevel<0.7 and 0xFFAA00 or 0x00FF88)
  local rodFill=math.floor(rodLevel*20)
  px(2,row,0x888888,0x000000,"CTRL RODS GLOBAL  ")
  px(20,row,rodFg,0x000000,string.format("[%s] %3d%%",string.rep("|",rodFill)..string.rep(".",20-rodFill),math.floor(rodLevel*100)))
  row=row+1
  local sideDesc={"v  BOTTOM  v","^  TOP  ^","<  NORTH  <",">  SOUTH  >","<  WEST  <",">  EAST  >"}
  local sideColors={0x00AAFF,0x00AAFF,0x00FF88,0x00FF88,0xFF8800,0xFF8800}
  local desc=sideDesc[side+1]; local col=sideColors[side+1]
  local pad=math.max(2,math.floor((W-#desc)/2))
  gpu.setBackground(0x0a1a0a); gpu.fill(1,row,W,1," ")
  px(pad,row,col,0x0a1a0a,"REDSTONE: "..desc)
  row=row+1; gpu.setBackground(0x000000)
  -- rsio section
  if rsio then
    px(2,row,0x00FF88,0x000000,"RSIO (Redstone Control Mod)"); row=row+1
    px(2,row,0xCCCCCC,0x000000,"RSIO Enabled     ")
    px(20,row,rsioEnabled and 0x00FF88 or 0xFF4444,0x000000,rsioEnabled and "[ON ]" or "[OFF]")
    px(26,row,0x555555,0x000000,"(i) toggle"); row=row+1
    px(2,row,0x555555,0x000000,string.format("Input port:  %d  Output port: %d",rsioInPort,rsioOutPort)); row=row+1
    -- Show live port values
    local ins=""
    for p=0,7 do
      local ok,v=pcall(rsio.getInput,p)
      ins=ins..string.format("%d:%s ",p,ok and tostring(v) or "?")
    end
    px(2,row,0x334455,0x000000,"Ports: "..ins); row=row+2
  end
  px(2,row,0x00FF88,0x000000,"REDSTONE OUTPUT (Emergency)"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"RS Output        ")
  px(20,row,rsOutEnabled and 0x00FF88 or 0xFF4444,0x000000,rsOutEnabled and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(o) toggle"); row=row+1
  px(2,row,0xCCCCCC,0x000000,string.format("Threshold: %dC",rsOutThreshold))
  px(26,row,0x555555,0x000000,"([)lower (])raise"); row=row+1
  local osx=20
  for i,name in ipairs(SIDE_NAMES) do
    local sel=(i-1)==rsOutSide
    px(osx,row,sel and 0xFF4444 or 0x555555,sel and 0x220000 or 0x000000,"["..name.."]"); osx=osx+#name+3
  end
  px(osx+1,row,0x555555,0x000000,"(;')side"); row=row+2
  row=row+1
  px(2,row,0x00FF88,0x000000,"REDSTONE INPUT CONTROL"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"RS Input Control ")
  px(20,row,rsInputEnabled and 0x00FF88 or 0xFF4444,0x000000,rsInputEnabled and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(i) toggle"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"Input Mode:      ")
  px(20,row,0x00FFAA,0x000000,rsInputMode==1 and "[ROD CONTROL]" or "[SCRAM TRIG ]")
  px(34,row,0x555555,0x000000,"(u) cycle"); row=row+1
  px(2,row,0x555555,0x000000,"Input Side:      ")
  local isx=18
  for i,name in ipairs(SIDE_NAMES) do
    local sel=(i-1)==rsInputSide
    px(isx,row,sel and 0x00FFAA or 0x555555,sel and 0x001111 or 0x000000,"["..name.."]")
    isx=isx+#name+3
  end
  px(isx+1,row,0x555555,0x000000,"(m/n)cycle"); row=row+1
  -- Show live signal
  if rs then
    local ok,sig = pcall(rs.getInput, rsInputSide)
    local val = ok and sig or 0
    local sigFg = val>0 and 0xFF4444 or 0x336633
    local bar = string.rep("|",math.floor(val/15*20))..string.rep(".",20-math.floor(val/15*20))
    px(2,row,0x888888,0x000000,"Live Input:      ")
    px(20,row,sigFg,0x000000,string.format("[%s] %2d/15",bar,val)); row=row+1
    -- All sides quick view
    px(2,row,0x555555,0x000000,"All sides: ")
    local ax=13
    for side=0,5 do
      local ok2,sv = pcall(rs.getInput,side)
      local sv2 = ok2 and sv or 0
      px(ax,row,sv2>0 and 0xFF4444 or 0x334433,0x000000,
        string.format("%s:%d ",SIDE_NAMES[side+1]:sub(1,1),sv2))
      ax=ax+4
    end
    row=row+2
  end
  -- NTM Gauge section
  row=row+1
  px(2,row,0xFFAA00,0x000000,"NTM GAUGES"); row=row+1
  px(2,row,0xFF4444,0x000000,"!! ONLY FOR HBM:CE OR 1.7.10 - NOT BASE 1.12.2 !!"); row=row+1
  px(2,row,0xCCCCCC,0x000000,"Gauge Display    ")
  px(20,row,gaugeEnabled and 0x00FF88 or 0xFF4444,0x000000,gaugeEnabled and "[ON ]" or "[OFF]")
  px(26,row,0x555555,0x000000,"(n) toggle"); row=row+1
  if gaugeEnabled then
    local hasPwr = pwrG~=nil; local hasFld = fldG~=nil
    px(2,row,hasPwr and 0x00FF88 or 0x555555,0x000000,"  Power gauge:  "..(hasPwr and "connected" or "not found")); row=row+1
    px(2,row,hasFld and 0x00FF88 or 0x555555,0x000000,"  Fluid gauge:  "..(hasFld and "connected" or "not found")); row=row+1
    if pwrG then
      local ok,info=pcall(pwrG.getInfo)
      if ok and type(info)=="table" then
        local stored=info.stored or info.energy or info.power or 0
        local cap=info.capacity or info.max or info.maxEnergy or 1
        local transfer=0; local ok2,tr=pcall(pwrG.getTransfer)
        if ok2 and type(tr)=="table" then transfer=tr.transfer or tr.rate or 0
        elseif ok2 then transfer=tonumber(tr) or 0 end
        px(2,row,0xFFAA00,0x000000,string.format("  Power: %d/%d HE  (%+d/t)",stored,cap,transfer)); row=row+1
      else px(2,row,0x555555,0x000000,"  Power gauge: no data"); row=row+1 end
    end
    if fldG then
      local ok,info=pcall(fldG.getInfo)
      local ok2,fluid=pcall(fldG.getFluid)
      if ok and type(info)=="table" then
        local amount=info.amount or info.stored or 0
        local cap=info.capacity or info.max or 1
        local name=info.name or info.fluid or ""
        if ok2 and type(fluid)=="table" then
          name=fluid.name or fluid.fluid or name
          amount=fluid.amount or fluid.stored or amount
        end
        px(2,row,0x4488FF,0x000000,string.format("  Fluid: %d/%d mB %s",amount,cap,name)); row=row+1
      else px(2,row,0x555555,0x000000,"  Fluid gauge: no data"); row=row+1 end
    end
    -- Turbines
    local turbCount=0
    local turbPower=0
    for addr,_ in component.list("ntm_turbine") do
      turbCount=turbCount+1
      local t=component.proxy(addr)
      local ok,info=pcall(t.getInfo)
      if ok and type(info)=="table" then
        turbPower=turbPower+(info.power or info.output or 0)
      else
        local ok2,pw=pcall(t.getPower)
        if ok2 then turbPower=turbPower+(tonumber(pw) or 0) end
      end
    end
    if turbCount>0 then
      px(2,row,0x00FFAA,0x000000,string.format("  Turbines: %d  Power: %d HE/t",turbCount,turbPower)); row=row+1
    end
  end
  row=row+1
  row=row+1
  px(2,row,0xFFAA00,0x000000,"[G] Graphics Settings")
  px(25,row,0x555555,0x000000,"analog/scanlines/CRT"); row=row+2
  px(2,row,0x336633,0x000000,"(space) back")
end

local viewMode6Sub = false  -- false=main settings, true=graphics

local function drawHeader(W,wx,storm,vm)
  gpu.setBackground(0x0a0a1a); gpu.fill(1,1,W,1," ")
  local views={"[1]STA","[2]GRD","[3]CIR","[4]GRP","[5]LOG","[6]SET","[7]GAU","[8]DEP"}
  local hdrCol = analogMode and applyAnalog(0x00FF88) or 0x00FF88
  px(2,1,hdrCol,0x0a0a1a,"RBMK")
  px(8,1,0x334455,0x0a0a1a,"|")
  px(10,1,0x888888,0x0a0a1a,os.date("%H:%M:%S"))
  if wx then px(21,1,0x336688,0x0a0a1a,string.format("%.0fC %.0fm/s",wx.tc,wx.spd)) end
  local tabW=0; for _,v in ipairs(views) do tabW=tabW+#v+1 end
  local tx=W-tabW
  for i,v in ipairs(views) do
    px(tx,1,i==vm and 0x00FF88 or 0x444455,i==vm and 0x112211 or 0x0a0a1a,v); tx=tx+#v+1
  end
  if scrammed then px(W//2-4,1,0xFF2222,0x0a0a1a,"!!AZ-5!!") end
  local wStr=wx and (storm and "STORM" or (wx.rain and "RAIN" or "CLEAR")) or ""
  if #wStr>0 then px(W-#wStr-1,1,storm and 0xFF3333 or 0x44AAFF,0x0a0a1a,wStr) end
  gpu.setBackground(0x000000)
end

local function drawFooter(W,H,sc,ss,peakTemp)
  gpu.setBackground(0x0a0a0a); gpu.fill(1,H-1,W,1," ")
  if ss then px(2,H-1,0xFF4488,0x0a0a0a,"STORM SCRAM")
  elseif sc then px(2,H-1,0xFF2222,0x0a0a0a,"AZ-5 SHUTDOWN")
  elseif peakTemp>=WARN_TEMP then px(2,H-1,0xFF8800,0x0a0a0a,string.format("WARNING %dC",peakTemp))
  else px(2,H-1,0x00FF88,0x0a0a0a,"NOMINAL") end
  gpu.setBackground(0x0a0a0a); gpu.fill(1,H-2,W,1," ")
  if viewMode==6 then
    if viewMode6Sub then
      px(2,H-2,0x444444,0x0a0a0a,"(a)analog/CRT (l)scanlines (d)dim  (space)back")
    else
      px(2,H-2,0x444444,0x0a0a0a,"(t)storm (y)autotemp (b)beep (w)weather (g)graphics (space)back")
    end
  else
    px(2,H-2,0x444444,0x0a0a0a,"(s)scram (.)raise (,)lower (r)reset (tab/1-6)view (q)quit")
  end
  gpu.setBackground(0x0a140a); gpu.fill(1,H,W,1," ")
  local fact=FACTS[factIndex]
  local mf=W-4; if #fact>mf then fact=fact:sub(1,mf-3).."..." end
  px(2,H,0x44AA44,0x0a140a,"» "..fact)
end

local function drawStats(W,H,cols,maxX,maxY,d)
  local mapW=maxX+2; local mapX=W-mapW
  local statW=mapX-3; local BL=math.max(5,math.min(W//4,statW-22))
  local LW=18; local row=2
  px(mapX,2,0x334455,0x000000,"MAP")
  for y=0,maxY do for x=0,maxX do
    local col=cols[y] and cols[y][x]
    local ch=col and (TYPESYM[col.type] or "?") or " "; local fg=0x222222
    if col then
      local t=math.floor(col.hullTemp or 0); fg=TYPECOL[col.type] or 0xFFFFFF
      if t>=SCRAM_TEMP then fg=0xFF2222 elseif t>=WARN_TEMP then fg=0xFF8800 end
    end
    px(mapX+x,3+y,fg,0x000000,ch)
  end end
  -- Gauge readings on map side if connected
  if gaugeEnabled and (pwrG or fldG) then
    local gr=3+maxY+3
    if pwrG then
      local ok,info=pcall(pwrG.getInfo)
      if ok and type(info)=="table" then
        local s=info.stored or info.energy or 0
        local m=info.capacity or info.max or 1
        if m>0 then px(mapX,gr,0xFFAA00,0x000000,string.format("PWR%3d%%",math.floor(s/m*100))); gr=gr+1 end
      end
    end
    if fldG then
      local ok,info=pcall(fldG.getInfo)
      if ok and type(info)=="table" then
        local s=info.amount or info.stored or 0
        local m=info.capacity or info.max or 1
        if m>0 then px(mapX,gr,0x4488FF,0x000000,string.format("FLD%3d%%",math.floor(s/m*100))); gr=gr+1 end
      end
    end
    local tc=0; for _,_ in component.list("ntm_turbine") do tc=tc+1 end
    if tc>0 then px(mapX,gr,0x00FFAA,0x000000,string.format("TRB x%d",tc)); gr=gr+1 end
  end
  px(mapX,3+maxY+1,0x334455,0x000000,"F C O")
  px(mapX,3+maxY+2,0x334455,0x000000,"B ~ R")
  local tCol,tBar=minibar(d.peakTemp,1200,BL,0xFF3300,0x00CC44)
  px(2,row,0x888888,0x000000,"HEAT") px(7,row,tCol,0x000000,level(d.peakTemp,1200))
  px(13,row,0xCCCCCC,0x000000,string.format("%4dC",d.peakTemp)) px(LW+1,row,tCol,0x000000,tBar); row=row+1
  if d.cryoCount>0 then
    local cCol,cBar=minibar(d.minCryo,16000,BL,0x0099FF,0xFF4400)
    px(2,row,0x888888,0x000000,"CRYO") px(7,row,cCol,0x000000,level(d.minCryo,16000))
    px(13,row,0xCCCCCC,0x000000,string.format("%5dmB%s",d.minCryo,d.minCryo<3000 and "!" or ""))
    px(LW+1,row,cCol,0x000000,cBar); row=row+1
  end
  if d.boilerCount>0 then
    local avgW=math.floor(d.totalWater/d.boilerCount)
    local wCol,wBar=minibar(avgW,10000,BL,0x4488FF,0xFF4400)
    px(2,row,0x888888,0x000000,"WATR") px(7,row,wCol,0x000000,level(avgW,10000))
    px(13,row,0xCCCCCC,0x000000,string.format("%5dmB",avgW)) px(LW+1,row,wCol,0x000000,wBar); row=row+1
    local avgSt=math.floor(d.totalSteam/d.boilerCount)
    local sCol,sBar=minibar(avgSt,1000,BL,0x00FFFF,0x336666)
    px(2,row,0x888888,0x000000,"STEA") px(7,row,sCol,0x000000,level(avgSt,1000))
    px(13,row,0xCCCCCC,0x000000,string.format("  %4d/t",avgSt)) px(LW+1,row,sCol,0x000000,sBar); row=row+1
  end
  local rodFill=math.floor(rodLevel*BL)
  local rodFg=rodLevel<0.3 and 0xFF4444 or (rodLevel<0.7 and 0xFFAA00 or 0x00FF88)
  px(2,row,0x888888,0x000000,"RODS") px(7,row,rodFg,0x000000,level(rodLevel,1))
  px(13,row,rodFg,0x000000,string.format("  %3d%%",math.floor(rodLevel*100)))
  px(LW+1,row,rodFg,0x000000,string.rep("|",rodFill)..string.rep(".",BL-rodFill)); row=row+1
  px(2,row,0x1a1a2e,0x000000,string.rep("-",statW)); row=row+1
  if #d.fuels>0 then
    px(2,row,0xFFAA00,0x000000,string.format("FUEL[%d]",#d.fuels)); row=row+1
    local cx=2
    for _,f in ipairs(d.fuels) do
      local fg=f.xen>50 and 0xFF4444 or (f.core>WARN_TEMP and 0xFF8800 or 0xCCCCCC)
      local cell=string.format("(%d,%d)%dC %.0f%%%s ",f.x,f.y,f.core,f.enr*100,f.xen>50 and "!XE" or "")
      if cx+#cell>statW then cx=2; row=row+1 end
      px(cx,row,fg,0x000000,cell); cx=cx+#cell
    end; row=row+1
  end
  if #d.outgassers>0 then
    px(2,row,0x44FF44,0x000000,string.format("OUTG[%d]",#d.outgassers)); row=row+1
    local cx=2
    for _,o in ipairs(d.outgassers) do
      local fg=o.pct>=80 and 0x00FF88 or (o.pct>=40 and 0xFFAA00 or 0xFF4444)
      local cell=string.format("(%d,%d)%d%% ",o.x,o.y,o.pct)
      if cx+#cell>statW then cx=2; row=row+1 end
      px(cx,row,fg,0x000000,cell); cx=cx+#cell
    end; row=row+1
  end
  px(2,row,0x4488FF,0x000000,string.format("RODS[%d] Glbl:%.0f%%",#d.ctrlRods,rodLevel*100)); row=row+1
  if #d.ctrlRods>0 then
    local cx=2
    for _,r in ipairs(d.ctrlRods) do
      local pct=math.floor(r.lvl*100)
      local fg=r.lvl<0.3 and 0xFF4444 or (r.lvl<0.7 and 0xFFAA00 or 0x00FF88)
      local cell=string.format("(%d,%d)%d%% ",r.x,r.y,pct)
      if cx+#cell>statW then cx=2; row=row+1 end
      px(cx,row,fg,0x000000,cell); cx=cx+#cell
    end
  end
end

local function drawGrid(W,H,cols,maxX,maxY)
  local row=2
  px(2,row,0xAAAAAA,0x000000,string.format("GRID %dx%d",maxX+1,maxY+1)); row=row+1
  for y=0,maxY do
    local hasData=false
    for x=0,maxX do if cols[y] and cols[y][x] then hasData=true; break end end
    if not hasData then goto skip end
    local cx=2
    for x=0,maxX do
      local d=cols[y] and cols[y][x]
      if d then
        local t=math.floor(d.hullTemp or 0)
        local tp=(d.type or "?"):sub(1,4):upper()
        local fg=0x00FF88
        if t>=SCRAM_TEMP then fg=0xFF2222 elseif t>=WARN_TEMP then fg=0xFF8800 elseif t>=200 then fg=0xFFFF00 end
        local cell=string.format("[%3dC %s]",t,tp)
        if cx+#cell<=W-2 then px(cx,row,fg,0x000000,cell); cx=cx+#cell+1 end
      end
    end
    row=row+1
    ::skip::
  end
end

local function drawCircle(W,H,cols,maxX,maxY,d)
  local leftW=20  -- width of left stats strip
  local cX=leftW+math.floor((W-leftW)/2)
  local cY=math.floor((H-2)/2)+2
  local rx=math.min(math.floor((W-leftW)/2)-2, maxX+2)
  local ry=math.min(math.floor((H-4)/2), maxY+2)
  px(2,2,0xAAAAAA,0x000000,string.format("VISUAL  Peak:%dC  Rods:%.0f%%",d.peakTemp,rodLevel*100))
  for y=0,maxY do for x=0,maxX do
    local col=cols[y] and cols[y][x]
    if col then
      local gx=(x-maxX/2)/(maxX/2+0.5); local gy=(y-maxY/2)/(maxY/2+0.5)
      local sx=math.floor(cX+gx*rx); local sy=math.floor(cY+gy*ry)
      local t=math.floor(col.hullTemp or 0); local fg=TYPECOL[col.type] or 0xFFFFFF
      if t>=SCRAM_TEMP then fg=0xFF2222 elseif t>=WARN_TEMP then fg=0xFF8800 end
      px(sx,sy,fg,0x000000,TYPESYM[col.type] or "?")
    end
  end end
  for i=0,35 do
    local angle=i*math.pi/18
    px(math.floor(cX+(rx+1)*math.cos(angle)),math.floor(cY+(ry+1)*math.sin(angle)*0.5),0x334455,0x000000,".")
  end
  px(2,3,0x888888,0x000000,string.format("HEAT:%4dC",d.peakTemp))
  if d.cryoCount>0 then px(2,4,0x0099FF,0x000000,string.format("CRYO:%5dmB",d.minCryo)) end
  if d.boilerCount>0 then
    px(2,5,0x4488FF,0x000000,string.format("WATR:avg%5dmB",math.floor(d.totalWater/d.boilerCount)))
    px(2,6,0x00FFFF,0x000000,string.format("STEA:avg%4d/t",math.floor(d.totalSteam/d.boilerCount)))
  end
  px(2,7,0x4488FF,0x000000,string.format("RODS[%d] %.0f%%",#d.ctrlRods,rodLevel*100))
  px(2,8,0xFFAA00,0x000000,string.format("FUEL[%d] OUTG[%d]",#d.fuels,#d.outgassers))
  px(2,H-3,0x555555,0x000000,"F=fuel C=ctrl O=outg B=boil ~=cool R=refl")
end

local function drawGraph(W,H,d)
  local row=2
  local statusStr="UNKNOWN"; local statusCol=0x888888
  if tempStatus==1 then statusStr="RISING  ^" statusCol=0xFF4444
  elseif tempStatus==2 then statusStr="DECREASING v" statusCol=0x00FF88
  elseif tempStatus==3 then statusStr="CLIMAX !" statusCol=0xFF8800
  end
  px(2,row,0xAAAAAA,0x000000,"TEMPERATURE GRAPH")
  px(W-#statusStr-2,row,statusCol,0x000000,statusStr); row=row+1
  local sum=0; for _,v in ipairs(tempHistory) do sum=sum+v end
  local avg=math.floor(#tempHistory>0 and sum/#tempHistory or 0)
  local minT,maxT=9999,0
  for _,v in ipairs(tempHistory) do if v<minT then minT=v end; if v>maxT then maxT=v end end
  px(2,row,0xCCCCCC,0x000000,string.format("Avg:%4dC  Min:%4dC  Max:%4dC  Points:%d",avg,minT,maxT,#tempHistory))
  row=row+2
  local gW=W-8; local gH=math.max(5,H-row-6); local gX=5; local gY=row
  for gy=gY,gY+gH do px(gX-1,gy,0x334455,0x000000,"|") end
  for gx=gX,gX+gW do px(gx,gY+gH+1,0x334455,0x000000,"-") end
  px(gX-1,gY+gH+1,0x334455,0x000000,"+")
  local yRange=math.max(100,maxT-minT+50); local yLow=math.max(0,minT-25)
  px(1,gY,0x555555,0x000000,string.format("%4d",yLow+yRange))
  px(1,gY+gH//2,0x555555,0x000000,string.format("%4d",yLow+yRange//2))
  px(1,gY+gH,0x555555,0x000000,string.format("%4d",yLow))
  local warnY=gY+gH-math.floor((WARN_TEMP-yLow)/yRange*gH)
  local scramY=gY+gH-math.floor((SCRAM_TEMP-yLow)/yRange*gH)
  if warnY>=gY and warnY<=gY+gH then
    for gx=gX,gX+gW do px(gx,warnY,0xFF6600,0x000000,"-") end
    px(gX+gW-7,warnY,0xFF6600,0x000000,"WARN")
  end
  if scramY>=gY and scramY<=gY+gH then
    for gx=gX,gX+gW do px(gx,scramY,0xFF2222,0x000000,"-") end
    px(gX+gW-8,scramY,0xFF2222,0x000000,"SCRAM")
  end
  if #tempHistory>1 then
    local step=math.max(1,math.floor(#tempHistory/gW)); local px2=gX
    for i=1,#tempHistory,step do
      local v=tempHistory[i]
      local py2=math.max(gY,math.min(gY+gH,gY+gH-math.floor((v-yLow)/yRange*gH)))
      local fg=v>=SCRAM_TEMP and 0xFF2222 or (v>=WARN_TEMP and 0xFF8800 or 0x00FF88)
      px(px2,py2,fg,0x000000,"*"); px2=px2+1
      if px2>gX+gW then break end
    end
  end
  local tFg=d.peakTemp>=SCRAM_TEMP and 0xFF2222 or (d.peakTemp>=WARN_TEMP and 0xFF8800 or 0x00FF88)
  px(2,gY+gH+3,0x888888,0x000000,"Current: ")
  px(11,gY+gH+3,tFg,0x000000,string.format("%dC",d.peakTemp))
  px(22,gY+gH+3,0x555555,0x000000,string.format("Avg: %dC",avg))
end

local function logLineColor(line)
  if line:find("EXPLODED") or line:find("!!! ") then return 0xFF2222 end
  if line:find("SCRAM")   then return 0xFF4444 end
  if line:find("WARNING") then return 0xFF8800 end
  if line:find("STORM")   then return 0xFF4488 end
  if line:find("Rods raised")  then return 0x00FF88 end
  if line:find("Rods lowered") then return 0x4488FF end
  if line:find("CHANGE") or line:find("changed") then return 0xFFAA00 end
  if line:find("Session") or line:find("Started") or line:find("Closed") then return 0x00FFAA end
  if line:find("Temp:")   then return 0x666666 end
  return 0x888888
end

local function drawLogs(W,H)
  local viewH=H-4; local maxScroll=math.max(0,#logLines-viewH)
  logScroll=math.max(0,math.min(logScroll,maxScroll))
  gpu.setBackground(0x0a0a1a); gpu.fill(1,2,W,1," ")
  px(2,2,0x00FF88,0x0a0a1a,"RBMK LOGS")
  px(14,2,0x555555,0x0a0a1a,logPath)
  local info=string.format("%d/%d  [j]dn [k]up [g]top [G]end",math.min(logScroll+viewH,#logLines),#logLines)
  px(W-#info-1,2,0x444444,0x0a0a1a,info)
  gpu.setBackground(0x000000)
  for i=1,viewH do
    local idx=logScroll+i
    if idx<=#logLines then
      local line=logLines[idx]; local fg=logLineColor(line)
      if #line>W-3 then line=line:sub(1,W-4)..">" end
      px(2,i+2,fg,0x000000,line)
    end
  end
  if #logLines>viewH then
    local barH=math.max(1,math.floor(viewH*viewH/#logLines))
    local barY=maxScroll>0 and math.floor(logScroll/maxScroll*(viewH-barH)) or 0
    for y=3,viewH+2 do px(W,y,0x222233,0x000000,"|") end
    for y=barY+3,barY+barH+2 do px(W,y,0x4488FF,0x000000,"#") end
  end
end


-- ── Gauges & Indicators view ──────────────────────────────────
local function rectGauge(x, y, w, h, val, maxVal, label, col, bgCol)
  local pct = math.max(0, math.min(val/math.max(maxVal,1), 1))
  local filled = math.floor(pct * h)
  -- Draw empty
  for gy = 0, h do
    local isFilled = gy >= (h - filled)
    local c = isFilled and col or (bgCol or 0x111111)
    gpu.setBackground(c)
    gpu.setForeground(0x000000)
    gpu.fill(x, y+gy, w, 1, " ")
  end
  -- Label at bottom
  gpu.setBackground(0x000000)
  gpu.setForeground(col)
  local lbl = label:sub(1,w)
  local lx = x + math.floor((w-#lbl)/2)
  gpu.set(lx, y+h+1, lbl)
  -- Percentage in middle
  local pctStr = string.format("%d%%", math.floor(pct*100))
  if w >= #pctStr then
    local midY = y + math.floor(h/2)
    gpu.setBackground(isFilled and col or 0x111111)
    gpu.setForeground(isFilled and 0x000000 or col)
    gpu.set(x + math.floor((w-#pctStr)/2), midY, pctStr)
  end
  gpu.setBackground(0x000000)
end

local function miniGraph(x, y, w, h, history, maxVal, col, label)
  if #history < 2 then return end
  -- Border
  gpu.setForeground(0x222233)
  for gx=x,x+w do gpu.set(gx,y+h+1,"-") end
  gpu.set(x-1,y+h+1,"+")
  for gy=y,y+h do gpu.set(x-1,gy,"|") end
  -- Label
  gpu.setForeground(0x334455)
  gpu.set(x, y-1, label:sub(1,w))
  -- Plot
  local step = math.max(1, math.floor(#history/w))
  local px2 = x
  for i=1,#history,step do
    local v = history[i]
    local py2 = y+h - math.floor((v/math.max(maxVal,1))*h)
    py2 = math.max(y, math.min(y+h, py2))
    gpu.setForeground(col)
    gpu.set(px2, py2, "*")
    px2 = px2+1
    if px2 > x+w then break end
  end
end

local function drawGaugeDash(W,H,d)
  local row = 2
  -- Title
  px(2,row,0x00FF88,0x000000,"GAUGES & INDICATORS"); row=row+1
  px(2,row,0x555555,0x000000,string.rep("-",W-4)); row=row+1

  -- ── Rectangular gauges row ────────────────────────────────
  local gH = math.max(6, math.floor((H-row-14)/2))  -- gauge height
  local gW = 5   -- gauge width
  local gap = 2
  local startX = 3
  local gY = row+1

  -- Define gauges
  local gauges = {}
  -- HEAT
  table.insert(gauges,{val=d.peakTemp,    max=1200,  label="HEAT", col=d.peakTemp>=SCRAM_TEMP and 0xFF2222 or (d.peakTemp>=WARN_TEMP and 0xFF8800 or 0x00CC44)})
  -- CRYO
  table.insert(gauges,{val=d.minCryo,     max=16000, label="CRYO", col=d.minCryo<3000 and 0xFF4444 or 0x0099FF})
  -- WATER
  if d.boilerCount>0 then
    local avgW=math.floor(d.totalWater/d.boilerCount)
    table.insert(gauges,{val=avgW, max=10000, label="WATR", col=0x4488FF})
  end
  -- STEAM
  if d.boilerCount>0 then
    local avgS=math.floor(d.totalSteam/d.boilerCount)
    table.insert(gauges,{val=avgS, max=2000, label="STEA", col=0x00FFFF})
  end
  -- RODS
  table.insert(gauges,{val=rodLevel, max=1, label="RODS", col=rodLevel<0.3 and 0xFF4444 or (rodLevel<0.7 and 0xFFAA00 or 0x00FF88)})
  -- POWER GAUGE (if connected)
  if gaugeEnabled and pwrG then
    local ok,info=pcall(pwrG.getInfo)
    if ok and type(info)=="table" then
      local s=info.stored or info.energy or 0
      local m=info.capacity or info.max or 1
      table.insert(gauges,{val=s, max=m, label="PWR", col=0xFFAA00})
    end
  end
  -- FLUID GAUGE (if connected)
  if gaugeEnabled and fldG then
    local ok,info=pcall(fldG.getInfo)
    if ok and type(info)=="table" then
      local s=info.amount or info.stored or 0
      local m=info.capacity or info.max or 1
      table.insert(gauges,{val=s, max=m, label="FLD", col=0x44FF88})
    end
  end

  -- Draw all gauges
  local gx = startX
  for _,g in ipairs(gauges) do
    if gx + gW < W-4 then
      rectGauge(gx, gY, gW, gH, g.val, g.max, g.label, g.col, 0x0a0a0a)
      gx = gx + gW + gap
    end
  end

  -- ── Status indicators row ─────────────────────────────────
  local indY = gY + gH + 3
  px(2,indY,0x555555,0x000000,"STATUS: ")
  local ix = 10
  local function indicator(label, ok, col)
    if ix + #label + 3 > W-2 then return end
    local fg = ok and col or 0x333333
    local bg = ok and 0x0a1a0a or 0x0a0a0a
    gpu.setBackground(bg); gpu.setForeground(fg)
    gpu.set(ix, indY, "["..label.."]")
    gpu.setBackground(0x000000); ix=ix+#label+3
  end
  indicator("NOMINAL",    d.peakTemp<WARN_TEMP,                0x00FF88)
  indicator("SCRAM",      scrammed,                            0xFF2222)
  indicator("XE-POISON",  false, 0xFF8800) -- placeholder
  local hasXe = false
  for _,f in ipairs(d.fuels) do if f.xen>50 then hasXe=true end end
  indicator("XE-POISON",  hasXe,  0xFF8800)
  indicator("HOT",        d.peakTemp>=WARN_TEMP,               0xFF8800)
  indicator("CRYO-LOW",   d.minCryo<3000,                     0x4488FF)
  local turbCount=0
  for _,_ in component.list("ntm_turbine") do turbCount=turbCount+1 end
  indicator("TURBINES x"..turbCount, turbCount>0,             0x00FFAA)
  indY = indY + 2

  -- ── Electricity Meter ─────────────────────────────────────
  if gaugeEnabled and pwrG then
    indY = indY + 1
    px(2,indY,0xFFAA00,0x000000,"ELECTRICITY METER"); indY=indY+1
    local ok,info=pcall(pwrG.getInfo)
    local ok2,tr=pcall(pwrG.getTransfer)
    local stored,cap,transfer=0,1,0
    if ok and type(info)=="table" then
      stored=info.stored or info.energy or info.power or 0
      cap=info.capacity or info.max or info.maxEnergy or 1
    end
    if ok2 and type(tr)=="table" then transfer=tr.transfer or tr.rate or tr.io or 0
    elseif ok2 then transfer=tonumber(tr) or 0 end
    local pct=math.floor(stored/math.max(cap,1)*100)
    local barW=math.floor((W-30)*pct/100)
    local barEmpty=W-30-barW
    local col=pct<20 and 0xFF2222 or (pct<50 and 0xFF8800 or 0xFFAA00)
    -- Stored bar
    gpu.setBackground(col); gpu.fill(3,indY,barW,1," ")
    gpu.setBackground(0x111100); gpu.fill(3+barW,indY,barEmpty,1," ")
    gpu.setBackground(0x000000)
    px(W-26,indY,col,0x000000,string.format("%6d/%6d HE  %+5d/t",stored,cap,transfer))
    indY=indY+1
    -- Transfer rate bar
    local absT=math.abs(transfer)
    local tBarW=math.floor(math.min(absT/math.max(cap*0.01,1),1)*(W-30))
    local tCol=transfer>=0 and 0x00FF88 or 0xFF4444
    local tLabel=transfer>=0 and "IN " or "OUT"
    px(2,indY,tCol,0x000000,tLabel.." ")
    gpu.setBackground(tCol); gpu.fill(6,indY,tBarW,1," ")
    gpu.setBackground(0x000000)
    indY=indY+2
  end

  -- ── Fluid Meter ───────────────────────────────────────────
  if gaugeEnabled and fldG then
    px(2,indY,0x4488FF,0x000000,"FLUID METER"); indY=indY+1
    local ok,info=pcall(fldG.getInfo)
    local ok2,fl=pcall(fldG.getFluid)
    local ok3,tr=pcall(fldG.getTransfer)
    local amount,cap,fluidName,transfer=0,1,"unknown",0
    if ok and type(info)=="table" then
      amount=info.amount or info.stored or 0
      cap=info.capacity or info.max or 1
      fluidName=info.name or info.fluid or fluidName
    end
    if ok2 and type(fl)=="table" then
      fluidName=fl.name or fl.fluid or fluidName
      amount=fl.amount or fl.stored or amount
    end
    if ok3 and type(tr)=="table" then transfer=tr.transfer or tr.rate or 0
    elseif ok3 then transfer=tonumber(tr) or 0 end
    local pct=math.floor(amount/math.max(cap,1)*100)
    local barW=math.floor((W-30)*pct/100)
    local barEmpty=W-30-barW
    local col=0x4488FF
    gpu.setBackground(col); gpu.fill(3,indY,barW,1," ")
    gpu.setBackground(0x001133); gpu.fill(3+barW,indY,barEmpty,1," ")
    gpu.setBackground(0x000000)
    px(W-26,indY,col,0x000000,string.format("%6d/%6d mB  %s",amount,cap,fluidName:sub(1,8)))
    indY=indY+1
    -- Transfer bar
    local tBarW=math.floor(math.min(math.abs(transfer)/math.max(cap*0.01,1),1)*(W-30))
    local tCol=transfer>=0 and 0x00FFFF or 0xFF4488
    local tLabel=transfer>=0 and "IN " or "OUT"
    px(2,indY,tCol,0x000000,tLabel.." ")
    gpu.setBackground(tCol); gpu.fill(6,indY,tBarW,1," ")
    gpu.setBackground(0x000000)
    indY=indY+2
  end

  -- ── Multi-graphs ──────────────────────────────────────────
  local graphW = math.floor((W-8)/2) - 2
  local graphH = math.max(4, H - indY - 4)
  local g1x = 4;  local g1y = indY+1
  local g2x = g1x+graphW+4; local g2y = indY+1

  if graphH > 3 then
    miniGraph(g1x, g1y, graphW, graphH, tempHistory,
      math.max(SCRAM_TEMP, (tempHistory[#tempHistory] or 0)+50),
      0xFF4444, "TEMP (C)")
    if #waterHistory > 2 then
      miniGraph(g2x, g2y, graphW, graphH, waterHistory, 10000, 0x4488FF, "WATER (mB)")
    elseif #steamHistory > 2 then
      miniGraph(g2x, g2y, graphW, graphH, steamHistory, 2000, 0x00FFFF, "STEAM (/t)")
    end
  end

  -- Value readout strip at very bottom
  local vY = H-3
  gpu.setBackground(0x0a0a0a); gpu.fill(1,vY,W,1," ")
  gpu.setForeground(0x888888)
  local vals = string.format(
    "T:%dC  C:%dmB  W:%dmB  S:%d/t  R:%.0f%%",
    d.peakTemp, d.minCryo,
    d.boilerCount>0 and math.floor(d.totalWater/d.boilerCount) or 0,
    d.boilerCount>0 and math.floor(d.totalSteam/d.boilerCount) or 0,
    rodLevel*100
  )
  gpu.set(2, vY, vals:sub(1,W-4))
  gpu.setBackground(0x000000)
end


-- ── 7-segment display ────────────────────────────────────────
local SEG7 = {
  ["0"]={"###","# #","# #","# #","###"},
  ["1"]={" # "," # "," # "," # "," # "},
  ["2"]={"###","  #","###","#  ","###"},
  ["3"]={"###","  #","###","  #","###"},
  ["4"]={"# #","# #","###","  #","  #"},
  ["5"]={"###","#  ","###","  #","###"},
  ["6"]={"###","#  ","###","# #","###"},
  ["7"]={"###","  #","  #","  #","  #"},
  ["8"]={"###","# #","###","# #","###"},
  ["9"]={"###","# #","###","  #","###"},
  ["."]={"   ","   ","   ","   "," # "},
  ["%"]={"# #","  #"," # ","#  ","# #"},
  [" "]={"   ","   ","   ","   ","   "},
  ["-"]={"   ","   ","###","   ","   "},
}

local function draw7seg(x, y, str, col, bgcol)
  for ci=1,#str do
    local ch = str:sub(ci,ci)
    local glyph = SEG7[ch] or SEG7[" "]
    for row=1,5 do
      local line = glyph[row]
      for lc=1,3 do
        local pixel = line:sub(lc,lc)
        if pixel=="#" then
          gpu.setForeground(col); gpu.setBackground(0x000000)
          gpu.set(x+(ci-1)*4+(lc-1), y+row-1, "#")
        else
          gpu.setForeground(0x0a1a0a); gpu.setBackground(0x000000)
          gpu.set(x+(ci-1)*4+(lc-1), y+row-1, ".")
        end
      end
    end
  end
  gpu.setBackground(0x000000)
end

-- Single segment rotating clockwise: bottom→lower-right→upper-right→top→upper-left→lower-left
-- rows: top, upper-sides, mid, lower-sides, bottom
local SEG7_SWEEP = {
  {"   ","   ","   ","   ","###"},  -- 1: bottom
  {"   ","   ","   ","  #","   "},  -- 2: lower-right
  {"   ","  #","   ","   ","   "},  -- 3: upper-right
  {"###","   ","   ","   ","   "},  -- 4: top
  {"   ","#  ","   ","   ","   "},  -- 5: upper-left
  {"   ","   ","   ","#  ","   "},  -- 6: lower-left
}

local function draw7segSweep(x, y, numDigits, frame, col)
  local glyph = SEG7_SWEEP[((frame-1)%#SEG7_SWEEP)+1]
  local dimCol = 0x004400  -- dim green for off segments
  for ci=0,numDigits-1 do
    -- First draw all segments dim
    local allSegs = {
      {"   ","   ","   ","   ","###"},
      {"   ","   ","   ","  #","   "},
      {"   ","  #","   ","   ","   "},
      {"###","   ","   ","   ","   "},
      {"   ","#  ","   ","   ","   "},
      {"   ","   ","   ","#  ","   "},
    }
    for _,seg in ipairs(allSegs) do
      for row=1,5 do
        local line = seg[row]
        for lc=1,3 do
          if line:sub(lc,lc)=="#" then
            gpu.setForeground(dimCol)
            gpu.setBackground(0x000000)
            gpu.set(x+ci*4+(lc-1), y+row-1, "#")
          end
        end
      end
    end
    -- Draw active segment bright
    for row=1,5 do
      local line = glyph[row]
      for lc=1,3 do
        if line:sub(lc,lc)=="#" then
          gpu.setForeground(col)
          gpu.setBackground(0x000000)
          gpu.set(x+ci*4+(lc-1), y+row-1, "#")
        else
          gpu.setForeground(0x0a0a0a)
          gpu.setBackground(0x000000)
          gpu.set(x+ci*4+(lc-1), y+row-1, ".")
        end
      end
    end
  end
  gpu.setBackground(0x000000)
end

-- ── Fuel Depletion view ───────────────────────────────────────
local function drawFuelDepletion(W,H,cols,maxX,maxY,d)
  local row=2

  -- 7-segment rod level display
  px(2,row,0x555555,0x000000,"CONTROL ROD LEVEL"); row=row+1
  if #d.ctrlRods == 0 then
    -- No control rods - show sweep animation
    draw7segSweep(2, row, 6, seg7Anim, 0x88FF00)
    px(2,row+6,0xFF4444,0x000000,"[ NO RODS  ]")
  else
    local rodPct = string.format("%4.1f%%", rodLevel*100)
    local rodCol = rodLevel<0.3 and 0xFF4444 or (rodLevel<0.7 and 0xFFAA00 or 0x00FF88)
    draw7seg(2, row, rodPct, rodCol)
    px(2,row+6,0x334455,0x000000,"[  GLOBAL  ]")
  end

  -- Depletion list on right side
  local lx = 34
  px(lx,row,0xAAAAAA,0x000000,"FUEL DEPLETION REPORT"); 
  local lr = row+1

  local totalFuel=0; local totalEnr=0
  local depleted=0;  local critical=0

  -- Collect and sort fuels by depletion descending
  local fuelList = {}
  for _,f in ipairs(d.fuels) do
    local depl = (1 - f.enr) * 100
    table.insert(fuelList, {x=f.x,y=f.y,depl=depl,enr=f.enr*100,core=f.core,xen=f.xen})
    totalFuel=totalFuel+1; totalEnr=totalEnr+f.enr*100
    if depl>=90 then depleted=depleted+1 end
    if depl>=95 then critical=critical+1 end
  end
  table.sort(fuelList, function(a,b) return a.depl>b.depl end)

  for _,f in ipairs(fuelList) do
    if lr > H-5 then break end
    local col
    if f.depl>=90     then col=0xFF2222
    elseif f.depl>=70 then col=0xFF6600
    elseif f.depl>=50 then col=0xFF8800
    elseif f.depl>=30 then col=0xFFFF00
    else                   col=0x00FF88
    end
    -- Mini bar 15 chars
    local barF = math.floor(f.depl/100*15)
    local bar = string.rep("|",barF)..string.rep(".",15-barF)
    local xe = f.xen>50 and "!XE" or "   "
    local line = string.format("(%d,%d) %5.1f%% [%s] %4dC %s",
      f.x,f.y,f.depl,bar,f.core,xe)
    px(lx,lr,col,0x000000,line); lr=lr+1
  end

  -- Summary box
  lr=lr+1
  if lr<=H-5 then
    local avgDepl = totalFuel>0 and (100-(totalEnr/totalFuel)) or 0
    local sumCol = avgDepl>=70 and 0xFF4444 or (avgDepl>=40 and 0xFF8800 or 0x00FF88)
    gpu.setBackground(0x0a0a0a); gpu.fill(lx,lr,W-lx-1,1," ")
    px(lx,lr,0x888888,0x0a0a0a,string.format("Rods:%d Avg:%4.1f%% Spent:%d Crit:%d",
      totalFuel,avgDepl,depleted,critical))
    gpu.setBackground(0x000000); lr=lr+1
  end

  -- Second 7-seg: average depletion
  local avgDepl2 = totalFuel>0 and (100-(totalEnr/totalFuel)) or 0
  local seg2x = 2
  local seg2y = row+8
  if seg2y+5 < H-4 then
    px(seg2x,seg2y,0x555555,0x000000,"AVG DEPLETION")
    if totalFuel == 0 then
      draw7segSweep(seg2x, seg2y+1, 6, seg7Anim+3, 0x88FF00)
      px(seg2x,seg2y+7,0xFF4444,0x000000,"[ NO FUEL  ]")
    else
      local avgStr = string.format("%4.1f%%", avgDepl2)
      local avgCol = avgDepl2>=70 and 0xFF4444 or (avgDepl2>=40 and 0xFF8800 or 0x00FF88)
      draw7seg(seg2x, seg2y+1, avgStr, avgCol)
    end
  end

  -- Color legend
  local legY = H-4
  gpu.setBackground(0x0a0a0a); gpu.fill(1,legY,W,1," ")
  px(2,legY,0x00FF88,0x0a0a0a,"<30%=fresh ")
  px(14,legY,0xFFFF00,0x0a0a0a,"30-50%=ok ")
  px(24,legY,0xFF8800,0x0a0a0a,"50-70%=aging ")
  px(38,legY,0xFF6600,0x0a0a0a,"70-90%=worn ")
  px(51,legY,0xFF2222,0x0a0a0a,"90%+=spent")
  gpu.setBackground(0x000000)
end

-- ── Main draw ─────────────────────────────────────────────────
local function draw()
  local W,H=gpu.getResolution()
  if not W or not H then return end
  local storm=isStorming()
  if storm and not scrammed and stormScramEnabled then doScram("storm") end
  local cols,maxX,maxY=discoverGrid()
  local wx=getWeather()
  local d=collectData(cols,maxX,maxY)
  -- Sync rod level from actual hardware
  if rodSyncEnabled and #d.ctrlRods > 0 then
    local sum = 0
    for _,r in ipairs(d.ctrlRods) do sum = sum + r.lvl end
    local actual = sum / #d.ctrlRods
    if math.abs(actual - rodLevel) > 0.05 then
      writeLog(string.format("Rod sync: OC %.0f%% -> HBM %.0f%%", rodLevel*100, actual*100))
      rodLevel = actual
    end
  end
  updateRsOutput(d.peakTemp)
  local bgCol = analogMode and 0x000800 or 0x000000
  gpu.setBackground(bgCol); gpu.fill(1,1,W,H," ")
  -- Scanlines
  if scanlines then
    gpu.setBackground(0x000000)
    for sy=2,H-3,2 do gpu.fill(1,sy,W,1," ") end
    gpu.setBackground(bgCol)
  end
  drawHeader(W,wx,storm,viewMode)
  if     viewMode==1 then drawStats(W,H,cols,maxX,maxY,d)
  elseif viewMode==2 then drawGrid(W,H,cols,maxX,maxY)
  elseif viewMode==3 then drawCircle(W,H,cols,maxX,maxY,d)
  elseif viewMode==4 then drawGraph(W,H,d)
  elseif viewMode==5 then drawLogs(W,H)
  elseif viewMode==6 then
    if viewMode6Sub then drawGraphicsSettings(W,H)
    else drawSettings(W,H) end
  elseif viewMode==7 then drawGaugeDash(W,H,d)
  elseif viewMode==8 then drawFuelDepletion(W,H,cols,maxX,maxY,d)
  end
  drawFooter(W,H,scrammed,stormScram,d.peakTemp)
  -- Explosion detection
  local colCount=0
  for y=0,maxY do for x=0,maxX do if cols[y] and cols[y][x] then colCount=colCount+1 end end end
  if prevColCount>10 and colCount==0 then
    writeLog("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    writeLog("!!! REACTOR MAY HAVE EXPLODED !!!!")
    writeLog("!!! ALL COLUMNS LOST INSTANTLY !!!")
    writeLog("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
    if beepEnabled then for _=1,5 do computer.beep(2000,0.3); computer.beep(100,0.2) end end
  end
  if prevColCount>=0 and colCount~=prevColCount and prevColCount>0 then
    writeLog(string.format("REACTOR CHANGE: columns %d -> %d",prevColCount,colCount))
  end
  prevColCount=colCount
  local curTypes={}
  for y=0,maxY do for x=0,maxX do
    local col=cols[y] and cols[y][x]
    if col then
      local key=x..","..y; local newType=col.type or "?"
      if prevColTypes[key] and prevColTypes[key]~=newType then
        writeLog(string.format("Column (%d,%d) changed: %s -> %s",x,y,prevColTypes[key],newType))
      end
      curTypes[key]=newType
    end
  end end
  prevColTypes=curTypes
  if #tempHistory%10==0 and #tempHistory>0 then
    writeLog(string.format("Temp:%dC Cryo:%dmB Rods:%.0f%%",d.peakTemp,d.minCryo,rodLevel*100))
    if d.peakTemp>=WARN_TEMP then writeLog("WARNING: High temperature "..d.peakTemp.."C") end
  end
  table.insert(tempHistory,d.peakTemp)
  if #tempHistory>histMax then table.remove(tempHistory,1) end
  local avgW2=d.boilerCount>0 and math.floor(d.totalWater/d.boilerCount) or 0
  local avgS2=d.boilerCount>0 and math.floor(d.totalSteam/d.boilerCount) or 0
  table.insert(waterHistory, avgW2)
  table.insert(steamHistory, avgS2)
  table.insert(cryoHistory,  d.minCryo)
  if #waterHistory>histMax then table.remove(waterHistory,1) end
  if #steamHistory>histMax then table.remove(steamHistory,1) end
  if #cryoHistory>histMax  then table.remove(cryoHistory,1)  end
  -- Power gauge history
  if gaugeEnabled and pwrG then
    local ok,info=pcall(pwrG.getInfo)
    local pval=0
    if ok and type(info)=="table" then pval=info.stored or info.energy or 0 end
    table.insert(powerHistory, pval)
    if #powerHistory>histMax then table.remove(powerHistory,1) end
  end
  if #tempHistory>=6 then
    local n=tempHistory; local sz=#n
    local win=math.min(20,sz)
    local peakVal,valleyVal=-1,99999
    local peakIdx,valleyIdx=sz,sz
    for i=sz-win+1,sz do
      if n[i]>peakVal then peakVal=n[i]; peakIdx=i end
      if n[i]<valleyVal then valleyVal=n[i]; valleyIdx=i end
    end
    local cur=n[sz]; local old=n[sz-win+1]
    if peakVal-old>40 and peakVal-cur>40 and peakIdx<sz then tempStatus=3
    elseif old-valleyVal>40 and cur-valleyVal>40 and valleyIdx<sz then tempStatus=3
    elseif cur-old>15 then tempStatus=1
    elseif cur-old<-15 then tempStatus=2
    end
  end
  seg7Anim = seg7Anim + 3
  local now=computer.uptime()
  if now-lastFact>FACT_TIMER then factIndex=(factIndex%#FACTS)+1; lastFact=now end
end

-- ── Intro ─────────────────────────────────────────────────────
local function runIntro()
  local IW,IH=gpu.getResolution()
  if not IW or not IH then return end
  local NICKLY={
    "#   #  ###   #### #   # #     #   #",
    "##  #  ###  #     #  #  #     #   #",
    "### #   #   #     # #   #      # # ",
    "# # #   #   #     ###   #      # # ",
    "#  ##   #   #     # #   #       #  ",
    "#   #  ###  #     #  #  #       #  ",
    "#   #  ###   #### #   # #####   #  ",
  }
  local ICON={
    "              ",
    "   #####      ",
    " ####   ####  ",
    " ####     ##  ",
    " ##        ## ",
    "        ##### ",
    "      #####   ",
  }
  local SUFFER={
    "#### #   # ##### ##### ##### #### ",
    "#    #   # #     #     #     #   #",
    "#    #   # #     #     #     #   #",
    " ### #   # ####  ####  ####  #### ",
    "   # #   # #     #     #     # #  ",
    "   # #   # #     #     #     #  # ",
    "####  ###  #     #     ##### #   #",
  }
  local lh=7; local iw=#ICON[1]; local nw=#NICKLY[1]; local sw=#SUFFER[1]
  local ox=math.max(1,math.floor((IW-math.max(nw,iw+2+sw))/2))
  local ny=math.max(2,math.floor(IH/2)-8); local sy2=ny+lh+2
  local credit  ="Made by azrailmaffay"
  local inspired="Inspired by nicklysuffer"
  local cx =math.floor((IW-#credit)/2)
  local cx2=math.floor((IW-#inspired)/2)
  local cry=sy2+lh+2
  gpu.setBackground(0x000000); gpu.fill(1,1,IW,IH," ")
  os.sleep(1)
  gpu.setForeground(0x00FF88)
  for i,line in ipairs(NICKLY) do gpu.set(ox,ny+i-1,line) end
  for i=1,lh do
    gpu.set(ox,      sy2+i-1, ICON[i])
    gpu.set(ox+iw+2, sy2+i-1, SUFFER[i])
  end
  os.sleep(1)
  gpu.setForeground(0x888888); gpu.set(cx,  cry,   credit)
  gpu.setForeground(0x555555); gpu.set(cx2, cry+1, inspired)
  os.sleep(1.5)
  for y=ny,cry+1 do gpu.fill(1,y,IW,1," "); os.sleep(0.04) end
end

-- ── Startup ───────────────────────────────────────────────────
local function fixResolution()
  local mW,mH=gpu.maxResolution(); local cW,cH=gpu.getResolution()
  if cW~=mW or cH~=mH then gpu.setResolution(mW,mH) end
end
fixResolution()
initLog()
runIntro()

-- ── Main loop ─────────────────────────────────────────────────
while true do
  draw()
  local e,_,char,code=event.pull(REFRESH,"key_down")
  if e=="key_down" and char and char>0 then
    local _,H=gpu.getResolution()
    local k=string.char(char):lower()
    if     k=="s" then doScram("manual")
    elseif k=="," then setRods(rodLevel-0.1)
    elseif k=="." then setRods(rodLevel+0.1)
    elseif k=="r" then scrammed=false; stormScram=false; writeLog("SCRAM reset by operator")
    elseif k=="1" then viewMode=1
    elseif k=="2" then viewMode=2
    elseif k=="3" then viewMode=3
    elseif k=="4" then viewMode=4
    elseif k=="5" then viewMode=5
    elseif k=="6" then prevView=viewMode; viewMode=6
    elseif k=="7" then viewMode=7
    elseif k=="8" then viewMode=8
    elseif k==" " and viewMode==6 then
      if viewMode6Sub then viewMode6Sub=false
      else viewMode=prevView end
    elseif k=="t" and viewMode==6 then stormScramEnabled=not stormScramEnabled
    elseif k=="y" and viewMode==6 then autoTempScram=not autoTempScram
    elseif k=="b" and viewMode==6 then beepEnabled=not beepEnabled
    elseif k=="w" and viewMode==6 then weatherEnabled=not weatherEnabled
    elseif k=="h" and viewMode==6 then rodSyncEnabled=not rodSyncEnabled; writeLog("Rod sync "..(rodSyncEnabled and "enabled" or "disabled"))
    elseif k=="i" and viewMode==6 then rsioEnabled=not rsioEnabled; writeLog("RSIO "..(rsioEnabled and "enabled" or "disabled"))
    elseif k=="n" and viewMode==6 then gaugeEnabled=not gaugeEnabled; writeLog("Gauges "..(gaugeEnabled and "enabled" or "disabled"))
    elseif k=="i" and viewMode==6 then rsInputEnabled=not rsInputEnabled; writeLog("RS input "..(rsInputEnabled and "enabled" or "disabled"))
    elseif k=="u" and viewMode==6 then rsInputMode=(rsInputMode%2)+1
    elseif k=="m" and viewMode==6 then rsInputSide=(rsInputSide-1)%6
    elseif k=="n" and viewMode==6 then rsInputSide=(rsInputSide+1)%6
    elseif k=="e" and viewMode==6 then rsEnabled=not rsEnabled
    elseif k=="o" and viewMode==6 then rsOutEnabled=not rsOutEnabled
    elseif k=="[" and viewMode==6 then rsOutThreshold=math.max(100,rsOutThreshold-50)
    elseif k=="]" and viewMode==6 then rsOutThreshold=math.min(1200,rsOutThreshold+50)
    elseif k==";" and viewMode==6 then rsOutSide=(rsOutSide-1)%6
    elseif k=="'" and viewMode==6 then rsOutSide=(rsOutSide+1)%6
    elseif k=="g" and viewMode==6 and not viewMode6Sub then viewMode6Sub=true
    elseif k=="a" and viewMode==6 and viewMode6Sub then analogMode=not analogMode; writeLog("Analog mode "..(analogMode and "ON" or "OFF"))
    elseif k=="l" and viewMode==6 and viewMode6Sub then scanlines=not scanlines
    elseif k=="d" and viewMode==6 and viewMode6Sub then dimBackground=not dimBackground
    elseif k=="<" and viewMode==6 then rsViewSide=(rsViewSide-1)%6
    elseif k==">" and viewMode==6 then rsViewSide=(rsViewSide+1)%6
    elseif viewMode==5 and k=="j" then logScroll=math.min(logScroll+1,math.max(0,#logLines-(H-4)))
    elseif viewMode==5 and k=="k" then logScroll=math.max(logScroll-1,0)
    elseif viewMode==5 and k=="g" then logScroll=0
    elseif viewMode==5 and k=="G" then logScroll=math.max(0,#logLines-(H-4))
    elseif k=="\t" or code==15 then viewMode=(viewMode%8)+1
    elseif k=="q" then
      closeLog()
      gpu.setBackground(0x000000); local W2,H2=gpu.getResolution(); gpu.fill(1,1,W2,H2," ")
      gpu.setForeground(0xFFFFFF); out("Closed.\n"); return
    end
  end
end
end

  local function launchRbmk()
    local ok, err = pcall(rbmkApp)
    if not ok then
      klog("RBMK app error: " .. tostring(err))
      cls()
      color(BG, RED)
      gpu.set(2, 2, "RBMK application error")
      color(BG, FG)
      gpu.set(2, 4, unicode.sub(tostring(err), 1, math.max(1, W - 4)))
      bar(H, "Press any key to return", GRAY, BLACK)
      waitKey()
      cls()
    end
  end
  def("rbmk", "rbmk", "Launch the RBMK reactor control console", launchRbmk,
    "Open the RBMK control dashboard. Press Q in the dashboard to return.")
  local ICONS = {
    { name = "ME Storage", box = 0x2060A0, glyph = "ME" },
    { name = "Settings",   box = GRAY,     glyph = "SET" },
    { name = "Notepad",    box = 0xFFFFC0, glyph = "NP" },
    { name = "Terminal",   box = 0x000000, glyph = ">_", fg = 0x00FF00 },
    { name = "RBMK Console", box = 0x802020, glyph = "RBMK", fg = 0xFFFFFF },
  }

  local MENU_ITEMS = { "ME Storage", "RBMK Console", "Settings", "Notepad", "Terminal", "Reboot", "Shut Down" }

  -- Popup menu anchored above the Start button, bottom-left, like classic
  -- ReactOS/Windows. Returns the chosen item's index, or nil if dismissed.
  local function startMenu()
    local mw = 16
    local mh = #MENU_ITEMS + 1
    local mx, my = 1, H - mh - 1
    color(GRAY, BLACK)
    gpu.fill(mx, my, mw, mh, " ")
    gpu.set(mx + 1, my, unicode.sub("ReactOS-OC", 1, mw - 2))
    local hit = {}
    for i, it in ipairs(MENU_ITEMS) do
      local y = my + i
      gpu.set(mx + 1, y, unicode.sub(it, 1, mw - 2))
      hit[#hit + 1] = { mx, y, mx + mw - 1, y, i }
    end
    color(BG, FG)
    while true do
      local kind, a, b = waitInput()
      if kind == "touch" then
        local x, y = a, b
        for _, r in ipairs(hit) do
          if x >= r[1] and x <= r[3] and y == r[2] then return r[5] end
        end
        if not (x >= mx and x <= mx + mw - 1 and y >= my and y <= my + mh - 1) then return nil end
      elseif kind == "key" then
        if a == 27 or b == 1 then return nil end
        local n = tonumber(unicode.char(a or 0))
        if n and MENU_ITEMS[n] then return n end
      end
    end
  end

  local function desktopApp()
    local hits, startBtn, done = {}, nil, false
    local function draw()
      cls()
      bar(1, "ReactOS Desktop", GRAY, BLACK)
      hits = {}
      local bx, by, bw, bh, gapX, gapY = 3, 3, 12, 3, 4, 2
      local rows = math.max(1, math.floor((H - by - 1) / (bh + gapY + 1)))
      for i, ic in ipairs(ICONS) do
        local col = math.floor((i - 1) / rows)
        local row = (i - 1) % rows
        local ix, iy = bx + col * (bw + gapX), by + row * (bh + gapY)
        gpu.setBackground(ic.box)
        gpu.setForeground(ic.fg or ((luma(ic.box) > 150) and BLACK or 0xFFFFFF))
        gpu.fill(ix, iy, bw, bh, " ")
        gpu.set(ix + math.max(0, math.floor((bw - unicode.len(ic.glyph)) / 2)), iy + 1, ic.glyph)
        color(BG, FG)
        gpu.set(ix, iy + bh, pad(ic.name, bw))
        hits[#hits + 1] = { ix, iy, ix + bw - 1, iy + bh - 1, i }
      end
      -- Taskbar with the real ReactOS logo as a Start button, bottom-left.
      color(GRAY, BLACK)
      gpu.fill(1, H, W, 1, " ")
      local sw = math.min(10, math.max(6, W - 4))
      drawImg(logoData, LOGO_W, LOGO_H, 1, H, sw, 1)
      startBtn = { 1, H, sw, H }
      color(GRAY, BLACK)
      gpu.set(sw + 2, H, unicode.sub("Start", 1, math.max(0, W - sw - 12)))
      gpu.set(math.max(sw + 10, W - 17), H, os.date("%H:%M"))
      color(BG, FG)
    end
    draw()
    while not done do
      local kind, a, b = waitInput()
      local idx, fromMenu
      if kind == "touch" then
        if a >= startBtn[1] and a <= startBtn[3] and b == startBtn[4] then
          idx = startMenu()
          fromMenu = true
          draw()
        else
          for _, r in ipairs(hits) do
            if a >= r[1] and a <= r[3] and b >= r[2] and b <= r[4] then idx = r[5]; break end
          end
        end
      elseif kind == "key" then
        if a == 27 or b == 1 then done = true
        elseif a == 32 or a == 13 then     -- space/enter also opens the Start menu
          idx = startMenu()
          fromMenu = true
          draw()
        else
          local n = tonumber(unicode.char(a or 0))
          if n and ICONS[n] then idx = n end
        end
      end
      if idx == 1 then sharedMeApp(""); draw()
      elseif (fromMenu and idx == 2) or (not fromMenu and idx == 5) then launchRbmk(); draw()
      elseif (fromMenu and idx == 3) or (not fromMenu and idx == 2) then settingsApp(); draw()
      elseif (fromMenu and idx == 4) or (not fromMenu and idx == 3) then notepadApp(); draw()
      elseif (fromMenu and idx == 5) or (not fromMenu and idx == 4) then done = true
      elseif fromMenu and idx == 6 then computer.shutdown(true)
      elseif fromMenu and idx == 7 then computer.shutdown() end
    end
    cls()
  end

  def("desktop|gui", "desktop", "Launch the touch/click graphical desktop", desktopApp,
    "Click (or physically tap, on a touch-capable screen) an icon:\n"
    .. "  ME Storage - the AE2 storage viewer\n"
    .. "  Settings   - tap a color swatch to recolor the whole UI (saved permanently)\n"
    .. "  Notepad    - the built-in text editor, opened on a file you name\n"
    .. "  Terminal   - closes the desktop and returns to this command line\n"
    .. "  RBMK Console - opens the reactor control dashboard.\n"
    .. "The ReactOS logo bottom-left is the Start button: click/tap it (or press\n"
    .. "Space/Enter) for a menu with the same apps plus Reboot and Shut Down.\n"
    .. "Keyboard also works: digits 1-5 launch an icon, Esc exits.\n"
    .. "Add a 'desktop' line to C:\\System32\\startup.cmd to boot straight into it.")
end

------------------------------------------------------------------
-- 16. API for programs / services, boot sequence, shell
------------------------------------------------------------------
ROS.version, ROS.out, ROS.readline, ROS.cls, ROS.color = VERSION, out, readline, cls, color
ROS.resolve, ROS.read, ROS.write, ROS.pull, ROS.env = resolve, fsRead, fsWrite, pull, ENV

local LOGO = {
  [[        .-~~~~~~~~~~-.        ]],
  [[     .-'   .-~~~~-.   '-.     ]],
  [[   .'    .'  .--.  '.    '.   ]],
  [[  /    .'   /    \   '.    \  ]],
  [[ |   .'    |  ()  |    '.   | ]],
  [[  \    '.   \    /   .'    /  ]],
  [[   '.    '.  '--'  .'    .'   ]],
  [[     '-.   '-....-'   .-'     ]],
  [[        '-..........-'        ]],
}

local function resetScreen()
  if not gpu then return end
  pcall(function()
    if origW then gpu.setResolution(origW, origH) end
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    local w, h = gpu.getResolution()
    gpu.fill(1, 1, w, h, " ")
  end)
end

local function restore()
  if HOSTED and gpu then
    resetScreen()
    pcall(function() require("term").clear() end)
  end
end

local function canOpenOS()
  return (not HOSTED) and drives.C and fsExists(drives.C, BACKUP)
end

local function fatal(msg)
  if HOSTED then
    restore()
    error("STOP: " .. msg, 0)
  end
  pcall(computer.beep, 400, 0.4)
  if gpu then
    color(BLACK, RED)
    gpu.fill(1, 1, W, H, " ")
    gpu.set(2, 2, "*** STOP: " .. unicode.sub(msg, 1, W - 12))
    gpu.set(2, 4, "System halted.")
    gpu.set(2, 6, canOpenOS() and "Press O to boot OpenOS, R to reboot." or "Press R to reboot.")
  end
  while true do
    local e, _, ch = pull()
    if e == "key_down" then
      if ch == 114 or ch == 82 then computer.shutdown(true) end
      if (ch == 111 or ch == 79) and canOpenOS() then wantOS = true; error("chain", 0) end
    end
  end
end

local function boot()
  local g, s, k = first("gpu"), first("screen"), first("keyboard")
  if not g then fatal("No GPU detected") end
  if not s then fatal("No screen detected") end
  if not k then fatal("No keyboard detected") end
  gpu = component.proxy(g)
  if not HOSTED or not gpu.getScreen() then gpu.bind(s) end
  origW, origH = gpu.getResolution()
  local mw, mh = gpu.maxResolution()
  W, H = math.min(mw, 80), math.min(mh, 25)
  gpu.setResolution(W, H)
  cls()

  local top = math.max(1, math.floor((H - #LOGO - 9) / 2) + 1)
  color(BG, CYAN)
  for i, l in ipairs(LOGO) do center(top + i - 1, l) end
  local ty = top + #LOGO + 1
  color(BG, FG)
  center(ty, "R e a c t O S")
  color(BG, GRAY)
  center(ty + 1, VERSION)

  local bw = math.min(40, W - 6)
  local bx = math.floor((W - bw) / 2) + 1
  local by = ty + 4
  color(BG, FG)
  center(by - 1, "ReactOS loading...")
  color(GRAY, GRAY)
  gpu.fill(bx - 1, by, bw + 2, 3, " ")
  color(BLACK, BLACK)
  gpu.fill(bx, by + 1, bw, 1, " ")

  local canOS = canOpenOS()
  if canOS then
    color(BG, GRAY)
    center(H, "Press O to boot OpenOS instead")
  end

  local steps = { "Checking GPU", "Checking screen", "Checking keyboard", "Mounting drives", "Scanning for ME network", "Starting shell" }
  local goOS = false
  for i, label in ipairs(steps) do
    color(BG, GRAY)
    gpu.fill(1, by + 4, W, 1, " ")
    center(by + 4, label .. "...")
    klog(label)
    if i == 5 then
      meType = (first("me_controller") and "me_controller") or (first("me_interface") and "me_interface") or nil
    end
    color(GREEN, GREEN)
    gpu.fill(bx, by + 1, math.floor(bw * i / #steps), 1, " ")
    local e, _, ch = pull(0.3)
    if e == "key_down" and canOS and (ch == 111 or ch == 79) then goOS = true; break end
  end
  if goOS then return true end

  color(BG, meType and GREEN or RED)
  gpu.fill(1, by + 4, W, 1, " ")
  center(by + 4, meType and ("ME network found: " .. meType) or "ME network not found")
  pull(0.6)
  cls()
  return false
end

local function prompt()
  local p = cwds[curDrive] or "/"
  local s = curDrive .. ":" .. (p == "/" and "\\" or (p:gsub("/", "\\")))
  local lim = math.floor(W / 2)
  if #s > lim then s = curDrive .. ":\\..." .. s:sub(-(lim - 6)) end
  return s .. ">"
end

local function startup()
  cfgLoad()
  for n in (cfg.services or ""):gmatch("[^,]+") do
    local ok, e = svcStart(n)
    if not ok then
      color(BG, RED)
      out("rc: " .. n .. ": " .. tostring(e) .. "\n")
      color(BG, FG)
    end
  end
  if drives.C and fsExists(drives.C, CFGDIR .. "/startup.cmd") then
    execScript(drives.C, CFGDIR .. "/startup.cmd")
  end
end

local function shell()
  out(VERSION .. "\n(C) ReactOS-OC. Type 'help' for a list of commands.\n")
  if meType then
    color(BG, GREEN); out("ME network: " .. meType .. " detected.\n")
  else
    color(BG, RED);   out("ME network: not detected.\n")
  end
  color(BG, FG)
  out("\n")
  startup()
  while not quitShell do
    out(prompt())
    local line = trim(readline())
    if line ~= "" then
      runLine(line)
      gc()
    end
  end
end

------------------------------------------------------------------
-- 17. Kernel entry
------------------------------------------------------------------
-- Command-line use inside OpenOS:  <file> install | <file> uninstall
if HOSTED and ARGS[1] then
  local c = ARGS[1]:lower()
  if c == "install" or c == "uninstall" then
    local ok, err
    if c == "install" then ok, err = doInstall(print, ARGS[2], ARGS[3])
    else ok, err = doUninstall(print, ARGS[2]) end
    if not ok then print("Failed: " .. tostring(err)) end
  else
    print("Usage: <this file> [install [drive] [file] | uninstall [drive]]")
  end
  return nil
end

local ok, err = pcall(function()
  if boot() then wantOS = true else shell() end
end)

if HOSTED then
  restore()
  if not ok and tostring(err) ~= "interrupted" then error(err, 0) end
  return nil
end

if not ok and not wantOS then pcall(fatal, tostring(err)) end
if wantOS then
  resetScreen()
  return "openos"
end
return nil
end -- main

local action = main({ ... })
main = nil

-- Hand over to the backed-up OpenOS boot program (bare mode only).
if action == "openos" then
  local a = computer.getBootAddress()
  local h = component.invoke(a, "open", BACKUP)
  local t = {}
  while true do
    local c = component.invoke(a, "read", h, math.huge)
    if not c or c == "" then break end
    t[#t + 1] = c
  end
  component.invoke(a, "close", h)
  local f = assert(load(table.concat(t), "=init", "t", _ENV))
  f()
  computer.shutdown(true)
end