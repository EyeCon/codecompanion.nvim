---@class CodeCompanion.SlashCommand.Now: CodeCompanion.SlashCommand
local SlashCommand = {}

---@param args CodeCompanion.SlashCommand
function SlashCommand.new(args)
  local self = setmetatable({
    Chat = args.Chat,
    config = args.config,
    context = args.context,
  }, { __index = SlashCommand })

  return self
end

---Execute the slash command
---@return nil
function SlashCommand:execute()
  local Chat = self.Chat
  -- RFC 3339 with space separator: YYYY-MM-DD HH:MM:SS+HH:MM
  local date_str = os.date("%Y-%m-%d %H:%M:%S")
  local offset = os.date("%z")
  -- RFC 3339 requires a colon in the timezone offset
  local formatted_offset = offset:sub(1, 3) .. ":" .. offset:sub(4, 5)
  Chat:add_buf_message({ content = date_str .. formatted_offset })
end

return SlashCommand
