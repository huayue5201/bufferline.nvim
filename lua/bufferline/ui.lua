-----------------------------------------------------------------------------//
-- UI
-----------------------------------------------------------------------------//
local lazy = require("bufferline.lazy")
local utils = lazy.require("bufferline.utils") ---@module "bufferline.utils"
local config = lazy.require("bufferline.config") ---@module "bufferline.config"
local constants = lazy.require("bufferline.constants") ---@module "bufferline.constants"
local highlights = lazy.require("bufferline.highlights") ---@module "bufferline.highlights"
local pick = lazy.require("bufferline.pick") ---@module "bufferline.pick"
local groups = lazy.require("bufferline.groups") ---@module "bufferline.groups"
local diagnostics = lazy.require("bufferline.diagnostics") ---@module "bufferline.diagnostics"
local duplicates = lazy.require("bufferline.duplicates") ---@module "bufferline.duplicates"
local numbers = lazy.require("bufferline.numbers") ---@module "bufferline.numbers"
local custom_area = lazy.require("bufferline.custom_area") ---@module "bufferline.custom_area"
local offset = lazy.require("bufferline.offset") ---@module "bufferline.offset"
local state = lazy.require("bufferline.state") ---@module "bufferline.state"

local M = {}

local api = vim.api

local sep_names = constants.sep_names
local sep_chars = constants.sep_chars
-- string.len counts number of bytes and so the unicode icons are counted
-- larger than their display width. So we use nvim's strwidth
local strwidth = vim.api.nvim_strwidth
local padding = constants.padding

--- Per-render tab width override (set by M.tabline). nil = fall back to options.tab_size
local render_tab_size = nil
--- Whether the current render forces equal-width tabs (set by M.tabline).
local render_regular = nil
--- Buffer ids that get one extra column this render, so the tabs fill the
--- window exactly instead of leaving a growing gap before the right edge.
local render_plus = nil
--- When true, non-current tabs drop their name, numbers, diagnostics and
--- padding and render as a compact icon-only tab. Set by M.tabline so a busy
--- tabline can keep every tab visible instead of hiding whole tabs.
local render_compact = false
--- How much optional per-tab chrome to drop this render when the window (or a
--- sidebar offset) leaves too little width. Each step is leaner than the last:
--- 0 = everything, 1 = no close/modified slot, 2 = also no numbers, 3 = also
--- no name (all tabs icon-only but still equally wide).
local render_trim = 0

---Effective width for a single tab this render (base + fill remainder).
---@param tab bufferline.TabElement?
---@return integer?
local function tab_width(tab)
  local base = render_tab_size
  if base == nil then return nil end
  if render_plus and tab and tab.id and render_plus[tab.id] then return base + 1 end
  return base
end

local components = {
  id = {
    diagnostics = "diagnostics",
    name = "name",
    icon = "icon",
    number = "number",
    groups = "groups",
    duplicates = "duplicates",
    close = "close",
    modified = "modified",
    pick = "pick",
  },
}

----------------------------------------------------------------------------------------------------
-- Hover events
----------------------------------------------------------------------------------------------------

---@param item bufferline.Component?
local function set_hover_state(item)
  state.set({ hovered = item })
  M.refresh()
end

---@class HoverOpts
---@field cursor_pos integer

---@param _ integer
---@param opts HoverOpts
function M.on_hover_over(_, opts)
  local mouse_pos, pos = opts.cursor_pos, state.left_offset_size
  for _, item in pairs(state.visible_components) do
    -- This value can be incorrect as truncation markers might push things off center
    local next_pos = pos + item.length
    if mouse_pos >= pos and mouse_pos <= next_pos then return set_hover_state(item) end
    pos = next_pos
  end
end

function M.on_hover_out() set_hover_state(vim.NIL) end

---@param component bufferline.Segment?
---@param id string
---@return bufferline.Segment?
local function set_id(component, id)
  if component then
    component.attr = component.attr or {}
    component.attr.__id = id
  end
  return component
end

local function get_id(component) return component and component.attr and component.attr.__id end

-----------------------------------------------------------------------------//
-- Context
-----------------------------------------------------------------------------//
---@type bufferline.RenderContext
local Context = {}

