---@meta
---@module 'hollow'

---@alias HollowColor string

---@alias HollowFontWeight "thin"|"extralight"|"light"|"regular"|"medium"|"semibold"|"bold"|"extrabold"|"black"

---@alias HollowFontStyle "normal"|"italic"|"oblique"
---@alias HollowCursorStyle "block"|"bar"|"underline"|"block_hollow"
---@alias HollowTopBarMode "always"|"tabs"
---@alias HollowSidebarSide "left"|"right"
---@alias HollowOverlayAlign "center"|"top_left"|"top_center"|"top_right"|"left_center"|"right_center"|"bottom_left"|"bottom_center"|"bottom_right"|"left"|"right"|"top"|"bottom"
---@class HollowUiThemeBackdrop
---@field color? HollowColor
---@field alpha? integer

---@class HollowPalette
---@field foreground HollowColor
---@field background HollowColor
---@field cursor_bg HollowColor
---@field cursor_fg HollowColor
---@field selection_bg HollowColor
---@field selection_fg HollowColor
---@field black HollowColor
---@field red HollowColor
---@field green HollowColor
---@field yellow HollowColor
---@field blue HollowColor
---@field magenta HollowColor
---@field cyan HollowColor
---@field white HollowColor
---@field bright_black HollowColor
---@field bright_red HollowColor
---@field bright_green HollowColor
---@field bright_yellow HollowColor
---@field bright_blue HollowColor
---@field bright_magenta HollowColor
---@field bright_cyan HollowColor
---@field bright_white HollowColor

---@class HollowResolvedTheme
---@field terminal HollowTerminalTheme
---@field ui HollowAppTheme
---@field palette HollowPalette

---@class HollowTerminalTheme
---@field foreground HollowColor
---@field background HollowColor
---@field cursor_bg HollowColor
---@field cursor_fg HollowColor
---@field selection_bg HollowColor
---@field selection_fg HollowColor
---@field ansi HollowColor[]
---@field brights HollowColor[]

---@class HollowAppTheme
---@field widgets table
---@field top_bar { height: integer, background: HollowColor }
---@field tab_bar table
---@field scrollbar HollowScrollbarConfig
---@field split_active HollowColor
---@field split_inactive HollowColor
---@field floating_active HollowColor
---@field floating_inactive HollowColor
---@field accent HollowColor
---@field warm HollowColor
---@field status { bg: HollowColor, fg: HollowColor }

---@class HollowThemeTerminalSpec
---@field foreground? HollowColor
---@field background? HollowColor
---@field cursor_bg? HollowColor
---@field cursor_fg? HollowColor
---@field selection_bg? HollowColor
---@field selection_fg? HollowColor
---@field ansi? HollowColor[]
---@field brights? HollowColor[]

---@class HollowThemeUiSpec
---@field widgets? table<string, HollowUiTheme> Shared `all` defaults followed by widget-kind overrides.
---@field top_bar? { height?: integer, background?: HollowColor }
---@field tab_bar? table
---@field scrollbar? HollowScrollbarConfig
---@field split_active? HollowColor
---@field split_inactive? HollowColor
---@field floating_active? HollowColor
---@field floating_inactive? HollowColor
---@field accent? HollowColor
---@field warm? HollowColor
---@field status? { bg?: HollowColor, fg?: HollowColor }

---@class HollowThemeSpec
---@field terminal? HollowThemeTerminalSpec
---@field ui? HollowThemeUiSpec
---@field palette? HollowPalette|table

---@class HollowUiBox
---@field top? number
---@field right? number
---@field bottom? number
---@field left? number
---@field x? number
---@field y? number
---@field horizontal? number
---@field vertical? number

---@alias HollowUiBoxValue number|HollowUiBox|number[]|false Pixel shorthand, CSS-order array, sparse box, or false to reset spacing.
---@alias HollowOverlayBackdropValue boolean|HollowColor|HollowUiThemeBackdrop
---@class HollowUiPaintParts
---@field sidebar? {fg?: HollowColor|HollowStyleToken, bg?: HollowColor|HollowStyleToken, border?: HollowColor|HollowStyleToken, alpha?: number}
---@field tab? {active?: {fg?: HollowColor|HollowStyleToken, bg?: HollowColor|HollowStyleToken}, inactive?: {fg?: HollowColor|HollowStyleToken, bg?: HollowColor|HollowStyleToken}, selection_accent?: HollowColor|HollowStyleToken}
---@field scrollbar? {track?: HollowColor|HollowStyleToken, thumb?: HollowColor|HollowStyleToken}
---@field list_row? {accent?: HollowColor|HollowStyleToken|false} Selected row accent and built-in selection indicator; false suppresses accent.
---@alias HollowUiThemeStyles table<string, table<string, HollowUiNodeStyle|table>> Built-in stylesheet slot overrides by sheet then slot; layers may nest `variants`, `sizes` and state tables.

---@class HollowUiTheme
---@field parts? HollowUiPaintParts Native component paint defaults, separate from geometry.
---@field styles? HollowUiThemeStyles Built-in component slot overrides, e.g. `{ select = { label = { fg = "title" } } }`.
---@field button_emphasis_bg? HollowColor Default dialog-button emphasis, derived after widget overrides.
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
---@field selection_bg? HollowColor
---@field selection_fg? HollowColor
---@field hover_bg? HollowColor
---@field hover_fg? HollowColor
---@field primary_bg? HollowColor
---@field primary_fg? HollowColor
---@field destructive_bg? HollowColor
---@field destructive_fg? HollowColor
---@field selected_muted? HollowColor
---@field detail? HollowColor
---@field subtle? HollowColor
---@field notify_fg? HollowColor
---@field counter? HollowColor
---@field empty? HollowColor
---@field scrollbar_track? HollowColor
---@field scrollbar_thumb? HollowColor
---@field radius? integer
---@field padding? HollowUiBoxValue
---@field margin? HollowUiBoxValue
---@field backdrop? HollowOverlayBackdropValue
---@field notify_levels? { info?: HollowColor, warn?: HollowColor, error?: HollowColor, success?: HollowColor }

--- Theme resolution fills these defaults; explicit partial overrides use HollowUiTheme.
---@class HollowUiResolvedTheme: HollowUiTheme
---@field fg HollowColor
---@field muted HollowColor
---@field panel_bg HollowColor
---@field panel_border HollowColor
---@field title HollowColor
---@field divider HollowColor
---@field notify_levels {info: HollowColor, warn: HollowColor, error: HollowColor, success: HollowColor}
---@alias HollowNotifyLevel "info"|"warn"|"error"|"success"
---@alias HollowKeyMode "normal"|"copy_mode"|(string & {})

---@alias HollowKeyChord string
---@alias HollowKeyMods string
---@alias HollowHexColor HollowColor
---@alias HollowUiKeyMods HollowKeyMods

---@alias HollowEventName
---| "config:reloaded"
---| "workspace:new"
---| "workspace:changed"
---| "workspace:closed"
---| "term:title_changed"
---| "term:tab_activated"
---| "term:tab_closed"
---| "term:pane_focused"
---| "term:pane_created"
---| "term:pane_exited"
---| "term:pane_closed"
---| "term:pane_layout_changed"
---| "term:cwd_changed"
---| "term:foreground_process_changed"
---| "term:command_started"
---| "term:command_finished"
---| "term:program_status_changed"
---| "term:bell"
---| "term:notification"
---| "key:unhandled"
---| "window:resized"
---| "window:files_dropped"
---| "window:focused"
---| "window:blurred"
---| "copy_mode:changed"
---| "copy_mode:search_requested"
---| "quick_select:changed"
---| "quick_select:no_matches"
---| "quick_select:action_executed"
---| "topbar:hover"
---| "topbar:leave"
---| "topbar:click"
---| "bottombar:hover"
---| "bottombar:leave"
---| "bottombar:click"
---| "sidebar:hover"
---| "sidebar:leave"
---| "sidebar:click"
---| "overlay:hover"
---| "overlay:leave"
---| "overlay:click"
---| "overlay:scroll"
---| "overlay:scrollbar"
---| "selection:begin"
---| "selection:cleared"
---| "window:focused"
---| "window:blurred"
---| string

---@class HollowEventPayloadMap
---@field ["config:reloaded"] {}
---@field ["workspace:new"] { workspace: HollowWorkspace, index: integer }
---@field ["workspace:changed"] { workspace: HollowWorkspace, index: integer }
---@field ["workspace:closed"] { name: string }
---@field ["term:title_changed"] { pane: HollowPane, old_title: string, new_title: string }
---@field ["term:tab_activated"] { tab: HollowTab }
---@field ["term:tab_closed"] { tab_id: integer }
---@field ["term:pane_focused"] { pane: HollowPane }
---@field ["term:pane_created"] { pane: HollowPane }
---@field ["term:pane_exited"] { pane: HollowPane, status: integer|nil }
---@field ["term:pane_closed"] { pane: HollowPane }
---@field ["term:pane_layout_changed"] { pane: HollowPane }
---@field ["term:cwd_changed"] { pane: HollowPane, old_cwd: string, new_cwd: string }
---@field ["term:foreground_process_changed"] { pane: HollowPane, old_process: string, new_process: string }
---@field ["term:command_started"] { pane: HollowPane, command: string, cwd: string }
---@field ["term:command_finished"] { pane: HollowPane, command?: string, status?: integer, took_ms?: integer }
---@field ["term:program_status_changed"] { pane: HollowPane }
---@field ["term:bell"] { pane: HollowPane }
---@field ["term:notification"] { pane: HollowPane, title: string, message: string, level: HollowNotifyLevel, id: string|nil, ttl_ms: integer|nil, close: boolean }
---@field ["key:unhandled"] { key: string, mods: string }
---@field ["window:resized"] { size: HollowSize }
---@field ["window:files_dropped"] HollowFileDropEvent
---@field ["window:focused"] {}
---@field ["window:blurred"] {}
---@field ["copy_mode:changed"] { active: boolean, query: string, match_count: integer, match_index: integer|nil, selecting: boolean, block: boolean }
---@field ["copy_mode:search_requested"] {}
---@field ["quick_select:changed"] { active: boolean, action: "open"|"copy" }
---@field ["quick_select:no_matches"] {}
---@field ["quick_select:action_executed"] { text: string, kind: HollowQuickSelectKind, action: "open"|"copy"|"callback"|"command"|"route", pattern_index: integer|nil }
---@field ["topbar:hover"] { id: string, mods: HollowKeyMods, shifted: boolean }
---@field ["topbar:leave"] {}
---@field ["topbar:click"] { id: string, mods: HollowKeyMods, shifted: boolean }
---@field ["bottombar:hover"] { id: string, mods: HollowKeyMods, shifted: boolean }
---@field ["bottombar:leave"] {}
---@field ["bottombar:click"] { id: string, mods: HollowKeyMods, shifted: boolean }
---@field ["sidebar:hover"] { id: string, mods: HollowKeyMods, shifted: boolean }
---@field ["sidebar:leave"] {}
---@field ["sidebar:click"] { id: string, mods: HollowKeyMods, shifted: boolean }
---@field ["overlay:hover"] { id: string, index: integer|nil }
---@field ["overlay:leave"] {}
---@field ["overlay:click"] { id: string, index: integer|nil }
---@field ["overlay:scroll"] { id: string, delta: number, index: integer }
---@field ["overlay:scrollbar"] { id: string, ratio: number, index: integer }
---@field ["selection:begin"] {}
---@field ["selection:cleared"] {}

---@alias HollowHtpValue nil|boolean|number|string|table
---@alias HollowEventHandle integer

--- Built-in token completions; custom palette keys and dotted paths remain valid.
---@alias HollowStyleToken
---| "fg"|"muted"|"detail"|"subtle"|"title"|"panel_bg"|"panel_border"|"divider"
---| "input_bg"|"input_fg"|"cursor_bg"|"cursor_fg"
---| "selected_bg"|"selected_fg"|"selected_detail_bg"|"selected_muted"
---| "selection_bg"|"selection_fg"|"hover_bg"|"hover_fg"
---| "primary_bg"|"primary_fg"|"destructive_bg"|"destructive_fg"|"button_emphasis_bg"
---| "notify_fg"|"notify_levels.info"|"notify_levels.warn"|"notify_levels.error"|"notify_levels.success"
---| "counter"|"empty"|"scrollbar_track"|"scrollbar_thumb"
---| "bar_bg"|"bar_fg"|"status_bg"|"status_fg"|"tab_bar_bg"
---| "tab_active_bg"|"tab_active_fg"|"tab_inactive_bg"|"tab_inactive_fg"|"tab_hover_bg"|"tab_hover_fg"
---| "accent"|"warm"
---| (string & {})
---@alias HollowStyleColor HollowColor|HollowStyleToken|false False suppresses an earlier color layer.
---@alias HollowStyleLayer HollowStyle|false|nil Conditional layer; true is not a style.

