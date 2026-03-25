-- src/core/event_bus.lua
-- Simple pub/sub event bus.
-- User scripts (and internal modules) subscribe with on(), fire with emit().

local EventBus = {}
local listeners = {}   -- event_name -> list of {fn, once}

function EventBus.on(event, fn)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], {fn = fn, once = false})
end

function EventBus.once(event, fn)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], {fn = fn, once = true})
end

function EventBus.off(event, fn)
    if not listeners[event] then return end
    for i = #listeners[event], 1, -1 do
        if listeners[event][i].fn == fn then
            table.remove(listeners[event], i)
        end
    end
end

function EventBus.emit(event, ...)
    if not listeners[event] then return end
    local to_remove = {}
    for i, entry in ipairs(listeners[event]) do
        local ok, err = pcall(entry.fn, ...)
        if not ok then
            io.stderr:write("[event:" .. event .. "] error: " .. tostring(err) .. "\n")
        end
        if entry.once then table.insert(to_remove, i) end
    end
    for i = #to_remove, 1, -1 do
        table.remove(listeners[event], to_remove[i])
    end
end

return EventBus
