---@diagnostic disable: need-check-nil
describe("Highlights -", function()
  local highlights ---@module "bufferline.highlights"
  local config ---@module "bufferline.config"

  before_each(function()
    package.loaded["bufferline.highlights"] = nil
    package.loaded["bufferline.config"] = nil

    highlights = require("bufferline.highlights")
    config = require("bufferline.config")
  end)

  it("should set highlights as default", function()
    config.setup({ options = { themable = true } })
    config.apply()
    local hl = highlights.set("BufferLineBufferSelected", { bold = true })
    assert.truthy(hl)
    assert.is_true(hl.default)
  end)

  it("should not set highlights as default if themable = false", function()
    config.setup({ options = { themable = true } })
    config.apply()
    local hl = highlights.set("BufferLineBufferSelected", { bold = true })
    assert.truthy(hl)
    assert.is_true(hl.default)
  end)

  it("should evaluate function-valued colours on set", function()
    config.setup({ options = { themable = false } })
    config.apply()
    local hl = highlights.set("BufferLineFnColor", { fg = function() return "#123456" end })
    assert.truthy(hl)
    assert.equals("#123456", hl.fg)
    local applied = vim.api.nvim_get_hl(0, { name = "BufferLineFnColor" })
    assert.equals(0x123456, applied.fg)
  end)
end)
