---@meta

---@alias HollowColor string

---@alias HollowFontWeight "thin"|"extralight"|"light"|"regular"|"medium"|"semibold"|"bold"|"extrabold"|"black"

---@alias HollowFontStyle "normal"|"italic"|"oblique"
---@alias HollowCursorStyle "block"|"bar"|"underline"
---@alias HollowSidebarSide "left"|"right"
---@alias HollowOverlayAlign "center"|"top_left"|"top_center"|"top_right"|"left_center"|"right_center"|"bottom_left"|"bottom_center"|"bottom_right"|"left"|"right"|"top"|"bottom"
---@class HollowUiThemeBackdrop
---@field color? HollowColor
---@field alpha? integer

---@alias HollowOverlayBackdropValue boolean|HollowColor|HollowUiThemeBackdrop
---@class HollowUiTheme
---@field panel_bg? HollowColor
---@field panel_border? HollowColor
---@field divider? HollowColor
---@field title? HollowColor
---@field fg? HollowColor
---@field muted? HollowColor
---@field input_bg? HollowColor
---@field input_fg? HollowColor
---@field cursor_bg? HollowColor
---@field cursor_fg? HollowColor
---@field selected_bg? HollowColor
---@field selected_detail_bg? HollowColor
---@field selected_fg? HollowColor
---@field selected_muted? HollowColor
---@field detail? HollowColor
---@field notify_fg? HollowColor
---@field counter? HollowColor
---@field empty? HollowColor
---@field scrollbar_track? HollowColor
---@field scrollbar_thumb? HollowColor
---@field backdrop? HollowOverlayBackdropValue
---@field notify_levels? { info?: HollowColor, warn?: HollowColor, error?: HollowColor, success?: HollowColor }
---@alias HollowNotifyLevel "info"|"warn"|"error"|"success"
---@alias HollowKeyMode "normal"

---@alias HollowKeyChord string
---@alias HollowKeyMods string
---@alias HollowHexColor HollowColor
---@alias HollowUiKeyMods HollowKeyMods

---@alias HollowEventName
---| "config:reloaded"
---| "term:title_changed"
---| "term:tab_activated"
---| "term:tab_closed"
---| "term:pane_focused"
---| "term:pane_layout_changed"
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
---@alias HollowUiNodeStyle HollowStyle

---@class HollowUiStyleWrapper
---@field style HollowUiNodeStyle

---@alias HollowUiNodeEventPayload table<string, any>

---@class HollowUiChrome
---@field bg? HollowColor
---@field border? HollowColor

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
---@field terminal_theme? table
---@field ui_theme? table
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
---@field default_domain? string
---@field domains? table<string, string>
---@field env? table<string, string>

---@class HollowPane
---@field id integer
---@field pid integer
---@field domain? string
---@field cwd string
---@field title string
---@field is_focused boolean
---@field is_floating boolean
---@field is_maximized boolean
---@field frame { x: integer, y: integer, width: integer, height: integer }
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

---@alias HollowPaneSnapshot HollowPane
---@alias HollowTabSnapshot HollowTab
---@alias HollowWorkspaceSnapshot HollowWorkspace
---@alias HollowPaneSizeSnapshot HollowSize
---@alias HollowWindowSizeSnapshot HollowSize

---@class HollowNewTabOpts
---@field cmd? string|string[]
---@field cwd? string
---@field env? table<string, string>
---@field title? string
---@field domain? string

---@class HollowSplitPaneOpts
---@field direction? "horizontal"|"vertical"
---@field ratio? number
---@field domain? string
---@field cwd? string
---@field floating? boolean
---@field fullscreen? boolean
---@field x? number
---@field y? number
---@field width? number
---@field height? number

---@class HollowPaneMaximizeOpts
---@field show_background? boolean

---@class HollowFloatingPaneBounds
---@field x? number
---@field y? number
---@field width? number
---@field height? number

---@class HollowMovePaneOpts
---@field pane_id? integer
---@field id? integer
---@field direction "left"|"right"|"up"|"down"
---@field amount? number

---@class HollowUiSpanNode
---@field _type "span"
---@field text string
---@field style? HollowUiNodeStyle|HollowHexColor

---@class HollowUiSpacerNode
---@field _type "spacer"

