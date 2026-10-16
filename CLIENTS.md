# Client discovery

The standard is identified by files and protocol metadata, not by a vendor name. A client should
look for `AGENTS.md` in the current directory and walk upward until it finds the workspace file.
Then read `mindattic-agent-standard/manifest.json` and invoke the shared runner or MCP/HTTP
transport described by the project protocol.

Supported client families include Claude, OpenAI clients, Gemini, Kimi, DeepSeek, and local or
custom LLM hosts. Slash commands are optional UI aliases; their portable meanings are documented
in the central command catalog and implemented by one runner.
