local M = {}

local HIGHLIGHTS = {
  native = {
    [vim.diagnostic.severity.ERROR] = "DiagnosticVirtualTextError",
    [vim.diagnostic.severity.WARN] = "DiagnosticVirtualTextWarn",
    [vim.diagnostic.severity.INFO] = "DiagnosticVirtualTextInfo",
    [vim.diagnostic.severity.HINT] = "DiagnosticVirtualTextHint",
  },
  coc = {
    [vim.diagnostic.severity.ERROR] = "CocErrorVirtualText",
    [vim.diagnostic.severity.WARN] = "CocWarningVirtualText",
    [vim.diagnostic.severity.INFO] = "CocInfoVirtualText",
    [vim.diagnostic.severity.HINT] = "CocHintVirtualText",
  },
}
local ICONS = {
  [vim.diagnostic.severity.ERROR] = "",
  [vim.diagnostic.severity.WARN] = "",
  [vim.diagnostic.severity.INFO] = "",
  [vim.diagnostic.severity.HINT] = "",
}
local ICON_HIGHLIGHTS = {
  [vim.diagnostic.severity.ERROR] = "DiagnosticVirtualIconError",
  [vim.diagnostic.severity.WARN] = "DiagnosticVirtualIconWarn",
  [vim.diagnostic.severity.INFO] = "DiagnosticVirtualIconInfo",
  [vim.diagnostic.severity.HINT] = "DiagnosticVirtualIconHint",
}

-- These don't get copied, do they? We only pass around and compare pointers, right?
local SPACE = "space"
local DIAGNOSTIC = "diagnostic"
local OVERLAP = "overlap"
local BLANK = "blank"

---Returns the distance between two columns in cells.
---
---Some characters (like tabs) take up more than one cell.
---Additionally, inline virtual text can make the distance between two columns larger.
---A diagnostic aligned
---under such characters needs to account for that and add that many spaces to
---its left.
---
---@return integer
local function distance_between_cols(bufnr, lnum, start_col, end_col)
  return vim.api.nvim_buf_call(bufnr, function()
    local s = vim.fn.virtcol({ lnum + 1, start_col })
    local e = vim.fn.virtcol({ lnum + 1, end_col + 1 })
    return e - 1 - s
  end)
end

-- Technically this works, but if the size of any windows change, we don't have any way to force it to update.
-- That's fine for my own uses (since I just about always have 3 panes), but it's not a good general solution.
local function smallest_width_for_buffer(bufnr)
  local smallest_width = nil

  -- Iterate over all windows
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    -- If the window's buffer matches the given buffer number
    if vim.api.nvim_win_get_buf(win) == bufnr then
      -- Get the window's width
      local width = vim.api.nvim_win_get_width(win)

      -- If this is the first window or if this window is smaller than the smallest found so far
      if not smallest_width or width < smallest_width then
        smallest_width = width
      end
    end
  end

  return smallest_width
end

local function word_wrap(text, width)
  -- Find the last space before the width.
  local begin = 1
  local result = {}
  while begin + width < #text do
    local pos = begin + width
    local substring = string.sub(text, begin, pos)
    local prestring, after_space = string.match(substring, "(.*)%s+()")
    if not after_space then
      prestring = substring
      after_space = begin + #substring
    end
    table.insert(result, prestring)
    begin = begin + after_space - 1
  end
  table.insert(result, string.sub(text, begin))
  return table.concat(result, "\n")
end