---@class HollowUiIconNode
---@field _type "icon"
---@field name string
---@field style? HollowUiNodeStyle|HollowHexColor

---@class HollowUiGroupNode
---@field _type "group"
---@field children HollowUiRenderableNode[]
---@field style? HollowUiNodeStyle|HollowHexColor

---@class HollowUiTextShorthand: HollowStyle
---@field [1] string

---@class HollowUiButtonOptions
---@field id string
---@field text? string
---@field style? HollowUiNodeStyle
---@field on_click? fun(e: { id: string })
---@field on_mouse_enter? fun(e: { id: string })
---@field on_mouse_leave? fun(e: { id: string })

---@alias HollowUiRenderableNode HollowUiSpanNode|HollowUiSpacerNode|HollowUiIconNode|HollowUiGroupNode
---@alias HollowUiInlineNode string|HollowUiRenderableNode|HollowUiTextShorthand
---@class HollowUiOverlayRowOptions
---@field fill_bg? HollowColor
---@field divider? HollowColor
---@field scrollbar_track? boolean
---@field scrollbar_thumb? boolean
---@field scrollbar_track_color? HollowColor
---@field scrollbar_thumb_color? HollowColor

---@class HollowUiOverlayRow
---@field _overlay_row true
---@field nodes HollowUiRenderableNode[]
---@field fill_bg? HollowColor
---@field divider? HollowColor
---@field scrollbar_track boolean
---@field scrollbar_thumb boolean
---@field scrollbar_track_color? HollowColor
---@field scrollbar_thumb_color? HollowColor

---@alias HollowUiRow HollowUiRenderableNode[]|HollowUiOverlayRow
---@alias HollowUiRows HollowUiRow[]

---@class HollowUiTagProps: HollowStyle
---@field name? string
---@field children? any[]
---@field color? HollowColor
---@field divider? HollowColor
---@field fill_bg? HollowColor
---@field scrollbar_track? boolean
---@field scrollbar_thumb? boolean
---@field scrollbar_track_color? HollowColor
---@field scrollbar_thumb_color? HollowColor
---@field style? HollowStyle

---@class HollowUiTabState
---@field id integer|nil
---@field title string
---@field index integer
---@field is_active boolean
---@field is_hovered boolean
---@field is_hover_close boolean
---@field pane HollowPane|nil
---@field panes HollowPane[]

---@class HollowUiWorkspaceState
---@field index integer
---@field name string
---@field is_active boolean
---@field active_index integer
---@field count integer

---@class HollowUiBarNodeOptionsBase
---@field _type? string
---@field style? HollowUiNodeStyle|HollowHexColor|fun(state:any, ctx?:HollowWidgetCtx): HollowUiNodeStyle|HollowHexColor|nil
---@field fit? "content"|"fill"

---@class HollowUiBarNodeBase: HollowUiBarNodeOptionsBase
---@field _type string

---@class HollowUiBarNodePayload
---@field id string

---@class HollowUiBarTabsOptions: HollowUiBarNodeOptionsBase
---@field fit? "fill"|"content"
---@field format? fun(tab: HollowUiTabState, ctx?:HollowWidgetCtx): string|HollowUiSpanNode
---@field style? HollowUiNodeStyle|HollowHexColor|fun(tab: HollowUiTabState, ctx?:HollowWidgetCtx): HollowUiNodeStyle|HollowHexColor|nil

---@class HollowUiBarTabsNode: HollowUiBarTabsOptions
---@field _type "bar_tabs"

---@class HollowUiBarWorkspaceOptions: HollowUiBarNodeOptionsBase
---@field format? fun(workspace: HollowUiWorkspaceState, ctx?:HollowWidgetCtx): string|HollowUiSpanNode
---@field style? HollowUiNodeStyle|HollowHexColor|fun(workspace: HollowUiWorkspaceState, ctx?:HollowWidgetCtx): HollowUiNodeStyle|HollowHexColor|nil

---@class HollowUiBarWorkspaceNode: HollowUiBarWorkspaceOptions
---@field _type "bar_workspace"

---@class HollowUiBarTimeOptions: HollowUiBarNodeOptionsBase
---@field style? HollowUiNodeStyle|HollowHexColor

