local lazy = require("bufferline.lazy")
local ui = lazy.require("bufferline.ui") ---@module "bufferline.ui"
local utils = lazy.require("bufferline.utils") ---@module "bufferline.utils"
local state = lazy.require("bufferline.state") ---@module "bufferline.state"
local groups = lazy.require("bufferline.groups") ---@module "bufferline.groups"
local config = lazy.require("bufferline.config") ---@module "bufferline.config"
local sorters = lazy.require("bufferline.sorters") ---@module "bufferline.sorters"
local buffers = lazy.require("bufferline.buffers") ---@module "bufferline.buffers"
local commands = lazy.require("bufferline.commands") ---@module "bufferline.commands"
local tabpages = lazy.require("bufferline.tabpages") ---@module "bufferline.tabpages"
local highlights = lazy.require("bufferline.highlights") ---@module "bufferline.highlights"
local hover = lazy.require("bufferline.hover") ---@module "bufferline.hover"

-- @v:lua@ in the tabline only supports global functions, so this is
-- the only way to add click handlers without autoloaded vimscript functions
_G.___bufferline_private = _G.___bufferline_private or {} -- to guard against reloads

local api = vim.api

-----------------------------------------------------------------------------//
--- API values
-----------------------------------------------------------------------------//
local M = {
  move = commands.move,
  move_to = commands.move_to,
  exec = commands.exec,
  go_to = commands.go_to,
  cycle = commands.cycle,
  sort_by = commands.sort_by,
  pick = commands.pick,
  get_elements = commands.get_elements,
  close_with_pick = commands.close_with_pick,
  close_in_direction = commands.close_in_direction,
  rename_tab = commands.rename_tab,
  close_others = commands.close_others,
  unpin_and_close = commands.unpin_and_close,

  ---@deprecated
  pick_buffer = commands.pick,
  ---@deprecated
  go_to_buffer = commands.go_to,
  ---@deprecated
  sort_buffers_by = commands.sort_by,
  ---@deprecated
  close_buffer_with_pick = commands.close_with_pick,

  style_preset = config.STYLE_PRESETS,

  groups = groups,
}
-----------------------------------------------------------------------------//

--- @return string, bufferline.Segment[][]
local function bufferline()
  local is_tabline = config:is_tabline()
  local options = config.options
  local tab_indicators = tabpages.get()
  local function build() return is_tabline and tabpages.get_components(state) or buffers.get_components(state) end

  -- NOTE: keep track of the previous state so it can be used for sorting
  -- specifically to position newly opened buffers next to the buffer that was previously open
  local prev_idx, prev_components = state.current_element_index, state.components

  local function sorter(list)
    return sorters.sort(list, {
      current_index = prev_idx,
      prev_components = prev_components,
      custom_sort = state.custom_sort,
    })
  end

  ---Build and arrange components exactly like the final render will, so sizes
  ---can be measured on the real list (including group markers).
  local function assemble()
    local list = build()
    return not is_tabline and groups.render(list, sorter) or sorter(list)
  end

  ---Width of a fully assembled list, split into tab width (which scales with
  ---the tab size) and fixed chrome such as group start/end markers.
  ---@param list bufferline.Component[]
  ---@return integer count, integer tabs, integer fixed
  local function measure(list)
    local count, tabs, fixed = 0, 0, 0
    for _, component in ipairs(list) do
      if not component.hidden then
        if component.name then
          count = count + 1
          tabs = tabs + component.length
        else
          fixed = fixed + component.length
        end
      end
    end
    return count, tabs, fixed
  end

  local components
  if options.tab_size == "auto" then
    local available = ui.available_width(tab_indicators)
    -- Probe at a known width to learn each tab's fixed chrome (numbers, icons,
    -- separators, group markers), since it is only observable once built.
    local probe = options.max_name_length
    ui.set_render_tab_size(probe, true)
    local count, tabs, fixed = measure(assemble())
    local size = ui.resolve_tab_size(options, available - fixed, count, tabs - probe * count)
    -- The estimate can be a column or two off (odd padding, duplicate prefixes,
    -- group markers). Shrink until the real, fully assembled tabline fits so we
    -- never fall into the truncate() path that hides whole tabs.
    for _ = 1, 32 do
      if size <= 1 then break end
      ui.set_render_tab_size(size, true)
      local _, t, f = measure(assemble())
      if t + f <= available then break end
      size = size - 1
    end
    -- Spread the leftover columns across the leading tabs so the tabs fill the
    -- bar exactly instead of leaving a gap that grows with the tab count.
    ui.set_render_tab_size(size, true)
    local _, t, f = measure(assemble())
    local remainder = available - (t + f)
    local plus = {}
    if remainder > 0 then
      for _, component in ipairs(assemble()) do
        if remainder <= 0 then break end
        if not component.hidden and component.id and component.name then
          plus[component.id] = true
          remainder = remainder - 1
        end
      end
    end
    ui.set_render_tab_size(size, true, next(plus) and plus or nil)
    components = assemble()
  elseif type(options.tab_size) == "function" then
    local probe = options.max_name_length
    ui.set_render_tab_size(probe, true)
    local count = measure(assemble())
    local size, regular = ui.resolve_tab_size(options, ui.available_width(tab_indicators), count)
    ui.set_render_tab_size(size, regular)
    components = assemble()
  else
    ui.set_render_tab_size(nil, nil)
    components = assemble()
  end

  local _, current_idx = utils.find(function(component) return component:current() end, components)

  state.set({ current_element_index = current_idx })
  local tabline = ui.tabline(components, tab_indicators)

  state.set({
    --- store the full unfiltered lists
    __components = components,
    --- Store copies without focusable/hidden elements
    components = components,
    visible_components = tabline.visible_components,
    --- size data stored for use elsewhere e.g. hover positioning
    left_offset_size = tabline.left_offset_size,
    right_offset_size = tabline.right_offset_size,
  })
  return tabline.str, tabline.segments