---@class (exact) HollowUiColorPair
---@field fg? HollowStyleColor
---@field bg? HollowStyleColor

---@class HollowStyle
---@field padding? HollowUiBoxValue Overlay span padding in pixels; included in row sizing and click targets.
---@field margin? HollowUiBoxValue
---@field fg? HollowStyleColor
---@field bg? HollowStyleColor
---@field bold? boolean
---@field italic? boolean
---@field underline? boolean
---@field strikethrough? boolean
---@field dim? boolean
---@field id? string
---@field radius? number Rounded corner radius for bg/border rect
---@field border? HollowStyleColor Border color for bg rect outline
---@field border_size? number Border thickness in pixels
---@field background_extend? number
---@field close_fg? HollowStyleColor Bar tab close-button part.
---@field close_bg? HollowStyleColor Bar tab close-button part.
---@field close_hover_fg? HollowStyleColor Bar tab close-button part.
---@field close_hover_bg? HollowStyleColor Bar tab close-button part.
---@field close_radius? number Bar tab close-button part.
---@field selection_accent? HollowStyleColor Unrounded active tab selection stripe.
---@field hover? HollowStyle|false Overrides applied to hovered spans; false removes an earlier hover layer.
---@field on_click? fun(e: { id: string, mods?: HollowKeyMods })
---@field on_mouse_enter? fun(e: { id: string, mods?: HollowKeyMods })
---@field on_mouse_leave? fun(e: { id: string, mods?: HollowKeyMods })

---@alias HollowStyleValue HollowStyle|HollowColor
--- Internal flat visual snapshot. Identity and callbacks remain on nodes.
--- Surface adapters retain their existing pixel/unit rules.
---@class HollowUiComputedStyle
---@field fg? HollowColor
---@field bold boolean
---@field bg? HollowColor
---@field border? HollowColor
---@field border_size? number
---@field radius? number
---@field background_extend? number
---@field padding? { top: number, right: number, bottom: number, left: number }
---@field margin? { top: number, right: number, bottom: number, left: number }

---@alias HollowUiNodeStyle HollowStyle

---@class HollowUiStyleWrapper
---@field style HollowUiNodeStyle

---@alias HollowUiNodeEventPayload table<string, any>

---@class HollowUiChrome
---@field bg? HollowStyleColor
---@field border? HollowStyleColor
---@field border_size? integer
---@field alpha? integer
---@field radius? integer
---@field padding? HollowUiBoxValue
---@field margin? HollowUiBoxValue

---@class HollowSize
---@field rows integer
---@field cols integer
---@field width integer
---@field height integer

---@alias HollowFontSmoothing "grayscale"|"subpixel"
---@alias HollowFontHinting "none"|"light"|"normal"

---@class HollowFontInfo
---@field family string
---@field styles string[]

---@class HollowFontsNamespace
---@field list fun(): HollowFontInfo[]
---@field find fun(query: string): HollowFontInfo[]
---@field has fun(family: string, style?: string): boolean
---@field pick fun(candidates: string[], style?: string): string|nil

---@class HollowFontsConfig
---@field size number
---@field line_height? number
---@field padding_x? number
---@field padding_y? number
---@field smoothing? HollowFontSmoothing
---@field hinting? HollowFontHinting
---@field ligatures? boolean
---@field embolden? number
---@field regular_embolden? number
---@field bold_embolden? number
---@field italic_embolden? number
---@field bold_italic_embolden? number
---@field family? string
---@field regular? string
---@field bold? string
---@field italic? string
---@field bold_italic? string
---@field fallbacks? string[]

---@class HollowCursorConfig
---@field style? HollowCursorStyle
---@field blink? boolean
---@field blink_rate? integer

---@class HollowUnfocusedPaneConfig
---@field cursor? HollowCursorStyle|false
---@field dim? boolean|number
---@field dim_opacity? number

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

---@alias HollowQuickSelectKind "url"|"ip"|"quote"|"filename"|"custom"

---@alias HollowLinkRouteSource "click"|"quick_select"

---@class HollowLinkRouteRequest
---@field url string Effective open target; can be URL or quick-select path
---@field text string Original matched text; OSC 8 links use their embedded URI
---@field pane HollowPane|nil Origin pane snapshot
---@field pane_id integer Origin pane ID
---@field mods HollowKeyMods Modifier chord, e.g. "<S>"; empty when unmodified
---@field source HollowLinkRouteSource
---@field kind HollowQuickSelectKind
---@field pattern_index integer|nil Custom quick-select pattern index

---@alias HollowLinkRouteResult { handled: true }|{ url: string }

---@class HollowRouteNamespace
---@field link fun(handler:fun(request:HollowLinkRouteRequest):HollowLinkRouteResult|false|nil):fun():boolean Register link handler; return unsubscribe function

---@class HollowQuickSelectActionContext
---@field kind HollowQuickSelectKind
---@field pattern_index integer|nil

---@class HollowQuickSelectCommandAction
---@field command string[] Command arguments; `{match}` is replaced with matched text

---@alias HollowQuickSelectAction "open"|"copy"|HollowQuickSelectCommandAction|fun(text:string, context:HollowQuickSelectActionContext)

---@class HollowQuickSelectPattern
---@field pattern string Lua string pattern
---@field action? HollowQuickSelectAction
---@field enabled? boolean

---@class HollowQuickSelectConfig
---@field actions? { url?: HollowQuickSelectAction, ip?: HollowQuickSelectAction, quote?: HollowQuickSelectAction, filename?: HollowQuickSelectAction }
---@field patterns? (string|HollowQuickSelectPattern)[] Additional Lua patterns; strings default to copy

---@class HollowConfig
---@field debug_overlay? boolean
---@field debug_terminal_trace? boolean
---@field backend? string
---@field vsync? boolean
---@field synchronized_output? boolean Hold terminal content during DEC synchronized output
---@field hide_mouse_cursor_when_typing? boolean
---@field max_fps? integer
---@field command_timing? boolean
---@field load_default_keymaps? boolean
---@field padding? integer
---@field alternate_screen_padding? integer
---@field alternate_screen_resize_nudge? boolean Send a delayed resize cycle after entering alternate screen (default true)
---@field alternate_padding_x? integer
---@field alternate_padding_y? integer
---@field alternate_padding_left? integer
---@field alternate_padding_right? integer
---@field alternate_padding_top? integer
---@field alternate_padding_bottom? integer
---@field theme? string|HollowThemeSpec
---@field fonts? HollowFontsConfig
---@field scrollback? integer
---@field cols? integer
---@field rows? integer
---@field window_title? string
---@field window_width? integer
---@field window_height? integer
---@field window_titlebar_show? boolean
---@field top_bar_mode? HollowTopBarMode
---@field top_bar_height? integer
---@field top_bar_bg? HollowColor
---@field bottom_bar_show? boolean
---@field bottom_bar_height? integer
---@field bottom_bar_bg? HollowColor
---@field bottom_bar_draw_status? boolean
---@field scrollbar? HollowScrollbarConfig
---@field hyperlinks? HollowHyperlinksConfig
---@field quick_select? HollowQuickSelectConfig
---@field cursor? HollowCursorConfig
---@field unfocused_pane? HollowUnfocusedPaneConfig
---@field shell? string|string[]
---@field default_domain? string
---@field domains? table<string, string|HollowDomainConfig>
---@field env? table<string, string>
---@field workspace? HollowWorkspaceConfig
---@field watch_dirs? string[]

---@class HollowWorkspaceConfig
---@field auto_bootstrap? "always"|"never"
---@field default_layout? string

---@class HollowDomainPtyConfig
---@field mode? "dedicated"|"mux" Dedicated by default; mux shares a connector across matching live panes
---@field read_workers? integer Persistent mux reader threads 0–4 (default 4); 0 uses inline reads, not dedicated mode
---@field batch_jobs? 1|2 Compatibility setting (default 2); no effect with persistent mux readers

---@class HollowDomainConfig
---@field pty? HollowDomainPtyConfig Experimental agent terminal transport; applies only to agent-backed domains
---@field shell? string
---@field ssh? HollowSshDomainConfig
---@field wsl_distro? string
---@field default_cwd? string
---@field env? table<string, string>
---@field host? false|HollowWorkspaceHostDescriptor|{ path_style?: "posix"|"wsl" } Agent terminal host (dedicated by default). On Windows, WSL domains use it implicitly (falling back to wsl.exe); `false` opts out

---@class HollowDomain: HollowDomainConfig
---@field name string
---@field is_active boolean
---@field is_default boolean

---@alias HollowSshBackend "native"|"wsl"
---@alias HollowSshReuse "none"|"auto"
---@class HollowSshDomainConfig
---@field host? string
---@field user? string
---@field alias? string
---@field backend? HollowSshBackend
---@field reuse? HollowSshReuse

---@class HollowProgramStatus
---@field id string Hierarchical record id; empty string denotes root.
---@field state "idle"|"working"|"done"|"blocked"|"error"
---@field kind "none"|"permission"|"question"|"auth"
---@field progress? integer Percentage, when reported (0–100).
---@field app string Effective application name, inherited from nearest ancestor.
---@field title string Untrusted plain-text label, never markup.
---@field message string Untrusted plain-text description, never markup.
---@field attention boolean Unread blocked/error report received while pane inactive; focus acknowledges without deleting status.

---@class HollowPane
---@field id integer
---@field pid integer
---@field domain? string
---@field direction? "horizontal"|"vertical"
---@field split_ratio? number
---@field active_screen '"primary"|"alternate"'
---@field cwd string
---@field title string
---@field is_focused boolean
---@field is_floating boolean
---@field is_maximized boolean
---@field has_bell boolean
---@field busy boolean True while shell integration reports a running command.
---@field at_prompt boolean True after a shell readiness hook, until the next command or run submission.
---@field running? { command: string, ms: integer } Current shell command and elapsed time.
---@field last? { command?: string, status?: integer, took_ms?: integer } Most recently finished shell command.
---@field frame { x: integer, y: integer, width: integer, height: integer }
---@field foreground_process string
---@field program_status HollowProgramStatus[] OSC 7501 records, oldest updated first.
---@field tags string[]
---@field size HollowSize

---@class HollowFileDropEvent
---@field paths string[] Original UTF-8 paths reported by the operating system
---@field pane HollowPane|nil Pane under drop position
---@field pane_id integer
---@field x number Window x coordinate
---@field y number Window y coordinate
---@field text string Default shell input text
---@alias HollowFileDropResult nil|boolean|string
---@alias HollowFileDropHandler fun(event: HollowFileDropEvent): HollowFileDropResult

---@class HollowTab
---@field id integer
---@field title string
---@field index integer
---@field is_active boolean
---@field panes HollowPane[]
---@field pane HollowPane

---@class HollowWorkspace
---@field id integer
---@field index integer
---@field name string
---@field domain? string
---@field is_active boolean

---@class HollowMuxWorkspace: HollowWorkspace
---@field tabs HollowTab[]

---@alias HollowPaneSnapshot HollowPane
---@alias HollowTabSnapshot HollowTab
---@alias HollowWorkspaceSnapshot HollowWorkspace
---@alias HollowDomainSnapshot HollowDomain
---@alias HollowPaneSizeSnapshot HollowSize
---@alias HollowWindowSizeSnapshot HollowSize

---@class HollowNewTabOpts
---@field cmd? string|string[]
---@field cwd? string
---@field env? table<string, string>
---@field title? string
---@field domain? string
---@field command? string
---@field insert_at_end? boolean
---@field on_complete? fun(result: { success: boolean, tab_id?: integer })

---@class HollowSplitPaneOpts
---@field direction? "horizontal"|"vertical"
---@field tag? string
---@field tags? string[]
---@field ratio? number
---@field domain? string
---@field cwd? string
---@field command? string
---@field command_mode? "send"|"spawn"
---@field close_on_exit? boolean
---@field floating? boolean
---@field fullscreen? boolean
---@field x? number
---@field y? number
---@field width? number
---@field height? number
---@field on_complete? fun(result: { success: boolean, pane_id?: integer })

---@class HollowNewWorkspaceOpts
---@field cwd? string
---@field domain? string
---@field command? string
---@field name? string
---@field on_complete? fun(result: { success: boolean, workspace_index?: integer })

---@class HollowPromise<T>
---@field status fun(self: HollowPromise<T>): "pending"|"fulfilled"|"rejected"
---@field value fun(self: HollowPromise<T>): T|nil
---@field error fun(self: HollowPromise<T>): any
---@field next fun(self: HollowPromise<T>, on_resolve?: fun(value: T): any, on_reject?: fun(err: any): any): HollowPromise<any>
---@field catch fun(self: HollowPromise<T>, on_reject: fun(err: any): any): HollowPromise<any>
---@field await fun(self: HollowPromise<T>): T

