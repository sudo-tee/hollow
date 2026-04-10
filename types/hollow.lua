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

---@alias HollowKeyChord string
---@alias HollowKeyMods string

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
---@field id? string
---@field on_click? fun(e: { id: string })
---@field on_mouse_enter? fun(e: { id: string })
---@field on_mouse_leave? fun(e: { id: string })

---@alias HollowStyleValue HollowStyle|HollowColor

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
---@field bottom_bar_show? boolean
---@field bottom_bar_height? integer
---@field bottom_bar_bg? HollowColor
---@field bottom_bar_draw_status? boolean
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
---@field style? HollowStyleValue

---@class HollowSpacerSpan
---@field _type "spacer"

---@class HollowIconSpan
---@field _type "icon"
---@field name string
---@field style? HollowStyleValue

---@class HollowGroupSpan
---@field _type "group"
---@field children HollowSpanNode[]
---@field style? HollowStyleValue

---@class HollowButtonOpts
---@field id string
---@field text? string
---@field style? HollowStyleValue
---@field on_click? fun(e: { id: string })
---@field on_mouse_enter? fun(e: { id: string })
---@field on_mouse_leave? fun(e: { id: string })

---@alias HollowSpanNode HollowSpan|HollowSpacerSpan|HollowIconSpan|HollowGroupSpan

---@class HollowBarTabState
---@field id integer|nil
---@field title string
---@field index integer
---@field is_active boolean
---@field is_hovered boolean
---@field is_hover_close boolean
---@field pane HollowPane|nil
---@field panes HollowPane[]

---@class HollowBarWorkspaceState
---@field index integer
---@field name string
---@field is_active boolean
---@field active_index integer
---@field count integer

---@alias HollowTopbarTabState HollowBarTabState
---@alias HollowTopbarWorkspaceState HollowBarWorkspaceState

---@class HollowBarTabsNode
---@field _type "bar_tabs"
---@field fit? "fill"|"content"
---@field format? fun(tab: HollowBarTabState, ctx: HollowWidgetCtx): string|HollowSpan
---@field style? HollowStyleValue|fun(tab: HollowBarTabState, ctx: HollowWidgetCtx): HollowStyleValue|nil

---@class HollowBarTabsOpts
---@field fit? "fill"|"content"
---@field format? fun(tab: HollowBarTabState, ctx: HollowWidgetCtx): string|HollowSpan
---@field style? HollowStyleValue|fun(tab: HollowBarTabState, ctx: HollowWidgetCtx): HollowStyleValue|nil

---@class HollowBarWorkspaceNode
---@field _type "bar_workspace"
---@field format? fun(workspace: HollowBarWorkspaceState, ctx: HollowWidgetCtx): string|HollowSpan
---@field style? HollowStyleValue|fun(workspace: HollowBarWorkspaceState, ctx: HollowWidgetCtx): HollowStyleValue|nil

---@class HollowBarWorkspaceOpts
---@field format? fun(workspace: HollowBarWorkspaceState, ctx: HollowWidgetCtx): string|HollowSpan
---@field style? HollowStyleValue|fun(workspace: HollowBarWorkspaceState, ctx: HollowWidgetCtx): HollowStyleValue|nil

---@class HollowBarTimeNode
---@field _type "bar_time"
---@field format string
---@field style? HollowStyleValue

---@class HollowBarTimeOpts
---@field style? HollowStyleValue

---@class HollowBarKeyLegendNode
---@field _type "bar_key_legend"
---@field style? HollowStyleValue

---@class HollowBarKeyLegendOpts
---@field style? HollowStyleValue

---@class HollowBarCustomNode
---@field _type "bar_custom"
---@field id? string
---@field render fun(ctx: HollowWidgetCtx): string|HollowSpan
---@field on_click? fun(e: { id: string })
---@field on_mouse_enter? fun(e: { id: string })
---@field on_mouse_leave? fun(e: { id: string })

---@alias HollowBarItem HollowSpanNode|HollowBarTabsNode|HollowBarWorkspaceNode|HollowBarTimeNode|HollowBarKeyLegendNode|HollowBarCustomNode

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

---@alias HollowWidgetRenderResult HollowBarItem[]|HollowSpanNode[][]

---@class HollowWidget
---@field render fun(ctx: HollowWidgetCtx): HollowWidgetRenderResult
---@field on_event? fun(name: string, e: any)
---@field on_mount? fun()
---@field on_unmount? fun()

---@class HollowTopbarOpts: HollowWidget
---@field height? integer

---@class HollowBottombarOpts: HollowWidget
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

---@alias HollowKeyAction string|fun()

---@class HollowKeymapOpts
---@field desc? string
---@field timeout_ms? integer

---@class HollowKeymapValue
---@field action HollowKeyAction
---@field desc? string

---@class HollowLeaderState
---@field active boolean
---@field prefix string
---@field sequence string[]
---@field display string
---@field next string[]
---@field next_display string[]
---@field desc? string
---@field remaining_ms integer
---@field timeout_ms integer
---@field complete boolean

---@class HollowKeymapNamespace
local keymap = {}

---@param chord HollowKeyChord
---@param rhs HollowKeyAction
---@param opts? HollowKeymapOpts
function keymap.set(chord, rhs, opts) end

