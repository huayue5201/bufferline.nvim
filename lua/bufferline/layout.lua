--- Tab width allocation for the tabline.
---
--- This replaces the stack of estimators (`fit_regular` -> `fit_expand` ->
--- `fit_compact`, each with its own probe measurement, plus a boolean `plus`
--- table to scatter leftover columns) that used to live in `bufferline.lua`.
--- That stack had two structural problems:
---
---   * a tab's rendered length is not a pure function of its assigned width
---     (a name longer than the width overflows it, diagnostics/markers can come
---     and go), so every estimator needed its own shrink/re-measure loop, and
---     shrinking a per-tab width by the *total* overflow removes `count` columns
---     per step, which is how the tabline ended up with a large gap before the
---     right edge;
---   * leftover columns were only ever handed out one per tab, so a remainder
---     bigger than the tab count could not be absorbed at all.
---
--- Here every layout goes through one path:
---
---   1. render once per decoration level ("trim") to learn how much width each
---      tab spends outside its padded name block, its *chrome* (icon, number,
---      diagnostics, duplicates, separators);
---   2. give the focused tab its full name, browser style, and split the rest
---      of the bar evenly between the other tabs;
---   3. correct the assignment against a real measurement until the tabs fill
---      the available width exactly, distributing whatever is left column by
---      column instead of guessing.
local M = {}

---Width used to measure a tab's chrome: wide enough that most names fit inside
---the padded block, narrow enough that long names are truncated.
local PROBE = 24

---@class bufferline.Layout
---@field widths table<integer, integer>? buffer id -> padded name width
---@field size integer? width used for every tab when `widths` is absent
---@field trim integer decoration level: 0 full, 1 no close slot, 2 + no numbers, 3 + no names
---@field expand boolean let the focused tab grow to its full name

---@class bufferline.LayoutCtx
---@field assemble fun(): bufferline.Component[]
---@field apply fun(layout: bufferline.Layout?)
---@field available integer
---@field options bufferline.Options

---@param ctx bufferline.LayoutCtx
---@param layout bufferline.Layout
---@return bufferline.Component[]
local function render(ctx, layout)
  ctx.apply(layout)
  return ctx.assemble()
end

---Sum of the rendered widths of a component list.
---@param list bufferline.Component[]
---@return integer
local function total_length(list)
  local total = 0
  for _, component in ipairs(list) do
    if not component.hidden then total = total + component.length end
  end
  return total
end

---Render once and collect the tabs of the list.
---
---`chrome` is the width a tab spends on everything but its padded name block.
---It is assumed to be independent of the assigned width, which holds for icons,
---numbers, diagnostics and separators; the correction step below absorbs the
---cases where it does not (a name that cannot be truncated any further).
---@param ctx bufferline.LayoutCtx
---@param layout bufferline.Layout
---@return table[] tabs, integer fixed, integer? focus
local function inspect(ctx, layout)
  local probe_width = layout.size or PROBE
  local tabs, fixed, focus = {}, 0, nil
  for _, component in ipairs(render(ctx, layout)) do
    if not component.hidden then
      if component.is_tab then
        tabs[#tabs + 1] = {
          id = component.id,
          chrome = math.max(0, component.length - probe_width),
        }
        if component:current() then focus = #tabs end
      else
        fixed = fixed + component.length
      end
    end
  end
  return tabs, fixed, focus
end

---Length of the focused tab once it is allowed to show its full name.
---@param ctx bufferline.LayoutCtx
---@param layout bufferline.Layout
---@return integer?
local function focused_length(ctx, layout)
  for _, component in ipairs(render(ctx, layout)) do
    if not component.hidden and component.is_tab and component:current() then return component.length end
  end
  return nil
end