---@class HollowUiBarTimeNode: HollowUiBarTimeOptions
---@field _type "bar_time"
---@field format string

---@class HollowUiBarKeyLegendOptions: HollowUiBarNodeOptionsBase
---@field style? HollowUiNodeStyle|HollowHexColor

---@class HollowUiBarKeyLegendNode: HollowUiBarKeyLegendOptions
---@field _type "bar_key_legend"

---@class HollowUiBarCustomNode
---@field _type "bar_custom"
---@field id? string
---@field render fun(ctx: HollowWidgetCtx): string|HollowUiSpanNode
---@field on_click? fun(e: { id: string })
---@field on_mouse_enter? fun(e: { id: string })
---@field on_mouse_leave? fun(e: { id: string })
---@class HollowUiBarCustomOptions
---@field id? string
---@field render fun(ctx:HollowWidgetCtx):string|HollowUiSegment|HollowUiNodeStyle|nil
---@field on_click? fun(payload:HollowUiNodeEventPayload)
---@field on_mouse_enter? fun(payload:HollowUiNodeEventPayload)
---@field on_mouse_leave? fun(payload:HollowUiNodeEventPayload)

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

---@class HollowUiFlatNode
---@field text string
---@field spacer? boolean
---@field style? HollowStyle

---@class HollowUiSegment
---@field text string
---@field fg? HollowColor
---@field bg? HollowColor
---@field bold? boolean
---@field id? string
---@field kind? string

---@class HollowUiTabsLayout
---@field kind "tabs"
---@field fit "content"|"fill"
---@field tabs HollowUiSegment[]

---@class HollowUiOverlaySerializedRow
---@field segments HollowUiSegment[]
---@field fill_bg? HollowColor
---@field divider? HollowColor
---@field scrollbar_track boolean
---@field scrollbar_thumb boolean
---@field scrollbar_track_color? HollowColor
---@field scrollbar_thumb_color? HollowColor

---@class HollowUiOverlaySerializedWidget
---@field align string
---@field backdrop HollowUiThemeBackdrop|nil
---@field chrome HollowUiChrome|nil
---@field width integer|nil
---@field height integer|nil
---@field max_height integer|nil
---@field rows HollowUiOverlaySerializedRow[]

---@class HollowUiSidebarState
---@field side "left"|"right"
---@field width integer
---@field reserve boolean
---@field rows HollowUiSegment[][]

---@alias HollowWidgetRenderResult HollowUiRows|HollowUiRenderableNode[]|HollowUiRenderableNode|nil

---@class HollowWidget
---@field _kind? string
---@field render fun(ctx: HollowWidgetCtx): HollowWidgetRenderResult
---@field on_event? fun(name: string, e: any)
---@field on_key? fun(key: string, mods: HollowKeyMods): boolean
---@field on_mount? fun()
---@field on_unmount? fun()
---@field height? number
---@field max_height? number
---@field width? number
---@field side? HollowSidebarSide
---@field align? HollowOverlayAlign|string
---@field backdrop? HollowOverlayBackdropValue
---@field chrome? HollowUiChrome|boolean
---@field hidden? boolean
---@field reserve? boolean
---@field _notify? boolean
---@field _expires_at? integer

---@alias HollowUiWidget HollowWidget
---@alias HollowUiWidgetOptions HollowWidget

---@class HollowUiTopbarOptions: HollowWidget
---@field height? integer

---@class HollowUiBottombarOptions: HollowWidget
---@field height? integer

---@class HollowUiSidebarOptions: HollowWidget
---@field side? HollowSidebarSide
---@field width? integer
---@field reserve? boolean

---@class HollowUiOverlayOptions
---@field render fun(ctx: HollowWidgetCtx): HollowWidgetRenderResult
---@field on_key? fun(key: string, mods: HollowKeyMods): boolean
---@field on_mount? fun()
---@field on_unmount? fun()
---@field align? HollowOverlayAlign
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field chrome? { bg?: HollowColor, border?: HollowColor }

---@class HollowUiNotifyAction
---@field label string
---@field fn fun()

---@class HollowUiNotifyOptions
---@field level? HollowNotifyLevel
---@field title? string
---@field ttl? number
---@field action? HollowUiNotifyAction
---@field align? HollowOverlayAlign
---@field backdrop? HollowOverlayBackdropValue
---@field chrome? { bg?: HollowColor, border?: HollowColor }
---@field theme? HollowUiTheme

