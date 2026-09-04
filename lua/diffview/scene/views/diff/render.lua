local config = require("diffview.config")
local hl = require("diffview.hl")
local utils = require("diffview.utils")

local pl = utils.path

---Files that have been marked as reviewed are rendered dimmed: this returns
---the dim highlight group in place of the given group for such entries.
---@param reviewed boolean
---@param hl_group string?
---@return string?
local function dim(reviewed, hl_group)
  if reviewed then return "DiffviewFilePanelReviewed" end
  return hl_group
end

---@param comp  RenderComponent
---@param show_path boolean
---@param depth integer|nil
local function render_file(comp, show_path, depth)
  ---@type FileEntry
  local file = comp.context
  local conf = config.get_config()
  local reviewed = not not file.reviewed

  comp:add_text(file.status .. " ", dim(reviewed, hl.get_git_hl(file.status)))

  if depth then
    comp:add_text(string.rep(" ", depth * 2 + 2))
  end

  local icon, icon_hl = hl.get_file_icon(file.basename, file.extension)
  comp:add_text(icon, dim(reviewed, icon_hl))
  comp:add_text(
    file.basename,
    dim(reviewed, file.active and "DiffviewFilePanelSelected" or "DiffviewFilePanelFileName")
  )

  if reviewed then
    comp:add_text(" " .. conf.signs.done, "DiffviewFilePanelReviewed")
  end

  if file.stats then
    if file.stats.additions then
      comp:add_text(" " .. file.stats.additions, dim(reviewed, "DiffviewFilePanelInsertions"))
      comp:add_text(", ", dim(reviewed, nil))
      comp:add_text(tostring(file.stats.deletions), dim(reviewed, "DiffviewFilePanelDeletions"))
    elseif file.stats.conflicts then
      local has_conflicts = file.stats.conflicts > 0
      local conflicts_hl = has_conflicts and "DiffviewFilePanelConflicts"
        or "DiffviewFilePanelInsertions"

      comp:add_text(
        " " .. (has_conflicts and file.stats.conflicts or conf.signs.done),
        dim(reviewed, conflicts_hl)
      )
    end
  end

  if file.kind == "conflicting" and not (file.stats and file.stats.conflicts) then
    comp:add_text(" !", dim(reviewed, "DiffviewFilePanelConflicts"))
  end

  if show_path then
    comp:add_text(" " .. file.parent_path, dim(reviewed, "DiffviewFilePanelPath"))
  end

  comp:ln()
end

---@param comp RenderComponent
local function render_file_list(comp)
  for _, file_comp in ipairs(comp.components) do
    render_file(file_comp, true)
  end
end

---@param ctx DirData
---@param tree_options TreeOptions
---@return string
local function get_dir_status_text(ctx, tree_options)
  local folder_statuses = tree_options.folder_statuses

  if folder_statuses == "always" or (folder_statuses == "only_folded" and ctx.collapsed) then
    return ctx.status
  end

  return " "
end

---Check whether every file in the subtree of a file tree component has been
---marked as reviewed.
---@param comp RenderComponent
---@return boolean
local function is_subtree_reviewed(comp)
  if comp.name == "file" then
    return not not (comp.context --[[@as FileEntry ]]).reviewed
  end

  if comp.name ~= "directory" then return false end

  local items = comp.components[2]

  for _, item in ipairs(items.components) do
    if not is_subtree_reviewed(item) then return false end
  end

  return #items.components > 0
end

---@param depth integer
---@param comp RenderComponent
local function render_file_tree_recurse(depth, comp)
  local conf = config.get_config()

  if comp.name == "file" then
    render_file(comp, false, depth)
    return
  end

  if comp.name ~= "directory" then return end

  -- Directory component structure:
  -- {
  --   name = "directory",
  --   context = <DirData>,
  --   { name = "dir_name" },
  --   { name = "items", ...<files> },
  -- }

  local dir = comp.components[1]
  local items = comp.components[2]
  local ctx = comp.context --[[@as DirData ]]
  local reviewed = is_subtree_reviewed(comp)

  dir:add_text(
    get_dir_status_text(ctx, conf.file_panel.tree_options) .. " ",
    dim(reviewed, hl.get_git_hl(ctx.status))
  )
  dir:add_text(string.rep(" ", depth * 2))
  dir:add_text(
    ctx.collapsed and conf.signs.fold_closed or conf.signs.fold_open,
    dim(reviewed, "DiffviewNonText")
  )

  if conf.use_icons then
    dir:add_text(
      " " .. (ctx.collapsed and conf.icons.folder_closed or conf.icons.folder_open) .. " ",
      dim(reviewed, "DiffviewFolderSign")
    )
  end

  dir:add_text(ctx.name, dim(reviewed, "DiffviewFolderName"))
  dir:ln()

  if not ctx.collapsed then
    for _, item in ipairs(items.components) do
      render_file_tree_recurse(depth + 1, item)
    end
  end
end

---@param comp RenderComponent
local function render_file_tree(comp)
  for _, c in ipairs(comp.components) do
    render_file_tree_recurse(0, c)
  end
