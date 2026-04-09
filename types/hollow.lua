---@meta

---@alias HollowColor string

---@alias HollowFontWeight
---| "thin"
---| "extralight"
---| "light"
---| "regular"
---| "medium"
---| "semibold"
---| "bold"
---| "extrabold"
---| "black"

---@alias HollowFontStyle "normal"|"italic"|"oblique"
---@alias HollowCursorStyle "block"|"bar"|"underline"
---@alias HollowSidebarSide "left"|"right"
---@alias HollowNotifyLevel "info"|"warn"|"error"|"success"
---@alias HollowKeyMode "normal"

---@alias HollowKeyMods
---| "NONE"
---| "CTRL"
---| "SHIFT"
---| "ALT"
---| "SUPER"
---| "CTRL|SHIFT"
---| "CTRL|ALT"
---| "CTRL|SUPER"
---| "SHIFT|ALT"
---| "SHIFT|SUPER"
---| "ALT|SUPER"
---| "CTRL|SHIFT|ALT"
---| "CTRL|SHIFT|SUPER"
---| "CTRL|ALT|SUPER"
---| "SHIFT|ALT|SUPER"
---| "CTRL|SHIFT|ALT|SUPER"

---@alias HollowEventName
---| "config:reloaded"
---| "term:title_changed"
---| "term:tab_activated"
---| "term:tab_closed"
---| "term:pane_focused"
---| "term:cwd_changed"
---| "key:unhandled"
---| "window:resized"
---| "window:focused"
---| "window:blurred"
---| string

---@alias HollowHtpValue nil|boolean|number|string|table
---@alias HollowEventHandle integer

---@class HollowStyle
---@field fg? HollowColor
---@field bg? HollowColor
---@field bold? boolean
---@field italic? boolean
---@field underline? boolean
---@field strikethrough? boolean
---@field dim? boolean

---@class HollowSize
---@field rows integer
---@field cols integer
---@field width integer
---@field height integer

---@alias HollowFontSmoothing "grayscale"|"subpixel"
---@alias HollowFontHinting "none"|"light"|"normal"

---@class HollowFontsConfig
---@field size number
---@field line_height? number
---@field padding_x? number
---@field padding_y? number
---@field smoothing? HollowFontSmoothing
---@field hinting? HollowFontHinting
---@field ligatures? boolean
---@field embolden? number
---@field regular? string
---@field bold? string
---@field italic? string
---@field bold_italic? string
---@field fallbacks? string[]

---@class HollowCursorConfig
---@field style? HollowCursorStyle
---@field blink? boolean
---@field blink_rate? integer

---@class HollowScrollbarConfig
---@field enabled? boolean
---@field width? integer
---@field min_thumb_size? integer
---@field margin? integer
---@field jump_to_click? boolean
---@field track? HollowColor
---@field thumb? HollowColor
---@field thumb_hover? HollowColor
---@field thumb_active? HollowColor
---@field border? HollowColor

---@class HollowHyperlinksConfig
---@field enabled? boolean
---@field shift_click_only? boolean
---@field match_www? boolean
---@field prefixes? string
---@field delimiters? string
---@field trim_leading? string
---@field trim_trailing? string

---@class HollowConfig
---@field debug_overlay? boolean
---@field backend? string
---@field vsync? boolean
---@field max_fps? integer
---@field padding? integer
---@field theme? table
---@field fonts? HollowFontsConfig
---@field scrollback? integer
---@field cols? integer
---@field rows? integer
---@field window_title? string
---@field window_width? integer
---@field window_height? integer
---@field window_titlebar_show? boolean
---@field top_bar_show? boolean
---@field top_bar_show_when_single_tab? boolean
---@field top_bar_height? integer
---@field top_bar_bg? HollowColor
---@field top_bar_draw_tabs? boolean
---@field top_bar_draw_status? boolean
---@field scrollbar? HollowScrollbarConfig
---@field hyperlinks? HollowHyperlinksConfig
---@field cursor? HollowCursorConfig
---@field shell? string|string[]
---@field env? table<string, string>

---@class HollowPane
---@field id integer
---@field pid integer
---@field cwd string
---@field title string
---@field is_focused boolean
---@field size HollowSize

---@class HollowTab
---@field id integer
---@field title string
---@field index integer
---@field is_active boolean
---@field panes HollowPane[]
---@field pane HollowPane

---@class HollowWorkspace
---@field index integer
---@field name string
---@field is_active boolean

