local lazy = require("bufferline.lazy")
local config = require("bufferline.config") ---@module "bufferline.config"
local utils = lazy.require("bufferline.utils") ---@module "bufferline.utils"
local highlights = lazy.require("bufferline.highlights") ---@module "bufferline.highlights"
local constants = lazy.require("bufferline.constants") ---@module "bufferline.constants"

local M = {}

local api = vim.api
local fn = vim.fn
local padding = constants.padding

---Format the content of a neighbouring offset's text
---@param size integer
---@param highlight table<string, string>
---@param offset table
---@param is_left boolean?
---@return string
local function get_section_text(size, highlight, offset, is_left)
  local text = offset.text

  if type(text) == "function" then text = text() end
  text = text or padding:rep(size - 2)

  local text_size, left, right = api.nvim_strwidth(text), 0, 0
  local alignment = offset.text_align or "center"

  if text_size + 2 >= size then
    text, left, right = utils.truncate_name(text, size - 2), 1, 1
  else
    local remainder = size - text_size
    local is_even, side = remainder % 2 == 0, remainder / 2
    if alignment == "center" then
      if not is_even then
        left, right = math.ceil(side), math.floor(side)
      else
        left, right = side, side
      end
    elseif alignment == "left" then
      left, right = 1, remainder - 1
    else
      left, right = remainder - 1, 1
    end
  end
  local str = highlight.text .. padding:rep(left) .. text .. padding:rep(right)
  if not offset.separator then return str end

  local sep_icon = type(offset.separator) == "string" and offset.separator or "│"
  local sep = highlight.sep .. sep_icon
  return (not is_left and sep or "") .. str .. (is_left and sep or "")
end

---A heuristic to attempt to derive a windows background color from a winhighlight
---@param win_id integer
---@param attribute string?
---@param match string?
---@return string|nil
local function guess_window_highlight(win_id, attribute, match)
  assert(win_id, 'A window id must be passed to "guess_window_highlight"')
  attribute = attribute or "bg"
  match = match or "Normal"
  local hl = vim.wo[win_id].winhighlight
  if not hl then return end
  local parts = vim.split(hl, ",")
  for i = #parts, 1, -1 do
    local grp, hl_name = unpack(vim.split(parts[i], ":"))
    if grp and grp:match(match) then return hl_name end
  end
  return match
end

--- Collect the current tab's normal windows grouped into columns. Windows
--- stacked vertically (horizontal splits) share a column, which is what an
--- offset is drawn against.
---@return table[]
local function get_columns()
  local tabpage = api.nvim_get_current_tabpage()
  local columns, seen = {}, {}
  for _, win_id in ipairs(api.nvim_tabpage_list_wins(tabpage)) do
    if api.nvim_win_get_config(win_id).relative == "" then
      local info = fn.getwininfo(win_id)[1]
      if info then
        local key = string.format("%d:%d", info.wincol, info.width)
        local column = seen[key]
        if not column then
          column = { wincol = info.wincol, width = info.width, windows = {} }
          seen[key] = column
          columns[#columns + 1] = column
        end
        column.windows[#column.windows + 1] = win_id
      end
    end
  end
  table.sort(columns, function(a, b) return a.wincol < b.wincol end)
  return columns
end

--- Find the window that should back an offset. Only the leftmost and rightmost
--- columns can carry an offset, but the matching buffer may live in any window
--- of that column (e.g. a panel that is itself split horizontally) (#789).
---@param offset table
---@param columns table[]
---@return number?, boolean?
local function find_offset_window(offset, columns)
  local last = #columns
  if last < 2 then return nil, nil end
  for index, column in ipairs(columns) do
    local is_left = index == 1
    if is_left or index == last then
      for _, win_id in ipairs(column.windows) do
        local buf = api.nvim_win_get_buf(win_id)
        if buf and vim.bo[buf].filetype == offset.filetype then return win_id, is_left end
      end
    end
  end
  return nil, nil
end

---@class OffsetData
---@field total_size number
---@field left string
---@field right string
---@field left_size integer
---@field right_size integer

---Calculate the size of padding required to offset the bufferline
---@return OffsetData
function M.get()
  local offsets, hls = config.options.offsets, config.highlights
  local left = ""
  local right = ""
  local left_size = 0
  local right_size = 0
  local total_size = 0
  local sep_hl = highlights.hl(hls.offset_separator.hl_group)

  if offsets and #offsets > 0 then
    local columns = get_columns()

    for _, offset in ipairs(offsets) do
      local win_id, is_left = find_offset_window(offset, columns)
      if win_id then
        local width = api.nvim_win_get_width(win_id) + (offset.padding or 0)

        local hl_name = offset.highlight or guess_window_highlight(win_id) or config.highlights.fill.hl_group

        local hl = highlights.hl(hl_name)
        local component = get_section_text(width, { text = hl, sep = sep_hl }, offset, is_left)

        total_size = total_size + width

        if is_left then
          left, left_size = component, left_size + width
        else
          right, right_size = component, right_size + width
        end
      end
    end
  end
  return {
    left = left,
    right = right,
    left_size = left_size,
    right_size = right_size,
    total_size = total_size,
  }
end

return M