---@class HollowAsyncNamespace
---@field run fun(fn: function): thread
---@field await fun(register: fun(resolve: fun(value: any), reject?: fun(err: any))): any
---@field promise fun(register: fun(resolve: fun(value: any), reject: fun(err: any))): HollowPromise<any>

---@class HollowWorkspaceBootstrapPane
---@field cwd? string
---@field domain? string
---@field command? string
---@field command_mode? "send"|"spawn"
---@field close_on_exit? boolean
---@field floating? boolean
---@field fullscreen? boolean
---@field x? number
---@field y? number
---@field width? number
---@field height? number
---@field size? number
---@field direction? "horizontal"|"vertical"
---@field main? boolean
---@field default? boolean

---@class HollowWorkspaceBootstrapTab
---@field name? string
---@field layout? "horizontal"|"vertical"
---@field panes HollowWorkspaceBootstrapPane[]

---@class HollowWorkspaceBootstrapSpec
---@field name? string
---@field tabs HollowWorkspaceBootstrapTab[]

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

---@alias HollowUiFormattedNode HollowUiSpanNode|HollowUiGroupNode
---@alias HollowUiFormattedValue string|HollowUiFormattedNode|HollowUiFormattedNode[]

---@class HollowUiTextShorthand: HollowStyle
---@field [1] string

---@alias HollowUiButtonVariant "default"|"primary"|"destructive"|"ghost"
---@alias HollowUiControlSize "sm"|"md"

---@class HollowUiButtonOptions
---@field variant? HollowUiButtonVariant Opts into the themed button recipe; raw buttons otherwise retain their style.
---@field size? HollowUiControlSize Opts into recipe spacing.
---@field disabled? boolean Suppresses click/hover callbacks and hover paint.
---@field theme? HollowUiTheme Select palette by default for recipe buttons; explicit partial palettes are authoritative.
---@field id string
---@field text? string
---@field style? HollowUiNodeStyle
---@field on_click? fun(e: { id: string })
---@field on_mouse_enter? fun(e: { id: string })
---@field on_mouse_leave? fun(e: { id: string })

---@class HollowUiActionButtonOptions: HollowUiButtonOptions
---@field theme? HollowUiTheme Select widget theme by default.
---@field state? { hovered_id?: string } Legacy option; hover is resolved by the overlay and this value is unused.
---@field hover_style? HollowUiNodeStyle Legacy hover overrides applied while hovered.

---@class HollowUiTabOptions
---@field id string
---@field label string
---@field active? boolean
---@field badge? { text: string|number, color: HollowColor }
---@field theme? HollowUiTheme Select widget theme by default.
---@field on_click? fun(e: { id: string })

---@class HollowUiTabBarOptions
---@field tabs HollowUiTabOptions[]
---@field theme? HollowUiTheme Default theme for tabs.

---@alias HollowUiRenderableNode HollowUiSpanNode|HollowUiSpacerNode|HollowUiIconNode|HollowUiGroupNode
---@alias HollowUiInlineNode string|HollowUiRenderableNode|HollowUiTextShorthand
---@alias HollowUiChild HollowUiInlineNode|number|boolean|nil|HollowUiChild[]
---@alias HollowUiRowChild HollowUiRowNode|HollowUiColumnNode|boolean|nil|HollowUiRowChild[]

---@class HollowUiFormatColumnSpec
---@field text? string
---@field style? HollowUiNodeStyle|HollowHexColor
---@field width? number
---@field align? "left"|"right"

---@class HollowUiRowStyle
---@field fg? HollowStyleColor
---@field bg? HollowStyleColor
---@field bold? boolean
---@field radius? number
---@field hover? HollowUiRowStyle|false

---@class HollowUiRowOptions
---@field style? HollowUiRowStyle Row paint; only fg/bold inherit into children.
---@field variant? "selectable"
---@field selected? boolean Explicit model selection, independent of pointer hover.
---@field theme? HollowUiTheme Optional partial palette for this row.
---@field id? string
---@field hoverable? boolean
---@field fill_bg? HollowColor|HollowStyleToken|false
---@field fill_radius? number
---@field accent_bar? HollowColor|HollowStyleToken|false
---@field divider? HollowColor|HollowStyleToken
---@field scrollbar_track? boolean
---@field scrollbar_thumb? boolean
---@field scrollbar_id? string
---@field scrollbar_thumb_ratio? number
---@field scrollbar_thumb_size? number
---@field scrollbar_track_color? HollowStyleColor
---@field scrollbar_thumb_color? HollowStyleColor

---@class HollowUiRowNode
---@field style? HollowUiRowStyle Row paint; only fg/bold inherit into children.
---@field variant? "selectable"
---@field selected? boolean Explicit model selection, independent of pointer hover.
---@field theme? HollowUiTheme Optional partial palette for this row.
---@field _type "row"
---@field children HollowUiRenderableNode[]
---@field id? string
---@field hoverable boolean
---@field fill_bg? HollowColor|HollowStyleToken|false
---@field fill_radius? number
---@field accent_bar? HollowColor|HollowStyleToken|false
---@field divider? HollowColor|HollowStyleToken
---@field scrollbar_track boolean
---@field scrollbar_thumb boolean
---@field scrollbar_id? string
---@field scrollbar_thumb_ratio? number
---@field scrollbar_thumb_size? number
---@field scrollbar_track_color? HollowStyleColor
---@field scrollbar_thumb_color? HollowStyleColor

---@class HollowUiColumnNode
---@field _type "column"
---@field children HollowUiRowNode[]

---@alias HollowUiRow HollowUiRowNode
---@alias HollowUiRows HollowUiRowNode[]

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
---@field mods HollowKeyMods
---@field shifted boolean

---@class HollowUiBarTabsOptions: HollowUiBarNodeOptionsBase
---@field fit? "fill"|"content"
---@field max_width? number
---@field format? fun(tab: HollowUiTabState, ctx?:HollowWidgetCtx): HollowUiFormattedValue
---@field style? HollowUiNodeStyle|HollowHexColor|fun(tab: HollowUiTabState, ctx?:HollowWidgetCtx): HollowUiNodeStyle|HollowHexColor|nil

---@class HollowUiBarTabsNode: HollowUiBarTabsOptions
---@field _type "bar_tabs"

---@class HollowUiBarWorkspaceOptions: HollowUiBarNodeOptionsBase
---@field format? fun(workspace: HollowUiWorkspaceState, ctx?:HollowWidgetCtx): HollowUiFormattedValue
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
---@field style? HollowUiNodeStyle
---@field render fun(ctx: HollowWidgetCtx): HollowUiFormattedValue
---@field on_click? fun(e: { id: string, mods: HollowKeyMods, shifted: boolean })
---@field on_mouse_enter? fun(e: { id: string, mods: HollowKeyMods, shifted: boolean })
---@field on_mouse_leave? fun(e: { id: string, mods?: HollowKeyMods })
---@class HollowUiBarCustomOptions
---@field id? string
---@field style? HollowUiNodeStyle
---@field render fun(ctx:HollowWidgetCtx):HollowUiFormattedValue|HollowUiSegment|HollowUiNodeStyle|nil
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
---@field fallback_style? {fg?: HollowColor, bg?: HollowColor, selection_accent?: HollowColor} Optional native-tab paint defaults, independent of layout.
---@field padding? {top:number,right:number,bottom:number,left:number} Normalized overlay span padding in pixels.
---@field text string
---@field fg? HollowColor
---@field bg? HollowColor
---@field bold? boolean
---@field id? string
---@field spacer? boolean When true, pushes subsequent segments to the right edge of the row
---@field segments? HollowUiSegment[]
---@field kind? string
---@field radius? number Rounded corner radius for bg/border rect
---@field border? HollowColor Border color for bg rect outline
---@field border_size? number Border thickness in pixels

---@class HollowUiTabsLayout
---@field kind "tabs"
---@field fit "content"|"fill"
---@field max_width? number
---@field tabs HollowUiSegment[]

---@class HollowUiRowPaint
---@field hover_bg? HollowColor Lua-owned hover paint, with native compatibility fallback.
---@field fill_bg? HollowColor
---@field fill_radius? number
---@field accent_bar? HollowColor|false
---@field divider? HollowColor
---@field scrollbar_track boolean
---@field scrollbar_thumb boolean
---@field scrollbar_id? string
---@field scrollbar_thumb_ratio? number
---@field scrollbar_thumb_size? number
---@field scrollbar_track_color? HollowColor
---@field scrollbar_thumb_color? HollowColor

---@class HollowUiSidebarState
---@field style? {fg?: HollowColor, bg?: HollowColor, border?: HollowColor, alpha?: number}
---@field row_styles? HollowUiRowPaint[] Optional row-paint metadata; rows retain their legacy segment-array shape.
---@field side "left"|"right"
---@field width integer
---@field reserve boolean
---@field rows HollowUiSegment[][]

---@alias HollowWidgetRenderResult HollowUiColumnNode|HollowUiRowNode|nil

---@class HollowWidget
---@field style? HollowStyle|HollowUiChrome Surface paint; explicit overlay chrome fields win.
---@field layout? { padding?: HollowUiBoxValue, margin?: HollowUiBoxValue }
---@field _kind? string
---@field _palette? table Internal resolved palette, including instance overrides.
---@field _theme_backdrop? boolean Internal marker for a theme-owned default backdrop.
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
---@field _modal? boolean
---@field _expires_at? integer

---@alias HollowUiWidget HollowWidget
---@alias HollowUiWidgetOptions HollowWidget

---@class HollowUiTopbarOptions: HollowWidget
---@field height? integer

---@class HollowUiTopbarCwdOptions
---@field style? HollowUiNodeStyle|HollowHexColor
---@field format? fun(pane: HollowPane|nil, ctx?: HollowWidgetCtx): HollowUiFormattedValue|nil

---@class HollowUiTopbarSeparatorOptions
---@field text? HollowUiFormattedValue
---@field value? HollowUiFormattedValue
---@field style? HollowUiNodeStyle|HollowHexColor

---@class HollowUiTopbarTimeOptions
---@field format? string
---@field style? HollowUiNodeStyle|HollowHexColor

---@class HollowUiTopbarConfigureOptions
---@field height? integer
---@field style? HollowUiNodeStyle|HollowHexColor
---@field layout? { padding?: HollowUiBoxValue, margin?: HollowUiBoxValue }
---@field workspace? false|HollowUiBarWorkspaceOptions
---@field tabs? false|HollowUiBarTabsOptions
---@field separator? false|string|HollowUiTopbarSeparatorOptions
---@field new_tab? false|{ id?: string, text?: string, shifted_text?: string, style?: HollowUiNodeStyle }
---@field cwd? false|HollowUiTopbarCwdOptions
---@field key_legend? false|HollowUiBarKeyLegendOptions
---@field time? false|string|HollowUiTopbarTimeOptions

---@class HollowUiBottombarOptions: HollowWidget
---@field height? integer

---@class HollowUiSidebarOptions: HollowWidget
---@field style? {fg?: HollowColor|HollowStyleToken, bg?: HollowColor|HollowStyleToken, border?: HollowColor|HollowStyleToken, alpha?: number} Sidebar surface paint, independent of layout.
---@field side? HollowSidebarSide
---@field width? integer
---@field reserve? boolean

---@class HollowUiOverlayOptions
---@field style? HollowUiChrome Surface paint below explicit chrome fields.
---@field render fun(ctx: HollowWidgetCtx): HollowWidgetRenderResult
---@field on_key? fun(key: string, mods: HollowKeyMods): boolean
---@field on_mount? fun()
---@field on_unmount? fun()
---@field align? HollowOverlayAlign
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field chrome? HollowUiChrome

---@class HollowUiNotifyAction
---@field label string
---@field fn fun()

---@class HollowUiNotifyOptions
---@field pane_id? integer Originating pane for activity history and background detection.
---@field level? HollowNotifyLevel
---@field title? string
---@field ttl? number
---@field action? HollowUiNotifyAction
---@field id? string
---@field align? HollowOverlayAlign
---@field backdrop? HollowOverlayBackdropValue
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme

---@class HollowUiInputOptions
---@field prompt? string
---@field default? string
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme
---@field align? HollowOverlayAlign
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

---@class HollowUiConfirmButton
---@field text string
---@field value? any
---@field style? "default"|"primary"|"secondary"|"destructive"
---@field on_confirm? fun()

---@class (exact) HollowUiDialogButton
---@field _button true
---@field id string
---@field text string
---@field kind "default"|"primary"|"destructive"
---@field on_click? fun(e: { id: string })

---@class HollowUiConfirmOptions
---@field prompt string
---@field title? string
---@field buttons? HollowUiConfirmButton[]
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme
---@field align? HollowOverlayAlign
---@field on_confirm? fun(value: any)
---@field on_cancel? fun()

---@class HollowUiModalHandle
---@field widget table
---@field close fun()
---@field invalidate fun()
---@field schedule_refresh fun(delay_ms: number) Request a future refresh while mounted; callbacks become inert after close.