---@class HollowUiInputOptions
---@field prompt? string
---@field default? string
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme
---@field on_confirm fun(value: string)
---@field on_cancel? fun()

---@class HollowUiInputState
---@field prompt string
---@field value string

---@class HollowUiSelectAction
---@field name string
---@field fn fun(item: any)
---@field key? string
---@field desc? string

---@class HollowUiSelectState
---@field index integer
---@field query string
---@field scroll_top integer

---@class HollowUiSelectEntry
---@field item any
---@field label_nodes HollowUiRenderableNode[]
---@field label_text string
---@field detail_nodes HollowUiRenderableNode[]|nil
---@field detail_text string|nil
---@field source_index integer
---@field score number

---@class HollowUiSelectOptions
---@field items any[]
---@field label? fun(item: any): HollowUiInlineNode|HollowUiInlineNode[]
---@field detail? fun(item: any): HollowUiInlineNode|HollowUiInlineNode[]
---@field prompt? string
---@field fuzzy? boolean
---@field query? string
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme
---@field actions HollowUiSelectAction[]
---@field on_cancel? fun()

---@class HollowEventListener
---@field name string
---@field handler fun(payload:any)
---@field once boolean

---@alias HollowEventHandleMap table<integer, HollowEventListener>
---@alias HollowEventListenerMap table<string, integer[]>

---@class HollowEventState
---@field builtin_names table<string, boolean>
---@field handles HollowEventHandleMap
---@field listeners HollowEventListenerMap
---@field next_handle integer

---@class HollowConfigState
---@field values table<string, any>

---@class HollowKeymapBinding
---@field action any
---@field desc string|nil

---@alias HollowKeymapBindingStore table<string, table<integer, HollowKeymapBinding>>
---@alias HollowKeymapSequenceChildren table<string, table<integer, HollowKeymapSequenceNode>>

---@class HollowKeymapSequenceNode
---@field action any
---@field desc string|nil
---@field children HollowKeymapSequenceChildren

---@class HollowKeymapLeader
---@field key string
---@field mods integer

---@class HollowKeymapState
---@field bindings HollowKeymapBindingStore
---@field sequence_bindings HollowKeymapSequenceNode
---@field leader HollowKeymapLeader|nil
---@field leader_bindings HollowKeymapSequenceNode
---@field sequence_timeout_ms integer
---@field sequence_pending_until integer|nil
---@field sequence_active_node HollowKeymapSequenceNode|nil
---@field sequence_steps string[]
---@field sequence_prefix string|nil

---@class HollowUiState
---@field mounted_topbar HollowUiWidget|nil
---@field topbar_hovered_id string|nil
---@field mounted_bottombar HollowUiWidget|nil
---@field bottombar_hovered_id string|nil
---@field mounted_sidebar HollowUiWidget|nil
---@field sidebar_visible boolean
---@field overlay_stack HollowUiWidget[]
---@field notifications HollowUiWidget[]

---@class HollowState
---@field host_api HollowHostBridge
---@field config HollowConfigState
---@field events HollowEventState
---@field keymap HollowKeymapState
---@field ui HollowUiState

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

---@return HollowTabSnapshot|nil
function term.current_tab() end

---@return HollowPaneSnapshot|nil
function term.current_pane() end

---@return HollowTabSnapshot[]
function term.tabs() end

---@return HollowWorkspaceSnapshot[]
function term.workspaces() end

---@return HollowWorkspaceSnapshot|nil
function term.current_workspace() end

---@param id integer
---@return HollowTabSnapshot|nil
function term.tab_by_id(id) end

---@param opts? HollowNewTabOpts
function term.new_tab(opts) end

---@param direction? "horizontal"|"vertical"|HollowSplitPaneOpts
---@param opts? HollowSplitPaneOpts
function term.split_pane(direction, opts) end

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

---@param pane_id? integer|HollowPaneMaximizeOpts
---@param opts? HollowPaneMaximizeOpts
function term.toggle_pane_maximized(pane_id, opts) end

