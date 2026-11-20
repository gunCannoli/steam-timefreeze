--- OS-agnostic path and environment helpers (guardrail 23).
--- Paths are built with "/" only (Windows accepts it).

local M = {}

M.deps = {
  getenv = nil,
  is_windows = nil,
}

local function env(name)
  local v = (M.deps.getenv or os.getenv)(name)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

local function slashes(p)
  return (tostring(p):gsub("\\", "/"):gsub("/+$", ""))
end

---@return boolean
function M.is_windows()
  if M.deps.is_windows ~= nil then return M.deps.is_windows end
  return package.config:sub(1, 1) == "\\"
end

---@return string
function M.os_name()
  return M.is_windows() and "windows" or "linux"
end

---@return string
function M.home()
  return slashes(M.is_windows() and (env("USERPROFILE") or "") or (env("HOME") or ""))
end

---@param ... string
---@return string
function M.join(...)
  local out = {}
  for _, part in ipairs({ ... }) do
    local s = slashes(part)
    if s ~= "" then
      out[#out + 1] = (#out > 0) and s:gsub("^/+", "") or s
    end
  end
  return table.concat(out, "/")
end

return M