---@class HollowUiDialogButtonOptions
---@field id? string
---@field text string
---@field kind? "default"|"primary"|"destructive"
---@field on_click? fun(e: { id: string })

---@class (exact) HollowUiListNav
---@field index integer
---@field count integer
---@field resize fun(new_n: integer)
---@field set fun(i: integer)
---@field next fun()
---@field prev fun()
---@field move fun(delta: integer)
---@field first fun()
---@field last fun()
---@field handlers table<string, function>

---@class (exact) HollowUiScrollNav
---@field index integer
---@field count integer
---@field resize fun(new_n: integer)
---@field visible_range fun(items: any[], budget: integer): integer, integer, boolean, integer, number, number
---@field scroll_to_ratio fun(items: any[], ratio: number, budget: integer)
---@field page_down fun()
---@field page_up fun()
---@field handlers table<string, function>

---@class (exact) HollowUiTextInput
---@field value string
---@field cursor integer
---@field on_change? fun(value: string)
---@field set fun(value: string, cursor?: integer)
---@field render fun(theme: table): any[]
---@field handlers table<string, function>

---@class (exact) HollowUiDialogOptions
---@field title? string
---@field body? table[]
---@field footer? (HollowUiDialogButton|{ text: string, kind?: string, id?: string, on_click?: fun(e: { id: string }) })[]
---@field selected? integer
---@field hovered? integer

---@class HollowUiModalSpec
---@field theme? HollowUiTheme|string Widget-kind name for a live palette, or an authoritative explicit palette table.
---@field render fun(theme: HollowUiTheme, state: table, ctx: HollowUiLayoutContext): HollowUiLayoutNode, number? Clay tree and optional preferred content height in pixels.
---@field keys? function
---@field width? integer
---@field height? integer
---@field max_height? integer
---@field chrome? table|boolean
---@field align? string
---@field backdrop? any
---@field on_event? function
---@field layout_live? boolean Rebuild on every preparation; use only for providers without explicit invalidation.
---@field semantic_hover? boolean Invalidate the render snapshot when hover state changes; native background hover needs no rebuild.
---@field layout_events? string[] Event names that invalidate the native snapshot while mounted.
---@field layout_refresh_after? fun(): number|nil Delay in milliseconds until the next time-dependent update; nil schedules none.
---@field on_mount? fun()
---@field on_unmount? fun()

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
---@field layout_live? boolean Callable sources default to live rebuilding; false requires explicit layout events or invalidation.
---@field layout_events? string[] Native snapshot invalidation events while mounted.
---@field layout_refresh_after? fun(): number|nil Native snapshot refresh delay in milliseconds.
---@field on_mount? fun()
---@field on_unmount? fun()
---@field layout_label? fun(item: any, ctx: HollowUiLayoutContext, view: { id: string, query: string, selected: boolean, hovered: boolean, theme: HollowUiTheme }): HollowUiLayoutNode|nil Optional Clay label tree; nil uses the normal label, which still supplies search/semantics.
---@field items any[]|fun(): any[] Live providers are evaluated on each render; avoid blocking work.
---@field label? fun(item: any): HollowUiInlineNode|HollowUiInlineNode[]
---@field search_text? fun(item: any): string|nil
---@field detail? fun(item: any): HollowUiInlineNode|HollowUiInlineNode[]
---@field prompt? string
---@field fuzzy? boolean
---@field query? string
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field max_height? integer
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme
---@field actions HollowUiSelectAction[]
---@field on_cancel? fun()

---@alias HollowActionCategory "tab"|"pane"|"workspace"|"window"|"scroll"|"copy_mode"|"general"|"user"|string

---@alias HollowShapeRule string|(fun(value: any): boolean)|table|HollowShapeSchema<any>
---@alias HollowShapeParser fun(value: any, path: string): boolean, any
---@alias HollowShapeRuleParser fun(value: any, rule: HollowShapeRule, path: string): boolean, any

---@class HollowShapeObjectOptions
---@field strict? boolean

---@class HollowShapeSchema<T>
---@field __index HollowShapeSchema<any>
---@field _parse HollowShapeParser
---@field parse fun(self: HollowShapeSchema<T>, value: any, message?: string): T
---@field safe_parse fun(self: HollowShapeSchema<T>, value: any): HollowShapeResult<T>
---@field check fun(self: HollowShapeSchema<T>, value: any): boolean
---@field is fun(self: HollowShapeSchema<T>, value: any): boolean
---@field optional fun(self: HollowShapeSchema<T>): HollowShapeSchema<T|nil>
---@field nullable fun(self: HollowShapeSchema<T>): HollowShapeSchema<T|nil>
---@field default fun(self: HollowShapeSchema<T>, value: T): HollowShapeSchema<T>
---@field array fun(self: HollowShapeSchema<T>): HollowShapeSchema<T[]>
---@field constraint fun(self: HollowShapeSchema<T>, fn: (fun(value: T): boolean), message?: string): HollowShapeSchema<T>
---@field min fun(self: HollowShapeSchema<T>, value: number): HollowShapeSchema<T>
---@field max fun(self: HollowShapeSchema<T>, value: number): HollowShapeSchema<T>
---@field transform fun(self: HollowShapeSchema<T>, fn: fun(value: T): any): HollowShapeSchema<any>
---@field convert fun(self: HollowShapeSchema<T>, fn: fun(value: T): any): HollowShapeSchema<any>
---@field or_ fun(self: HollowShapeSchema<T>, other: HollowShapeRule): HollowShapeSchema<T>

---@class HollowShapeResult<T>
---@field success boolean
---@field data? T
---@field error? string

---@class HollowShapeNamespace
---@field validate fun(value: any, spec: HollowShapeRule, message?: string): any
---@field parse fun(value: any, spec: HollowShapeRule, message?: string): any
---@field safe_parse fun(value: any, spec: HollowShapeRule, message?: string): HollowShapeResult<any>
---@field check fun(value: any, spec: HollowShapeRule): boolean
---@field is fun(value: any, spec: HollowShapeRule): boolean
---@field is_schema fun(value: any): boolean
---@field expect fun(condition: boolean, message: string): boolean
---@field assert fun(condition: boolean, message: string): boolean
---@field object fun(spec: table<any, HollowShapeRule>, options?: HollowShapeObjectOptions): HollowShapeSchema<table>
---@field strict_object fun(spec: table<any, HollowShapeRule>): HollowShapeSchema<table>
---@field array fun(item?: HollowShapeRule): HollowShapeSchema<table>
---@field enum fun(values: any[]): HollowShapeSchema<any>
---@field one_of fun(values: any[]): HollowShapeSchema<any>
---@field literal fun(value: any): HollowShapeSchema<any>
---@field union fun(first: HollowShapeRule|HollowShapeRule[], ...: HollowShapeRule): HollowShapeSchema<any>
---@field optional fun(rule: HollowShapeRule): HollowShapeSchema<any>
---@field nullable fun(rule: HollowShapeRule): HollowShapeSchema<any>
---@field custom fun(predicate: fun(value: any): boolean, description?: string): HollowShapeSchema<any>
---@field constraint fun(rule: HollowShapeRule, predicate: fun(value: any): boolean, description?: string): HollowShapeSchema<any>
---@field transform fun(rule: HollowShapeRule, transformer: fun(value: any): any): HollowShapeSchema<any>
---@field convert fun(rule: HollowShapeRule, converter: fun(value: any): any): HollowShapeSchema<any>
---@field any fun(): HollowShapeSchema<any>
---@field unknown fun(): HollowShapeSchema<any>
---@field string fun(): HollowShapeSchema<string>
---@field number fun(): HollowShapeSchema<number>
---@field integer fun(): HollowShapeSchema<integer>
---@field boolean fun(): HollowShapeSchema<boolean>
---@field function fun(): HollowShapeSchema<function>
---@field thread fun(): HollowShapeSchema<thread>
---@field userdata fun(): HollowShapeSchema<userdata>
---@field table fun(): HollowShapeSchema<table>

---@class HollowActionSpec
---@field run fun(...: any): any
---@field desc? string
---@field category? HollowActionCategory
---@field workspace_targetable? boolean
---@field available? fun(ctx: HollowActionContext): boolean Fast, synchronous check; only true shows action in palette
---@field keys? string[] Default chords registered with this action
---@field arguments? HollowShapeSchema<any> Opt-in schema for named arguments; use strict_object to reject unknown fields

---@class HollowActionResult
---@field success boolean
---@field status "ok"|"unknown_action"|"invalid_context"|"invalid_arguments"|"action_failed"
---@field value? any First callback return value; not an asynchronous completion signal
---@field error? string

---@class HollowActionContext
---@field name string Action being invoked or checked
---@field args table Original positional arguments, with n recording their count (including nils)
---@field origin string Invocation source: lua, key, palette, or caller-supplied metadata
---@field caller? table Caller metadata only; never targeting or authorization
---@field pane? HollowPane Current pane snapshot
---@field tab? HollowTab Current tab snapshot
---@field workspace? HollowWorkspace Current workspace snapshot

---@class HollowPaletteEntry
---@field name string
---@field desc string
---@field category HollowActionCategory
---@field chords string[]
---@field run fun()
---@field available? fun(ctx: HollowActionContext): boolean Registry predicate used by the command palette
---@field workspace_targetable? boolean
---@field arguments? HollowShapeSchema<any>

---@class HollowUiCommandPaletteOptions
---@field prompt? string
---@field query? string
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme
---@field on_confirm? fun(entry: HollowPaletteEntry)
---@field on_cancel? fun()

---@class HollowEventListener
---@field name string
---@field handler fun(payload:any)
---@field once boolean
---@field filter? boolean

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

---@class HollowKeymapModeState
---@field bindings HollowKeymapBindingStore
---@field sequence_bindings HollowKeymapSequenceNode
---@field leader_bindings HollowKeymapSequenceNode

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
---@field modes table<HollowKeyMode, HollowKeymapModeState>
---@field leader HollowKeymapLeader|nil
---@field sequence_timeout_ms integer
---@field sequence_pending_until integer|nil
---@field sequence_active_node HollowKeymapSequenceNode|nil
---@field sequence_steps string[]
---@field sequence_prefix string|nil
---@field active_mode HollowKeyMode

---@class HollowUiState
---@field mounted_topbar HollowUiWidget|nil
---@field configured_topbar HollowUiTopbarConfigureOptions|nil
---@field topbar_hovered_id string|nil
---@field topbar_hovered_shifted boolean
---@field mounted_bottombar HollowUiWidget|nil
---@field bottombar_hovered_id string|nil
---@field bottombar_hovered_shifted boolean
---@field mounted_sidebar HollowUiWidget|nil
---@field sidebar_visible boolean
---@field overlay_stack HollowUiWidget[]
---@field notifications HollowUiWidget[]

---@class HollowCopyModeState
---@field active boolean
---@field query string
---@field hud HollowUiWidget|nil
---@field selecting boolean
---@field block boolean
---@field pending_g boolean
---@field match_count integer
---@field match_index integer|nil
---@field prompt_depth integer|nil

---@class HollowState
---@field host_api HollowHostBridge
---@field config HollowConfigState
---@field events HollowEventState
---@field keymap HollowKeymapState
---@field ui HollowUiState
---@field copy_mode HollowCopyModeState|nil
---@field quick_select { active: boolean, action: "open"|"copy" }|nil

---@class HtpQueryContext
---@field pane HollowPane
---@field params table<string, any>

---@class HtpEmitContext
---@field pane HollowPane
---@field payload any

---@class HollowProcess
---@field status fun(self: HollowProcess): "running"|"finished"
---@field result fun(self: HollowProcess): HollowProcessRunResult|nil
---@field cancel fun(self: HollowProcess)
---@field kill fun(self: HollowProcess) Alias for cancel
---@field wait fun(self: HollowProcess): HollowProcessRunResult Coroutine only
---@field next fun(self: HollowProcess, callback: fun(result: HollowProcessRunResult)): HollowPromise

---@class HollowProcessRunResult
---@field code integer
---@field stdout string
---@field stderr string
---@field error? string Spawn, timeout, cancellation, or output limit failure
---@field canceled? boolean

---@class HollowProcessOpts
---@field cmd string|string[] Executable or argv; no implicit shell parsing
---@field cwd? string
---@field env? table<string, string> Overrides inherited environment
---@field timeout_ms? integer Default 30000; maximum 86400000
---@field output_limit? integer Per stream bytes; default 1 MiB, maximum 16 MiB
---@field on_complete? fun(result: HollowProcessRunResult)

---@class HollowProcessRunOpts
---@field hide_window? boolean Defaults to true on the host bridge

---@class HollowActionNamespace
---@field register fun(name: string, spec: HollowActionSpec)
---@field list fun(): HollowPaletteEntry[] All registered actions
---@field override fun(name: string, handler: fun(ctx: HollowActionContext): any): fun() Register an override; returns an unsubscribe function
---@field invoke fun(name: string, args?: table, ctx?: table): HollowActionResult Protected invocation with named arguments and separate caller metadata
---@field context fun(): HollowActionContext? Snapshot of current invocation; nil outside an action
---@field [string] fun(opts?: table)

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

