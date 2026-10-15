local M = {}

local lazy = require("bufferline.lazy")
local utils = lazy.require("bufferline.utils") ---@module "bufferline.utils"

local api = vim.api

-----------------------------------------------------------------------------//
-- State
-----------------------------------------------------------------------------//

---@type bufferline.State
local state = {
  is_picking = false,
  hovered = nil,
  -- custom buffer order is tracked per tabpage so that sorting/moving buffers in
  -- one tab does not leak into the (different) buffer set of another tab.
  custom_sorts = {},
  current_element_index = nil,
  components = {},
  __components = {},
  visible_components = {},
  left_offset_size = 0,
  right_offset_size = 0,
}

---@param list bufferline.Component[]
---@return bufferline.Component[]
local function filter_invisible(list)
  return utils.fold(function(accum, item)
    if item.focusable ~= false and not item.hidden then table.insert(accum, item) end
    return accum
  end, list, {})
end

local component_keys = { "components", "visible_components" }

---@param new_state bufferline.State
function M.set(new_state)
  for key, value in pairs(new_state) do
    if value == vim.NIL then value = nil end
    if key == "custom_sort" then
      -- scoped to the current tabpage, see state.custom_sorts
      state.custom_sorts[api.nvim_get_current_tabpage()] = value
    else
      if vim.tbl_contains(component_keys, key) then
        value = filter_invisible(value --[=[@as bufferline.Component[]]=])
      end
      state[key] = value
    end
  end
end

---Drop stored sort order for tabpages that no longer exist (avoids unbounded
---growth of `custom_sorts` over a long session).
function M.prune_custom_sorts()
  local live = {}
  for _, tabpage in ipairs(api.nvim_list_tabpages()) do
    live[tabpage] = true
  end
  for tabpage in pairs(state.custom_sorts) do
    if not live[tabpage] then state.custom_sorts[tabpage] = nil end
  end
end

return setmetatable(M, {
  __index = function(_, k)
    if k == "custom_sort" then return state.custom_sorts[api.nvim_get_current_tabpage()] end
    return state[k]
  end,
})
