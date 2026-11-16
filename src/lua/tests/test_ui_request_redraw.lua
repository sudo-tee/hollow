local harness = require("tests.harness")

describe("hollow.ui.request_redraw", function()
  it("requests a frame through the host", function()
    local env = harness.boot()
    local calls = 0
    env.host_api.request_redraw = function()
      calls = calls + 1
    end

    env.hollow.ui.request_redraw()

    assert.equals(1, calls)
  end)
end)
