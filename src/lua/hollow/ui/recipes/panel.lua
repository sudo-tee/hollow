local sheet = require("hollow.ui.style.sheet")

-- Radius, padding and margin come from the palette at the call site.
return sheet.define("panel", {
  root = { bg = "panel_bg", border = "panel_border" },
})