---@class HollowThemeNamespace
local theme = {}

---@param spec? HollowThemeSpec
---@return HollowResolvedTheme
function theme.create(spec) end

---@param name string
---@return HollowResolvedTheme
function theme.get(name) end

---@return HollowResolvedTheme
function theme.current() end

---@param kind string
---@param resolved? HollowResolvedTheme
---@return HollowUiResolvedTheme
function theme.resolve_widget(kind, resolved) end

---@class HollowJsonNamespace
local json = {}

---@param value any
---@return string
function json.encode(value) end

---@param text string
---@return any
function json.decode(text) end

---@class HollowWorkspaceNamespace
local workspace_api = {}

---@class HollowAsyncNamespace
local async = {}

---@param fn function
---@return thread
function async.run(fn) end

---@param register fun(resolve: fun(value: any), reject?: fun(err: any))
---@return any
function async.await(register) end

function async.next_tick() end

---@param register fun(resolve: fun(value: any), reject: fun(err: any))
---@return HollowPromise<any>
function async.promise(register) end

---@param spec HollowWorkspaceBootstrapSpec
---@param opts? { base_dir?: string, name?: string, replace_current?: boolean }
---@return HollowWorkspaceSnapshot|nil
function workspace_api.bootstrap(spec, opts) end

---@param path string
---@return HollowWorkspaceBootstrapSpec
function workspace_api.load(path) end

---@param path string
---@param opts? { base_dir?: string, name?: string, replace_current?: boolean }
---@return HollowWorkspaceSnapshot|nil
function workspace_api.load_and_bootstrap(path, opts) end

---@return HollowWorkspaceBootstrapSpec
function workspace_api.export_current() end

---@param path string
---@return string
function workspace_api.export_to(path) end

---@param dir? string
---@return string|nil
function workspace_api.project_local_path(dir) end

---@return string|nil
function workspace_api.resolve_auto_bootstrap_path() end

---@return boolean
function workspace_api.auto_bootstrap() end

---@param dir? string
---@return boolean
function workspace_api.bootstrap_project(dir) end

---Load project/default layout off the UI thread; skip if the active pane changes.
---@param dir? string
---@param domain? string Terminal domain; defaults to the active pane's domain.
---@return HollowPromise<boolean>
function workspace_api.bootstrap_project_async(dir, domain) end

---@class HollowTermNamespace
---@field jobs HollowTermJobs
local term = {}

---@class HollowTermJobOptions
---@field argv? string[] Literal arguments; exactly one of argv or cmd is required.
---@field cmd? string Explicit shell command.
---@field cwd? string
---@field domain? string
---@field user_shell? boolean Load target shell's interactive startup configuration.

---@class HollowTermJobHandle
---@field pane_id integer
---@field tab_id integer
---@field workspace_id integer
---@field token string Ownership token; not socket authentication.
---@field cursor integer Pre-launch event cursor.

---@class HollowTermJobState
---@field pane_id integer
---@field state "running"|"exited"
---@field status? integer Process exit status; nil means unknown.
---@field cursor integer
---@field output_bytes integer
---@field output_truncated boolean
---@field output_incomplete boolean

---@class HollowTermJobResult: HollowTermJobState
---@field tab_id integer
---@field workspace_id integer
---@field token string
---@field closed? boolean True only after successful auto cleanup.

---@class HollowTermJobOutput
---@field encoding "base64"
---@field data string Bounded raw PTY tail, base64 encoded; not viewport text.
---@field truncated boolean
---@field incomplete boolean
---@field capacity_bytes integer

---@class HollowTermJobError
---@field code string
---@field message string
---@field handle? HollowTermJobHandle Included on wait timeout; job is not canceled.

---@class HollowTermJobWaitOptions
---@field timeout_ms? integer Nonnegative timeout; omitted means no deadline. Does not cancel job.
---@field auto_close? boolean Close after observed exit, including failure; discards retained output.

---@class HollowTermJob
local term_job = {}
---@return HollowPromise<HollowTermJobHandle>
function term_job:ready() end
---@return HollowTermJobHandle|nil Snapshot once creation completes.
function term_job:handle() end
---@return HollowPromise<HollowTermJobState>
function term_job:get() end
---@return HollowPromise<HollowTermJobOutput>
function term_job:output() end
---@param opts? HollowTermJobWaitOptions
---@return HollowPromise<HollowTermJobResult> Nonzero workload status fulfills; infrastructure errors reject.
function term_job:wait(opts) end
---@return HollowPromise<boolean> Rejects running jobs or mismatched ownership.
function term_job:cleanup() end

---@class HollowTermJobs
local term_jobs = {}
---Create a retained background pane without focus. Methods queue until creation completes.
---@param opts HollowTermJobOptions
---@return HollowTermJob
function term_jobs.spawn(opts) end

---@return HollowTabSnapshot|nil
function term.current_tab() end

---@return HollowPaneSnapshot|nil
function term.current_pane() end

---@param id integer
---@return HollowPaneSnapshot|nil
function term.pane_by_id(id) end

---@return HollowTabSnapshot[]
function term.tabs() end

---@return HollowWorkspaceSnapshot[]
function term.workspaces() end

---@return HollowMuxWorkspace[]
function term.mux_tree() end

---@return HollowWorkspaceSnapshot|nil
function term.current_workspace() end

---@param id integer
---@return HollowWorkspaceSnapshot|nil
function term.workspace_by_id(id) end

---@return HollowDomainSnapshot|nil
function term.current_domain() end

---@param id integer
---@return HollowTabSnapshot|nil
function term.tab_by_id(id) end

---@param opts? HollowNewTabOpts
function term.new_tab(opts) end

---@param args string[]
---@param domain? string
---@param opts? HollowProcessRunOpts
---@return boolean, string, string
function term.run_domain_process(args, domain, opts) end

---@param direction? "horizontal"|"vertical"|HollowSplitPaneOpts
---@param opts? HollowSplitPaneOpts
function term.split_pane(direction, opts) end

---@param id integer
function term.focus_tab(id) end

---@param id integer
function term.close_tab(id) end

function term.next_tab() end

function term.prev_tab() end

---@param title string
---@param tab_id? integer
function term.set_title(title, tab_id) end

---@param combo string  e.g. "<C-h>", "<C-A-Left>", "home"
---@param pane_id? integer
function term.send_key(combo, pane_id) end

---@param text string
---@param pane_id? integer
function term.send_text(text, pane_id) end

---@class HollowTermRunOpts
---@field pane_id? integer Defaults to the focused pane, captured at submission.
---@field timeout_ms? integer Positive timeout in milliseconds; default 30000. Does not cancel the command.

---@class HollowTermRunResult
---@field pane_id integer
---@field command string Submitted command, before shell expansion.
---@field status? integer Shell exit status; nonzero exits still fulfill the promise.
---@field took_ms? integer Command duration measured by shell integration.

---Submit a single-line command and await completion and the following shell prompt.
---Requires updated Bash, Zsh, or Fish shell integration and an exclusively driven pane.
---@param command string Non-empty single-line shell command without control characters; Enter is appended.
---@param opts? HollowTermRunOpts
---@return HollowPromise<HollowTermRunResult>
function term.run(command, opts) end

---@param pane_id? integer
function term.bell(pane_id) end

---@param pane_id? integer
---@return string
function term.get_pane_text(pane_id) end

---@param pane_id? integer
---@return string[]
function term.get_pane_tags(pane_id) end

---@param tags? string[]
---@param pane_id? integer
function term.set_pane_tags(tags, pane_id) end

---@param tag string
---@param pane_id? integer
function term.add_pane_tag(tag, pane_id) end

---@param tag string
---@param pane_id? integer
function term.remove_pane_tag(tag, pane_id) end

---@param pane_id integer|nil
---@param process string|nil
function term.set_pane_foreground_process(pane_id, process) end

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

---@param pane_id? integer
function term.close_pane(pane_id) end

---@param direction string
function term.focus_pane(direction) end

---@param pane_id integer
function term.focus_pane_by_id(pane_id) end

---@param axis_or_direction string
---@param delta number
function term.resize_pane(axis_or_direction, delta) end

---@param name string
function term.set_workspace_name(name) end

---@param cwd string
function term.set_workspace_default_cwd(cwd) end

---@param opts? { cwd?: string, domain?: string, command?: string, name?: string }
function term.new_workspace(opts) end

---@param id? integer
function term.close_workspace(id) end

function term.next_workspace() end

function term.prev_workspace() end

---@param index integer
function term.switch_workspace(index) end

function term.reload_config() end

---@param where string
function term.scroll(where) end

---@param name string
function term.set_theme(name) end

---@class HollowEventsNamespace
local events = {}

---@param name HollowEventName
---@param handler fun(e: HollowEventPayloadMap[name])
---@return HollowEventHandle
function events.on(name, handler) end

---@param handle HollowEventHandle
function events.off(handle) end

---@param name HollowEventName
---@param handler fun(e: HollowEventPayloadMap[name])
function events.once(name, handler) end

---@param name string
---@param payload? any
function events.emit(name, payload) end

---@class HollowSpawnSpec
---@field shell string Read-only configured shell command string (not argv).
---@field domain? string Read-only domain name.
---@field cwd? string Local launch directory; nil inherits the host directory.
---@field env table<string, string> Environment overrides, not the full inherited environment.

---Register an ordered synchronous transformation. Remove with events.off(handle).
---Does not intercept notifications; the producer must call apply_filters.
---@overload fun(name: "term:spawn", handler: fun(spec: HollowSpawnSpec): HollowSpawnSpec|nil): HollowEventHandle
---@param name string
---@param handler fun(payload: table): table|nil
---@return HollowEventHandle
function events.filter(name, handler) end

---Apply custom filters. nil/error/invalid returns preserve the previous payload.
---@generic T: table
---@param name string
---@param payload T
---@return T
function events.apply_filters(name, payload) end

---@alias HollowKeyAction string|fun()

---@class HollowKeymapOpts
---@field desc? string
---@field args? table Named arguments passed to a registered action
---@field timeout_ms? integer
---@field mode? HollowKeyMode

---@class HollowKeymapValue
---@field action HollowKeyAction
---@field desc? string
---@field args? table Named arguments passed to a registered action

---@class HollowLeaderState
---@field active boolean
---@field mode HollowKeyMode
---@field prefix string
---@field sequence string[]
---@field display string
---@field next string[]
---@field next_display string[]
---@field desc? string
---@field remaining_ms integer
---@field timeout_ms integer
---@field complete boolean

---@class HollowKeymapBindingInfo
---@field action any
---@field chord string
---@field desc string|nil
---@field mode HollowKeyMode

---@class HollowKeymapNamespace
local keymap = {}

---@param chord HollowKeyChord
---@param rhs HollowKeyAction
---@param opts? HollowKeymapOpts
function keymap.set(chord, rhs, opts) end

---@param chord HollowKeyChord
---@param rhs HollowKeyAction
---@param opts? HollowKeymapOpts
function keymap.default(chord, rhs, opts) end

function keymap.apply_defaults() end

---@param chord HollowKeyChord
---@param opts? HollowKeymapOpts
---@return boolean
function keymap.del(chord, opts) end

---@param chord HollowKeyChord
---@param opts? HollowKeymapOpts
---@return HollowKeyAction|nil
function keymap.get(chord, opts) end

---@param chord? HollowKeyChord
---@param opts? HollowKeymapOpts
function keymap.set_leader(chord, opts) end

function keymap.clear_leader() end

---@return boolean
function keymap.is_leader_active() end

---@return HollowLeaderState|nil
function keymap.get_leader_state() end

---@param mode? HollowKeyMode
---@return HollowKeymapBindingInfo[]
function keymap.list_bindings(mode) end

---@param action_name string
---@param mode? HollowKeyMode
---@return string[]
function keymap.find_by_action(action_name, mode) end

---@param mods integer
---@return string
function keymap.format_mods(mods) end

---@param key string
---@param mods integer
---@return string
function keymap.format_chord(key, mods) end

---@param chord string
---@return string, integer
function keymap.parse_chord(chord) end

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

---@param opts? HollowUiTopbarConfigureOptions
function topbar.configure(opts) end

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

---@param notification_id? string
function notify.clear(notification_id) end

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

---@class HollowUiConfirmNamespace
local confirm = {}

---@param opts HollowUiConfirmOptions
function confirm.open(opts) end

function confirm.close() end

---@class HollowUiCommandPaletteNamespace
local command_palette = {}

---@param opts? HollowUiCommandPaletteOptions
function command_palette.open(opts) end

function command_palette.close() end

---@class HollowUiLuaReplOptions
---@field width? integer Width in cells (default 80).
---@field height? integer Fixed height in cells; omitted for automatic content sizing.
---@field theme? HollowUiTheme

