--- Pure Lua parser and format-preserving updater for Valve KeyValues (.acf / .vdf).
--- Handles libraryfolders.vdf and appmanifest_<appid>.acf without losing Steam's
--- exact formatting or untouched sections.

local M = {}

local function unescape_vdf(s)
  return (s:gsub("\\\\", "\\"):gsub('\\"', '"'))
end

local function escape_vdf(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

--- Parse a text VDF / ACF string into a nested Lua table.
---@param text string
---@return table
function M.parse(text)
  if type(text) ~= "string" then return {} end
  local len = #text
  local pos = 1

  local function skip_ws()
    while pos <= len do
      local c = text:sub(pos, pos)
      if c == " " or c == "\t" or c == "\r" or c == "\n" then
        pos = pos + 1
      elseif c == "/" and text:sub(pos + 1, pos + 1) == "/" then
        local nl = text:find("\n", pos + 2, true)
        pos = nl and (nl + 1) or (len + 1)
      else
        break
      end
    end
  end

  local function read_token()
    skip_ws()
    if pos > len then return nil end
    local c = text:sub(pos, pos)
    if c == "{" or c == "}" then
      pos = pos + 1
      return c, "brace"
    end
    if c == '"' then
      pos = pos + 1
      local out = {}
      while pos <= len do
        local ch = text:sub(pos, pos)
        if ch == "\\" and pos < len then
          out[#out + 1] = text:sub(pos + 1, pos + 1)
          pos = pos + 2
        elseif ch == '"' then
          pos = pos + 1
          return table.concat(out), "string"
        else
          out[#out + 1] = ch
          pos = pos + 1
        end
      end
      return table.concat(out), "string"
    end
    -- Unquoted token
    local start = pos
    while pos <= len do
      local ch = text:sub(pos, pos)
      if ch == " " or ch == "\t" or ch == "\r" or ch == "\n" or ch == "{" or ch == "}" or ch == '"' then
        break
      end
      pos = pos + 1
    end
    return text:sub(start, pos - 1), "string"
  end

  local function parse_block()
    local tbl = {}
    while true do
      local key, kind = read_token()
      if not key or kind == "brace" and key == "}" then
        break
      end
      local val, vkind = read_token()
      if not val then break end
      if vkind == "brace" and val == "{" then
        tbl[key] = parse_block()
      else
        tbl[key] = val
      end
    end
    return tbl
  end

  return parse_block()
end

--- Extract all library root paths from libraryfolders.vdf text.
---@param text string
---@return string[]
function M.library_paths(text)
  local parsed = M.parse(text)
  local root = parsed["libraryfolders"] or parsed["LibraryFolders"] or parsed
  if type(root) ~= "table" then return {} end
  local out = {}
  local seen = {}
  for _, v in pairs(root) do
    local p = nil
    if type(v) == "table" and type(v.path) == "string" then
      p = v.path
    elseif type(v) == "string" and (v:find("/") or v:find("\\")) then
      p = v
    end
    if p and p ~= "" then
      local norm = (unescape_vdf(p):gsub("\\", "/"):gsub("/+$", ""))
      local key = norm:lower()
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = norm
      end
    end
  end
  return out
end

--- Extract structured fields from an appmanifest_<appid>.acf string.
---@param text string
---@return table|nil
function M.parse_manifest(text)
  local parsed = M.parse(text)
  local state = parsed["AppState"]
  if type(state) ~= "table" then return nil end

  local depots = {}
  if type(state.InstalledDepots) == "table" then
    for depot_id, info in pairs(state.InstalledDepots) do
      if type(info) == "table" and type(info.manifest) == "string" then
        depots[tostring(depot_id)] = {
          manifest = info.manifest,
          size = tostring(info.size or "0"),
          -- DLC depots name their DLC: their latest manifest lives in the DLC's app info, not the game's.
          dlcappid = (type(info.dlcappid) == "string" and info.dlcappid ~= "") and info.dlcappid or nil,
        }
      end
    end
  end

  local shared_count = 0
  if type(state.SharedDepots) == "table" then
    for _ in pairs(state.SharedDepots) do shared_count = shared_count + 1 end
  end

  local language = nil
  if type(state.UserConfig) == "table" and type(state.UserConfig.language) == "string" then
    language = state.UserConfig.language
  end

  local betakey = nil
  if type(state.UserConfig) == "table" and type(state.UserConfig.betakey) == "string" and state.UserConfig.betakey ~= "" then
    betakey = state.UserConfig.betakey
  elseif type(state.MountedConfig) == "table" and type(state.MountedConfig.betakey) == "string" and state.MountedConfig.betakey ~= "" then
    betakey = state.MountedConfig.betakey
  end

  return {
    appid = tonumber(state.appid) or 0,
    name = tostring(state.name or ""),
    stateFlags = tonumber(state.StateFlags) or 0,
    buildid = tostring(state.buildid or ""),
    targetBuildId = tostring(state.TargetBuildID or "0"),
    lastUpdated = tonumber(state.LastUpdated) or 0,
    lastPlayed = tonumber(state.LastPlayed) or 0,
    sizeOnDisk = tostring(state.SizeOnDisk or "0"),
    bytesToDownload = tonumber(state.BytesToDownload) or 0,
    autoUpdateBehavior = tonumber(state.AutoUpdateBehavior) or 0,
    scheduledAutoUpdate = tonumber(state.ScheduledAutoUpdate) or 0,
    installdir = tostring(state.installdir or ""),
    betakey = betakey or "public",
    hasStagedDepots = type(state.StagedDepots) == "table",
    installedDepots = depots,
    sharedDepotCount = shared_count,
    language = language or "",
    bytesToStage = tonumber(state.BytesToStage) or 0,
    updateResult = tostring(state.UpdateResult or ""),
  }
end

--- Format-preserving in-place patch of an appmanifest_<appid>.acf string.
--- `top_updates`: map of top-level AppState key -> string value (e.g. StateFlags = "4").
--- `depot_manifests`: optional map of depotId -> new manifest gid string.
--- `remove_sections`: optional set of top-level AppState subsection names to strip (e.g. { StagedDepots = true }).
---@param raw string
---@param top_updates table<string, string>
---@param depot_manifests table<string, string>|nil
---@param remove_sections table<string, boolean>|nil
---@return string
function M.patch_manifest(raw, top_updates, depot_manifests, remove_sections)
  local lines = {}
  for line in (raw .. "\n"):gmatch("(.-)\r?\n") do
    lines[#lines + 1] = line
  end
  -- Drop the extra empty line introduced by appending "\n" if raw already ended with newline
  if #lines > 0 and raw:sub(-1) == "\n" then
    lines[#lines] = nil
  end

  local depth = 0
  local section_stack = {}
  local current_key = nil
  local seen_top = {}
  local skip_depth = nil
  local out_lines = {}

  for i = 1, #lines do
    local line = lines[i]
    local trimmed = line:match("^%s*(.-)%s*$")

    if skip_depth ~= nil then
      if trimmed == "{" then
        depth = depth + 1
      elseif trimmed == "}" then
        depth = math.max(0, depth - 1)
        if depth < skip_depth then
          skip_depth = nil
        end
      end
    elseif trimmed == "{" then
      depth = depth + 1
      section_stack[depth] = current_key
      if remove_sections and depth == 2 and section_stack[1] == "AppState" and current_key and remove_sections[current_key] then
        -- Drop the section key line that was just appended to out_lines
        if #out_lines > 0 then
          table.remove(out_lines)
        end
        skip_depth = depth
      else
        out_lines[#out_lines + 1] = line
      end
      current_key = nil
    elseif trimmed == "}" then
      section_stack[depth] = nil
      depth = math.max(0, depth - 1)
      current_key = nil
      out_lines[#out_lines + 1] = line
    else
      local k, ws_mid, v = line:match('^%s*"([^"]+)"(%s+)"([^"]*)"%s*$')
      if k and v then
        if depth == 1 and section_stack[1] == "AppState" then
          if top_updates and top_updates[k] ~= nil then
            local indent = line:match("^(%s*)") or "\t"
            line = indent .. '"' .. k .. '"' .. ws_mid .. '"' .. escape_vdf(top_updates[k]) .. '"'
            seen_top[k] = true
          end
        elseif depth == 3 and section_stack[1] == "AppState" and section_stack[2] == "InstalledDepots" then
          local depot_id = section_stack[3]
          if k == "manifest" and depot_manifests and depot_id and depot_manifests[depot_id] ~= nil then
            local indent = line:match("^(%s*)") or "\t\t\t"
            line = indent .. '"manifest"' .. ws_mid .. '"' .. escape_vdf(depot_manifests[depot_id]) .. '"'
          end
        end
        current_key = nil
        out_lines[#out_lines + 1] = line
      else
        local only_key = trimmed:match('^"([^"]+)"$')
        if only_key then
          current_key = only_key
        end
        out_lines[#out_lines + 1] = line
      end
    end
  end

  lines = out_lines

  -- Insert any top_updates keys that weren't present in the file before the final "}"
  if top_updates then
    local missing = {}
    for k, v in pairs(top_updates) do
      if not seen_top[k] then
        missing[#missing + 1] = { k = k, v = v }
      end
    end
    table.sort(missing, function(a, b) return a.k < b.k end)
    if #missing > 0 then
      local insert_at = #lines
      for i = #lines, 1, -1 do
        if lines[i]:match("^%s*}%s*$") then
          insert_at = i
          break
        end
      end
      for idx = #missing, 1, -1 do
        local item = missing[idx]
        table.insert(lines, insert_at, '\t"' .. item.k .. '"\t\t"' .. escape_vdf(item.v) .. '"')
      end
    end
  end

  local eol = raw:find("\r\n", 1, true) and "\r\n" or "\n"
  return table.concat(lines, eol) .. eol
end

return M