---@param chord HollowKeyChord
---@return boolean
function keymap.del(chord) end

---@param chord HollowKeyChord
---@return HollowKeyAction|nil
function keymap.get(chord) end

---@param chord? HollowKeyChord
---@param opts? HollowKeymapOpts
function keymap.set_leader(chord, opts) end

function keymap.clear_leader() end

---@return boolean
function keymap.is_leader_active() end

---@return HollowLeaderState|nil
function keymap.get_leader_state() end

---@class HollowBarNamespace
local bar = {}

---@param opts? HollowBarTabsOpts
---@return HollowBarTabsNode
function bar.tabs(opts) end

---@param opts? HollowBarWorkspaceOpts
---@return HollowBarWorkspaceNode
function bar.workspace(opts) end

---@param fmt string
---@param opts? HollowBarTimeOpts
---@return HollowBarTimeNode
function bar.time(fmt, opts) end

---@param opts? HollowBarKeyLegendOpts
---@return HollowBarKeyLegendNode
function bar.key_legend(opts) end

---@param opts HollowBarCustomNode
---@return HollowBarCustomNode
function bar.custom(opts) end

---@class HollowTopbarNamespace
local topbar = {}

---@param opts HollowTopbarOpts
---@return HollowWidget
function topbar.new(opts) end

---@param widget HollowWidget
function topbar.mount(widget) end

function topbar.unmount() end

function topbar.invalidate() end

---@class HollowBottombarNamespace
local bottombar = {}

---@param opts HollowBottombarOpts
---@return HollowWidget
function bottombar.new(opts) end

---@param widget HollowWidget
function bottombar.mount(widget) end

function bottombar.unmount() end

function bottombar.invalidate() end

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
---@param style? HollowStyleValue
---@return HollowSpan
function ui.span(text, style) end

---@return HollowSpacerSpan
function ui.spacer() end

---@param name string
---@param style? HollowStyleValue
---@return HollowIconSpan
function ui.icon(name, style) end

---@param children HollowSpanNode[]
---@param style? HollowStyleValue
---@return HollowGroupSpan
function ui.group(children, style) end

---@param opts HollowButtonOpts
---@return HollowSpan
function ui.button(opts) end

ui.bar = bar
ui.topbar = topbar
ui.bottombar = bottombar
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

---@class HollowHostBridge
---@field set_config fun(opts: table)
---@field new_tab fun()
---@field close_tab fun()
---@field switch_tab fun(index: integer)
---@field new_workspace fun()
---@field next_workspace fun()
---@field prev_workspace fun()
---@field set_workspace_name fun(name: string)
---@field get_workspace_name fun(index: integer): string
---@field get_workspace_count fun(): integer
---@field get_active_workspace_index fun(): integer
---@field set_tab_title fun(title: string)
---@field send_text fun(text: string)
---@field switch_tab_by_id fun(tab_id: integer): boolean
---@field close_tab_by_id fun(tab_id: integer): boolean
---@field set_tab_title_by_id fun(tab_id: integer, title: string): boolean
---@field send_text_to_pane fun(pane_id: integer, text: string): boolean
---@field get_window_width fun(): integer
---@field get_window_height fun(): integer
---@field pane_exists fun(pane_id: integer): boolean
---@field get_pane_pid fun(pane_id: integer): integer
---@field get_pane_cwd fun(pane_id: integer): string
---@field get_pane_title fun(pane_id: integer): string
---@field pane_is_focused fun(pane_id: integer): boolean
---@field get_pane_rows fun(pane_id: integer): integer
---@field get_pane_cols fun(pane_id: integer): integer
---@field get_pane_width fun(pane_id: integer): integer
---@field get_pane_height fun(pane_id: integer): integer
---@field get_tab_pane_count fun(tab_id: integer): integer
---@field get_tab_pane_id_at fun(tab_id: integer, index: integer): integer
---@field get_tab_active_pane_id fun(tab_id: integer): integer
---@field current_tab_id fun(): integer|nil
---@field get_tab_index_by_id fun(tab_id: integer): integer|nil
---@field get_tab_count fun(): integer
---@field get_tab_id_at fun(index: integer): integer|nil
---@field current_pane_id fun(): integer|nil
---@field reload_config fun(): boolean
---@field strftime fun(fmt: string): string
---@field on_key fun(handler: fun(key: string, mods: integer): boolean)
---@field split_pane fun(direction: string, ratio?: number)
---@field close_pane fun()
---@field focus_pane fun(direction: string)
---@field resize_pane fun(axis: string, delta: number)
---@field copy_selection fun()
---@field paste_clipboard fun()
---@field scroll_active fun(delta: integer)
---@field scroll_active_page fun(pages: integer)
---@field scroll_active_top fun()
---@field scroll_active_bottom fun()
---@field platform HollowPlatformInfo

---@class Hollow
---@field config HollowConfigNamespace
---@field term HollowTermNamespace
---@field events HollowEventsNamespace
---@field keymap HollowKeymapNamespace
---@field ui HollowUiNamespace
---@field htp HollowHtpNamespace
---@field process HollowProcessNamespace
---@field platform HollowPlatformInfo

---@type Hollow
hollow = {}

hollow.config = config
hollow.term = term
hollow.events = events
hollow.keymap = keymap
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
