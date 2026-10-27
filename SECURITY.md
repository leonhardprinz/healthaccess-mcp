# Security

Please report security problems privately to **support@healthaccessmcp.com**, not in a public issue. Include what you found, how to reproduce it and which version (app, `healthaccess-mcp` on npm, or the site). You get an answer within a week.

What is in scope: the iOS app, the MCP server and CLI (`healthaccess-mcp`, `healthaccess`), the npm packages and healthaccessmcp.com. What the project promises, and what a report would break:

- Health data goes only into the folder the user picks. The app has no server and no account.
- The MCP server and CLI read that folder and write only `plans/`, `mcp/clients/` and the two rating fields of a workout. The npm binaries contain no network code.
- Usage statistics are opt-in and never contain health values, file names or folder paths.

Please do not test against other people's data or devices.