---@param pane_id integer|{ pane_id?: integer, id?: integer, floating?: boolean }
---@param floating? boolean
function term.set_pane_floating(pane_id, floating) end

---@param pane_id integer
---@param opts HollowFloatingPaneBounds
function term.set_floating_pane_bounds(pane_id, opts) end

---@param direction_or_opts "left"|"right"|"up"|"down"|HollowMovePaneOpts
---@param opts? HollowMovePaneOpts
function term.move_pane(direction_or_opts, opts) end

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

---@class HollowUiBarNamespace
local bar = {}

---@param opts? HollowUiBarTabsOptions
---@return HollowUiBarTabsNode
function bar.tabs(opts) end

---@param opts? HollowUiBarWorkspaceOptions
---@return HollowUiBarWorkspaceNode
function bar.workspace(opts) end

---@param fmt string
---@param opts? HollowUiBarTimeOptions
---@return HollowUiBarTimeNode
function bar.time(fmt, opts) end

---@param opts? HollowUiBarKeyLegendOptions
---@return HollowUiBarKeyLegendNode
function bar.key_legend(opts) end

---@param opts HollowUiBarCustomOptions
---@return HollowUiBarCustomNode
function bar.custom(opts) end

---@class HollowUiWidgetSurfaceNamespace
local topbar = {}

---@param opts HollowUiTopbarOptions
---@return HollowWidget
function topbar.new(opts) end

---@param widget HollowWidget
function topbar.mount(widget) end

function topbar.unmount() end

---@return boolean
function topbar.invalidate() end

---@alias HollowUiTopbarNamespace HollowUiWidgetSurfaceNamespace

---@class HollowUiBottombarNamespace
local bottombar = {}

---@param opts HollowUiBottombarOptions
---@return HollowWidget
function bottombar.new(opts) end

---@param widget HollowWidget
function bottombar.mount(widget) end

function bottombar.unmount() end

---@return boolean
function bottombar.invalidate() end

---@class HollowUiSidebarNamespace
local sidebar = {}

---@param opts HollowUiSidebarOptions
---@return HollowWidget
function sidebar.new(opts) end

---@param widget HollowWidget
function sidebar.mount(widget) end

function sidebar.unmount() end

---@return boolean
function sidebar.toggle() end

---@return boolean
function sidebar.invalidate() end

---@class HollowUiOverlayNamespace
local overlay = {}

---@param opts HollowUiOverlayOptions
---@return HollowWidget
function overlay.new(opts) end

---@param widget HollowWidget
function overlay.push(widget) end

function overlay.pop() end

function overlay.clear() end

---@return integer
function overlay.depth() end

---@class HollowUiNotifyNamespace
local notify = {}

---@param message string
---@param opts? HollowUiNotifyOptions
function notify.show(message, opts) end

function notify.clear() end

---@param message string
---@param opts? HollowUiNotifyOptions
function notify.info(message, opts) end

---@param message string
---@param opts? HollowUiNotifyOptions
function notify.warn(message, opts) end

---@param message string
---@param opts? HollowUiNotifyOptions
function notify.error(message, opts) end

---@class HollowUiInputNamespace
local input = {}

---@param opts HollowUiInputOptions
function input.open(opts) end

function input.close() end

---@class HollowUiSelectNamespace
local select = {}

---@param opts HollowUiSelectOptions
function select.open(opts) end

function select.close() end

---@class HollowUi
local ui = {}

---@class HollowUiOverlayRowNamespace
---@field make fun(nodes:HollowUiRenderableNode[]|nil, opts:HollowUiOverlayRowOptions|nil):HollowUiOverlayRow
---@field nodes fun(row:HollowUiRow):HollowUiRenderableNode[]

---@alias HollowUiTagBuilder fun(props:HollowUiTagProps|HollowUiInlineNode|string|number|nil, ...:any):any

---@class HollowUiTags
---@field overlay_row fun(props:HollowUiTagProps|nil, ...:any):HollowUiOverlayRow
---@field divider fun(props:HollowUiTagProps|nil):HollowUiOverlayRow
---@field text HollowUiTagBuilder
---@field span HollowUiTagBuilder
---@field group HollowUiTagBuilder
---@field row HollowUiTagBuilder
---@field rows HollowUiTagBuilder
---@field icon HollowUiTagBuilder
---@field spacer HollowUiTagBuilder
---@field button HollowUiTagBuilder

