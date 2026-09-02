-- Exercise steelblue_boot.lua against a fake REAPER.
--
-- The fake says "no" by default: APIExists only answers true for names the
-- scenario put there, and the JS_* functions only exist when the scenario says
-- so. A fake that agrees with everything would prove nothing.

local folder = ((arg[0]:match("(.*/)") or "./").."../")..""

local IMGUI_NAMES = { "ImGui_CreateContext", "ImGui_DestroyContext" }
local JS_NAMES = {
  "JS_Localize",
  "JS_Window_ArrayFind",
  "JS_Window_HandleFromAddress",
  "JS_Window_FindChildByID",
  "JS_ListView_ListAllSelItems",
  "JS_ListView_GetItemText",
  "new_array",
}

local scenario = {}
local boxes = {}
local destroyed = {}

local function build_reaper()
  local present = {}
  if scenario.imgui ~= false then
    for _, name in ipairs(IMGUI_NAMES) do
      present[name] = true
    end
  end

  local r = {}

  r.ShowMessageBox = function(message, title, kind)
    boxes[#boxes + 1] = { message = message, title = title, kind = kind }
    return 1
  end

  -- an ancient REAPER has no APIExists at all
  if not scenario.no_api_exists then
    r.APIExists = function(name)
      return present[name] == true
    end
  end

  if scenario.imgui ~= false then
    r.ImGui_CreateContext = function(title) return "ctx:" .. title end
    r.ImGui_DestroyContext = function(ctx) destroyed[#destroyed + 1] = ctx end
  end

  if scenario.js ~= false then
    for _, name in ipairs(JS_NAMES) do
      r[name] = function() end
    end
  end

  return r
end

local fails = 0

local function run(name, setup, fn)
  scenario = setup
  boxes = {}
  destroyed = {}
  reaper = build_reaper()

  local BOOT = dofile(folder .. "steelblue_boot.lua")
  local ok, detail = fn(BOOT)
  if not ok then
    fails = fails + 1
  end
  print(string.format("%-46s %s%s", name, ok and "PASS" or "FAIL", detail and ("  -- " .. detail) or ""))
end

print("steelblue_boot.lua behaviour:\n")

-- ------------------------------------------------------- check_dependencies

run("both extensions there: ok, no message box", { imgui = true, js = true }, function(BOOT)
  local ok, missing = BOOT.check_dependencies({
    title = "Copy Markers", imgui = "required", js = "optional",
    js_cost = "the click order is lost.",
  })
  if not ok then return false, "ok was false" end
  if #missing ~= 0 then return false, #missing .. " reported missing" end
  return #boxes == 0, #boxes .. " boxes"
end)

run("required ReaImGui missing: not ok, one box", { imgui = false, js = true }, function(BOOT)
  local ok = BOOT.check_dependencies({ title = "Live BPM Analyzer", imgui = "required" })
  if ok then return false, "ok was true although ReaImGui is required" end
  if #boxes ~= 1 then return false, #boxes .. " boxes" end
  if not boxes[1].message:find("ReaImGui (required)", 1, true) then
    return false, "box does not name the required extension"
  end
  return true, "refuses and says why"
end)

-- the exact wording is part of the deliverable, so it is asserted whole
run("the required message reads exactly as specified", { imgui = false, js = true }, function(BOOT)
  BOOT.check_dependencies({ title = "Live BPM Analyzer", imgui = "required" })
  local want =
    "Live BPM Analyzer is missing a REAPER extension.\n\n" ..
    "ReaImGui (required): without it this plugin cannot open its window.\n" ..
    "\nRun steelblue_install.lua from the package to install what is missing, then restart REAPER."
  if boxes[1].message ~= want then
    return false, "got:\n" .. boxes[1].message
  end
  if boxes[1].title ~= "Live BPM Analyzer" then return false, "title=" .. tostring(boxes[1].title) end
  return boxes[1].kind == 0, "type=" .. tostring(boxes[1].kind)
end)

run("optional JS missing: still ok, box names the cost", { imgui = true, js = false }, function(BOOT)
  local ok, missing = BOOT.check_dependencies({
    title = "Rename selected markers", imgui = "required", js = "optional",
    js_cost = "cues are numbered by position, not by the order you clicked.",
  })
  if not ok then return false, "an optional extension must not block the plugin" end
  if #boxes ~= 1 then return false, #boxes .. " boxes" end
  if not boxes[1].message:find("cues are numbered by position", 1, true) then
    return false, "box does not say what it costs"
  end
  if boxes[1].message:find("ReaImGui", 1, true) then
    return false, "box mentions ReaImGui, which is installed"
  end
  if #missing ~= 1 or missing[1].name ~= "JS_ReaScriptAPI" then
    return false, "missing list is wrong"
  end
  return true, "runs, but says what it loses"
end)

run("both missing: exactly one box, both lines", { imgui = false, js = false }, function(BOOT)
  local ok = BOOT.check_dependencies({
    title = "Rename selected markers", imgui = "required", js = "required",
  })
  if ok then return false, "ok was true" end
  if #boxes ~= 1 then return false, #boxes .. " boxes -- two dialogs read as a crash" end
  local message = boxes[1].message
  if not message:find("ReaImGui (required)", 1, true) then return false, "no ReaImGui line" end
  if not message:find("JS_ReaScriptAPI (required)", 1, true) then return false, "no JS line" end
  return true, "one box, two lines"
end)

run("unchecked extension is never mentioned", { imgui = true, js = false }, function(BOOT)
  local ok = BOOT.check_dependencies({ title = "Copy Markers", imgui = "required" })
  return ok and #boxes == 0, #boxes .. " boxes, ok=" .. tostring(ok)
end)

-- ------------------------------------------------------------ ImGui helpers

run("has_imgui: yes when the API is there", { imgui = true, js = true }, function(BOOT)
  return BOOT.has_imgui() and true or false, "APIExists says yes"
end)

run("has_imgui: no when ReaImGui is absent", { imgui = false, js = true }, function(BOOT)
  return not BOOT.has_imgui(), "APIExists says no"
end)

run("has_imgui: no on a REAPER without APIExists", { no_api_exists = true }, function(BOOT)
  return not BOOT.has_imgui(), "no APIExists at all"
end)

run("create/destroy context round trip", { imgui = true, js = true }, function(BOOT)
  local ctx = BOOT.create_context("Copy Markers")
  if ctx ~= "ctx:Copy Markers" then return false, tostring(ctx) end
  BOOT.destroy_context(ctx)
  return #destroyed == 1 and destroyed[1] == ctx, #destroyed .. " destroyed"
end)

run("destroy_context is guarded, not a crash", { imgui = false, js = true }, function(BOOT)
  BOOT.destroy_context("ctx")
  BOOT.destroy_context(nil)
  return #destroyed == 0, "nothing destroyed, nothing thrown"
end)

-- ---------------------------------------------------------------- modules

run("load_module: missing file gives a sentence", { imgui = true, js = true }, function(BOOT)
  local module = BOOT.load_module(folder, "steelblue_not_here.lua", "Copy Markers")
  if module ~= nil then return false, "returned something" end
  if #boxes ~= 1 then return false, #boxes .. " boxes" end
  local want =
    "steelblue_not_here.lua is missing next to this script.\n\n" ..
    "Please copy the whole steelblue package into the same folder."
  if boxes[1].message ~= want then return false, "got:\n" .. boxes[1].message end
  return boxes[1].title == "Copy Markers", "title=" .. tostring(boxes[1].title)
end)

run("load_module: loads a real module", { imgui = true, js = true }, function(BOOT)
  local MA = BOOT.load_module(folder, "steelblue_matools.lua", "Copy Markers")
  if type(MA) ~= "table" then return false, "type=" .. type(MA) end
  if #boxes ~= 0 then return false, "complained about a file that is there" end
  return MA.VERSION ~= nil, "steelblue_matools.lua " .. tostring(MA.VERSION)
end)

print(fails == 0 and "\nALL PASS" or ("\nFAILURES: " .. fails))
os.exit(fails == 0 and 0 or 1)
