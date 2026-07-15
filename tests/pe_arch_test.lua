-- Checks the installer's PE-header arch reader against the real bundled DLLs.
--
-- This exists because we have no Windows machine. The reader is pure Lua and
-- the DLLs are right there in the package, so the one Windows-specific piece of
-- logic in the installer can be proven here rather than hoped about. It cannot
-- tell us REAPER loads the DLL — only that we identify it correctly.
--
--   lua tests/pe_arch_test.lua

local HERE = arg[0]:match("(.*)/[^/]+$") or "."
local PKG = HERE .. "/.."
local EXT = PKG .. "/extensions"

local failures = 0
local checks = 0

local function check(what, got, want)
  checks = checks + 1
  if got == want then
    print(string.format("  ok    %-52s %s", what, tostring(got)))
  else
    failures = failures + 1
    print(string.format("  FAIL  %-52s got %s, want %s", what, tostring(got), tostring(want)))
  end
end

-- The reader, lifted verbatim from steelblue_install.lua. Keeping a copy would
-- let the two drift, so pull the real source and evaluate just that function.
local function load_pe_arch()
  local f = assert(io.open(PKG .. "/steelblue_install.lua", "r"))
  local src = f:read("a")
  f:close()

  local body = src:match("(local PE_MACHINES.-\nend)\n")
  assert(body, "could not find pe_arch in steelblue_install.lua -- did it get renamed?")

  local chunk = assert(load(body .. "\nreturn pe_arch"))
  return chunk()
end

local pe_arch = load_pe_arch()

print("PE arch reader")
print("")

-- The real thing: every DLL we ship, identified from its header alone.
check("reaper_imgui-x64.dll",          pe_arch(EXT .. "/Windows/reaper_imgui-x64.dll"),          "x64")
check("reaper_imgui-x86.dll",          pe_arch(EXT .. "/Windows/reaper_imgui-x86.dll"),          "x86")
check("reaper_js_ReaScriptAPI64.dll",  pe_arch(EXT .. "/Windows/reaper_js_ReaScriptAPI64.dll"),  "x64")
check("reaper_js_ReaScriptAPI32.dll",  pe_arch(EXT .. "/Windows/reaper_js_ReaScriptAPI32.dll"),  "x86")

print("")

-- Everything below must return nil. nil means "I cannot tell", and the installer
-- treats that as permission to continue -- so a false *positive* here would be
-- the dangerous bug: it would reject a file that was perfectly fine.
check("a Mach-O dylib is not a PE",    pe_arch(EXT .. "/macOS/reaper_imgui-arm64.dylib"),        nil)
check("a text file is not a PE",       pe_arch(PKG .. "/steelblue_install.lua"),                 nil)
check("a file that does not exist",    pe_arch(PKG .. "/nope.dll"),                              nil)

-- Truncated and malformed input: the reader indexes at fixed offsets, so these
-- are exactly where an out-of-range read would throw instead of returning nil.
local tmp = os.tmpname()
local function write_bytes(s)
  local f = assert(io.open(tmp, "wb"))
  f:write(s)
  f:close()
  return tmp
end

check("empty file",                    pe_arch(write_bytes("")),                                 nil)
check("'MZ' and nothing else",         pe_arch(write_bytes("MZ")),                               nil)
check("MZ header, no PE behind it",    pe_arch(write_bytes("MZ" .. string.rep("\0", 62))),       nil)
check("PE offset points past the end", pe_arch(write_bytes("MZ" .. string.rep("\0", 58) ..
                                                           "\255\255\255\127" .. "\0\0")),       nil)
check("PE signature but truncated",    pe_arch(write_bytes("MZ" .. string.rep("\0", 58) ..
                                                           "\64\0\0\0" .. "PE\0\0")),            nil)
check("valid PE, unknown machine",     pe_arch(write_bytes("MZ" .. string.rep("\0", 58) ..
                                                           "\64\0\0\0" .. "PE\0\0" .. "\1\1")),  nil)

-- A well-formed PE body behind something that is NOT an MZ stub. Every other
-- malformed case above is caught by the "PE\0\0" check whether or not we look
-- for "MZ", so without this one the MZ check could be deleted and the suite
-- would still pass -- verified by mutation, it did exactly that.
check("PE body but no MZ stub",        pe_arch(write_bytes("XX" .. string.rep("\0", 58) ..
                                                           "\64\0\0\0" .. "PE\0\0" .. "\100\134")), nil)
os.remove(tmp)

print("")
if failures == 0 then
  print(string.format("all %d checks passed", checks))
  os.exit(0)
else
  print(string.format("%d of %d checks FAILED", failures, checks))
  os.exit(1)
end
