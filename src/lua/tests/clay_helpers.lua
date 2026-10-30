local M = {}

function M.row(ui, row, theme)
  local shared = require("hollow.ui.shared")
  return require("hollow.ui.builder.components.layout_select").from_row(
    row,
    row.id or "row",
    shared.nodes_plain_text(row.children),
    theme or shared.palette("overlay"),
    { cell_w = 8, cell_h = 19 }
  )
end

function M.nodes(ui)
  ui._overlay_state()
  ui._layout_prepare(1200, 900, 8, 19)
  return ui._layout_tree or {}
end

function M.find(ui, suffix)
  for _, node in ipairs(M.nodes(ui)) do
    if node.id and node.id:sub(-#suffix) == suffix then
      return node
    end
  end
end

function M.text_node(ui, text, predicate)
  for _, node in ipairs(M.nodes(ui)) do
    if node.text == text and (not predicate or predicate(node)) then
      return node
    end
  end
end

function M.label(ui, text)
  for _, node in ipairs(M.nodes(ui)) do
    if node.label == text then
      return node
    end
  end
end

function M.children(ui, suffix)
  local nodes = M.nodes(ui)
  for i, node in ipairs(nodes) do
    if node.id and node.id:sub(-#suffix) == suffix then
      local result, remaining = {}, node.children or 0
      while remaining > 0 do
        i = i + 1
        local child = nodes[i]
        result[#result + 1] = child
        remaining = remaining - 1 + (child.children or 0)
      end
      return result
    end
  end
  error("missing node: " .. suffix)
end

function M.text(ui)
  local parts = {}
  for _, node in ipairs(M.nodes(ui)) do
    if node.text then
      parts[#parts + 1] = node.text
    end
  end
  return table.concat(parts)
end

return M