---@param text string
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiSpanNode
function ui.span(text, style) end

---@param value HollowUiInlineNode
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiRenderableNode
function ui.text(value, style) end

---@param ... HollowUiInlineNode|HollowUiInlineNode[]
---@return HollowUiRenderableNode[]
function ui.row(...) end

---@param ... any
---@return HollowUiRows
function ui.rows(...) end

---@type HollowUiTags
ui.tags = {}

---@return HollowUiSpacerNode
function ui.spacer() end

---@param name string
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiIconNode
function ui.icon(name, style) end

---@param children HollowUiRenderableNode[]
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiGroupNode
function ui.group(children, style) end

---@param opts HollowUiButtonOptions
---@return HollowUiSpanNode
function ui.button(opts) end

---@type HollowUiOverlayRowNamespace
ui.overlay_row = {}

ui.bar = bar
ui.topbar = topbar
ui.bottombar = bottombar
ui.sidebar = sidebar
ui.overlay = overlay
ui.notify = notify
ui.input = input
ui.select = select

---@field new_widget fun(kind:string, opts:HollowUiWidgetOptions):HollowUiWidget
---@field close_overlay_widget fun(widget:HollowUiWidget):HollowUiWidget|nil
---@field dispatch_widget_event fun(name:string, payload:HollowUiNodeEventPayload)
---@field dispatch_overlay_key fun(key:string, mods:HollowUiKeyMods):boolean
---@field trim_row_for_width fun(row:HollowUiRow, max_chars:number|nil):HollowUiSegment[]
---@field handle_bar_node_event fun(kind:string, payload:HollowUiBarNodePayload|any)
---@field resolve_theme fun(kind:string):HollowUiTheme
---@field _overlay_state fun():HollowUiOverlaySerializedWidget[]|nil
---@field _topbar_state fun():((HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"})[])|nil
---@field _bottombar_state fun():((HollowUiSegment|HollowUiTabsLayout|{kind:"spacer"})[])|nil
---@field _bottombar_layout fun():{height:integer}|nil
---@field _sidebar_state fun():HollowUiSidebarState|nil

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
---@field new_tab fun(opts?: table)
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
---@field get_pane_domain fun(pane_id: integer): string
---@field get_window_width fun(): integer
---@field get_window_height fun(): integer
---@field now_ms fun(): integer
---@field pane_exists fun(pane_id: integer): boolean
---@field get_pane_pid fun(pane_id: integer): integer
---@field get_pane_cwd fun(pane_id: integer): string
---@field get_pane_title fun(pane_id: integer): string
---@field pane_is_focused fun(pane_id: integer): boolean
---@field get_pane_rows fun(pane_id: integer): integer
---@field get_pane_cols fun(pane_id: integer): integer
---@field get_pane_x fun(pane_id: integer): integer
---@field get_pane_y fun(pane_id: integer): integer
---@field get_pane_width fun(pane_id: integer): integer
---@field get_pane_height fun(pane_id: integer): integer
---@field pane_is_floating fun(pane_id: integer): boolean
---@field pane_is_maximized fun(pane_id: integer): boolean
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
---@field split_pane fun(opts_or_direction: HollowSplitPaneOpts|string, ratio?: number, domain?: string)
---@field toggle_pane_maximized fun(pane_id?: integer, show_background?: boolean)
---@field set_pane_floating fun(pane_id?: integer, floating?: boolean)
---@field set_floating_pane_bounds fun(pane_id?: integer, x?: number, y?: number, width?: number, height?: number)
---@field move_pane fun(pane_id?: integer, direction: string, amount?: number)
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

---@class HollowUiModuleExports
---@field dispatch_widget_event fun(name:string, payload:HollowUiNodeEventPayload)
---@field dispatch_overlay_key fun(key:string, mods:HollowUiKeyMods):boolean
---@field handle_bar_node_event fun(kind:string, payload:HollowUiBarNodePayload|any)

---@class Hollow
---@field config HollowConfigNamespace
---@field term HollowTermNamespace
---@field events HollowEventsNamespace
---@field keymap HollowKeymapNamespace
---@field ui HollowUi
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