---@class HollowUiLuaReplNamespace
local lua_repl = {}

---Open the Clay console in the live Lua runtime. Not sandboxed.
---@param opts? HollowUiLuaReplOptions
---@return HollowUiModalHandle? handle Nil if another modal is active.
function lua_repl.open(opts) end

function lua_repl.close() end

---@class HollowUiMuxNavigatorOptions
---@field query? string
---@field filter? "all"|"pane_bell"
---@field title? string
---@field backdrop? HollowOverlayBackdropValue
---@field width? integer
---@field height? integer
---@field max_height? integer
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme

---@class HollowUiMuxNavigatorNamespace
local mux_navigator = {}

---@param opts? HollowUiMuxNavigatorOptions
function mux_navigator.open(opts) end

function mux_navigator.close() end

---@alias HollowActivityView "inbox"|"history"

---@class HollowActivityEntry
---@field source? "program_status"|"shell_command" Origin of a live Running entry; shell commands are not explicit task-status reports.
---@field category? "task"|"command" Live classification, independent of source.
---@field app? string Program-reported application name, independent of task title.
---@field id integer|string Numeric for retained events; string for live running tasks.
---@field kind "notification"|"bell"|"program"
---@field title? string
---@field message? string
---@field level? HollowNotifyLevel
---@field state? "working"|"blocked"|"done"|"error"
---@field block_kind? string
---@field program_id? string Protocol record identity within the originating pane.
---@field progress? integer
---@field timestamp_ms? integer Monotonic session timestamp; absent for live tasks.
---@field pending? boolean
---@field count? integer Grouped bell occurrences.
---@field pane_id? integer
---@field pane_closed? boolean
---@field pane_title? string
---@field workspace? string
---@field tab_title? string
---@field cwd? string

---@class HollowActivityNamespace
---@field setup fun(opts?: HollowActivityOptions) Replace all shell-command rules; omitted lists reset to empty. Explicit program status is unaffected.
---@field list fun(opts?: { view?: HollowActivityView|"running", pane_id?: integer, workspace?: string, activity_kind?: "notification"|"bell"|"program", level?: HollowNotifyLevel }): HollowActivityEntry[] Retained events newest first; isolated snapshots with exact-match filters. Never acknowledges entries.
---@field running fun(): HollowActivityEntry[] Live working/blocked programs and shell-integrated commands.
---@field summary fun(): { count: integer, level?: HollowNotifyLevel } Pending entries only; never running tasks.
---@field dismiss fun(id: integer): boolean Acknowledge an entry without changing program state.
---@field dismiss_all fun()
---@field clear_history fun() Remove acknowledged history, preserving pending entries.

---@class HollowActivityOptions
---@field tasks? string[] Lua patterns matching full shell command text to promote into Tasks.
---@field commands? string[] Lua patterns forcing Commands, overriding tasks.
---@field ignore? string[] Lua patterns hiding shell commands from live listings and task badges, overriding both lists.

---@class HollowUiActivityOptions
---@field view? HollowActivityView
---@field width? integer
---@field height? integer
---@field max_height? integer
---@field theme? HollowUiTheme
---@field chrome? HollowUiChrome|boolean
---@field backdrop? HollowOverlayBackdropValue

---@class HollowUiActivityNamespace
---@field open fun(opts?: HollowUiActivityOptions): HollowUiModalHandle|nil

---@class HollowUiSelectNamespace
local select = {}

---@param opts HollowUiSelectOptions
function select.open(opts) end

function select.close() end

---@class HollowUiWorkspaceItem
---@field id string
---@field workspace_id? integer
---@field name string
---@field cwd? string
---@field domain? string
---@field source "open"|"user"|"local"|"wsl"|"ssh"|"host"
---@field host_id? string Host-backed discovery identity
---@field is_active boolean
---@field is_open boolean
---@field has_bell boolean Any pane in this workspace has bell attention
---@field program_status_badge? string Aggregated OSC 7501 badge for open workspaces, including trailing space.
---@field program_status_state? string State of the aggregated visible OSC 7501 indicator; idle is hidden.
---@field program_status_attention? boolean True when any pane in an open workspace has unread blocked/error attention; independent of OSC bell state.
---@field program_status_attention_level? "warn"|"error"
---@field open_index? integer Used only for switching to an already-open workspace
---@field last_opened_at? integer

---@class HollowWorkspaceLocalHost
---@field type "local"

---@class HollowWorkspaceWslHost: HollowWslHostOpts
---@field type "wsl"
---@field id? string Automatically allocated when omitted

---@class HollowWorkspaceSshHost: HollowSshHostOpts
---@field type "ssh"
---@field id? string Automatically allocated when omitted

---@class HollowWorkspacePodmanHost: HollowPodmanHostOpts
---@field type "podman"
---@field id? string Automatically allocated when omitted

---@class HollowWorkspaceDockerHost: HollowDockerHostOpts
---@field type "docker"
---@field id? string Automatically allocated when omitted

---@alias HollowWorkspaceHostDescriptor HollowWorkspaceLocalHost|HollowWorkspaceWslHost|HollowWorkspaceSshHost|HollowWorkspacePodmanHost|HollowWorkspaceDockerHost

---@class HollowUiWorkspaceSource
---@field resolver? "local"|"wsl"|"ssh" Deprecated; converted in memory with migration warning
---@field host? HollowAgentHost|HollowWorkspaceHostDescriptor Persistent discovery host; omitted uses native-local unless migrating an unambiguous legacy guest source
---@field name? string
---@field domain? string
---@field roots? string[]
---@field items? fun(): HollowUiWorkspaceItem[]|table[]|nil
---@field cwd_resolver? "wsl_unc"|fun(cwd: string, item: HollowUiWorkspaceItem, source: HollowUiWorkspaceSource): string|nil Deprecated compatibility transform; use host-native paths
---@field default? boolean

---@class HollowUiWorkspaceSwitcherOptions
---@field prompt? string
---@field width? integer
---@field height? integer
---@field max_height? integer
---@field backdrop? HollowOverlayBackdropValue
---@field chrome? HollowUiChrome|boolean
---@field theme? HollowUiTheme
---@field known_workspaces? fun(): HollowUiWorkspaceItem[]|table[]|nil
---@field sources? HollowUiWorkspaceSource[]|fun(): HollowUiWorkspaceSource[]|nil
---@field format_item? fun(workspace: HollowUiWorkspaceItem): HollowUiInlineNode|HollowUiInlineNode[]
---@field filter_item? fun(workspace: HollowUiWorkspaceItem): boolean|nil
---@field cache_ttl_ms? integer
---@field force_refresh? boolean
---@field project_roots? string[] Deprecated; use sources[].roots
---@field status_column_width? integer
---@field name_column_width? integer
---@field column_gap? integer
---@field workspace_color_fn? fun(name: string): HollowUiColorPair Workspace/domain paint only; geometry and event fields are ignored.
---@field rename_key? string
---@field rename_desc? string
---@field close_key? string
---@field close_desc? string
---@field create_key? string
---@field create_desc? string

---@class HollowUiWorkspaceNamespace
---@field configure fun(opts?: HollowUiWorkspaceSwitcherOptions)
---@field clear_cache fun()
---@field known_workspaces fun(force_refresh?: boolean): HollowUiWorkspaceItem[]
---@field items fun(force_refresh?: boolean): HollowUiWorkspaceItem[]
---@field open_switcher fun(opts?: HollowUiWorkspaceSwitcherOptions)
---@field switcher fun(opts?: HollowUiWorkspaceSwitcherOptions)
---@field topbar_button fun(opts?: HollowUiWorkspaceTopbarOptions): HollowUiSpanNode|HollowUiSpanNode[]
---@field create fun(opts?: { prompt?: string, on_confirm?: fun(name: string) })
---@field rename fun(workspace?: HollowWorkspaceSnapshot|HollowUiWorkspaceItem, opts?: { prompt?: string, on_confirm?: fun(name: string, workspace: any) })
---@field close fun(workspace?: HollowWorkspaceSnapshot|HollowUiWorkspaceItem)
---@field open fun(opts?: HollowUiWorkspaceOpenOptions)
local workspace = {}

---@class HollowUiWorkspaceOpenOptions: HollowNewWorkspaceOpts
---@field source? string Configured discovery source name.
---@field item? HollowUiWorkspaceItem

---@class HollowUiWorkspaceTopbarOptions
---@field id? string
---@field text? string
---@field prefix? string
---@field suffix? string
---@field style? HollowUiNodeStyle
---@field switcher? HollowUiWorkspaceSwitcherOptions
---@field colorize? boolean

--- Private discovery state; not an additional public configuration API.
---@class HollowUiWorkspaceSwitcherState: HollowUiWorkspaceSwitcherOptions
---@field host_scan_revision? integer

---@class HollowUiStylePresets
---@field muted HollowStyle
---@field title HollowStyle
---@field label HollowStyle
---@field empty HollowStyle
---@field counter HollowStyle
---@field key_hint HollowStyle
---@field pill HollowStyle
---@field badge HollowStyle
---@field kbd HollowStyle

--- Hierarchical Clay layout; inline row/column helpers remain for bars and rich labels.
---@class HollowUiLayoutOptions
---@field id? string Required for clickable nodes; unique within the surface.
---@field label? string Automation label for clickable containers.
---@field role? 'button'|'listitem' Automation role for clickable containers.
---@field width? number|'fit'|'grow' Pixel count, content size, or remaining space.
---@field height? number|'fit'|'grow'
---@field min_width? number Minimum pixel width for fit/grow sizing.
---@field max_width? number Maximum pixel width for fit/grow sizing.
---@field min_height? number Minimum pixel height for fit/grow sizing.
---@field max_height? number Maximum pixel height for fit/grow sizing.
---@field border_width? number|{left?: number, right?: number, top?: number, bottom?: number, between_children?: number} Pixel border widths; border color comes from style.border.
---@field padding? HollowUiBoxValue
---@field gap? number
---@field style? HollowUiNodeStyle
---@field scroll? boolean Vertical scrolling.
---@field scroll_x? boolean Horizontal scrolling; children may exceed the viewport width.
---@field reveal? string Local ID of a descendant container to keep visible, e.g. a caret.
---@field reveal_start? boolean Align the reveal target with the viewport start instead of nearest-edge reveal.
---@field measure? boolean Report scroll viewport dimensions through ctx.metrics; opt-in to avoid per-node feedback.
---@field scrollbar_id? string Local selectable-list scrollbar ID; enables overlay scrollbar paint and drag routing.
---@field scrollbar_thumb_ratio? number Full-list scroll position from 0 to 1.
---@field scrollbar_thumb_size? number Visible fraction of the full logical list.
---@field scrollbar_track_color? string
---@field scrollbar_thumb_color? string
---@field align_y? 'start'|'center'|'end' Vertical alignment of container children.
---@field on_click? fun(event: { id: string })

---@class HollowUiLayoutTextOptions
---@field wrap? 'words'|'newlines'|'none'
---@field text_align? 'left'|'center'|'right'|0|1|2

---@class HollowUiLayoutNode: HollowUiLayoutOptions, HollowUiLayoutTextOptions
---@field kind integer
---@field children? table
---@field text? string
---@field value? number Progress value.

--- Surface engine: mounts, invalidates and debugs Clay trees built with `hollow.ui.components`.
---@class HollowUiLayout
---@field new fun(opts: HollowUiLayoutSurfaceOptions): HollowUiLayoutSurface
---@field show fun(root: HollowUiLayoutNode) Replace the single modal surface with a validated snapshot.
---@field hide fun()
---@field debug fun(enabled: boolean) Toggle Clay's built-in inspector for the active surface.
---@field debug_grid fun(enabled: boolean) Toggle Clay's inspector over the window's bars, sidebar and pane layout.
---@field debug_width fun(width?: number): number? Get, or set in pixels, the inspector panel width (default 400; clamped to the window).

--- Clay node constructors and composed components.
---@class HollowUiComponents
---@field row fun(children: table, opts?: HollowUiLayoutOptions): HollowUiLayoutNode
---@field column fun(children: table, opts?: HollowUiLayoutOptions): HollowUiLayoutNode
---@field text fun(value: any, style?: HollowUiNodeStyle, opts?: HollowUiLayoutTextOptions): HollowUiLayoutNode
---@field button fun(opts?: HollowUiButtonOptions): HollowUiLayoutNode
---@field progress fun(value: number, opts?: HollowUiLayoutOptions): HollowUiLayoutNode Custom-painted native progress element.
---@field dialog fun(opts: table, theme: HollowUiTheme, ctx: HollowUiLayoutContext): HollowUiLayoutNode Title, body and footer buttons.
---@field input fun(input: HollowUiTextInput, theme: HollowUiTheme, ctx: HollowUiLayoutContext, inline?: boolean): HollowUiLayoutNode Text field for a `ui.text_input` behavior.
---@field select table Bounded selectable-list composition (`render`, `sections`, `inline`, `from_row`).
---@field demo fun()

