local async = require('gitsigns.async')
local util = require('gitsigns.util')

local M = {
  CacheEntry = {},
}

--- @class (exact) Gitsigns.CacheEntry
--- @field bufnr              integer
--- @field file               string
--- @field compare_text?      string[]
--- @field hunks?             Gitsigns.Hunk.Hunk[]
--- @field force_next_update? boolean
--- @field file_mode?         boolean
---
--- @field compare_text_head? string[]
--- @field hunks_staged?      Gitsigns.Hunk.Hunk[]
---
--- @field staged_diffs?      Gitsigns.Hunk.Hunk[]
--- @field gitdir_watcher?    uv.uv_fs_event_t
--- @field git_obj            Gitsigns.GitObj
--- @field blame?             table<integer,Gitsigns.BlameInfo?>
local CacheEntry = M.CacheEntry

function CacheEntry:get_rev_bufname(rev)
  rev = rev or self.git_obj.revision or ':0'
  return string.format('gitsigns://%s/%s:%s', self.git_obj.repo.gitdir, rev, self.git_obj.relpath)
end

--- Invalidate any state dependent on the buffer content.
--- If 'all' is passed, then invalidate everything.
--- @param all? boolean
function CacheEntry:invalidate(all)
  self.hunks = nil
  self.hunks_staged = nil
  self.blame = nil
  if all then
    -- The below doesn't need to be invalidated
    -- if the buffer changes
    self.compare_text = nil
    self.compare_text_head = nil
  end
end

--- @param o Gitsigns.CacheEntry
--- @return Gitsigns.CacheEntry
function M.new(o)
  o.staged_diffs = o.staged_diffs or {}
  return setmetatable(o, { __index = CacheEntry })
end

local sleep = async.wrap(2, function(duration, cb)
  vim.defer_fn(cb, duration)
end)

--- @private
function CacheEntry:wait_for_hunks()
  local loop_protect = 0
  while not self.hunks and loop_protect < 10 do
    loop_protect = loop_protect + 1
    sleep(100)
  end
end

-- If a file contains has up to this amount of lines, then
-- always blame the whole file, otherwise only blame one line
-- at a time.
local BLAME_THRESHOLD_LEN = 1000000

--- @private
--- @param lnum integer
--- @param opts Gitsigns.BlameOpts
--- @return table<integer,Gitsigns.BlameInfo?>?
function CacheEntry:run_blame(lnum, opts)
  local bufnr = self.bufnr
  local blame_cache --- @type table<integer,Gitsigns.BlameInfo?>?
  repeat
    local buftext = util.buf_lines(bufnr)
    local tick = vim.b[bufnr].changedtick
    local lnum0 = #buftext > BLAME_THRESHOLD_LEN and lnum or nil
    -- TODO(lewis6991): Cancel blame on changedtick
    blame_cache = self.git_obj:run_blame(buftext, lnum0, opts)
    async.scheduler()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
  until vim.b[bufnr].changedtick == tick
  return blame_cache
end

--- @param file string
--- @param lnum integer
--- @return Gitsigns.BlameInfo
local function get_blame_nc(file, lnum)
  local Git = require('gitsigns.git')

  return {
    orig_lnum = 0,
    final_lnum = lnum,
    commit = Git.not_committed(file),
    filename = file,
  }
end

--- @param lnum integer
--- @param opts Gitsigns.BlameOpts
--- @return Gitsigns.BlameInfo?
function CacheEntry:get_blame(lnum, opts)
  if opts.rev then
    local buftext = util.buf_lines(self.bufnr)
    return self.git_obj:run_blame(buftext, lnum, opts)[lnum]
  end

  local blame_cache = self.blame

  if not blame_cache or not blame_cache[lnum] then
    self:wait_for_hunks()
    local Hunks = require('gitsigns.hunks')
    if Hunks.find_hunk(lnum, self.hunks) then
      --- Bypass running blame (which can be expensive) if we know lnum is in a hunk
      blame_cache = blame_cache or {}
      blame_cache[lnum] = get_blame_nc(self.git_obj.relpath, lnum)
    else
      -- Refresh cache
      blame_cache = self:run_blame(lnum, opts)
    end
    self.blame = blame_cache
  end

  if blame_cache then
    return blame_cache[lnum]
  end
end

function CacheEntry:destroy()
  local w = self.gitdir_watcher
  if w and not w:is_closing() then
    w:close()
  end
end

---@type table<integer,Gitsigns.CacheEntry>
M.cache = {}

--- @param bufnr integer
function M.destroy(bufnr)
  M.cache[bufnr]:destroy()
  M.cache[bufnr] = nil
end

return M