end

--- If the item count has changed and the next tabline status is different then update it
local function toggle_bufferline()
  if not config.options.auto_toggle_bufferline then return end
  local item_count = config:is_tabline() and utils.get_tab_count() or utils.get_buf_count()
  local status = (config.options.always_show_bufferline or item_count > 1) and 2 or 0
  if vim.o.showtabline ~= status then vim.o.showtabline = status end
end

---@private
function _G.nvim_bufferline()
  toggle_bufferline() -- Always populate state regardless of if tabline status is less than 2 #352
  return bufferline()
end

---@param conf bufferline.Config
local function setup_autocommands(conf)
  local BUFFERLINE_GROUP = "BufferlineCmds"
  local options = conf.options
  api.nvim_create_augroup(BUFFERLINE_GROUP, { clear = true })
  api.nvim_create_autocmd("ColorScheme", {
    pattern = "*",
    group = BUFFERLINE_GROUP,
    callback = function()
      highlights.reset_icon_hl_cache()
      highlights.set_all(config.update_highlights())
    end,
  })
  api.nvim_create_autocmd("TabClosed", {
    group = BUFFERLINE_GROUP,
    callback = function() state.prune_custom_sorts() end,
  })
  if not options or vim.tbl_isempty(options) then return end
  if options.persist_buffer_sort then
    api.nvim_create_autocmd("SessionLoadPost", {
      pattern = "*",
      group = BUFFERLINE_GROUP,
      callback = function() state.set({ custom_sort = utils.restore_positions() }) end,
    })
  end
  if not options.always_show_bufferline then
    -- toggle tabline
    api.nvim_create_autocmd({ "BufAdd", "TabEnter" }, {
      pattern = "*",
      group = BUFFERLINE_GROUP,
      callback = function() toggle_bufferline() end,
    })
  end

  api.nvim_create_autocmd("BufRead", {
    pattern = "*",
    once = true,
    callback = function() vim.schedule(groups.handle_group_enter) end,
  })

  api.nvim_create_autocmd("BufEnter", {
    pattern = "*",
    callback = function() groups.handle_group_enter() end,
  })

  api.nvim_create_autocmd("User", {
    pattern = "BufferLineHoverOver",
    callback = function(args) ui.on_hover_over(args.buf, args.data) end,
  })

  api.nvim_create_autocmd("User", {
    pattern = "BufferLineHoverOut",
    callback = ui.on_hover_out,
  })
end

local function command(name, cmd, opts) api.nvim_create_user_command(name, cmd, opts or {}) end

local function setup_commands()
  command("BufferLinePick", function() M.pick() end)
  command("BufferLinePickClose", function() M.close_with_pick() end)
  command("BufferLineCycleNext", function() M.cycle(1) end)
  command("BufferLineCyclePrev", function() M.cycle(-1) end)
  command("BufferLineCloseRight", function() M.close_in_direction("right") end)
  command("BufferLineCloseLeft", function() M.close_in_direction("left") end)
  command("BufferLineCloseOthers", function() M.close_others() end)
  command("BufferLineMoveNext", function() M.move(1) end)
  command("BufferLineMovePrev", function() M.move(-1) end)
  command("BufferLineSortByExtension", function() M.sort_by("extension") end)
  command("BufferLineSortByDirectory", function() M.sort_by("directory") end)
  command("BufferLineSortByRelativeDirectory", function() M.sort_by("relative_directory") end)
  command("BufferLineSortByTabs", function() M.sort_by("tabs") end)
  -- go to a buffer by its position in the *full* component list (the ordinal
  -- shown in the tabline), so pinned/collapsed groups and tabs that overflow the
  -- window width do not shift the number <n> refers to. Previously this used
  -- `state.visible_components`, making <n> count only the currently visible tabs.
  command("BufferLineGoToBuffer", function(opts) M.go_to(opts.args, true) end, { nargs = 1 })
  command("BufferLineTogglePin", function() groups.toggle_pin() end, { nargs = 0 })
  command("BufferLineTabRename", function(opts) M.rename_tab(opts.fargs) end, { nargs = "*" })
  command("BufferLineGroupClose", function(opts) groups.action(opts.args, "close") end, {
    nargs = 1,
    complete = groups.complete,
  })
  command("BufferLineGroupToggle", function(opts) groups.action(opts.args, "toggle") end, {
    nargs = 1,
    complete = groups.complete,
  })
end

local function setup_diagnostic_handler(preferences)
  if preferences.options.diagnostics == "nvim_lsp" and preferences.options.diagnostics_update_on_event then
    vim.diagnostic.handlers["bufferline"] = {
      show = function() ui.refresh() end,
      hide = function() ui.refresh() end,
    }
  end
end

---@param conf bufferline.UserConfig?
function M.setup(conf)
  conf = conf or {}
  config.setup(conf)
  groups.setup(conf) -- Groups must be set up before the config is applied
  local preferences = config.apply()
  -- on loading (and reloading) the plugin's config reset all the highlights
  highlights.set_all(preferences)
  hover.setup(preferences)
  setup_commands()
  setup_autocommands(preferences)
  setup_diagnostic_handler(preferences)
  vim.o.tabline = "%!v:lua.nvim_bufferline()"
  toggle_bufferline()
end

return M
