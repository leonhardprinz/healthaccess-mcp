# healthaccess-mcp

Apple Health for your AI. The Health Access iPhone app writes your workouts, daily health data and a one-page briefing as plain files into a folder you pick (iCloud Drive, Dropbox, any Files provider). This MCP server lets Claude, Cursor or any MCP client read that folder and write workout plans back, which the app puts on your Apple Watch. Local files, no cloud, no account.

## Run it

```
npx -y healthaccess-mcp
```

It finds the Health Access folder on its own: iCloud Drive first, then Dropbox, Google Drive, OneDrive and Box, then `~/Documents`. To point it at a folder yourself:

```
npx -y healthaccess-mcp --dir "/path/to/your/Health Access folder"
```

## Register it

Claude Code:

```
claude mcp add --scope user healthaccess -- npx -y healthaccess-mcp
```

Claude Desktop, Cursor and others (`mcpServers` in the client's config):

```json
{
  "mcpServers": {
    "healthaccess": { "command": "npx", "args": ["-y", "healthaccess-mcp"] }
  }
}
```

Thirteen tools (`list_workouts`, `get_workout`, `training_summary`, `get_days`, `push_plan` and more), six prompts that start with questions, and resources for the index, each workout and the briefing. The full docs, written so an AI can follow them: https://healthaccessmcp.com/llms.txt

## The command line

The same package carries the `healthaccess` CLI:

```
npx -y -p healthaccess-mcp healthaccess list
npx -y -p healthaccess-mcp healthaccess doctor
```

## Privacy

The binaries in this package contain no network code. They read and write files in your folder and nothing else. Privacy policy: https://healthaccessmcp.com/privacy-policy

Made by Prinz Tech Consulting d.o.o., Ljubljana. MIT licence. Support: support@healthaccessmcp.com