---@class HollowNewTabOpts
---@field cmd? string|string[]
---@field cwd? string
---@field env? table<string, string>
---@field title? string

---@class HollowSpan
---@field _type "span"
---@field text string
---@field style? HollowStyle

---@class HollowSpacerSpan
---@field _type "spacer"

---@class HollowIconSpan
---@field _type "icon"
---@field name string
---@field style? HollowStyle

---@class HollowGroupSpan
---@field _type "group"
---@field children HollowSpanNode[]
---@field style? HollowStyle

---@alias HollowSpanNode HollowSpan|HollowSpacerSpan|HollowIconSpan|HollowGroupSpan

---@class HollowWidgetCtxTerm
---@field tab HollowTab|nil
---@field pane HollowPane|nil
---@field tabs HollowTab[]
---@field workspace HollowWorkspace|nil
---@field workspaces HollowWorkspace[]

---@class HollowWidgetCtxTime
---@field epoch_ms integer
---@field iso string

---@class HollowWidgetCtx
---@field term HollowWidgetCtxTerm
---@field size HollowSize
---@field time HollowWidgetCtxTime

---@alias HollowWidgetRenderResult HollowSpanNode[]|HollowSpanNode[][]

---@class HollowWidget
---@field render fun(ctx: HollowWidgetCtx): HollowWidgetRenderResult
---@field on_event? fun(name: string, e: any)
---@field on_mount? fun()
---@field on_unmount? fun()

---@class HollowTopbarOpts: HollowWidget
---@field height? integer

---@class HollowSidebarOpts: HollowWidget
---@field side? HollowSidebarSide
---@field width? integer
---@field reserve? boolean

---@class HollowOverlayOpts
---@field render fun(ctx: HollowWidgetCtx): HollowWidgetRenderResult
---@field on_key? fun(key: string, mods: HollowKeyMods): boolean
---@field on_mount? fun()
---@field on_unmount? fun()

---@class HollowNotifyAction
---@field label string
---@field fn fun()

---@class HollowNotifyOpts
---@field level? HollowNotifyLevel
---@field title? string
---@field ttl? integer
---@field action? HollowNotifyAction

---@class HollowInputOpts
---@field prompt? string
---@field default? string
---@field on_confirm fun(value: string)
---@field on_cancel? fun()

---@generic T
---@class HollowSelectAction<T>
---@field name string
---@field fn fun(item: T)
---@field key? string
---@field desc? string

---@generic T
---@class HollowSelectOpts<T>
---@field items T[]
---@field label? fun(item: T): string
---@field detail? fun(item: T): string
---@field prompt? string
---@field fuzzy? boolean
---@field actions HollowSelectAction<T>[]
---@field on_cancel? fun()

---@class HtpQueryContext
---@field pane HollowPane
---@field params table<string, any>

---@class HtpEmitContext
---@field pane HollowPane
---@field payload any

---@class HollowProcessWriter
---@field write fun(data: string)

---@class HollowProcessReader
---@field read fun(): string|nil

---@class HollowProcess
---@field pid integer
---@field stdin HollowProcessWriter
---@field stdout HollowProcessReader
---@field stderr HollowProcessReader
---@field wait fun(): integer
---@field kill fun()

---@class HollowExecResult
---@field exit_code integer
---@field stdout string
---@field stderr string

---@class HollowProcessOpts
---@field cmd string|string[]
---@field cwd? string
---@field env? table<string, string>

---@class HollowConfigNamespace
local config = {}

---@param opts HollowConfig
function config.set(opts) end

---@param key string
---@return any
function config.get(key) end

---@return HollowConfig
function config.snapshot() end

function config.reload() end

---@class HollowTermNamespace
local term = {}

---@return HollowTab|nil
function term.current_tab() end

---@return HollowPane|nil
function term.current_pane() end

---@return HollowTab[]
function term.tabs() end

---@return HollowWorkspace[]
function term.workspaces() end

---@return HollowWorkspace|nil
function term.current_workspace() end

---@param id integer
---@return HollowTab|nil
function term.tab_by_id(id) end

---@param opts? HollowNewTabOpts
function term.new_tab(opts) end

---@param id integer
function term.focus_tab(id) end

---@param id integer
function term.close_tab(id) end

---@param title string
---@param tab_id? integer
function term.set_title(title, tab_id) end

---@param text string
---@param pane_id? integer
function term.send_text(text, pane_id) end

---@param name string
function term.set_workspace_name(name) end

function term.new_workspace() end

function term.next_workspace() end

function term.prev_workspace() end

