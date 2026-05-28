# agent instruction

**When the user asks for content 'as a single block of markdown' in chat, default to writing it to a file in the repo AND wrapping any inline copy in a code fence.** "If the user asks for markdown 'as a block' / 'as a single block' / 'inline' / 'in chat', the user wants either a copyable artifact or a renderable document — never raw `# heading` characters interleaved with the conversation. Default behavior: write the content to a named file in the repo (so it's durable), and if the user explicitly wants it in chat too, wrap the markdown in a triple-backtick fence so the literal characters render verbatim rather than being interpreted as conversation headings. When the request is ambiguous, write to a file and link to it."

*Grounded in: auto-003 post-retro phase, where the agent produced a 200-line handoff inline as raw markdown that the renderer interpreted as conversation headings; the user replied 'What the fuck part of "give it to me here as a single block of markdown" do you not understand?' and instructed the agent to write the file instead.*

# justification

"Single block of markdown" in chat is ambiguous — did the user want it rendered, or did they want raw markdown text they could copy elsewhere? Defaulting to a file resolves the ambiguity (the file is the durable form; the chat link is the pointer). Cost of adopting: one `Write` call per long-form handoff. Cost of not adopting: the agent produces an unusable conversation-formatted blob, the user has to ask again with sharper words, and the file gets written anyway in the second round. The agent ends up doing the same work twice and burning user patience on the first try.