---@class HollowUiLayoutContext
---@field metrics? table<string, { width: number, height: number }> Latest measured overlay viewport dimensions by local ID. Read-only; changes invalidate the surface.
---@field width? number Host window width in pixels.
---@field height? number Host window height in pixels.
---@field cell_w? number Existing renderer cell width.
---@field cell_h? number Existing renderer cell height.

---@class HollowUiLayoutSurfaceOptions
---@field render fun(ctx: HollowUiLayoutContext): HollowUiLayoutNode
---@field theme? HollowUiTheme Token palette for this surface.
---@field frame? HollowUiLayoutFrame

---@class HollowUiLayoutFrame
---@field width? number Width in terminal cells.
---@field height? number Height in terminal rows; omitted uses fit sizing.
---@field max_height? number Maximum terminal rows, capping fit or fixed height.
---@field align_x? 0|1|2 Start, center or end alignment.
---@field align_y? 0|1|2 Start, center or end alignment.
---@field chrome? HollowUiChrome

---@class HollowUiLayoutSurface
---@field id integer
---@field namespace string
---@field show fun(self: HollowUiLayoutSurface): HollowUiLayoutSurface Show as the standalone surface.
---@field invalidate fun(self: HollowUiLayoutSurface) Rebuild on the next frame.
---@field destroy fun(self: HollowUiLayoutSurface) Drop cached nodes and callbacks.
---@field snapshot fun(self: HollowUiLayoutSurface, ctx?: HollowUiLayoutContext): table[] Validate and serialize only when dirty.

---@class HollowUi
---@field layout HollowUiLayout Experimental Clay-backed surface engine.
---@field components HollowUiComponents Experimental Clay node constructors and components.
---@field styles HollowUiStylePresets Shared presets; do not mutate. Clone with ui.style before modifying.
local ui = {}

--- True when Hollow's window has OS focus, not merely when a pane is active.
---@return boolean
function ui.is_focused() end

---@param text string
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiSpanNode
function ui.span(text, style) end

---@generic T: HollowUiRenderableNode
---@overload fun(value: T, style?: nil): T
---@param value HollowUiInlineNode|number|boolean|nil
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiSpanNode
function ui.text(value, style) end

---@param children HollowUiChild[]
---@param opts? HollowUiRowOptions
---@return HollowUiRowNode
function ui.row(children, opts) end

---@param children HollowUiRowChild[]
---@return HollowUiColumnNode
function ui.column(children) end

---@param color? HollowColor
---@return HollowUiRowNode
function ui.divider(color) end

---@return HollowUiSpacerNode
function ui.spacer() end

---@param name string
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiIconNode
function ui.icon(name, style) end

---@param children HollowUiChild[]|nil
---@param style? HollowUiNodeStyle|HollowHexColor
---@return HollowUiGroupNode
function ui.group(children, style) end

--- Select a branch, evaluating it only when it is a function.
---@param cond any
---@param then_ any
---@param else_? any
---@return any
function ui.when(cond, then_, else_) end

--- Map an array or HollowTbl wrapper into a fragment.
---@generic T, R
---@param list T[]|HollowTbl|nil
---@param fn fun(item: T, index: integer): R|nil|false
---@return (R|false)[]
function ui.each(list, fn) end

--- Join truthy items with a separator or separator factory.
---@param items any[]
---@param sep any|fun(index: integer): any
---@return any[]
function ui.join(items, sep) end

--- Merge style layers into a fresh table, skipping nil and false layers.
---@param ... HollowStyleLayer
---@return HollowStyle
function ui.style(...) end

--- Merge styles and resolve tokens against theme; nil theme leaves tokens unresolved.
---@param theme HollowUiTheme|nil
---@param ... HollowStyleLayer
---@return HollowStyle
function ui.styled(theme, ...) end

---@param opts HollowUiActionButtonOptions
---@return HollowUiSpanNode
function ui.action_button(opts) end

---@param opts HollowUiButtonOptions
---@return HollowUiSpanNode
function ui.button(opts) end

---@param opts HollowUiTabOptions
---@return HollowUiGroupNode
function ui.tab(opts) end

---@param opts HollowUiTabBarOptions
---@return HollowUiGroupNode
function ui.tab_bar(opts) end

---@param spec HollowUiModalSpec
---@return HollowUiModalHandle|nil Returns nil if another modal is already open.
function ui.modal(spec) end

---@param ... table
---@return function
function ui.keys(...) end

---@param fn function|nil
---@param value? any
function ui.fire(fn, value) end

---@param n integer
---@return HollowUiListNav
function ui.list_nav(n) end

---@param n integer
---@param opts? { row_count_fn?: fun(item: any): integer, row_budget?: integer }
---@return HollowUiScrollNav
function ui.scroll_nav(n, opts) end

---@param opts? { initial?: string, on_change?: fun(value: string) }
---@return HollowUiTextInput
function ui.text_input(opts) end

---@class HollowUiTextView
---@field nav HollowUiScrollNav
---@field set fun(text: string)
---@field render fun(theme: HollowUiTheme): HollowUiRowNode[]
---@field keys fun(key: string, mods: HollowUiKeyMods): boolean
---@field on_event fun(name: string, event: table): boolean

--- Read-only wrapped text behavior. Width counts terminal display cells.
---@param opts? { text?: string, width?: integer, row_budget?: integer, id?: string }
---@return HollowUiTextView
function ui.text_view(opts) end

---@param opts { id_prefix: string, items: fun(): any[], row_budget: fun(): integer, row_count_fn?: fun(item: any): integer, on_activate: fun(index: integer) }
---@return table
function ui.selectable_list(opts) end

---@param kind string
---@param opts HollowUiWidgetOptions
---@return HollowUiWidget
function ui.new_widget(kind, opts) end

---@param widget HollowUiWidget
---@return HollowUiWidget|nil
function ui.close_overlay_widget(widget) end

---@param name string
---@param payload HollowUiNodeEventPayload
function ui.dispatch_widget_event(name, payload) end

---@param key string
---@param mods HollowUiKeyMods
---@return boolean
function ui.dispatch_overlay_key(key, mods) end

---@param row HollowUiRow
---@param max_chars number|nil
---@return HollowUiSegment[]
function ui.trim_row_for_width(row, max_chars) end

ui.bar = bar
ui.topbar = topbar
ui.bottombar = bottombar
ui.sidebar = sidebar
ui.overlay = overlay
ui.notify = notify
ui.input = input
ui.command_palette = command_palette
ui.lua_repl = lua_repl
ui.mux_navigator = mux_navigator
---@type HollowUiActivityNamespace
ui.activity = {}
ui.select = select
ui.confirm = confirm
ui.workspace = workspace

---@field handle_bar_node_event fun(kind:string, payload:HollowUiBarNodePayload|any)
---@field resolve_theme fun():HollowResolvedTheme
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
---@return HollowPromise<HollowProcessRunResult>
function process.exec(opts) end

---@param args string[]
---@param opts? HollowProcessRunOpts
---@return boolean, string, string
function process.run_child_process(args, opts) end

---@param cmd string
---@param args? string[]
---@return HollowProcessRunResult
function process.run(cmd, args) end

---@class HollowFsNamespace
local fs = {}

---@class HollowHostError
---@field code string
---@field message string
---@field truncated boolean

---@class HollowHostConnectOpts
---@field id string Stable host identifier
---@field backend? "agent"|"local" Default agent; local never launches an agent
---@field argv? string[] Agent already on the host: exact argv that runs `hollow-agent stdio`
---@field connector? HollowHostConnector Install the agent through this connector, then run it
---@field agent? HollowHostAgentSource Where the agent comes from (with connector)

---@class HollowHostConnector
---@field argv string[] Command prefix that runs a command on the host
---@field remote_shell? boolean The connector joins arguments for a remote shell (ssh)

---@class HollowHostAgentSource
---@field path? string Absolute preinstalled Linux executable; skips deployment
---@field dir? string Client-native bundle directory with SHA256SUMS
---@field artifacts? {x86_64?:HollowAgentArtifact, aarch64?:HollowAgentArtifact}
---@field timeout_ms? integer Deploy deadline; default 60000, maximum 300000

---@class HollowAgentArtifact
---@field path string Absolute native path to a trusted Linux musl agent artifact
---@field sha256 string Expected 64-hex SHA-256 from the trusted release manifest

---@class HollowPodmanHostOpts
---@field id string Stable host identifier
---@field container string Existing running container name or ID
---@field podman? string Podman executable (inside WSL when via is set); defaults to "podman"
---@field via? HollowContainerWslVia Run container CLI inside this WSL distro
---@field artifacts? {x86_64?:HollowAgentArtifact, aarch64?:HollowAgentArtifact} Explicit artifacts override bundle discovery
---@field agent_dir? string Client-native absolute directory containing SHA256SUMS and linux-*/hollow-agent
---@field agent_path? string Absolute preinstalled Linux agent executable; skips deployment
---@field timeout_ms? integer Whole bootstrap deadline; default 60000, maximum 300000

---@class HollowContainerWslVia
---@field type "wsl"
---@field distro string Explicit existing WSL distribution name
---@field user? string WSL user owning the containers; omitted preserves distro default
---@field wsl? string Native launcher executable; defaults to "wsl.exe"

---@class HollowWslHostOpts
---@field id string Stable host identifier
---@field distro string Explicit existing WSL distribution name
---@field user? string Linux user; omitted preserves distro default, never implies root
---@field wsl? string Native WSL launcher executable; defaults to "wsl.exe"
---@field artifacts? {x86_64?:HollowAgentArtifact, aarch64?:HollowAgentArtifact} Explicit Windows artifacts override discovery
---@field agent_dir? string Absolute client-native bundle directory
---@field agent_path? string Absolute preinstalled Linux executable; skips deployment
---@field timeout_ms? integer Whole bootstrap deadline; default 60000, maximum 300000

---@class HollowSshHostOpts
---@field id string Stable host identifier
---@field destination string SSH alias, hostname or IP; supply user/port separately
---@field user? string Omitted preserves SSH configuration
---@field port? integer 1–65535
---@field ssh? string Native OpenSSH executable; default "ssh"
---@field identity_file? string Absolute native private-key path
---@field known_hosts? string Absolute native known_hosts path; strict verification always enabled
---@field config_file? string Absolute native SSH configuration path
---@field artifacts? {x86_64?:HollowAgentArtifact, aarch64?:HollowAgentArtifact}
---@field agent_dir? string Absolute client-native bundle directory
---@field agent_path? string Absolute preinstalled Linux executable; skips deployment
---@field timeout_ms? integer Whole bootstrap deadline; default 60000, maximum 300000

---@class HollowDockerHostOpts
---@field id string Stable host identifier
---@field container string Existing running Linux container name or ID
---@field docker? string Docker executable (inside WSL when via is set); default "docker"
---@field via? HollowContainerWslVia Run container CLI inside this WSL distro
---@field context? string Explicit Docker context; omitted uses native Docker client selection
---@field artifacts? {x86_64?:HollowAgentArtifact, aarch64?:HollowAgentArtifact}
---@field agent_dir? string Absolute client-native bundle directory
---@field agent_path? string Absolute preinstalled Linux executable; skips deployment
---@field timeout_ms? integer Whole bootstrap deadline; default 60000, maximum 300000

---@class HollowHostExecOpts
---@field argv string[] Byte strings; empty arguments after argv[1] are preserved
---@field cwd? string
---@field env? table<string, string>
---@field timeout_ms? integer Default 30000, maximum 86400000
---@field output_limit? integer Combined stdout/stderr limit; maximum 1048576

---@class HollowHostExecResult
---@field exit_code integer Nonzero exit is a successful RPC result
---@field stdout string Raw bytes
---@field stderr string Raw bytes

---@class HollowHostInfo
---@field executable_dir? string Native-local process executable directory; not supplied by remote agents
---@field os string
---@field arch string
---@field build string
---@field protocol_major integer
---@field protocol_minor integer
---@field cwd string Byte-valued path
---@field home string Byte-valued path

---@class HollowHostStat
---@field kind "file"|"directory"|"symlink"|"other"|"unknown"
---@field mode integer
---@field size integer|string Decimal string outside Lua's exact integer range
---@field mtime integer|string

---@class HollowHostList
---@field entries {name:string, kind:string}[] Byte-valued names; kinds currently "unknown"
---@field next_offset integer|nil
---@field eof boolean

---@class HollowHostFs
---@field stat fun(path:string): HollowPromise<HollowHostStat>
---@field list fun(path:string, opts?:{offset?:integer, limit?:integer}): HollowPromise<HollowHostList>
---@field read fun(path:string, opts?:{offset?:integer, limit?:integer}): HollowPromise<{bytes:string, eof:boolean}>

