local CONFIG = require("kulala.config")
local FS = require("kulala.utils.fs")
local GLOBALS = require("kulala.globals")
local Logger = require("kulala.logger")
local M = {}

local NPM_EXISTS = vim.fn.executable("npm") == 1
local NODE_EXISTS = vim.fn.executable("node") == 1
local NPM_BIN = vim.fn.exepath("npm")
local NODE_BIN = vim.fn.exepath("node")
local SCRIPTS_DIR = FS.get_scripts_dir()
local REQUEST_SCRIPTS_DIR = FS.get_request_scripts_dir()
local SCRIPTS_BUILD_DIR = FS.get_tmp_scripts_build_dir()
local BASE_DIR = FS.join_paths(SCRIPTS_DIR, "engines", "javascript", "lib")
local BASE_FILE_PRE_CLIENT_ONLY = FS.join_paths(SCRIPTS_BUILD_DIR, "dist", "pre_request_client_only.js")
local BASE_FILE_PRE = FS.join_paths(SCRIPTS_BUILD_DIR, "dist", "pre_request.js")
local BASE_FILE_POST_CLIENT_ONLY = FS.join_paths(SCRIPTS_BUILD_DIR, "dist", "post_request_client_only.js")
local BASE_FILE_POST = FS.join_paths(SCRIPTS_BUILD_DIR, "dist", "post_request.js")
local FILE_MAPPING = {
  pre_request_client_only = BASE_FILE_PRE_CLIENT_ONLY,
  pre_request = BASE_FILE_PRE,
  post_request_client_only = BASE_FILE_POST_CLIENT_ONLY,
  post_request = BASE_FILE_POST,
}

M.install_dependencies = function()
  if FS.file_exists(BASE_FILE_PRE) and FS.file_exists(BASE_FILE_POST) then return end

  Logger.warn("Javascript base files not found.")
  Logger.info("Installing Javascript dependencies...")

  FS.copy_dir(BASE_DIR, SCRIPTS_BUILD_DIR)
  local res_install = vim.system({ NPM_BIN, "install", "--prefix", SCRIPTS_BUILD_DIR }):wait()
  if res_install.code ~= 0 then
    Logger.error("npm install fail with code " .. res_install.code)
    return
  end
  local res_build = vim.system({ NPM_BIN, "run", "build", "--prefix", SCRIPTS_BUILD_DIR }):wait()
  if res_build.code ~= 0 then
    Logger.error("npm run build fail with code " .. res_build.code)
    return
  end
end

---@param script_type "pre_request_client_only" | "pre_request" | "post_request_client_only" | "post_request"
---type of script
---@param is_external_file boolean -- is external file
---@param script_data string[]|string -- either list of inline scripts or path to script file
---@return string|nil, string|nil
local generate_one = function(script_type, is_external_file, script_data)
  local userscript
  local base_file_path = FILE_MAPPING[script_type]

  if base_file_path == nil then return nil, nil end

  local base_file = FS.read_file(base_file_path)
  if base_file == nil then return nil, nil end

  local script_cwd
  local buf_dir = FS.get_current_buffer_dir()

  if is_external_file then
    -- if script_data starts with ./ or ../, it is a relative path
    if string.match(script_data, "^%./") or string.match(script_data, "^%../") then
      local local_script_path = script_data:gsub("^%./", "")
      script_data = FS.join_paths(buf_dir, local_script_path)
    end

    if FS.file_exists(script_data) then
      script_cwd = FS.get_dir_by_filepath(script_data)
      userscript = FS.read_file(script_data)
    else
      Logger.error(("Could not read the %s script: %s"):format(script_type, script_data))
      userscript = ""
    end
  end

  script_cwd = script_cwd or buf_dir
  userscript = userscript or vim.fn.join(script_data, "\n")
  base_file = base_file .. "\n" .. userscript

  local uuid = FS.get_uuid()
  local script_path = FS.join_paths(REQUEST_SCRIPTS_DIR, uuid .. ".js")

  FS.write_file(script_path, base_file, false)

  return script_path, script_cwd
end

---@class JsScripts
---@field path string -- path to script
---@field cwd string -- current working directory

---@param script_type "pre_request_client_only" | "pre_request" | "post_request_client_only" | "post_request" -- type of script
---@param scripts_data ScriptData -- data for scripts
---@return JsScripts<table> -- paths to scripts
local generate_all = function(script_type, scripts_data)
  local scripts = {}
  local script_path, script_cwd = generate_one(script_type, false, scripts_data.inline)
  if script_path ~= nil and script_cwd ~= nil then table.insert(scripts, { path = script_path, cwd = script_cwd }) end
  for _, script_data in ipairs(scripts_data.files) do
    script_path, script_cwd = generate_one(script_type, true, script_data)
    if script_path ~= nil and script_cwd ~= nil then table.insert(scripts, { path = script_path, cwd = script_cwd }) end
  end
  return scripts
end

local scripts_is_empty = function(scripts_data)
  return #scripts_data.inline == 0 and #scripts_data.files == 0
end

---@param type "pre_request_client_only" | "pre_request" | "post_request_client_only" | "post_request" -- type of script
---@param data ScriptData
M.run = function(type, data)
  local pre_output = GLOBALS.SCRIPT_PRE_OUTPUT_FILE
  local post_output = GLOBALS.SCRIPT_POST_OUTPUT_FILE

  if scripts_is_empty(data) then return end

  if not NODE_EXISTS then
    Logger.error("node not found, please install nodejs")
    return
  end

  if not NPM_EXISTS then
    Logger.error("npm not found, please install nodejs")
    return
  end

  M.install_dependencies()

  local scripts = generate_all(type, data)
  if #scripts == 0 then return end

  for _, script in ipairs(scripts) do
    local output = vim
      .system({
        NODE_BIN,
        script.path,
      }, {
        cwd = script.cwd,
        env = {
          NODE_PATH = FS.join_paths(script.cwd, "node_modules"),
        },
      })
      :wait()

    if output.stderr ~= nil and not string.match(output.stderr, "^%s*$") then
      if not CONFIG.get().disable_script_print_output then
        Logger.error(("Errors while running JS script: %s"):format(output.stderr))
      end

      if type == "pre_request" then
        FS.write_file(pre_output, output.stderr)
      elseif type == "post_request" then
        FS.write_file(post_output, output.stderr)
      end
    end

    if output.stdout ~= nil and not string.match(output.stdout, "^%s*$") then
      if not CONFIG.get().disable_script_print_output then Logger.info("JS: " .. output.stdout) end

      if type == "pre_request" then
        if not FS.write_file(pre_output, output.stdout) then Logger.error("write " .. pre_output .. " fail") end
      elseif type == "post_request" then
        if not FS.write_file(post_output, output.stdout) then Logger.error("write " .. post_output .. " fail") end
      end
    end
  end
end

return M
