local config = require("diffview.config")
local oop = require("diffview.oop")
local renderer = require("diffview.renderer")
local utils = require("diffview.utils")
local Panel = require("diffview.ui.panel").Panel
local api = vim.api
local M = {}

---@class DiffStats
---@field additions integer
---@field deletions integer

---@class TreeOptions
---@field flatten_dirs boolean
---@field folder_statuses "never"|"only_folded"|"always"

---@class FilePanel : Panel
---@field adapter VCSAdapter
---@field files FileDict
---@field path_args string[]
---@field rev_pretty_name string|nil
---@field cur_file FileEntry
---@field listing_style "list"|"tree"
---@field tree_options TreeOptions
---@field show_reviewed boolean # Whether files marked as reviewed are listed.
---@field render_data RenderData
---@field components CompStruct
---@field constrain_cursor function
---@field help_mapping string
local FilePanel = oop.create_class("FilePanel", Panel)

FilePanel.winopts = vim.tbl_extend("force", Panel.winopts, {
  cursorline = true,
  winhl = {
    "EndOfBuffer:DiffviewEndOfBuffer",
    "Normal:DiffviewNormal",
    "CursorLine:DiffviewCursorLine",
    "WinSeparator:DiffviewWinSeparator",
    "SignColumn:DiffviewNormal",
    "StatusLine:DiffviewStatusLine",
    "StatusLineNC:DiffviewStatuslineNC",
    opt = { method = "prepend" },
  },
})

FilePanel.bufopts = vim.tbl_extend("force", Panel.bufopts, {
  filetype = "DiffviewFiles",
})

---FilePanel constructor.
---@param adapter VCSAdapter
---@param files FileEntry[]
---@param path_args string[]
function FilePanel:init(adapter, files, path_args, rev_pretty_name)
  local conf = config.get_config()
  self:super({
    config = conf.file_panel.win_config,
    bufname = "DiffviewFilePanel",
  })
  self.adapter = adapter
  self.files = files
  self.path_args = path_args
  self.rev_pretty_name = rev_pretty_name
  self.listing_style = conf.file_panel.listing_style
  self.tree_options = conf.file_panel.tree_options
  self.show_reviewed = true

  self:on_autocmd("BufNew", {
    callback = function()
      self:setup_buffer()
    end,
  })
end

---@override
function FilePanel:open()
  FilePanel.super_class.open(self)
  vim.cmd("wincmd =")
end

function FilePanel:setup_buffer()
  local conf = config.get_config()

  local default_opt = { silent = true, nowait = true, buffer = self.bufid }
  for _, mapping in ipairs(conf.keymaps.file_panel) do
    local opt = vim.tbl_extend("force", default_opt, mapping[4] or {}, { buffer = self.bufid })
    vim.keymap.set(mapping[1], mapping[2], mapping[3], opt)
  end

  local help_keymap = config.find_help_keymap(conf.keymaps.file_panel)
  if help_keymap then self.help_mapping = help_keymap[2] end
end

---Check whether a file entry should be listed in the panel.
---@param file FileEntry
---@return boolean
function FilePanel:is_file_visible(file)
  return self.show_reviewed or not file.reviewed
end

