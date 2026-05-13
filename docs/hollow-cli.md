# Hollow CLI

## Command Surface

Queries:

- `hollow-cli get pane [--id ID]`
- `hollow-cli get pane-text [--id ID]`
- `hollow-cli get current-pane`
- `hollow-cli get tab [--id ID]`
- `hollow-cli get current-tab`
- `hollow-cli get tabs`
- `hollow-cli get panes`
- `hollow-cli get workspace [--id ID|--index N]`
- `hollow-cli get current-workspace`
- `hollow-cli get workspaces`
- `hollow-cli get domain`
- `hollow-cli get htp <channel> [params-json]`

Mutations:

- `hollow-cli workspace new [--cwd PATH] [--domain NAME] [--cmd CMD] [--name NAME]`
- `hollow-cli workspace close [--id ID|--index N]`
- `hollow-cli workspace next`
- `hollow-cli workspace prev`
- `hollow-cli workspace select <index>`
- `hollow-cli workspace rename <name> [--id ID|--index N]`
- `hollow-cli tab new [--cmd CMD] [--domain NAME]`
- `hollow-cli tab close [--id ID|--index N]`
- `hollow-cli tab next`
- `hollow-cli tab prev`
- `hollow-cli tab select <index>`
- `hollow-cli tab rename <name> [--id ID|--index N]`
- `hollow-cli pane split vertical|horizontal [--cmd CMD] [--cwd PATH] [--domain NAME] [--ratio N]`
- `hollow-cli pane popup <cmd> [--cwd PATH] [--domain NAME] [--x N] [--y N] [--width N] [--height N]`
- `hollow-cli pane close [--id ID]`
- `hollow-cli pane zoom [--id ID]`
- `hollow-cli pane float [--id ID]`
- `hollow-cli pane tile [--id ID]`
- `hollow-cli pane move <left|right|up|down> [--id ID] [--amount N]`
- `hollow-cli pane resize <left|right|up|down> [--amount N]`
- `hollow-cli pane send-text <text> [--id ID]`
- `hollow-cli send-keys <keys> [--id ID]`
- `hollow-cli focus <left|right|up|down>`
- `hollow-cli scroll <top|bottom|page-up|page-down>`
- `hollow-cli config reload`
- `hollow-cli config theme <name>`
- `hollow-cli run <cmd> [--domain NAME]`
- `hollow-cli emit <channel> [payload-json]`
