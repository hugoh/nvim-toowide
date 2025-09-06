-- main module file
-- local module = require("plugin_name.module")

---@class ToowideColorConfig
---@field ctermfg integer|nil Terminal foreground color (0-255) or nil to inherit
---@field ctermbg integer|string|nil Terminal background color (0-255) or a cterm color name, or nil
---@field fg string|nil GUI foreground color in "#RRGGBB" or highlight group name, or nil
---@field bg string|nil GUI background color in "#RRGGBB" or highlight group name, or nil

---@class ToowideConfig
---@field colors ToowideColorConfig Highlight colors for over-limit text
---@field filetypes string[] Filetype patterns to enable the plugin for
---@field excluded_filetypes string[] Filetype patterns (Lua patterns) to always disable the plugin for
---@field max_lines integer Do not enable for buffers with more than this many lines
---@field debounce_ms integer Debounce time in milliseconds for highlighting after changes
---@field default_limit integer Default column limit when 'textwidth' is 0 and no filetype override exists
---@field filetype_limits table<string, integer> Per-filetype column limit overrides
local default_config = {
  colors = {
    ctermfg = nil,
    ctermbg = "darkgrey",
    fg = nil,
    bg = "#8B0000",
  },
  filetypes = { "*" },
  excluded_filetypes = { "", "nofile", "NeogitStatus", "NeogitDiffView", "snacks_.*" },
  max_lines = 10000,
  debounce_ms = 100,
  default_limit = 80,
  filetype_limits = { go = 120, lua = 120, yaml = 120 },
}

---@class ToowideModule
---@field config ToowideConfig
---@field setup fun(opts?:ToowideConfig)
---@field setup_highlight fun()
---@field get_limit fun(bufnr:integer): integer
---@field highlight fun(bufnr:integer, start_line?:integer, end_line?:integer)
---@field should_enable fun(bufnr:integer): boolean
---@field attach_buffer fun(bufnr:integer)
---@field detach_buffer fun(bufnr:integer)
local M = {}

---@type ToowideConfig
M.config = default_config

--- Namespace for highlights
---@type string
local hl_id = "LineLengthHighlight"
---@type integer
local ns_id = vim.api.nvim_create_namespace(hl_id)

-- Track buffers with attached change listeners
---@type table<integer, boolean>
local attached_buffers = {}

--- Set up highlight
---@function setup_highlight
---@return nil
M.setup_highlight = function()
  vim.api.nvim_set_hl(0, hl_id, {
    fg = M.config.colors.fg,
    bg = M.config.colors.bg,
    ctermfg = M.config.colors.ctermfg,
    ctermbg = M.config.colors.ctermbg,
  })
end

--- Returns character limit for a buffer
---@function get_limit
---@param bufnr integer Buffer handle
---@return integer limit
M.get_limit = function(bufnr)
  local tw = vim.bo[bufnr].textwidth or 0
  if tw > 0 then
    return tw
  end
  local ft = vim.bo[bufnr].filetype
  if M.config.filetype_limits and M.config.filetype_limits[ft] then
    return M.config.filetype_limits[ft]
  end
  return M.config.default_limit
end

--- Highlight a section of a buffer
---@function highlight
---@param bufnr integer Buffer handle
---@param start_line? integer 0-indexed inclusive start line
---@param end_line? integer 0-indexed exclusive end line
---@return nil
M.highlight = function(bufnr, start_line, end_line)
  -- Ensure buffer is valid and loaded
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return
  end

  local limit = M.get_limit(bufnr)

  -- Clamp line range to valid bounds
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  start_line = math.max(0, start_line or 0)
  end_line = math.min(line_count, end_line or line_count)

  -- Clear and re-apply extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, start_line, end_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line, false)
  for i, line in ipairs(lines) do
    local len = #line
    if len > limit then
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, start_line + i - 1, limit, {
        end_col = len,
        hl_group = hl_id,
        ephemeral = false,
      })
    end
  end
end

--- Returns whether highlighting should be enabled
---@function should_enable
---@param bufnr integer Buffer handle
---@return boolean enabled
M.should_enable = function(bufnr)
  local ft = vim.bo[bufnr].filetype
  if M.config.excluded_filetypes and #M.config.excluded_filetypes > 0 then
    for _, pat in ipairs(M.config.excluded_filetypes) do
      local anchored = "^" .. pat .. "$"
      if ft:match(anchored) then
        return false
      end
    end
  end
  if M.get_limit(bufnr) == 0 then
    return false
  end
  local bt = vim.bo[bufnr].buftype
  return vim.bo[bufnr].modifiable and vim.api.nvim_buf_line_count(bufnr) <= M.config.max_lines
end

--- Attach buffer for highlighting
---@function attach_buffer
---@param bufnr integer Buffer handle
---@return nil
M.attach_buffer = function(bufnr)
  if attached_buffers[bufnr] or not M.should_enable(bufnr) then
    return
  end

  -- Timer for debouncing
  ---@type uv.uv_timer_t|nil
  local timer = nil
  ---@param start_line integer
  ---@param end_line integer
  local debounced_highlight = function(start_line, end_line)
    if timer then
      timer:stop()
      timer:close()
    end
    timer = vim.loop.new_timer()
    timer:start(
      M.config.debounce_ms,
      0,
      vim.schedule_wrap(function()
        M.highlight(bufnr, start_line, end_line)
      end)
    )
  end

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, _, start_line, last_line, end_line_new, _)
      if last_line ~= end_line_new then
        -- Structural change (join/split): rehighlight entire buffer
        debounced_highlight(0, vim.api.nvim_buf_line_count(bufnr))
      else
        debounced_highlight(start_line, last_line)
      end
    end,
    on_detach = function()
      attached_buffers[bufnr] = nil
      if timer then
        timer:stop()
        timer:close()
      end
    end,
  })
  attached_buffers[bufnr] = true

  -- Initial highlight for the entire buffer
  debounced_highlight(0, vim.api.nvim_buf_line_count(bufnr))
end

--- Detach buffer from highlighting
---@function detach_buffer
---@param bufnr integer Buffer handle
---@return nil
M.detach_buffer = function(bufnr)
  if attached_buffers[bufnr] then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    attached_buffers[bufnr] = nil
    -- Note: on_detach in nvim_buf_attach handles timer cleanup
  end
end

--- Plugin setup -- must be called to activate plugin
---@function setup
---@param opts ToowideConfig|nil User configuration overrides
---@return nil
M.setup = function(opts)
  -- Merge user config with defaults
  M.config = vim.tbl_deep_extend("force", default_config, opts or {})

  M.setup_highlight()

  -- Global autocommands
  -- Buffer entry and option changes
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    pattern = M.config.filetypes,
    callback = function(args)
      M.attach_buffer(args.buf)
    end,
  })
  -- Option changes
  vim.api.nvim_create_autocmd("OptionSet", {
    pattern = { "textwidth", "filetype" },
    callback = function(args)
      local bufnr = args.buf
      if M.should_enable(bufnr) then
        M.attach_buffer(bufnr)
      else
        M.detach_buffer(bufnr)
      end
    end,
  })
  -- Clean up
  vim.api.nvim_create_autocmd("BufDelete", {
    callback = function(args)
      M.detach_buffer(args.buf)
    end,
  })
end

return M