function FilePanel:update_components()
  local conflicting_files
  local working_files
  local staged_files
  local filter = utils.bind(self.is_file_visible, self)

  if self.listing_style == "list" then
    conflicting_files = { name = "files" }
    working_files = { name = "files" }
    staged_files = { name = "files" }

    for _, file in ipairs(self.files.conflicting) do
      if filter(file) then
        table.insert(conflicting_files, {
          name = "file",
          context = file,
        })
      end
    end

    for _, file in ipairs(self.files.working) do
      if filter(file) then
        table.insert(working_files, {
          name = "file",
          context = file,
        })
      end
    end

    for _, file in ipairs(self.files.staged) do
      if filter(file) then
        table.insert(staged_files, {
          name = "file",
          context = file,
        })
      end
    end

  elseif self.listing_style == "tree" then
    self.files.conflicting_tree:update_statuses()
    self.files.working_tree:update_statuses()
    self.files.staged_tree:update_statuses()

    conflicting_files = utils.tbl_merge(
      { name = "files" },
      self.files.conflicting_tree:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs,
        filter = filter,
      })
    )

    working_files = utils.tbl_merge(
      { name = "files" },
      self.files.working_tree:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs,
        filter = filter,
      })
    )

    staged_files = utils.tbl_merge(
      { name = "files" },
      self.files.staged_tree:create_comp_schema({
        flatten_dirs = self.tree_options.flatten_dirs,
        filter = filter,
      })
    )
  end

  ---@type CompStruct
  self.components = self.render_data:create_component({
    { name = "path" },
    { name = "summary" },
    {
      name = "conflicting",
      { name = "title" },
      conflicting_files,
      { name = "margin" },
    },
    {
      name = "working",
      { name = "title" },
      working_files,
      { name = "margin" },
    },
    {
      name = "staged",
      { name = "title" },
      staged_files,
      { name = "margin" },
    },
    {
      name = "info",
      { name = "title" },
      { name = "entries" },
    },
  })

  self.constrain_cursor = renderer.create_cursor_constraint({
    self.components.conflicting.files.comp,
    self.components.working.files.comp,
    self.components.staged.files.comp,
  })
end

---Sum up the diff stats for all the entries in the panel, and for only the
---entries that have not been marked as reviewed.
---@return DiffStats total
---@return DiffStats unreviewed
---@return integer reviewed_count # The number of entries marked as reviewed.
function FilePanel:get_stats_summary()
  local total = { additions = 0, deletions = 0 }
  local unreviewed = { additions = 0, deletions = 0 }
  local reviewed_count = 0

  for _, file in self.files:iter() do
    local stats = file.stats

    if file.reviewed then reviewed_count = reviewed_count + 1 end

    -- Entries without line stats (binaries, conflicts) are not counted.
    if stats and stats.additions and stats.deletions then
      total.additions = total.additions + stats.additions
      total.deletions = total.deletions + stats.deletions

      if not file.reviewed then
        unreviewed.additions = unreviewed.additions + stats.additions
        unreviewed.deletions = unreviewed.deletions + stats.deletions
      end
    end
  end

  return total, unreviewed, reviewed_count
end

---The listed file entries, in the order they appear in the panel.
---The number of file entries that are currently left out of the listing
---because they have been marked as reviewed.
---@return integer
function FilePanel:hidden_file_count()
  if self.show_reviewed then return 0 end

  local count = 0

  for _, file in self.files:iter() do
    if not self:is_file_visible(file) then count = count + 1 end
  end

  return count
end

