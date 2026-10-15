describe("State -", function()
  local state ---@module "bufferline.state"

  before_each(function()
    package.loaded["bufferline.state"] = nil
    state = require("bufferline.state")
  end)

  it("should scope custom_sort to the current tabpage", function()
    state.set({ custom_sort = { 1, 2, 3 } })
    assert.same({ 1, 2, 3 }, state.custom_sort)

    vim.cmd("tabnew")
    assert.is_nil(state.custom_sort)
    state.set({ custom_sort = { 9 } })
    assert.same({ 9 }, state.custom_sort)

    vim.cmd("tabprevious")
    assert.same({ 1, 2, 3 }, state.custom_sort)

    vim.cmd("tabclose")
  end)

  it("should prune custom_sort for closed tabpages", function()
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    state.set({ custom_sort = { 1 } })
    vim.cmd("tabclose")
    state.prune_custom_sorts()
    assert.is_nil(state.custom_sorts[tab])
  end)
end)
