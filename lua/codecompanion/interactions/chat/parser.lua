--=============================================================================
-- Functions for parsing a chat buffer using Tree-sitter
--=============================================================================
local config = require("codecompanion.config")
local helpers = require("codecompanion.interactions.chat.helpers")
local log = require("codecompanion.utils.log")
local yaml = require("codecompanion.utils.yaml")

local get_node_text = vim.treesitter.get_node_text --[[@type function]]
local get_query = vim.treesitter.query.get --[[@type function]]

local cached_markdown_chat_query
local function markdown_chat_query()
  cached_markdown_chat_query = cached_markdown_chat_query or get_query("markdown", "chat")
  return cached_markdown_chat_query
end

local cached_yaml_chat_query
local function yaml_chat_query()
  cached_yaml_chat_query = cached_yaml_chat_query or get_query("yaml", "chat")
  return cached_yaml_chat_query
end

local cached_image_query
local function image_query()
  cached_image_query = cached_image_query
    or vim.treesitter.query.parse(
      "markdown_inline",
      [[((image) @image)
    ((inline_link) @link)]]
    )
  return cached_image_query
end

local M = {}

---Parse the chat buffer for settings
---@param bufnr number
---@param parser vim.treesitter.LanguageTree
---@param adapter? CodeCompanion.HTTPAdapter
---@return table
function M.settings(bufnr, parser, adapter)
  local settings = {}

  local query = yaml_chat_query()
  local root = parser:parse()[1]:root()

  local end_line = -1
  if adapter then
    -- Account for the two YAML lines and the fact Tree-sitter is 0-indexed
    end_line = vim.tbl_count(adapter.schema) + 2 - 1
  end

  for _, matches, _ in query:iter_matches(root, bufnr, 0, end_line) do
    local nodes = matches[1]
    local node = type(nodes) == "table" and nodes[1] or nodes

    local value = get_node_text(node, bufnr)

    settings = yaml.decode(value)
    break
  end

  if not settings then
    log:error("[chat::parser] Failed to parse settings in chat buffer")
    return {}
  end

  return settings
end

---Recursively walk a Tree-sitter tree to find block_mapping_pair nodes
---containing the given row position
---@param node TSNode
---@param row number 0-indexed row
---@param result table Accumulator for found pairs
local function find_pairs_at_row(node, row, result)
  for child in node:iter_children() do
    if child:type() == "block_mapping_pair" then
      local sr, _, er, _ = child:range()
      if sr <= row and row <= er then
        table.insert(result, child)
      end
    else
      -- Recurse into intermediate nodes (stream, document, block_node, block_mapping, etc.)
      local sr, _, er, _ = child:range()
      if sr <= row and row <= er then
        find_pairs_at_row(child, row, result)
      end
    end
  end
end

---Get the settings key at the current cursor position
---@param chat CodeCompanion.Chat
---@param opts? table
function M.get_settings_key(chat, opts)
  opts = opts or {}
  local cursor
  if opts.pos then
    cursor = opts.pos -- already 0-indexed
  else
    cursor = vim.api.nvim_win_get_cursor(0)
    cursor[1] = cursor[1] - 1 -- convert from 1-indexed to 0-indexed
  end
  local row = cursor[1]
  local col = cursor[2] or 0

  -- Use the chat's dedicated YAML parser (which works in the injected region)
  -- instead of vim.treesitter.get_node() which cannot traverse into injections
  -- in a markdown buffer.
  if not chat.parsers or not chat.parsers.yaml then
    return
  end

  local root = chat.parsers.yaml:parse()[1]:root()

  -- Recursively find all block_mapping_pair nodes on the cursor row
  local pairs = {}
  find_pairs_at_row(root, row, pairs)

  if #pairs == 0 then
    return
  end

  -- Pick the best match: the pair whose key column range contains col,
  -- or the last pair on the row (most specific/innermost)
  local best_node = nil
  for _, pair in ipairs(pairs) do
    local key_node = pair:named_child(0)
    if key_node then
      local _, ksc, _, kec = key_node:range()
      if ksc <= col and col <= kec then
        best_node = pair
        break
      end
    end
    best_node = pair
  end

  local key_node = best_node:named_child(0)
  local key_name = get_node_text(key_node, chat.bufnr)
  -- Strip surrounding quotes from quoted YAML keys (e.g. "provider.order")
  if key_name then
    key_name = key_name:match('^"(.+)"$') or key_name:match("^'(.+)'$") or key_name
  end
  return key_name, best_node
