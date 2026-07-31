local Curl = require("plenary.curl")
local adapter_utils = require("codecompanion.adapters.utils")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")

local _cache_expires_models
local _cached_models

---Return the cached models
---@param opts? table
local function models(opts)
  if opts and opts.last then
    return _cached_models[1]
  end
  return _cached_models
end

---Get a list of available OpenRouter models
---@param self CodeCompanion.HTTPAdapter
---@param opts? table
---@return table
local function get_models(self, opts)
  if _cached_models and _cache_expires_models and _cache_expires_models > os.time() then
    return models(opts)
  end

  _cached_models = {}

  local adapter = require("codecompanion.adapters").resolve(self)
  if not adapter then
    log:error("Could not resolve OpenRouter adapter for model fetching")
    return {}
  end

  adapter_utils.get_env_vars(adapter, { timeout = config.adapters.opts.cmd_timeout })
  local url = adapter.env_replaced.url .. adapter.env_replaced.models_endpoint

  local headers = adapter_utils.set_env_vars(adapter, adapter.headers) or {}

  local ok, response, json

  ok, response = pcall(function()
    return Curl.get(url, {
      sync = true,
      headers = headers,
      insecure = config.adapters.http.opts.allow_insecure,
      proxy = config.adapters.http.opts.proxy,
    })
  end)
  if not ok then
    log:error("Could not fetch OpenRouter models from %s.\nError: %s", url, response)
    return {}
  end

  ok, json = pcall(vim.json.decode, response.body)
  if not ok then
    log:error("Could not parse OpenRouter model response from %s", url)
    return {}
  end

  for _, model in ipairs(json.data) do
    table.insert(_cached_models, model.id)
  end

  _cache_expires_models = adapter_utils.cache_expiry(config.adapters.http.opts.cache_models_for)

  return models(opts)
end

local _cache_expires_providers
local _cached_providers

---Fetch the list of available OpenRouter providers with caching
---@param self CodeCompanion.HTTPAdapter
---@return table Dict-style: {["slug"] = {formatted_name = "Name"}}
local function get_providers(self)
  if _cached_providers and _cache_expires_providers and _cache_expires_providers > os.time() then
    return _cached_providers
  end

  _cached_providers = {}

  local adapter = require("codecompanion.adapters").resolve(self)
  if not adapter then
    log:error("Could not resolve OpenRouter adapter for provider fetching")
    return {}
  end

  adapter_utils.get_env_vars(adapter, { timeout = config.adapters.opts.cmd_timeout })
  local url = adapter.env_replaced.url .. "/v1/providers"

  local headers = adapter_utils.set_env_vars(adapter, adapter.headers) or {}

  local ok, response = pcall(function()
    return Curl.get(url, {
      sync = true,
      headers = headers,
      insecure = config.adapters.http.opts.allow_insecure,
      proxy = config.adapters.http.opts.proxy,
    })
  end)
  if not ok then
    log:error("Could not fetch OpenRouter providers from %s.\nError: %s", url, response)
    return {}
  end

  local json
  ok, json = pcall(vim.json.decode, response.body)
  if not ok then
    log:error("Could not parse OpenRouter provider response from %s", url)
    return {}
  end

  for _, provider in ipairs(json.data) do
    _cached_providers[provider.slug] = {
      formatted_name = provider.name,
    }
  end

  _cache_expires_providers = adapter_utils.cache_expiry(config.adapters.http.opts.cache_models_for)

  return _cached_providers
end

