# 2026-08-31: MCP Tester

- **Authors:** @g-linville
- **Created:** 2026-08-31

## Summary

Add an MCP tester in the UI, which is a simple chat interface that supports tools, resources, and prompts.

## Related issues

- [obot-platform/obot#7598: MCP Servers Playground POC](https://github.com/obot-platform/obot/issues/7598)
  requests an in-product alternative to configuring a third-party MCP client
  merely to observe and exercise a server.

## Problem and motivation

Right now, after setting up a server in Obot, a user has to connect with a third-party client
to see if it works. Adding this MCP tester into the UI will make it easier for them to test.

## Goals

- Allow users to chat with the default LLM model, talking to a single MCP server, and able
  to call tools, use prompts, and read resources
- Use existing backend code as much as reasonably possible

## Non-goals

- Persisting chats
- Supporting more advanced MCP features (elicitations, roots, sampling, etc.)
- Model selection, file upload, etc.

## Context and constraints

We are going to leverage the existing MCP gateway routes for MCP traffic.
The UI will be responsible for calling it.

For the LLM proxy, to avoid having to write a bunch of logic for each LLM API
(OAI responses, Anthropic messages, chat completions, etc.), we are going to add
a new route to the backend to handle talking to the default LLM, and have a single
API representation for chats that the UI needs to support, to keep things simpler.

As for permissions, any users who can talk to an MCP server through the gateway
are also allowed to use the tester on it.

Chat sessions won't be persisted. When the user exits the MCP tester, there will
be no way for them to resume their previous session. However, their chat messages
will show up in the LLM audit logs and their MCP calls in the MCP audit logs.

## Proposed design

### Entry and page structure

I'll add a **Test** button to the deployed server's Details page.
This will take the user to `/mcp-servers/test/{serverID}`.

The tester will be a full page (not a modal). It will have four tabs:
Chat, Tools, Prompts, and Resources. We will load all tools, prompts, and resources
when the user loads the page.

### Inspector interactions

The Tools tab will show complete information about tools.
I will expose a form for a user to fill in for the arguments for a tool, and a **Call** button to submit it.

For prompts and resources, in the list, there will be a button to read it, and a **Use in Chat** button
which will stage it in chat as a removable preview (either using the prompt or referencing the resource URI).

### Chat interaction

Chat will always use the default `llm` alias model and never anything else.

I'll load the initial tool definitions when the user starts the chat, but not
refresh them after that. So if the tools in the server change, the user will need
to click the **New Chat** button and start over, if they want to use the new ones.

Users will have to manually accept/reject each tool call the model makes.

## Alternatives considered

### Call the LLM gateway directly from the browser

While this would eliminate the need for new backend code, it would introduce
a lot of complexity to the frontend that I'd rather take care of in the backend.

## Risks and open questions

None.

## Rollout and migration

N/A

## Testing and validation

I'll have unit tests in the backend for the API translation logic.

In the frontend, I'll add plent of vitest tests to make sure the chat and
"inspector" logic works, mocking out the backend for those.
