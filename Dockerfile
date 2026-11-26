# For MCP directories that build and inspect the server in a container (Glama and others).
# It runs the published npm package against the synthetic example folder, so the server starts
# and lists its tools without anyone's health data. Not how you use Health Access MCP yourself:
# for that, `npx -y healthaccess-mcp` on the computer that sees your own folder.
FROM node:22-slim
RUN npm install -g healthaccess-mcp@1.1.0
COPY examples /data
ENTRYPOINT ["healthaccess-mcp", "--dir", "/data"]