end

---Render a section title, followed by the number of entries in the section,
---and how many of them are still waiting to be reviewed.
---@param comp RenderComponent
---@param label string
---@param files FileEntry[]
local function render_section_title(comp, label, files)
  local unreviewed = 0

  for _, file in ipairs(files) do
    if not file.reviewed then unreviewed = unreviewed + 1 end
  end

  comp:add_text(label .. " ", "DiffviewFilePanelTitle")

  -- The unreviewed count is only interesting once something in the section has
  -- been reviewed: otherwise it's just the entry count over again.
  if unreviewed == #files then
    comp:add_text("(" .. #files .. ")", "DiffviewFilePanelCounter")
    comp:ln()
    return
  end

  comp:add_text("(", "DiffviewFilePanelPath")
  comp:add_text(tostring(#files), "DiffviewFilePanelCounter")
  comp:add_text((" %s, "):format(#files == 1 and "file" or "files"), "DiffviewFilePanelPath")

  if unreviewed == 0 then
    comp:add_text(config.get_config().signs.done, "DiffviewFilePanelReviewed")
  else
    comp:add_text(tostring(unreviewed), "DiffviewFilePanelCounter")
    comp:add_text(" unreviewed", "DiffviewFilePanelPath")
  end

  comp:add_text(")", "DiffviewFilePanelPath")
  comp:ln()
end

---@param listing_style "list"|"tree"
---@param comp RenderComponent
local function render_files(listing_style, comp)
  if listing_style == "list" then
    return render_file_list(comp)
  end
  render_file_tree(comp)
end

---@param panel FilePanel
return function(panel)
  if not panel.render_data then
    return
  end

  panel.render_data:clear()
  local conf = config.get_config()
  local width = panel:infer_width()

  local comp = panel.components.path.comp

  comp:add_line(
    pl:truncate(pl:vim_fnamemodify(panel.adapter.ctx.toplevel, ":~"), width - 6),
    "DiffviewFilePanelRootPath"
  )

  if conf.show_help_hints and panel.help_mapping then
    comp:add_text("Help: ", "DiffviewFilePanelPath")
    comp:add_line(panel.help_mapping, "DiffviewFilePanelCounter")
    comp:add_line()
  end

  do
    local total, unreviewed, reviewed_count = panel:get_stats_summary()

    comp = panel.components.summary.comp

    local rows = { { label = "Total:", stats = total } }
    local label_width = #rows[1].label

    -- Until something has been reviewed this would just repeat the total.
    if reviewed_count > 0 then
      rows[#rows + 1] = { label = "Unreviewed:", stats = unreviewed }
      label_width = math.max(label_width, #rows[2].label)
    end

    for _, item in ipairs(rows) do
      local pad = string.rep(" ", label_width - #item.label + 1)

      comp:add_text(item.label .. pad, "DiffviewFilePanelTitle")
      comp:add_text("+" .. item.stats.additions, "DiffviewFilePanelInsertions")
      comp:add_text(" ")
      comp:add_text("-" .. item.stats.deletions, "DiffviewFilePanelDeletions")
      comp:ln()
    end

    local hidden = panel:hidden_file_count()

    if hidden > 0 then
      comp:add_line(
        ("%d reviewed %s hidden"):format(hidden, hidden == 1 and "file" or "files"),
        "DiffviewFilePanelPath"
      )
    end

    comp:add_line()
  end

  if #panel.files.conflicting > 0 then
    render_section_title(
      panel.components.conflicting.title.comp,
      "Conflicts",
      panel.files.conflicting
    )

    render_files(panel.listing_style, panel.components.conflicting.files.comp)
    panel.components.conflicting.margin.comp:add_line()
  end

  local has_other_files = #panel.files.conflicting > 0 or #panel.files.staged > 0

  -- Don't show the 'Changes' section if it's empty and we have other visible
  -- sections.
  if #panel.files.working > 0 or not has_other_files then
    render_section_title(panel.components.working.title.comp, "Changes", panel.files.working)

    render_files(panel.listing_style, panel.components.working.files.comp)
    panel.components.working.margin.comp:add_line()
  end

  if #panel.files.staged > 0 then
    render_section_title(panel.components.staged.title.comp, "Staged changes", panel.files.staged)

    render_files(panel.listing_style, panel.components.staged.files.comp)
    panel.components.staged.margin.comp:add_line()
  end

  if panel.rev_pretty_name or (panel.path_args and #panel.path_args > 0) then
    local extra_info = utils.vec_join({ panel.rev_pretty_name }, panel.path_args or {})

    comp = panel.components.info.title.comp
    comp:add_line("Showing changes for:", "DiffviewFilePanelTitle")

    comp = panel.components.info.entries.comp

    for _, arg in ipairs(extra_info) do
      local relpath = pl:relative(arg, panel.adapter.ctx.toplevel)
      if relpath == "" then relpath = "." end
      comp:add_line(pl:truncate(relpath, width - 5), "DiffviewFilePanelPath")
    end
  end
end