---@param ctx bufferline.RenderContext
---@return bufferline.RenderContext
function Context:new(ctx)
  assert(ctx.tab, "A tab view entity is required to create a context")
  self.tab = ctx.tab
  self.__index = self
  return setmetatable(ctx, self)
end

-----------------------------------------------------------------------------//
---@param s bufferline.Segment?
---@return boolean
local function has_text(s)
  if s == nil or s.text == nil or s.text == "" then return false end
  return true
end

---@param parts bufferline.Segment[]
---@return bufferline.Segment[]
local function filter_invalid(parts)
  local result = {}
  for _, p in pairs(parts) do
    if p ~= nil then result[#result + 1] = p end
  end
  return result
end

---@param segments bufferline.Segment[]
---@return integer
local function get_component_size(segments)
  assert(utils.is_list(segments), "Segments must be a list")
  local sum = 0
  for _, s in pairs(segments) do
    if has_text(s) then sum = sum + strwidth(tostring(s.text)) end
  end
  return sum
end

local function get_marker_size(count, element_size) return count > 0 and strwidth(tostring(count)) + element_size or 0 end

function M.refresh() utils.schedule_redraw() end

---Add click action to a component
---@param func_name string
---@param id number
---@param component bufferline.Segment
function M.make_clickable(func_name, id, component)
  component.attr = component.attr or {}
  component.attr.prefix = "%" .. id .. "@v:lua.___bufferline_private." .. func_name .. "@"
  -- the %X works as a closing label. @see :h tabline
  component.attr.suffix = "%X"
  return component
end

---@class PadSide
---@field size integer
---@field hl string

---@class PadOpts
---@field left PadSide?
---@field right PadSide?

---Add padding to either side of a component
---@param opts PadOpts
---@return bufferline.Segment, bufferline.Segment
local function pad(opts)
  opts.left, opts.right = opts.left or {}, opts.right or {}
  local left, left_hl = opts.left.size or 0, opts.left.hl or ""
  local right, right_hl = opts.right.size or 0, opts.right.hl or left_hl
  local left_p, right_p = string.rep(padding, left), string.rep(padding, right)
  return { text = left_p, highlight = left_hl }, { text = right_p, highlight = right_hl }
end

---@param options bufferline.Options
---@param hls bufferline.Highlights
---@return bufferline.Segment[]
local function get_tab_close_button(options, hls)
  if options.show_close_icon and (#vim.api.nvim_list_tabpages() > 1) then
    return {
      {
        text = padding .. options.close_icon .. padding,
        highlight = hls.tab_close.hl_group,
        attr = { prefix = "%999X" },
      },
    }
  end
  return {}
end

---@param items bufferline.Component[]
---@return bufferline.Section
---@return bufferline.Section
---@return bufferline.Section
local function get_sections(items)
  local Section = require("bufferline.models").Section
  local current = Section:new()
  local before = Section:new()
  local after = Section:new()

  for _, tab_view in ipairs(items) do
    if not tab_view.hidden then
      if tab_view:current() then
        current:add(tab_view)
      elseif current.length == 0 then -- We haven't reached the current buffer yet
        before:add(tab_view)
      else
        after:add(tab_view)
      end
    end
  end
  return before, current, after
end

---@param ctx bufferline.RenderContext
---@param length number
---@return bufferline.Segment?, bufferline.Segment?
local function add_space(ctx, length)
  -- Compact tabs have no room to spare, so they carry no padding at all.
  if render_compact and not ctx.tab:current() then return end
  local options = config.options
  local curr_hl = ctx.current_highlights
  local left_size, right_size = 0, 0
  local icon = options.buffer_close_icon
  -- pad each tab smaller than the max tab size to make it consistent
  local base_size = tab_width(ctx.tab)
  if not base_size then
    base_size = type(options.tab_size) == "number" and options.tab_size or options.max_name_length
  end
  local difference = base_size - length
  if difference > 0 then
    local size = math.floor(difference / 2)
    -- give the odd remainder to the right so the tab always reaches base_size
    left_size, right_size = size + left_size, difference - size + right_size
  end
  if not options.show_buffer_close_icons or render_trim >= 1 then
    right_size = right_size > 0 and right_size - strwidth(icon) or right_size
    left_size = left_size + strwidth(icon)
  end
  return pad({
    left = { size = left_size, hl = curr_hl.buffer },
    right = { size = right_size },
  })
end

--- @param buffer bufferline.TabElement
--- @param hl_defs bufferline.Highlights
--- @return bufferline.Segment?
local function get_icon(buffer, hl_defs)
  local icon = buffer.icon
  local original_hl = buffer.icon_highlight

  if not icon or icon == "" then return end
  if not original_hl or original_hl == "" then return { text = icon } end

  local icon_hl = highlights.set_icon_highlight(buffer:visibility(), hl_defs, original_hl)
  return { text = icon, highlight = icon_hl, attr = { text = "%*" } }
end

---Determine if the separator style is one of the slant options
---@param style string
---@return boolean
local function is_slant(style)
  return vim.tbl_contains({ sep_names.slant, sep_names.padded_slant, sep_names.slope, sep_names.padded_slope }, style)
end

--- Resolve the effective tab width for a render.
--- `options.tab_size` may be a number, "auto" (fill the window), or a function.
--- `total_extra` is the sum over visible tabs of the width each tab spends
--- outside the padded name block (icons, numbers, diagnostics, separators).
--- @param options bufferline.Options
--- @param available_width integer
--- @param count integer number of visible tabs
--- @param total_extra? integer
--- @return integer width
--- @return boolean regular whether tabs should be forced to equal width
local function resolve_tab_size(options, available_width, count, total_extra)
  local tab_size = options.tab_size
  if type(tab_size) == "function" then return tab_size(available_width, count), true end
  if tab_size ~= "auto" then return tab_size, options.enforce_regular_tabs end
  if count <= 0 then return options.max_name_length, true end
  local size = math.floor((available_width - (total_extra or 0)) / count)
  if options.min_tab_size and options.min_tab_size > 0 then size = math.max(size, options.min_tab_size) end
  if options.max_tab_size and options.max_tab_size > 0 then size = math.min(size, options.max_tab_size) end
  return math.max(size, 1), true
end

--- "▍" "░"
--- Reference: https://en.wikipedia.org/wiki/Block_Elements
--- @param focused boolean
--- @param style table | string
local function get_separator(focused, style)
  if type(style) == "table" then return focused and style[1] or style[2] end
  ---@diagnostic disable-next-line: undefined-field
  local chars = sep_chars[style] or sep_chars.thin
  if is_slant(style) then return chars[1], chars[2] end
  return focused and chars[1] or chars[2]
end

---Constant width reserved for the per-tab modified/close button slot. Keeping it
---fixed means toggling the modified flag or revealing the close button on hover
---never changes a tab's width (which would shift the whole tabline).
---@param options bufferline.Options
---@return integer
local function button_width(options)
  local modified = strwidth(options.modified_icon)
  if not options.show_buffer_close_icons then return modified end
  return math.max(modified, strwidth(options.buffer_close_icon))
end

--- @param buf_id number
--- @return bufferline.Segment?
local function get_close_icon(buf_id, context)
  local options = config.options
  if not options.show_buffer_close_icons then return end
  local close_str = options.buffer_close_icon
  if options.hover.enabled and not context.tab:current() and vim.tbl_contains(options.hover.reveal, "close") then
    if not state.hovered or state.hovered.id ~= context.tab.id then
      -- keep the reserved slot while hidden so revealing it on hover does not resize the tab
      return { text = string.rep(padding, button_width(options)) }
    end
  end
  local close_button_hl = context.current_highlights.close_button
  local lead = string.rep(padding, button_width(options) - strwidth(close_str))
  return M.make_clickable("handle_close", buf_id, {
    text = lead .. close_str,
    highlight = close_button_hl,
  })
end

--- @param context bufferline.RenderContext
--- @return bufferline.Segment?
local function add_indicator(context)
  local element = context.tab
  local hl = config.highlights
  local curr_hl = context.current_highlights
  local options = config.options
  local style = options.separator_style
  local symbol, highlight = padding, nil

  if is_slant(style) then return { text = symbol, highlight = highlight } end

  local is_current = element:current()

  symbol = is_current and options.indicator.icon or symbol
  highlight = is_current and hl.indicator_selected.hl_group
    or element:visible() and hl.indicator_visible.hl_group
    or curr_hl.buffer

  if options.indicator.style ~= "icon" then return { text = padding, highlight = highlight } end

  -- since all non-current buffers do not have an indicator they need
  -- to be padded to make up the difference in size
  return { text = symbol, highlight = highlight }
end

--- @param context bufferline.RenderContext
--- @return bufferline.Segment?
local function add_icon(context)
  local element = context.tab
  local options = config.options
  if context.is_picking and element.letter then
    return pick.component(context)
  elseif options.show_buffer_icons and element.icon then
    return get_icon(element, config.highlights)
  end
end

--- The suffix can be either the modified icon, space to replace the icon if
--- a user has turned them off or the close icon if the element is not currently modified
--- @param context bufferline.RenderContext
--- @return bufferline.Segment?
local function add_suffix(context)
  local element = context.tab
  local hl = context.current_highlights
  local options = config.options
  local symbol = options.modified_icon
  local slot = button_width(options)
  -- If the buffer is modified add an icon, if it isn't pad
  -- the buffer so it doesn't "jump" when it becomes modified i.e.
  -- due to the sudden addition of a new character
  local modified = {
    text = element.modified and (symbol .. string.rep(padding, slot - strwidth(symbol))) or string.rep(padding, slot),
    highlight = element.modified and hl.modified or nil,
  }
  local close = get_close_icon(element.id, context)
  return not element.modified and close or modified
end

--- TODO: We increment the buffer length by the separator although the final
--- buffer will not have a separator so we are technically off by 1
--- @param context bufferline.RenderContext
--- @return bufferline.Segment?, bufferline.Segment
local function add_separators(context)
  local options = config.options
  local style = options.separator_style
  local focused = context.tab:current() or context.tab:visible()
  local right_sep, left_sep = get_separator(focused, style)
  -- Always use the state-aware highlight so `separator_selected`/
  -- `separator_visible` apply to non-slant styles (thin/thick) too, not just slants.
  local sep_hl = context.current_highlights.separator

  local left_separator = left_sep and { text = left_sep, highlight = sep_hl } or nil
  local right_separator = { text = right_sep, highlight = sep_hl }
  return left_separator, right_separator
end

-- if we are enforcing regular tab size then all components will try and fit
-- into the maximum tab size. If not we enforce a minimum tab size
-- and allow components to be larger than the max.
---@param context bufferline.RenderContext
---@return number
local function get_max_length(context)
  local options = config.options
  local element = context.tab
  local icon_size = strwidth(element.icon)
  local padding_size = strwidth(padding) * 2
  local max_length = options.max_name_length

  local tab_size = tab_width(context.tab)
  if not tab_size then tab_size = type(options.tab_size) == "number" and options.tab_size or options.max_name_length end
  local enforce = render_regular
  if enforce == nil then
    enforce = options.enforce_regular_tabs or options.tab_size == "auto" or type(options.tab_size) == "function"
  end

  local autosize = not options.truncate_names and not enforce
  local name_size = strwidth(context.tab.name)
  if autosize and name_size >= max_length then return name_size end

  if not enforce then return max_length end
  -- estimate the maximum allowed size of a filename given that it will be
  -- padded and prefixed with a file icon
  -- The close/modified slot is the first thing dropped when space is tight, so
  -- do not reserve room for it then.
  local button = render_trim >= 1 and 0 or button_width(options)
  return tab_size - button - icon_size - padding_size
end

---@param ctx bufferline.RenderContext
---@return bufferline.Segment
local function get_name(ctx)
  local name = utils.truncate_name(ctx.tab.name, get_max_length(ctx))
  -- escape filenames that contain "%" as this breaks in statusline patterns
  name = name:gsub("%%", "%%%1")
  return { text = name, highlight = ctx.current_highlights.buffer }
end

---Create the render function that components need to position their
---separators once rendering calculations are complete
---@param left_separator bufferline.Segment?
---@param right_separator bufferline.Segment?
---@param component bufferline.Segment[]
---@return fun(next: bufferline.Component): bufferline.Segment[]
local function create_renderer(left_separator, right_separator, component)
  --- We return a function from render buffer as we do not yet have access to
  --- information regarding which buffers will actually be rendered
  --- @param next_item bufferline.Component
  --- @return string
  return function(next_item)
    -- if using the non-slanted tab style then we must check if the component is at the end of
    -- of a section e.g. the end of a group and if so it should not be wrapped with separators
    -- as it can use those of the next item
    if not is_slant(config.options.separator_style) and next_item and next_item:is_end() then return component end

    if left_separator then
      table.insert(component, 1, left_separator)
      table.insert(component, right_separator)
      return component
    end

    if next_item then table.insert(component, right_separator) end

    return component
  end
end

---@param id number
---@return bufferline.Segment
local function tab_click_handler(id) return M.make_clickable("handle_click", id, { attr = { global = true } }) end

---@class SpacingOpts
---@field when any
---@field highlight string

---Create a spacing component that can be dependent on other items in a component
---@param opts SpacingOpts?
---@return bufferline.Segment?
local function spacing(opts)
  opts = opts or { when = true }
  if not opts.when then return end
  return { text = constants.padding, highlight = opts.highlight }
end

---@param trunc_icon string
---@param count_hl string
---@param icon_hl string
---@param count number
---@return bufferline.Segment[]?
local function get_trunc_marker(trunc_icon, count_hl, icon_hl, count)
  if count > 0 then
    return {
      { highlight = count_hl, text = padding .. count .. padding },
      { highlight = icon_hl, text = trunc_icon .. padding },
    }
  end
end

---@param tab_indicators table<string, bufferline.Segment>
---@param options bufferline.Options
---@return bufferline.Segment[]
---@return integer
local function get_tab_indicator(tab_indicators, options)
  local items, length = {}, 0
  if not options.show_tab_indicators or #tab_indicators <= 1 then return items, length end
  for _, tab in ipairs(tab_indicators) do
    local component = tab.component
    table.insert(items, component)
    length = length + get_component_size(component)
  end
  return items, length
end

--- @param current_state bufferline.State
--- @param element bufferline.TabElement
--- @return bufferline.TabElement
function M.element(current_state, element)
  local curr_hl = highlights.for_element(element)
  local ctx = Context:new({
    tab = element,
    current_highlights = curr_hl,
    is_picking = current_state.is_picking,
  })

  -- Trimmed tail (see render_trim) eventually strips the name from every tab,
  -- current one included, so all tabs keep the same width.
  local compact = (render_compact and not element:current()) or render_trim >= 3
  local trim = render_trim
  local duplicate_prefix = not compact and duplicates.component(ctx) or nil
  local group_item = element.group and groups.component(ctx) or nil
  local diagnostic = not compact and diagnostics.component(ctx) or nil
  local icon = not compact and add_icon(ctx) or nil
  local number_item = not compact and trim < 2 and numbers.component(ctx) or nil
  local suffix = not compact and trim < 1 and add_suffix(ctx) or nil
  local indicator = add_indicator(ctx)
  local left, right = add_separators(ctx)

  local name = not compact and get_name(ctx) or nil
  -- Guess how much space there will for padding based on the buffer's name
  local name_size = get_component_size({ duplicate_prefix, name, spacing(), icon, suffix })
  local left_space, right_space = add_space(ctx, name_size)

  local component = filter_invalid({
    tab_click_handler(element.id),
    indicator,
    left_space,
    set_id(number_item, components.id.number),
    spacing({ when = number_item }),
    set_id(icon, components.id.icon),
    spacing({ when = icon }),
    set_id(group_item, components.id.groups),
    spacing({ when = group_item }),
    set_id(duplicate_prefix, components.id.duplicates),
    set_id(name, components.id.name),
    spacing({ when = name, highlight = curr_hl.buffer }),
    set_id(diagnostic, components.id.diagnostics),
    spacing({ when = diagnostic and #diagnostic.text > 0 }),
    right_space,
    suffix,
    spacing({ when = suffix }),
  })

  element.component = create_renderer(left, right, component)
  -- NOTE: we must count the size of the separators here although we do not
  -- add them yet, since by the time they are added the component will already have rendered
  element.length = get_component_size(filter_invalid({ left, right, unpack(component) }))
  -- Marks this element as a tab (group start/end markers are not tabs), so the
  -- layout can size tabs even when a compact tab has no name.
  element.is_tab = true
  return element
end

-- The extends field means that the components highlights should be applied
-- to another with a matching ID. This function does an initial scan of the component
-- parts and updates the highlights for any part that has an extension.
---@param component bufferline.Segment[]
---@return bufferline.Segment[]
local function extend_highlight(component)
  local locations, extension_map = {}, {}
  for index, part in pairs(component) do
    local id = get_id(part)
    if id then locations[id] = index end
    local extends = vim.tbl_get(part, "attr", "extends")
    if extends then
      for _, target in pairs(extends) do
        extension_map[target.id] = target.highlight or part.highlight
      end
    end
  end
  for id, hl in pairs(extension_map) do
    local target = component[locations[id]]
    if target then target.highlight = hl end
  end
  return component
end

--- Takes a list of Segments of the shape {text = <text>, highlight = <hl>, attr = <table>}
--- and converts them into an nvim tabline format string i.e. `%#HL#text`. It handles cases
--- like applying global or local attributes like click handlers. As well as extending highlights
---@param component bufferline.Segment[]
local function to_tabline_str(component)
  component = component or {}
  local str = {}
  local globals = {}
  extend_highlight(component)
  for _, part in ipairs(component) do
    local attr = part.attr
    if attr and attr.global then table.insert(globals, { attr.prefix or "", attr.suffix or "" }) end
    local hl = highlights.hl(part.highlight)
    table.insert(str, {
      hl,
      ((attr and not attr.global) and attr.prefix or ""),
      (part.text or ""),
      ((attr and not attr.global) and attr.suffix or ""),
    })
  end
  for _, attr in ipairs(globals) do
    table.insert(str, 1, attr[1])
    table.insert(str, #str + 1, attr[1])
  end
  return table.concat(utils.tbl_flatten(str))
end

--- PREREQUISITE: active buffer always remains in view
--- 1. Find amount of available space in the window
--- 2. Find the amount of space the bufferline will take up
--- 3. If the bufferline will be too long remove one tab from the before or after
--- section
--- 4. Re-check the size, if still too long truncate recursively till it fits
--- 5. Add the number of truncated buffers as an indicator
---@param before bufferline.Section
---@param current bufferline.Section
---@param after bufferline.Section
---@param available_width number
---@param marker table
---@param visible bufferline.Component[]
---@return bufferline.Segment[][]
---@return table
---@return bufferline.Buffer[]
local function truncate(before, current, after, available_width, marker, visible)
  visible = visible or {}

  local left_trunc_marker = get_marker_size(marker.left_count, marker.left_element_size)
  local right_trunc_marker = get_marker_size(marker.right_count, marker.right_element_size)

  local markers_length = left_trunc_marker + right_trunc_marker
  local total_length = before.length + current.length + after.length + markers_length

  if available_width >= total_length then
    local items = {}
    visible = utils.merge_lists(before.items, current.items, after.items)
    for index, item in ipairs(visible) do
      table.insert(items, item.component(visible[index + 1]))
    end
    return items, marker, visible
  -- if we aren't even able to fit the current buffer into the
  -- available space that means the window is really narrow
  -- so don't show anything
  elseif available_width < current.length then
    return {}, marker, visible
  else
    if before.length >= after.length then
      before:drop(1)
      marker.left_count = marker.left_count + 1
    else
      after:drop(#after.items)
      marker.right_count = marker.right_count + 1
    end
    -- drop the markers if the window is too narrow
    -- this assumes we have dropped both before and after
    -- sections since if the space available is this small
    -- we have likely removed these
    if (current.length + markers_length) > available_width then
      marker.left_count = 0
      marker.right_count = 0
    end
    return truncate(before, current, after, available_width, marker, visible)
  end
end

---@param list bufferline.Segment[][]
local function join(list)
  local str = ""
  for _, item in pairs(list) do
    str = str .. to_tabline_str(item)
  end
  return str
end

--- Get the width of statusline/tabline format string
---@vararg string
---@return integer
local function statusline_str_width(...)
  local str = table.concat({ ... }, "")
  return api.nvim_eval_statusline(str, { use_tabline = true }).width
end

---@class BufferlineTablineData
---@field str string
---@field left_offset_size integer
---@field right_offset_size integer
---@field segments bufferline.Segment[][]
---@field visible_components bufferline.TabElement[]

---Width available to the tabs: window width minus custom areas, tab indicators
---and the tab close button.
---@param tab_indicators bufferline.Segment[]
---@return integer
function M.available_width(tab_indicators)
  local options = config.options
  local hl = config.highlights
  local tab_close_button = get_tab_close_button(options, hl)
  local _, tab_indicator_length = get_tab_indicator(tab_indicators, options)
  local offsets = offset.get()
  local custom_area_size = custom_area.get()
  return vim.o.columns
    - custom_area_size
    - offsets.total_size
    - tab_indicator_length
    - get_component_size(tab_close_button)
end

--- TODO: All components should return Segment[] that are then combined in one go into a tabline
--- @param items bufferline.Component[]
--- @param tab_indicators bufferline.Segment[]
--- @return BufferlineTablineData
function M.tabline(items, tab_indicators)
  local options = config.options
  local hl = config.highlights
  local right_align = { { highlight = hl.fill.hl_group, text = "%=" } }

  local tab_close_button = get_tab_close_button(options, hl)
  local tab_indicator_segments = get_tab_indicator(tab_indicators, options)
  local offsets = offset.get()
  local _, left_area, right_area = custom_area.get()
  local available_width = M.available_width(tab_indicators)

  local left_trunc_icon = options.left_trunc_marker
  local right_trunc_icon = options.right_trunc_marker

  local before, current, after = get_sections(items)
  local segments, marker, visible_components
  if render_tab_size ~= nil then
    -- Flex mode: tab widths were fitted to the window, so render every tab in
    -- order and never drop tabs to make room (the legacy truncate behaviour).
    visible_components = utils.merge_lists(before.items, current.items, after.items)
    segments = {}
    for index, item in ipairs(visible_components) do
      table.insert(segments, item.component(visible_components[index + 1]))
    end
    marker = { left_count = 0, right_count = 0 }
  else
    -- NOTE: this estimates the size of the truncation marker as we don't know how big it will be yet
    local max_padding = string.rep(padding, 2)
    segments, marker, visible_components = truncate(before, current, after, available_width, {
      left_count = 0,
      right_count = 0,
      left_element_size = utils.measure(max_padding, left_trunc_icon, max_padding),
      right_element_size = utils.measure(max_padding, right_trunc_icon, max_padding),
    })
  end

  local marker_hl = hl.trunc_marker.hl_group
  local left_marker = get_trunc_marker(left_trunc_icon, marker_hl, marker_hl, marker.left_count)
  local right_marker = get_trunc_marker(right_trunc_icon, marker_hl, marker_hl, marker.right_count)

  local core = join(
    utils.merge_lists(
      { left_marker },
      segments,
      { right_marker, right_align },
      tab_indicator_segments,
      { tab_close_button }
    )
  )

  --- NOTE: the custom areas are essentially mini tablines a user can define so they can't
  --- be safely converted to segments so they are concatenated to string and joined with
  --- the rest of the tabline
  local tabline = utils.join(offsets.left, left_area, core, right_area, offsets.right)

  local left_offset_size = offsets.left_size + statusline_str_width(left_area)
  local left_marker_size = left_marker and get_component_size(left_marker) or 0
  local right_offset_size = offsets.right_size + statusline_str_width(right_area)
  local right_marker_size = right_marker and get_component_size(right_marker) or 0

  return {
    str = tabline,
    segments = segments,
    visible_components = visible_components,
    right_offset_size = right_offset_size + right_marker_size,
    left_offset_size = left_offset_size + left_marker_size,
  }
end

M.get_component_size = get_component_size
M.components = components
---Resolve the effective tab width for a given width/tab-count. Exposed for tests.
M.resolve_tab_size = resolve_tab_size

---Set the tab width used while building components for the current render.
---Pass `nil` to fall back to `options.tab_size`.
---@param size integer?
---@param regular boolean?
---@param plus table<integer, boolean>? buffer ids that get one extra column
---@param compact boolean? render non-current tabs in compact icon-only mode
---@param trim integer? optional chrome to drop (0 = none, 1 = no close slot, 2 = also no numbers, 3 = also no names)
function M.set_render_tab_size(size, regular, plus, compact, trim)
  render_tab_size = size
  render_regular = regular
  render_plus = plus
  render_compact = compact or false
  render_trim = trim or 0
end

if utils.is_test() then
  M.to_tabline_str = to_tabline_str
  M.set_id = set_id
  M.add_indicator = add_indicator
  M.get_name = get_name
end

return M
