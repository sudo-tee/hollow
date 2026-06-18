-- UI bootstrap: require all sub-modules in dependency order.
-- Modules mutate `hollow.ui` directly, so loading them is enough.

require("hollow.ui.shared")
require("hollow.ui.primitives")
require("hollow.ui.widgets.core")
require("hollow.ui.widgets.bars")
require("hollow.ui.widgets.overlay")
require("hollow.ui.widgets.notify")
require("hollow.ui.widgets.input")
require("hollow.ui.widgets.format")
require("hollow.ui.widgets.scroll_view")
require("hollow.ui.widgets.select")
require("hollow.ui.widgets.confirm")
require("hollow.ui.workspace.source")
require("hollow.ui.workspace.actions")
require("hollow.ui.widgets.workspace")
require("hollow.ui.widgets.palette")