---@class CodeCompanion.HTTPAdapter.OpenRouter: CodeCompanion.HTTPAdapter
return require("codecompanion.adapters").extend("openai", {
  name = "openrouter_eyecon",
  formatted_name = "OpenRouter (EyeCon)",
  env = {
    api_key = "OPENROUTER_API_KEY",
    url = "https://openrouter.ai/api",
    chat_url = "/v1/chat/completions",
    models_endpoint = "/v1/models",
  },
  url = "${url}${chat_url}",
  schema = {
    ---@type CodeCompanion.Schema
    model = {
      desc = "ID of the model to use. See https://openrouter.ai/models for available models.",
      default = function(self)
        return get_models(self, { last = true })
      end,
      choices = function(self)
        return get_models(self)
      end,
    },
    ---@type CodeCompanion.Schema
    reasoning_effort = {
      type = "enum",
      enabled = true,
      default = nil,
      desc = "Constrains effort on reasoning for reasoning models. Reducing reasoning effort can result in faster responses and fewer tokens used on reasoning in a response.",
      choices = { "xhigh", "high", "medium", "low", "minimal", "none" },
    },
    -- temperature, top_p, stop, max_tokens, presence_penalty, frequency_penalty,
    -- logit_bias, and user are inherited from the openai adapter
    ---@type CodeCompanion.Schema
    top_k = {
      order = 11,
      mapping = "parameters",
      type = "integer",
      optional = true,
      default = nil,
      desc = "Limits the model's choice of tokens at each step, making it choose from a smaller set. A value of 1 means the model will always pick the most likely next token, leading to predictable results. By default this setting is disabled.",
      validate = function(n)
        return n >= 0, "Must be 0 or above"
      end,
    },
    ---@type CodeCompanion.Schema
    -- repetition_penalty = {
    --   order = 12,
    --   mapping = "parameters",
    --   type = "number",
    --   optional = true,
    --   default = nil,
    --   desc = "Helps to reduce the repetition of tokens from the input. A higher value makes the model less likely to repeat tokens, but too high a value can make the output less coherent. Token penalty scales based on original token's probability.",
    --   validate = function(n)
    --     return n >= 0 and n <= 2, "Must be between 0 and 2"
    --   end,
    -- },
    ---@type CodeCompanion.Schema
    -- min_p = {
    --   order = 13,
    --   mapping = "parameters",
    --   type = "number",
    --   optional = true,
    --   default = nil,
    --   desc = "Represents the minimum probability for a token to be considered, relative to the probability of the most likely token. If Min-P is set to 0.1, only tokens at least 1/10th as probable as the best option are considered.",
    --   validate = function(n)
    --     return n >= 0 and n <= 1, "Must be between 0 and 1"
    --   end,
    -- },
    ---@type CodeCompanion.Schema
    -- top_a = {
    --   order = 14,
    --   mapping = "parameters",
    --   type = "number",
    --   optional = true,
    --   default = nil,
    --   desc = "Consider only the top tokens with sufficiently high probabilities based on the probability of the most likely token. Think of it like a dynamic Top-P. A lower value focuses choices based on the highest probability token but with a narrower scope.",
    --   validate = function(n)
    --     return n >= 0 and n <= 1, "Must be between 0 and 1"
    --   end,
    -- },
    ---@type CodeCompanion.Schema
    max_completion_tokens = {
      order = 15,
      mapping = "parameters",
      type = "integer",
      optional = true,
      default = nil,
      desc = "The upper limit for the number of tokens the model can generate in response. It won't produce more than this limit. The maximum value is the context length minus the prompt length.",
      validate = function(n)
        return n > 0, "Must be greater than 0"
      end,
    },
    ---@type CodeCompanion.Schema
    verbosity = {
      order = 16,
      mapping = "parameters",
      type = "enum",
      optional = true,
      default = nil,
      desc = "Constrains the verbosity of the model's response. Lower values produce more concise responses, while higher values produce more detailed and comprehensive responses.",
      choices = { "low", "medium", "high", "xhigh", "max" },
    },
    ---@type CodeCompanion.Schema
    ["provider.order"] = {
      order = 20,
      mapping = "parameters",
      type = "ordered_choices",
      optional = true,
      default = nil,
      choices = get_providers,
      desc = "Preferred provider routing order (select to remove/append, re-append to reorder)",
    },
    ---@type CodeCompanion.Schema
    ["provider.only"] = {
      order = 21,
      mapping = "parameters",
      type = "ordered_choices",
      optional = true,
      default = nil,
      choices = get_providers,
      desc = "Forced provider routing order (select to remove/append, re-append to reorder)",
    },
    ---@type CodeCompanion.Schema
    ["provider.allow_fallbacks"] = {
      order = 22,
      mapping = "parameters",
      type = "boolean",
      optional = true,
      default = true,
      desc = "Allow backup providers when primary is unavailable",
    },
    ---@type CodeCompanion.Schema
    ["provider.sort"] = {
      order = 23,
      mapping = "parameters",
      type = "enum",
      optional = true,
      default = nil,
      desc = "How to sort providers when routing requests",
      choices = { "price", "throughput", "latency" },
    },
  },
})
