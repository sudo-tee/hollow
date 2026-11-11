local harness = require("tests.harness")

describe("workspace session banner", function()
  local env, ui, calls
  before_each(function()
    env = harness.boot()
    ui = env.hollow.ui
    calls = {}
    env.host_api.session_banner_action = function(id, action)
      calls[#calls + 1] = { id, action }
    end
    ui._register_bar_invalidation_hooks()
  end)

  local function prepare(phase, workspace_id, width)
    return ui._session_banner_prepare(
      width or 1400,
      52,
      8,
      16,
      workspace_id or 12,
      phase,
      "Frozen view"
    )
  end

  local function find(nodes, suffix)
    for _, node in ipairs(nodes) do
      if node.id and node.id:sub(-#suffix) == suffix then
        return node
      end
    end
    error("missing button: " .. suffix)
  end

  local function click(node)
    env.hollow.events.emit("session_banner:click", { id = node.id })
  end

  it("uses styled native buttons with hover paint and workspace-bound callbacks", function()
    local nodes = prepare("idle")
    local reclaim = find(nodes, ":reclaim")
    assert.is_true(reclaim.clickable)
    assert.is_not_nil(reclaim.bg)
    assert.is_not_nil(reclaim.hover_bg)
    assert.is_true(reclaim.radius > 0)
    click(reclaim)
    click(find(nodes, ":close"))
    assert.same({ { 12, "reclaim" }, { 12, "close" } }, calls)
  end)

  it("replaces confirmation callbacks and ignores retired workspace buttons", function()
    local old = find(prepare("idle"), ":reclaim")
    local confirming = prepare("confirming")
    click(old)
    click(find(confirming, ":confirm"))
    click(find(confirming, ":cancel"))
    prepare("idle", 99)
    click(find(confirming, ":confirm"))
    assert.same({ { 12, "confirm" }, { 12, "cancel" } }, calls)
  end)

  it(
    "disables reclaim while connecting and keeps local close available in narrow windows",
    function()
      local nodes = prepare("connecting", 12, 320)
      local pending = find(nodes, ":pending")
      assert.is_nil(pending.clickable)
      assert.is_nil(pending.hover_bg)
      click(pending)
      click(find(nodes, ":close"))
      assert.same({ { 12, "close" } }, calls)
    end
  )
end)