---Grow or shrink the assigned widths until the tabline is exactly
---`ctx.available` columns wide.
---
---Columns are handed out one at a time (round robin over the tabs that are
---allowed to resize), so the leftover space always ends up on screen instead of
---becoming a gap before the right edge. Returns nil when the widths cannot be
---adjusted any further (`widths` may be mutated in that case, so callers must
---treat a nil result as "try another level").
---@param ctx bufferline.LayoutCtx
---@param layout bufferline.Layout
---@param tabs table[]
---@param focus integer?
---@return bufferline.Layout?
local function fill(ctx, layout, tabs, focus)
  local ids = {}
  for index, tab in ipairs(tabs) do
    if not (layout.expand and index == focus) then ids[#ids + 1] = tab.id end
  end
  if #ids == 0 then return nil end

  for _ = 1, 8 do
    local delta = ctx.available - total_length(render(ctx, layout))
    if delta == 0 then return layout end

    local step = delta > 0 and 1 or -1
    local remaining = math.abs(delta)
    local stalled, index = 0, 0
    while remaining > 0 and stalled < #ids do
      index = index % #ids + 1
      local id = ids[index]
      local width = layout.widths[id] + step
      if width >= 1 then
        layout.widths[id] = width
        remaining = remaining - 1
        stalled = 0
      else
        stalled = stalled + 1
      end
    end
    if remaining > 0 then return nil end
  end
  return nil
end

---Split `budget` columns between `count` tabs of equal width, taking the
---immovable `chrome` out of the budget first and honoring the size bounds.
---@param budget integer
---@param chrome integer
---@param count integer
---@param options bufferline.Options
---@return integer? base
local function equal_width(budget, chrome, count, options)
  if count <= 0 then return nil end
  local base = math.floor((budget - chrome) / count)
  if options.max_tab_size and options.max_tab_size > 0 then base = math.min(base, options.max_tab_size) end
  if options.min_tab_size and options.min_tab_size > 0 then base = math.max(base, options.min_tab_size) end
  if base < 1 then return nil end
  return base
end

---Lay the tabs out at one decoration level.
---@param ctx bufferline.LayoutCtx
---@param trim integer
---@param expand boolean
---@return bufferline.Layout?
local function fit_level(ctx, trim, expand)
  local options = ctx.options

  -- Probe pass: give every tab the same known width so the chrome of each tab
  -- can be read off its rendered length.
  local seeded = render(ctx, { widths = {}, trim = trim, expand = false })
  local probe_widths = {}
  for _, component in ipairs(seeded) do
    if not component.hidden and component.is_tab then probe_widths[component.id] = PROBE end
  end
  local tabs, fixed, focus = inspect(ctx, { widths = probe_widths, trim = trim, expand = false })
  local count = #tabs
  if count == 0 then return nil end

  -- The focused tab, if any, keeps its name in full; it is then excluded from
  -- the even split below.
  local focus_length
  if expand and focus then
    focus_length = focused_length(ctx, { widths = probe_widths, trim = trim, expand = true })
    if not focus_length then expand = false end
  end
  if not expand then focus = nil end

  local ids, chrome = {}, 0
  for index, tab in ipairs(tabs) do
    if not (expand and index == focus) then
      ids[#ids + 1] = tab.id
      chrome = chrome + tab.chrome
    end
  end

  local budget = ctx.available - fixed - (focus_length or 0)
  local base = equal_width(budget, chrome, #ids, options)
  if not base then return nil end
  -- Expanding is only worth it when the focused tab really is wider than the
  -- tabs it keeps company with.
  if expand and base >= focus_length then return nil end

  local widths = {}
  for _, id in ipairs(ids) do widths[id] = base end
  -- Columns that do not divide evenly go to the leftmost tabs.
  local leftover = budget - chrome - base * #ids
  for _, id in ipairs(ids) do
    if leftover <= 0 then break end
    widths[id] = widths[id] + 1
    leftover = leftover - 1
  end

  local layout = { widths = widths, trim = trim, expand = expand }
  return fill(ctx, layout, tabs, focus)
end

---Last resort: one column per tab, everything else heaped onto the first tab so
---the tabline still reaches the right edge.
---@param ctx bufferline.LayoutCtx
---@param trim integer
---@return bufferline.Layout
local function fit_minimal(ctx, trim)
  local seeded = render(ctx, { widths = {}, trim = trim, expand = false })
  local tabs, fixed, focus = inspect(ctx, { widths = {}, trim = trim, expand = false })
  local widths, first = {}, nil
  for index, tab in ipairs(tabs or {}) do
    widths[tab.id] = 1
    if (not first) or index == (focus or 1) then first = tab.id end
  end
  if not first then
    for _, component in ipairs(seeded) do
      if component.is_tab then first = component.id end
    end
  end
  if first then
    local widths_all = widths
    local chrome_all = 0
    for _, tab in ipairs(tabs or {}) do
      chrome_all = chrome_all + tab.chrome
    end
    local spare = ctx.available - fixed - chrome_all - #(tabs or {})
    if spare > 0 then widths_all[first] = 1 + spare end
  end
  return { widths = widths, trim = trim, expand = false }
end

---Pick the layout that best fills the bar.
---
---Decorations are dropped in order (close slot, numbers, names) before the tabs
---themselves are allowed to collapse, so a bar narrowed by a sidebar offset
---keeps its labels for as long as possible.
---@param ctx bufferline.LayoutCtx
---@return bufferline.Layout
function M.fit(ctx)
  for trim = 0, 3 do
    for _, expand in ipairs({ true, false }) do
      local layout = fit_level(ctx, trim, expand)
      if layout then return layout end
    end
  end
  return fit_minimal(ctx, 3)
end

return M
