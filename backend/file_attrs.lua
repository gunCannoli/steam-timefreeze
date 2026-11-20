--- Cross-platform read-only file attribute helper via LuaJIT FFI (guardrail 23).
--- Zero shell-outs: uses kernel32 GetFileAttributesW/SetFileAttributesW on Windows
--- and libc chmod/access on Linux/macOS.

local bit = require("bit")
local platform = require("platform")

local M = {}

M.deps = {
  is_readonly = nil,
  set_readonly = nil,
}

local ok_ffi, ffi = pcall(require, "ffi")
local win_ready = false
local posix_ready = false
local kernel32 = nil

local FILE_ATTRIBUTE_READONLY = 0x00000001
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local CP_UTF8 = 65001

local function init_win()
  if win_ready then return kernel32 ~= nil end
  win_ready = true
  if not ok_ffi then return false end
  pcall(ffi.cdef, [[
    int MultiByteToWideChar(unsigned int CodePage, unsigned int dwFlags,
      const char* lpMultiByteStr, int cbMultiByte,
      wchar_t* lpWideCharStr, int cchWideChar);
    unsigned int GetFileAttributesW(const wchar_t* lpFileName);
    int SetFileAttributesW(const wchar_t* lpFileName, unsigned int dwFileAttributes);
  ]])
  local ok_k, k = pcall(ffi.load, "kernel32")
  if ok_k and k then
    kernel32 = k
    return true
  end
  return false
end

local function init_posix()
  if posix_ready then return ok_ffi end
  posix_ready = true
  if not ok_ffi then return false end
  pcall(ffi.cdef, [[
    int chmod(const char* path, unsigned int mode);
    int access(const char* path, int mode);
  ]])
  return true
end

local function to_wide(utf8)
  local len = kernel32.MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nil, 0)
  if len <= 0 then return nil end
  local buf = ffi.new("wchar_t[?]", len)
  local written = kernel32.MultiByteToWideChar(CP_UTF8, 0, utf8, -1, buf, len)
  if written <= 0 then return nil end
  return buf
end

--- Returns true if `path` is read-only, false if writable, or nil + err on failure.
---@param path string
---@return boolean|nil, string|nil
function M.is_readonly(path)
  if M.deps.is_readonly then return M.deps.is_readonly(path) end
  if type(path) ~= "string" or path == "" then return nil, "invalid path" end

  if platform.is_windows() then
    if not init_win() then return nil, "kernel32 unavailable" end
    local w = to_wide(path)
    if not w then return nil, "utf8 conversion failed" end
    local attrs = kernel32.GetFileAttributesW(w)
    if attrs == INVALID_FILE_ATTRIBUTES then
      return nil, "file not found"
    end
    return bit.band(attrs, FILE_ATTRIBUTE_READONLY) ~= 0, nil
  else
    if not init_posix() then return nil, "ffi unavailable" end
    -- W_OK = 2; access returns 0 when writable, -1 when read-only or missing
    local ok_f = io.open(path, "rb")
    if not ok_f then return nil, "file not found" end
    ok_f:close()
    local res = ffi.C.access(path, 2)
    return res ~= 0, nil
  end
end

--- Sets or clears the read-only attribute on `path`.
---@param path string
---@param readonly boolean
---@return boolean, string|nil
function M.set_readonly(path, readonly)
  if M.deps.set_readonly then return M.deps.set_readonly(path, readonly) end
  if type(path) ~= "string" or path == "" then return false, "invalid path" end

  if platform.is_windows() then
    if not init_win() then return false, "kernel32 unavailable" end
    local w = to_wide(path)
    if not w then return false, "utf8 conversion failed" end
    local attrs = kernel32.GetFileAttributesW(w)
    if attrs == INVALID_FILE_ATTRIBUTES then
      return false, "file not found"
    end
    local next_attrs = readonly
      and bit.bor(attrs, FILE_ATTRIBUTE_READONLY)
      or bit.band(attrs, bit.bnot(FILE_ATTRIBUTE_READONLY))
    local ok = kernel32.SetFileAttributesW(w, next_attrs)
    if ok == 0 then return false, "SetFileAttributesW failed" end
    return true, nil
  else
    if not init_posix() then return false, "ffi unavailable" end
    -- 0444 = 292 (r--r--r--), 0644 = 420 (rw-r--r--)
    local mode = readonly and 292 or 420
    local res = ffi.C.chmod(path, mode)
    if res ~= 0 then return false, "chmod failed" end
    return true, nil
  end
end

return M
