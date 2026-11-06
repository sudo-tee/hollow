# Workspace picker

Open the workspace switcher to switch among open workspaces, reattach persistent sessions, or open configured projects.
Open workspaces stay in **OPENED** at the top; everything else is grouped by terminal domain.
Search matches loaded workspaces and projects globally, including domain names and persistent session IDs.

## Domain actions

Headings share the reusable collapsible category component with the command palette.
Press Enter or click a heading to collapse or expand it; search reveals matching children without changing saved collapse choices.
Domain headings are flat titles colored like their pills.
A heading shows **loading…** while its domain is still listing sessions or projects.
When a search matches only one section, its heading is hidden and results show as a flat list.
Focus a domain heading and press `<C-n>`, or click its trailing **+**, to name a new workspace on that domain.
For a domain with `persist = true`, this creates a persistent session.
Other domains create ordinary workspaces; the picker never changes domain configuration automatically.
`<C-n>` on an existing row uses that row's domain too.
Headings and status rows cannot be renamed or closed.

## Load an SSH domain

Opening, filtering, or reopening the picker does not contact SSH hosts.
An unloaded SSH domain offers **Load sessions**, **Load projects**, or **Load sessions and projects**, depending on configuration.
Press Enter on its load row to start the configured work without closing the picker.
Session listing and project discovery finish independently, so a failed session query does not hide successfully discovered projects.
Loaded SSH results stay cached until you explicitly load or refresh them again.
`<C-l>` refreshes local sources and previously loaded SSH domains without contacting unloaded SSH domains.

Configure project roots separately from the persistent terminal domain:

```lua
hollow.config.set({
  domains = {
    remote = {
      persist = true,
      host = { type = "ssh", destination = "devbox", user = "alice" },
    },
  },
})

hollow.ui.workspace.configure({
  load_timeout_ms = 15000,
  sources = {
    {
      name = "Remote projects",
      domain = "remote",
      host = { type = "ssh", destination = "devbox", user = "alice" },
      roots = { "/home/alice/projects" },
    },
  },
})
```

The source `host` selects where roots are scanned; `domain` independently selects where project terminals open.
Use host-native paths, and configure SSH keys and host trust yourself before loading.
The default 15-second picker deadline can be increased for slow first-time deployment, up to 300000 milliseconds.

## Loading, empty results, and failures

Loading rows show elapsed time and always leave loading after completion or timeout.
An unavailable host keeps an error row with an explicit retry action; late replies from expired attempts are ignored.
Successful empty results keep **No sessions**, **All sessions already open**, or **No projects** visible instead of removing the domain.
Once a domain section has projects or sessions, its loading and ready status rows fold into the heading; load and retry rows stay.
A discovered project already open in the same domain and directory is listed only under **OPENED**.
Paths under a home directory display as `~/…`.
An SSH timeout does not block local project discovery.

Name and path columns truncate to leave space for status badges and domain pills.
Compact open rows place colored work indicators beside current/attention markers in the leading column.
Only mixed-domain open rows need domain pills; other rows inherit their domain heading.
See the [workspace reference](reference/lua/workspace.md) for custom formatting, source options, and actions.