---@return FileEntry[]
function FilePanel:ordered_file_list()
  local list = {}

  if self.listing_style == "list" then
    for _, file in self.files:iter() do
      if self:is_file_visible(file) then
        list[#list + 1] = file
      end
    end
  else
    local nodes = utils.vec_join(
      self.files.conflicting_tree.root:leaves(),
      self.files.working_tree.root:leaves(),
      self.files.staged_tree.root:leaves()
    )

    for _, node in ipairs(nodes) do
      if self:is_file_visible(node.data) then
        list[#list + 1] = node.data
      end
    end
  end

  return list
end

function FilePanel:set_cur_file(file)
  if self.cur_file then
    self.cur_file:set_active(false)
  end

  self.cur_file = file
  if self.cur_file then
    self.cur_file:set_active(true)
  end
end

function FilePanel:prev_file()
  local files = self:ordered_file_list()
  if not self.cur_file and #files > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end

  local i = utils.vec_indexof(files, self.cur_file)
  if i ~= -1 then
    self:set_cur_file(files[(i - vim.v.count1 - 1) % #files + 1])
    return self.cur_file
  end
end

function FilePanel:next_file()
  local files = self:ordered_file_list()
  if not self.cur_file and #files > 0 then
    self:set_cur_file(files[1])
    return self.cur_file
  end

  local i = utils.vec_indexof(files, self.cur_file)
  if i ~= -1 then
    self:set_cur_file(files[(i + vim.v.count1 - 1) % #files + 1])
    return self.cur_file
  end
end

---Get the file entry under the cursor.
---@return (FileEntry|DirData)?
function FilePanel:get_item_at_cursor()
  if not self:is_open() and self:buf_loaded() then return end

  local line = api.nvim_win_get_cursor(self.winid)[1]
  local comp = self.components.comp:get_comp_on_line(line)
  if comp and comp.name == "file" then
    return comp.context
  elseif comp and comp.name == "dir_name" then
    return comp.parent.context
  end
end

---Get the parent directory data of the item under the cursor.
---@return DirData?
---@return RenderComponent?
function FilePanel:get_dir_at_cursor()
  if self.listing_style ~= "tree" then return end
  if not self:is_open() and self:buf_loaded() then return end

  local line = api.nvim_win_get_cursor(self.winid)[1]
  local comp = self.components.comp:get_comp_on_line(line)

  if not comp then return end

  if comp.name == "dir_name" then
    local dir_comp = comp.parent
    return dir_comp.context, dir_comp
  elseif comp.name == "file" then
    local dir_comp = comp.parent.parent
    return dir_comp.context, dir_comp
  end
end

function FilePanel:highlight_file(file)
  if not (self:is_open() and self:buf_loaded()) then
    return
  end

  if self.listing_style == "list" then
    for _, file_list in ipairs({
      self.components.conflicting.files,
      self.components.working.files,
      self.components.staged.files,
    }) do
      for _, comp_struct in ipairs(file_list) do
        if file == comp_struct.comp.context then
          utils.set_cursor(self.winid, comp_struct.comp.lstart + 1, 0)
        end
      end
    end

  else -- tree
    for _, comp_struct in ipairs({
      self.components.conflicting.files,
      self.components.working.files,
      self.components.staged.files,
    }) do
      comp_struct.comp:deep_some(function(cur)
        if file == cur.context then
          local was_concealed = false
          local dir = cur.parent.parent

          while dir and dir.name == "directory" do
            if dir.context and dir.context.collapsed then
              was_concealed = true
              dir.context.collapsed = false
            end

            dir = utils.tbl_access(dir, { "parent", "parent" })
          end

          if was_concealed then
            self:render()
            self:redraw()
          end

          utils.set_cursor(self.winid, cur.lstart + 1, 0)
          return true
        end

        return false
      end)
    end
  end

  -- Needed to update the cursorline highlight when the panel is not focused.
  utils.update_win(self.winid)
end

function FilePanel:highlight_cur_file()
  if self.cur_file then
    self:highlight_file(self.cur_file)
  end
end

function FilePanel:highlight_prev_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(
    api.nvim_win_set_cursor,
    self.winid,
    { self.constrain_cursor(self.winid, -vim.v.count1), 0 }
  )
  utils.update_win(self.winid)
end

function FilePanel:highlight_next_file()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, vim.v.count1),
    0,
  })
  utils.update_win(self.winid)
end

function FilePanel:reconstrain_cursor()
  if not (self:is_open() and self:buf_loaded()) or self.files:len() == 0 then
    return
  end

  pcall(api.nvim_win_set_cursor, self.winid, {
    self.constrain_cursor(self.winid, 0),
    0,
  })
end

---@param item DirData|any
---@param open boolean
function FilePanel:set_item_fold(item, open)
  if type(item.collapsed) == "boolean" and open == item.collapsed then
    item.collapsed = not open
    self:render()
    self:redraw()

    if item.collapsed then
      self.components.comp:deep_some(function(comp, _, _)
        if comp.context == item then
          utils.set_cursor(self.winid, comp.lstart + 1)
          return true
        end
      end)
    end
  end
end

function FilePanel:toggle_item_fold(item)
  self:set_item_fold(item, item.collapsed)
end

function FilePanel:render()
  require("diffview.scene.views.diff.render")(self)
end

M.FilePanel = FilePanel
return M
