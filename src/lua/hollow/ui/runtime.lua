-- UI bootstrap: require all sub-modules in dependency order.
-- Modules mutate `hollow.ui` directly, so loading them is enough.

local modules = {
  "hollow.ui.shared",
  "hollow.ui.primitives",
  "hollow.ui.widgets.core",
  "hollow.ui.widgets.bars",
  "hollow.ui.widgets.overlay",
  "hollow.ui.widgets.notify",
  "hollow.ui.widgets.input",
  "hollow.ui.widgets.select",
}

for _, module_name in ipairs(modules) do
  require(module_name)
end
