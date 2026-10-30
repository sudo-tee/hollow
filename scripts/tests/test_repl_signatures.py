import runpy
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
generate = runpy.run_path(str(ROOT / "scripts/generate-repl-signatures.py"))["generate"]


class ReplSignaturesTest(unittest.TestCase):
    def test_checked_in_metadata_is_current(self):
        source = (ROOT / "types/hollow.lua").read_text()
        self.assertEqual(
            (ROOT / "src/lua/hollow/ui/repl_signatures.lua").read_text(), generate(source)
        )

    def test_core_and_nested_namespace_signatures(self):
        result = generate((ROOT / "types/hollow.lua").read_text())
        for path in (
            "hollow.term.current_pane", "hollow.term.send_text",
            "hollow.action.invoke", "hollow.ui.lua_repl.open",
            "hollow.ui.command_palette.open", "hollow.theme.current",
        ):
            self.assertIn(f'["{path}"] = "fun(', result)
        self.assertIn("pane_id?: integer", result)
        self.assertIn("HollowPaneSnapshot|nil", result)

    def test_optional_params_callbacks_and_namespace_aliases(self):
        source = """---@class Hollow
---@field nested Namespace
---@class Namespace
local ns = {}
---@param fn fun(value: string): boolean
---@param opts? table
---@return boolean
function ns.run(fn, opts) end
"""
        self.assertIn(
            '["hollow.nested.run"] = "fun(fn: fun(value: string): boolean, opts?: table): boolean"',
            generate(source),
        )


if __name__ == "__main__":
    unittest.main()