end

---Parse the chat buffer for the last message
---@param chat CodeCompanion.Chat
---@param start_range number
---@return { content: string }|nil
function M.messages(chat, start_range)
  local query = markdown_chat_query()

  local tree = chat.parsers.markdown:parse({ start_range - 1, -1 })[1]
  local root = tree:root()

  local content = {}
  local last_role = nil

  for id, node in query:iter_captures(root, chat.bufnr, start_range - 1, -1) do
    if query.captures[id] == "role" then
      last_role = helpers.format_role(get_node_text(node, chat.bufnr))
    elseif last_role == config.interactions.chat.roles.user and query.captures[id] == "content" then
      table.insert(content, get_node_text(node, chat.bufnr))
    end
  end

  content = helpers.strip_context(content) -- If users send a blank message to the LLM, sometimes context is included
  if not vim.tbl_isempty(content) then
    return { content = vim.trim(table.concat(content, "\n\n")) }
  end

  return nil
end

---Parse the chat buffer for the last header
---@param chat CodeCompanion.Chat
---@return number|nil
function M.headers(chat)
  local query = markdown_chat_query()

  local tree = chat.parsers.markdown:parse({ 0, -1 })[1]
  local root = tree:root()

  local last_match = nil
  for id, node in query:iter_captures(root, chat.bufnr) do
    if query.captures[id] == "role_only" then
      local role = helpers.format_role(get_node_text(node, chat.bufnr))
      if role == config.interactions.chat.roles.user then
        last_match = node
      end
    end
  end

  if last_match then
    return last_match:range()
  end
end

---Parse a section of the buffer for Markdown images.
---@param chat CodeCompanion.Chat The chat instance.
---@param start_range number The 1-indexed line number from where to start parsing.
function M.images(chat, start_range)
  local ts_query = image_query()
  local parser = chat.parsers.markdown_inline or vim.treesitter.get_parser(chat.bufnr, "markdown_inline")

  local tree = parser:parse({ start_range, -1 })[1]
  local root = tree:root()

  local links = {}

  for id, node in ts_query:iter_captures(root, chat.bufnr, start_range - 1, -1) do
    local capture_name = ts_query.captures[id]
    if capture_name == "image" or capture_name == "link" then
      local link_label_text = nil
      local link_dest_text = nil

      for child in node:iter_children() do
        local child_type = child:type()

        if child_type == "link_text" or child_type == "image_description" then
          local text = get_node_text(child, chat.bufnr)
          link_label_text = text
        elseif child_type == "link_destination" then
          local text = get_node_text(child, chat.bufnr)
          link_dest_text = text
        end
      end

      if link_dest_text and (capture_name == "image" or link_label_text == "Image") then
        table.insert(links, { text = link_label_text, path = link_dest_text })
      end
    end
  end

  if vim.tbl_isempty(links) then
    return nil
  end

  return links
end

---Parse the chat buffer for a code block
---returns the code block that the cursor is in or the last code block
---@param chat CodeCompanion.Chat
---@param cursor? table
---@return TSNode|nil
function M.codeblock(chat, cursor)
  local root = chat.parsers.markdown:parse()[1]:root()
  local query = markdown_chat_query()
  if query == nil then
    return nil
  end

  local last_match = nil
  for id, node in query:iter_captures(root, chat.bufnr, 0, -1) do
    if query.captures[id] == "code" then
      if cursor then
        local start_row, start_col, end_row, end_col = node:range()
        if cursor[1] >= start_row and cursor[1] <= end_row and cursor[2] >= start_col and cursor[2] <= end_col then
          return node
        end
      end
      last_match = node
    end
  end

  return last_match
end

return M