---@class HollowEventsNamespace
local events = {}

---@param name HollowEventName
---@param handler fun(e: table)
---@return HollowEventHandle
function events.on(name, handler) end

---@param handle HollowEventHandle
function events.off(handle) end

---@param name HollowEventName
---@param handler fun(e: table)
function events.once(name, handler) end

---@param name string
---@param payload? any
function events.emit(name, payload) end

---@class HollowKeyBind
---@field mods HollowKeyMods
---@field key string
---@field action fun()
---@field mode? HollowKeyMode

---@class HollowKeysNamespace
local keys = {}

---@param binds HollowKeyBind[]
function keys.bind(binds) end

---@param bind HollowKeyBind
function keys.bind_one(bind) end

---@param mods HollowKeyMods
---@param key string
function keys.unbind(mods, key) end

---@class HollowTopbarNamespace
local topbar = {}

---@param opts HollowTopbarOpts
---@return HollowWidget
function topbar.new(opts) end

---@param widget HollowWidget
function topbar.mount(widget) end

function topbar.unmount() end

function topbar.invalidate() end

---@class HollowSidebarNamespace
local sidebar = {}

---@param opts HollowSidebarOpts
---@return HollowWidget
function sidebar.new(opts) end

---@param widget HollowWidget
function sidebar.mount(widget) end

function sidebar.unmount() end

function sidebar.toggle() end

function sidebar.invalidate() end

---@class HollowOverlayNamespace
local overlay = {}

---@param opts HollowOverlayOpts
---@return HollowWidget
function overlay.new(opts) end

---@param widget HollowWidget
function overlay.push(widget) end

function overlay.pop() end

function overlay.clear() end

---@return integer
function overlay.depth() end

---@class HollowNotifyNamespace
local notify = {}

---@param message string
---@param opts? HollowNotifyOpts
function notify.show(message, opts) end

function notify.clear() end

---@param message string
---@param opts? HollowNotifyOpts
function notify.info(message, opts) end

---@param message string
---@param opts? HollowNotifyOpts
function notify.warn(message, opts) end

---@param message string
---@param opts? HollowNotifyOpts
function notify.error(message, opts) end

---@class HollowInputNamespace
local input = {}

---@param opts HollowInputOpts
function input.open(opts) end

function input.close() end

---@class HollowSelectNamespace
local select = {}

---@generic T
---@param opts HollowSelectOpts<T>
function select.open(opts) end

function select.close() end

---@class HollowUiNamespace
local ui = {}

---@param text string
---@param style? HollowStyle
---@return HollowSpan
function ui.span(text, style) end

---@return HollowSpacerSpan
function ui.spacer() end

---@param name string
---@param style? HollowStyle
---@return HollowIconSpan
function ui.icon(name, style) end

---@param children HollowSpanNode[]
---@param style? HollowStyle
---@return HollowGroupSpan
function ui.group(children, style) end

ui.topbar = topbar
ui.sidebar = sidebar
ui.overlay = overlay
ui.notify = notify
ui.input = input
ui.select = select

---@class HollowHtpNamespace
local htp = {}

---@param channel string
---@param handler fun(ctx: HtpQueryContext): HollowHtpValue
function htp.on_query(channel, handler) end

---@param channel string
---@param handler fun(ctx: HtpEmitContext)
function htp.on_emit(channel, handler) end

---@param channel string
function htp.off_query(channel) end

---@param channel string
function htp.off_emit(channel) end

---@class HollowProcessNamespace
local process = {}

---@param opts HollowProcessOpts
---@return HollowProcess
function process.spawn(opts) end

---@param opts HollowProcessOpts
---@return HollowExecResult
function process.exec(opts) end

---@class HollowPlatformInfo
---@field os string
---@field is_windows boolean
---@field is_linux boolean
---@field is_macos boolean
---@field default_shell string

---@class Hollow
---@field config HollowConfigNamespace
---@field term HollowTermNamespace
---@field events HollowEventsNamespace
---@field keys HollowKeysNamespace
---@field ui HollowUiNamespace
---@field htp HollowHtpNamespace
---@field process HollowProcessNamespace
---@field platform HollowPlatformInfo

---@type Hollow
hollow = {}

hollow.config = config
hollow.term = term
hollow.events = events
hollow.keys = keys
hollow.ui = ui
hollow.htp = htp
hollow.process = process

---@type HollowPlatformInfo
hollow.platform = {
    os = "",
    is_windows = false,
    is_linux = false,
    is_macos = false,
    default_shell = "",
}

return hollow
