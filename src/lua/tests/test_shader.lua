local harness = require("tests.harness")

describe("shader validation", function()
  it("forwards the selected path and returns the native diagnostic unchanged", function()
    local env = harness.boot()
    local result = {
      valid = false,
      code = "shader_invalid",
      message = "Missing entry point: mainImage",
      target = "hlsl",
    }
    local selected_path
    env.host_api.shader_validate = function(path)
      selected_path = path
      return result
    end
    assert.equals(result, env.hollow.shader.validate("shader.glsl"))
    assert.equals("shader.glsl", selected_path)
  end)

  it("returns valid results without changing shader configuration", function()
    local env = harness.boot()
    env.hollow.config.set({ custom_shader = "active.glsl" })
    env.host_api.shader_validate = function()
      return { valid = true, code = "ok", message = "", target = "glsl" }
    end
    local result = env.hollow.shader.validate("candidate.glsl")
    assert.is_true(result.valid)
    assert.equals("active.glsl", env.hollow.config.get("custom_shader"))
  end)
end)
