-- conf.lua  (Love2D window configuration)
function love.conf(t)
	t.identity = "hollow"
	t.version = "11.5" -- minimum Love version
	-- Set GHOSTTY_LOVE_DEBUG=1 (or use launch.sh --console) to see errors.
	t.console = (os.getenv("GHOSTTY_LOVE_DEBUG") == "1")

	t.window.title = "hollow"
	t.window.width = 1280
	t.window.height = 800
	t.window.resizable = true
	t.window.minwidth = 400
	t.window.minheight = 300
	t.window.vsync = 1
	t.window.msaa = 0
	t.window.highdpi = true
	t.window.usedpiscale = true
	t.window.gammacorrect = false

	-- Disable unused Love modules to reduce startup overhead
	t.modules.audio = false
	t.modules.physics = false
	t.modules.joystick = false
	t.modules.sound = false
	t.modules.video = false
end
