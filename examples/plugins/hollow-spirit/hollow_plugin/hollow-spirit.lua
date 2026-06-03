local hollow = _G.hollow

local M = {}

local moods = {
  "curious", "playful", "sleepy", "excited", "mysterious",
  "cheerful", "grumpy", "thoughtful",
}

local reactions = {
  bell = {
    "Yikes! What was that noise?!",
    "Ow! My spectral ears!",
    "Whoa! No need to shout!",
    "That bell startled me!",
    "Oof! Right through me!",
  },
  tab_activated = {
    "Ooh, where are we going?",
    "Hello there!",
    "Peek-a-boo!",
    "*waves shyly*",
    "This looks interesting!",
  },
  process_started = {
    "Working hard I see!",
    "Ooh, what are we building?",
    "Let's go!",
    "I'll watch!",
    "You've got this!",
  },
  process_done = {
    "All done! Nicely done!",
    "Poof! Task complete!",
    "Well, that was quick!",
    "Done and dusted!",
    "Another victory!",
  },
}

local function spirit_name()
  local ok, mod = pcall(require, "hollow-spirit")
  if ok and type(mod) == "table" and type(mod.name) == "string" then
    return mod.name
  end
  return "Spirit"
end

local function react(category)
  local pool = reactions[category]
  if not pool or #pool == 0 then return end
  local msg = pool[math.random(#pool)]
  local name = spirit_name()
  hollow.ui.notify.info("👻 " .. name .. ": " .. msg, { ttl = 3200 })
end

math.randomseed(os.time())

hollow.events.on("term:bell", function()
  react("bell")
end)

hollow.events.on("term:tab_activated", function()
  if math.random() < 0.25 then
    react("tab_activated")
  end
end)

local last_process = ""
hollow.events.on("term:foreground_process_changed", function(payload)
  local new_process = payload and payload.new_process or ""
  if last_process == "" and new_process ~= "" then
    if math.random() < 0.2 then
      react("process_started")
    end
  elseif last_process ~= "" and new_process == "" then
    if math.random() < 0.35 then
      react("process_done")
    end
  end
  last_process = new_process
end)

hollow.keymap.set("<leader>ss", function()
  local name = spirit_name()
  local idx = math.random(#moods)
  local mood = moods[idx]
  local colors = { "#ff6b6b", "#ffd93d", "#6bcb77", "#4d96ff", "#ff8cc8", "#c084fc" }
  local color = colors[math.random(#colors)]
  hollow.ui.notify.info(
    "👻 " .. name .. " feels " .. mood .. " today",
    { ttl = 4000, fg = color }
  )
end, { desc = "check spirit mood" })

hollow.events.on("config:reloaded", function()
  hollow.defer(function()
    local name = spirit_name()
    hollow.ui.notify.info("👻 " .. name .. " is still here!", { ttl = 2000 })
  end, 3000)
end)