---@param namespace number
---@param bufnr number
---@param diagnostics table
---@param opts boolean|Opts
---@param source 'native'|'coc'|nil If nil, defaults to 'native'.
function M.show(namespace, bufnr, diagnostics, opts, source)
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end
  vim.validate({
    namespace = { namespace, "n" },
    bufnr = { bufnr, "n" },
    diagnostics = {
      diagnostics,
      vim.islist or vim.tbl_islist,
      "a list of diagnostics",
    },
    opts = { opts, "t", true },
  })

  table.sort(diagnostics, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    else
      return a.col < b.col
    end
  end)

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  if #diagnostics == 0 then
    return
  end
  local highlight_groups = HIGHLIGHTS[source or "native"]

  -- This loop reads line by line, and puts them into stacks with some
  -- extra data, since rendering each line will require understanding what
  -- is beneath it.
  local line_stacks = {}
  local prev_lnum = -1
  local prev_col = 0
  for _, diagnostic in ipairs(diagnostics) do
    if line_stacks[diagnostic.lnum] == nil then
      line_stacks[diagnostic.lnum] = {}
    end

    local stack = line_stacks[diagnostic.lnum]

    if diagnostic.lnum ~= prev_lnum then
      table.insert(stack, { SPACE, string.rep(" ", distance_between_cols(bufnr, diagnostic.lnum, 0, diagnostic.col)) })
    elseif diagnostic.col ~= prev_col then
      -- Clarification on the magic numbers below:
      -- +1: indexing starting at 0 in one API but at 1 on the other.
      -- -1: for non-first lines, the previous col is already drawn.
      table.insert(
        stack,
        { SPACE, string.rep(" ", distance_between_cols(bufnr, diagnostic.lnum, prev_col + 1, diagnostic.col) - 1) }
      )
    else
      table.insert(stack, { OVERLAP, diagnostic.severity })
    end

    if diagnostic.message:find("^%s*$") then
      table.insert(stack, { BLANK, diagnostic })
    else
      table.insert(stack, { DIAGNOSTIC, diagnostic })
    end

    prev_lnum = diagnostic.lnum
    prev_col = diagnostic.col
  end

  for lnum, lelements in pairs(line_stacks) do
    local virt_lines = {}

    -- We read in the order opposite to insertion because the last
    -- diagnostic for a real line, is rendered upstairs from the
    -- second-to-last, and so forth from the rest.
    for i = #lelements, 1, -1 do -- last element goes on top
      if lelements[i][1] == DIAGNOSTIC then
        local diagnostic = lelements[i][2]
        local empty_space_hi
        if opts.virtual_lines and opts.virtual_lines.highlight_whole_line == false then
          empty_space_hi = ""
        else
          empty_space_hi = highlight_groups[diagnostic.severity]
        end

        local left = {}
        local overlap = false
        local multi = 0

        -- Iterate the stack for this line to find elements on the left.
        for j = 1, i - 1 do
          local type = lelements[j][1]
          local data = lelements[j][2]
          if type == SPACE then
            if multi == 0 then
              table.insert(left, { data, empty_space_hi })
            else
              table.insert(left, { string.rep("─", data:len()), highlight_groups[diagnostic.severity] })
            end
          elseif type == DIAGNOSTIC then
            -- If an overlap follows this, don't add an extra column.
            if lelements[j + 1][1] ~= OVERLAP then
              table.insert(left, { "│", highlight_groups[data.severity] })
            end
            overlap = false
          elseif type == BLANK then
            if multi == 0 then
              table.insert(left, { "└", highlight_groups[data.severity] })
            else
              table.insert(left, { "┴", highlight_groups[data.severity] })
            end
            multi = multi + 1
          elseif type == OVERLAP then
            overlap = true
          end
        end

        local center_symbol
        if overlap and multi > 0 then
          center_symbol = "┼"
        elseif overlap then
          center_symbol = "├"
        elseif multi > 0 then
          center_symbol = "┴"
        else
          center_symbol = "└"
        end
        -- local center_text =
        local center = {
          { string.format("%s%s", center_symbol, "───"), highlight_groups[diagnostic.severity] },
          { ICONS[diagnostic.severity], ICON_HIGHLIGHTS[diagnostic.severity] },
          { "  ", highlight_groups[diagnostic.severity] },
        }

        -- TODO: We can draw on the left side if and only if:
        -- a. Is the last one stacked this line.
        -- b. Has enough space on the left.
        -- c. Is just one line.
        -- d. Is not an overlap.

        local msg
        if diagnostic.code then
          msg = string.format("%s: %s", diagnostic.code, diagnostic.message)
        else
          msg = diagnostic.message
        end
        local prefix_size = 0
        for _, entry in ipairs(left) do
          prefix_size = prefix_size + entry[1]:len()
        end
        local width = opts.virtual_lines and opts.virtual_lines.width or 80
        if opts.virtual_lines.auto_width then
          local auto_width = smallest_width_for_buffer(bufnr)
          if auto_width and auto_width > 20 then
            width = auto_width - 10
          end
        end
        msg = word_wrap(msg, math.max(20, width - prefix_size))
        for msg_line in msg:gmatch("([^\n]+)") do
          local vline = {}
          vim.list_extend(vline, left)
          vim.list_extend(vline, center)
          vim.list_extend(vline, { { msg_line, highlight_groups[diagnostic.severity] } })

          table.insert(virt_lines, vline)

          -- Special-case for continuation lines:
          if overlap then
            center = { { "│", highlight_groups[diagnostic.severity] }, { "     ", empty_space_hi } }
          else
            center = { { "      ", empty_space_hi } }
          end
        end
      end
    end

    vim.api.nvim_buf_set_extmark(bufnr, namespace, lnum, 0, { virt_lines = virt_lines })
  end
end

---@param namespace number
---@param bufnr number
function M.hide(namespace, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

return M