---@class HollowAgentHost
---@field id string
---@field generation string Opaque connection generation; cache identity only
---@field fs HollowHostFs
---@field status fun(self:HollowAgentHost): "connecting"|"ready"|"disconnected", HollowHostError|nil
---@field close fun(self:HollowAgentHost): boolean|nil, HollowHostError|nil
---@field info fun(self:HollowAgentHost): HollowPromise<HollowHostInfo>
---@field exec fun(self:HollowAgentHost, opts:HollowHostExecOpts): HollowPromise<HollowHostExecResult>

---@class HollowHostNamespace
local host = {}

---Experimental explicit subprocess connector; connection and operation promises support :cancel().
---@param opts HollowHostConnectOpts
---@return HollowPromise<HollowAgentHost>
function host.connect(opts) end

---Get the runtime's cached native-local host; existing hollow.process defaults are unchanged.
---@return HollowPromise<HollowAgentHost>
function host.local_host() end

---Bootstrap an agent in an existing container, then use the common persistent host API.
---Does not create/start/remove containers or elevate the configured container user.
---@param opts HollowPodmanHostOpts
---@return HollowPromise<HollowAgentHost>
function host.podman(opts) end

---Experimental WSL fs/exec host. Existing PTYs and WSL bypass are unchanged.
---@param opts HollowWslHostOpts
---@return HollowPromise<HollowAgentHost>
function host.wsl(opts) end

---Experimental noninteractive SSH fs/exec host; no PTY or ControlMaster dependency.
---@param opts HollowSshHostOpts
---@return HollowPromise<HollowAgentHost>
function host.ssh(opts) end

---Experimental Docker fs/exec host; selects an existing running Linux container.
---Preserves configured user and never creates, starts, stops or removes containers.
---@param opts HollowDockerHostOpts
---@return HollowPromise<HollowAgentHost>
function host.docker(opts) end

---@return string
function fs.data_dir() end

---@param pattern string
---@return string[]
function fs.glob(pattern) end

---@param path string
---@return boolean
function fs.is_dir(path) end

---@param path string
function fs.mkdir_p(path) end

---@class HollowPluginsNamespace
local plugins = {}

---@param config { plugins?: (string|{[1]: string, opts?: table})[] }|nil
function plugins.setup(config) end

function plugins.sync() end

---@class HollowPlatformInfo
---@field os string
---@field is_windows boolean
---@field is_linux boolean
---@field is_macos boolean
---@field default_shell string

---@class HollowHostBridge
---@field term_job_request fun(request: table, callback: fun(response: table)): boolean?, string?
---@field set_config fun(opts: table)
---@field list_fonts fun(): HollowFontInfo[]
---@field new_tab fun(opts?: table)
---@field close_tab fun()
---@field switch_tab fun(index: integer)
---@field new_workspace fun(opts?: { cwd?: string })
---@field defer fun(handler: fun(), timeout_ms?: integer)
---@field schedule fun(handler: fun())
---@field close_workspace fun()
---@field next_workspace fun()
---@field prev_workspace fun()
---@field switch_workspace fun(index: integer)
---@field set_workspace_name fun(name: string)
---@field set_workspace_default_cwd fun(cwd: string)
---@field get_workspace_name fun(index: integer): string
---@field get_workspace_count fun(): integer
---@field get_active_workspace_index fun(): integer
---@field set_tab_title fun(title: string)
---@field send_text fun(text: string)
---@field on_gui_ready fun(handler: fun())
---@field switch_tab_by_id fun(tab_id: integer): boolean
---@field close_tab_by_id fun(tab_id: integer): boolean
---@field close_pane_by_id fun(pane_id: integer): boolean
---@field set_tab_title_by_id fun(tab_id: integer, title: string): boolean
---@field bell_pane fun(pane_id: integer): boolean
---@field send_text_to_pane fun(pane_id: integer, text: string): boolean
---@field get_pane_domain fun(pane_id: integer): string
---@field get_pane_split_direction fun(pane_id: integer): "horizontal"|"vertical"|nil
---@field get_pane_split_ratio fun(pane_id: integer): number|nil
---@field get_window_width fun(): integer
---@field window_is_focused fun(): boolean|nil
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
---@field pane_has_bell fun(pane_id: integer): boolean
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
---@field read_dir fun(path: string): string[]
---@field data_dir fun(): string
---@field glob fun(pattern: string): string[]
---@field is_dir fun(path: string): boolean
---@field mkdir_p fun(path: string)
---@field read_file fun(path: string): string
---@field write_file fun(path: string, contents: string): boolean
---@field path_exists fun(path: string): boolean
---@field list_wsl_distros fun(): string[]
---@field run_child_process fun(args: string[], opts?: HollowProcessRunOpts): boolean, string, string
---@field run_process fun(cmd: string, args?: string[]): HollowProcessRunResult
---@field default_config_path fun(): string|nil
---@field json_encode fun(value: any): string

---@field json_decode fun(text: string): any
---@field on_key fun(handler: fun(key: string, mods: integer): boolean)
---@field on_file_drop fun(handler: HollowFileDropHandler|nil)
---@field split_pane fun(opts_or_direction: HollowSplitPaneOpts|string, ratio?: number, domain?: string)
---@field toggle_pane_maximized fun(pane_id?: integer, show_background?: boolean)
---@field set_pane_floating fun(pane_id?: integer, floating?: boolean)
---@field set_floating_pane_bounds fun(pane_id?: integer, x?: number, y?: number, width?: number, height?: number)
---@field move_pane fun(pane_id?: integer, direction: string, amount?: number)
---@field close_pane fun()
---@field focus_pane fun(direction: string)
---@field focus_pane_by_id fun(pane_id: integer): boolean
---@field resize_pane fun(axis: string, delta: number)
---@field copy_selection fun()
---@field clipboard_write fun(text:string):boolean
---@field paste_clipboard fun()
---@field scroll_active fun(delta: integer)
---@field scroll_active_page fun(pages: integer)
---@field scroll_active_top fun()
---@field scroll_active_bottom fun()
---@field prompt_jump fun(direction: "prev"|"next")
---@field set_bar_cache_state fun(surface: string, dirty: boolean, expires_at_ms: integer, visible: boolean)
---@field copy_mode_enter fun()
---@field copy_mode_exit fun()
---@field copy_mode_move fun(direction: "left"|"right"|"up"|"down"|"page_up"|"page_down"|"line_start"|"line_end"|"top"|"bottom", extend?: boolean)
---@field copy_mode_begin_selection fun(block?: boolean)
---@field copy_mode_clear_selection fun()
---@field copy_mode_copy fun()
---@field copy_mode_open_search fun()
---@field copy_mode_search_set_query fun(query: string)
---@field copy_mode_search_next fun()
---@field copy_mode_search_prev fun()
---@field quick_select_start fun(action: "open"|"copy")
---@field quick_select_handlers fun(match_handler:fun(row_text:string):table[], action_handler:fun(kind:string, pattern_index:integer, text:string, fallback:string):string)
---@field link_route_handler fun(handler:fun(request:table):any)
---@field platform HollowPlatformInfo

---@class HollowUiModuleExports
---@field dispatch_widget_event fun(name:string, payload:HollowUiNodeEventPayload)
---@field dispatch_overlay_key fun(key:string, mods:HollowUiKeyMods):boolean
---@field handle_bar_node_event fun(kind:string, payload:HollowUiBarNodePayload|any)

---@class HollowClipboardNamespace
---@field write fun(text:string):boolean Queue a clipboard write; false if unavailable or rejected. Embedded NUL is unsupported.

---@class Hollow
---@field clipboard HollowClipboardNamespace
---@field activity HollowActivityNamespace
---@field action HollowActionNamespace
---@field config HollowConfigNamespace
---@field fonts HollowFontsNamespace
---@field json HollowJsonNamespace
---@field term HollowTermNamespace
---@field workspace HollowWorkspaceNamespace
---@field async HollowAsyncNamespace
---@field events HollowEventsNamespace
---@field keymap HollowKeymapNamespace
---@field route HollowRouteNamespace
---@field ui HollowUi
---@field htp HollowHtpNamespace
---@field fs HollowFsNamespace
---@field process HollowProcessNamespace
---@field host HollowHostNamespace
---@field plugins HollowPluginsNamespace
---@field platform HollowPlatformInfo
---@field on_gui_ready fun(handler: fun())
---@field on_file_drop fun(handler: HollowFileDropHandler|nil)
---@field log fun(...: any)
---@field inspect fun(value: any): string
---@field read_dir fun(path: string): string[]
---@field schedule fun(handler: fun())
---@field defer fun(handler: fun(), timeout_ms?: integer)
---@field color HollowColorModule
---@field util HollowUtilNamespace
---@field shape HollowShapeNamespace
---@field theme HollowThemeNamespace
---@field tbl HollowTblModule

---@type Hollow
hollow = {}

hollow.config = config
hollow.host = host
hollow.fonts = {}
hollow.json = json
hollow.term = term
hollow.workspace = workspace_api
hollow.events = events
hollow.keymap = keymap
hollow.route = {}
hollow.color = color
hollow.ui = ui
hollow.htp = htp
hollow.fs = fs
hollow.process = process
hollow.plugins = plugins

---@type HollowPlatformInfo
hollow.platform = {
  os = "",
  is_windows = false,
  is_linux = false,
  is_macos = false,
  default_shell = "",
}

---@class HollowColorModule
---@field is_hex_color fun(value:any): boolean
---@field normalize_hex_color fun<F>(value:any, fallback:F|nil): string|F|nil
---@field adjust_hex_color fun<F>(value:any, amount:number|string, fallback:F|nil): string|F|nil
---@field brighten_hex_color fun<F>(value:any, amount:number|string, fallback:F|nil): string|F|nil
---@field darken_hex_color fun<F>(value:any, amount:number|string, fallback:F|nil): string|F|nil
---@field contrast_hex_color fun<F>(value:any, amount:number|string, fallback:F|nil): string|F|nil
---@field hex_from_hsl fun(h:number, s:number, l:number): string
---@field hex_luminance fun(hex:string): number

---@class HollowUtilNamespace
---@field clone_value fun(value:any, seen:table|nil): any
---@field merge_tables fun(dst:table, src:table): table
---@field unsupported fun(name:string)
---@field host_now_ms fun(host_api:table|nil): integer
---@field path_separator fun(path:string|nil): string
---@field normalize_path fun(path:string, separator:string|nil): string|nil
---@field join_path fun(...:string): string
---@field basepath fun(path:string): string|nil
---@field basename fun(path:string): string|nil
---@field group_by fun(list:table, key_fn:fun(item:any):any): table, any[]
---@field has_any_key fun(t:table, keys:table): boolean

---@class HollowTbl
---@field get fun(self): table
---@field done fun(self): table
---@field totable fun(self): table
---@field each fun(self, fn:fun(v:any, i:integer, t:table)): HollowTbl
---@field map fun(self, fn:fun(v:any, i:integer, t:table):any): HollowTbl
---@field filter fun(self, fn:fun(v:any, i:integer, t:table):boolean): HollowTbl
---@field filter_map fun(self, fn:fun(v:any, i:integer, t:table):any|nil): HollowTbl
---@field take fun(self, n:integer): HollowTbl
---@field skip fun(self, n:integer): HollowTbl
---@field flatten fun(self): HollowTbl
---@field flat_map fun(self, fn:fun(v:any, i:integer, t:table):table|any): HollowTbl
---@field reduce fun(self, fn:fun(acc:any, v:any, i:integer, t:table):any, initial:any|nil): any
---@field some fun(self, fn:fun(v:any, i:integer, t:table):boolean): boolean
---@field every fun(self, fn:fun(v:any, i:integer, t:table):boolean): boolean
---@field find fun(self, fn:fun(v:any, i:integer, t:table):boolean): any, integer|nil
---@field first fun(self): any|nil
---@field last fun(self): any|nil
---@field len fun(self): integer
---@field count fun(self, fn?:fun(v:any):boolean): integer
---@field nth fun(self, n:integer): any|nil
---@field sort fun(self, fn?:fun(a:any, b:any):boolean): HollowTbl
---@field reverse fun(self): HollowTbl
---@field uniq fun(self, fn?:fun(v:any):any): HollowTbl
---@field concat fun(self, ...:table|any): HollowTbl
---@field join fun(self, sep?:string): string
---@field group_by fun(self, fn:fun(v:any):any): table
---@field chunk fun(self, n:integer): HollowTbl
---@field entries fun(self): table
---@field map_entries fun(self, fn:fun(k:any, v:any):any, any): table
---@field pick fun(self, ...:any): table
---@field omit fun(self, ...:any): table

---@class HollowTblModule
---@field range fun(start:integer, stop:integer, step?:integer): HollowTbl
---@field new fun(t:table|nil): HollowTbl
---@overload fun(t: table|nil): HollowTbl

---@type HollowTblModule
hollow.tbl = {}

hollow.util = {}

return hollow
