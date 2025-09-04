local toowide = require("toowide")

local function new_buf(lines, ft)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  if ft then
    vim.bo[buf].filetype = ft
  end
  return buf
end

local function get_marks(buf)
  local ns = vim.api.nvim_get_namespaces()["LineLengthHighlight"]
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end

describe("toowide", function()
  before_each(function()
    -- Use a small limit and fast debounce for tests
    toowide.config.default_limit = 3
    toowide.config.debounce_ms = 10
    toowide.setup_highlight()
  end)

  it("computes limit from textwidth when set", function()
    local buf = new_buf({}, "lua")
    vim.bo[buf].textwidth = 100
    local limit = toowide.get_limit(buf)
    assert(limit == 100, "expected limit 100, got " .. tostring(limit))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("falls back to filetype_limits when textwidth is 0", function()
    local buf = new_buf({}, "go")
    vim.bo[buf].textwidth = 0
    local limit = toowide.get_limit(buf)
    assert(limit == 120, "expected limit 120 for go, got " .. tostring(limit))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("highlights characters beyond the limit", function()
    local buf = new_buf({ "abc", "abcd", "abcdefgh" }, "text")
    toowide.highlight(buf)
    local marks = get_marks(buf)
    assert(#marks == 2, "expected 2 extmarks, got " .. tostring(#marks))

    -- Organize marks by row for assertions
    local by_row = {}
    for _, m in ipairs(marks) do
      local row, col, details = m[2], m[3], m[4]
      by_row[row] = { col = col, end_col = details.end_col }
    end

    assert(by_row[1] ~= nil, "missing mark on line 2")
    assert(by_row[1].col == 3, "start col should be 3 for 'abcd'")
    assert(by_row[1].end_col == 4, "end col should be 4 for 'abcd'")

    assert(by_row[2] ~= nil, "missing mark on line 3")
    assert(by_row[2].col == 3, "start col should be 3 for 'abcdefgh'")
    assert(by_row[2].end_col == 8, "end col should be 8 for 'abcdefgh'")

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("attaches, updates on changes with debounce, and detaches clearing marks", function()
    local buf = new_buf({ "abc", "abcd" }, "text")
    toowide.attach_buffer(buf)
    vim.wait(50, function()
      return false
    end)

    local marks = get_marks(buf)
    assert(#marks == 1, "expected 1 extmark after initial highlight, got " .. tostring(#marks))

    -- Make first line exceed the limit
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "abcd" })
    vim.wait(50, function()
      return false
    end)

    marks = get_marks(buf)
    assert(#marks == 2, "expected 2 extmarks after change, got " .. tostring(#marks))

    -- Detach and ensure marks are cleared
    toowide.detach_buffer(buf)
    marks = get_marks(buf)
    assert(#marks == 0, "expected 0 extmarks after detach, got " .. tostring(#marks))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("should_enable enables on buffers", function()
    local buf = new_buf({ "foo.yaml" }, "yaml")
    local enabled = toowide.should_enable(buf)
    assert(enabled == true, "expected enabled for YAML")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("should_enable respects excluded filetypes", function()
    local buf = new_buf({ "foo" }, "NeogitStatus")
    local enabled = toowide.should_enable(buf)
    assert(enabled == false, "expected disabled for excluded filetype")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("should_disable when computed limit is 0", function()
    local buf = new_buf({}, "zeroft")
    toowide.config.filetype_limits["zeroft"] = 0
    local enabled = toowide.should_enable(buf)
    assert(enabled == false, "expected disabled when limit is 0")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
