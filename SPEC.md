# Emacs Agent Harness
Replicate the full functionality of a harness like Pi or Claude Code using completely native Emacs UI / UX patterns.

Goals:

- High performance in Emacs as the top priority, avoid all common pitfalls when making emacs plugins and user interfaces, do no blocking work on the main thread, do no expensive work on the main thread
- Use all elisp and emacs commands
- Follow the patterns emacs uses in its source code for modularity, customization, hooks, modes ect
- Follow the patterns emacs uses in its user experience and user interface with buffers, input, organization, shortcuts, ect
- The harness should dogfood its own core functionality to make features, it should be extensible from the start so that after the initial implementation of the core features can be added as plugins on top of the core, this will give plugin writers ultimate extnesibility to modify the harness to their will 

Replicate features of harnesses:

- Conversation interface to view messages between agent and user 
- Text entry and message submission
- Sessions with names tied to projectile projects 
- Search sessions by content 
- Resume sessions 
- Tree view of session messages
- Status line with model, cost, any other messages
- Tool calls with specially formatted output
- Tracking of session status (working, idle, blocked by user output) 
- List of sessions per project filtered by status 
- Sub-agents, inherit model of current session but model can be overriden or a specific model for a specific personality (ie reviewer or planner) can be specified, list of running subagents, view sub-agent by using first class agent conversation view ui to also view subagents 
- Control over how buffers open (which location)
- Queued messages with editing of queued messages 
- Auto mode for commands (Ask dumb model if command is okay)
- Nice UI for ask user question tool, uses full emacs style ui to present each question with an area to fill in or select the resoponse (inspired by customization ui)
- Key shortcuts to navigate between sessions 
- Select the model 
- Theme-able
- Add providers as a pluggable thing you can implement (this way a standard openapi completion provider can be used or a custom provider which uses claude code cli json-rpc [don't do this], the provider should submit and receive inference from a provider and also get stats about the provider like the model and the price)
- Built in hot reload using the built in emacs / doom hot reload mechanism (play nice and let the system do it) so that plugin development and iteration is easy
- During composing message the @ notation can be used to attach the contents of a file or directory and fuzzy search helps find that filesystem object (very important the contents are attached to the message so the agent doesn't need to find the file)
- Working directory awareness per session (commands for tools, @ notation finding, everything) based on directory awareness
- Git worktree native integration, sets working directory, automatically creates working tree, can clean up on exit
- Handle very long amounts of context gracefully (only have relevant context loaded in the buffer, smartly use quick on another thread async operations when require full access to context ex when searching)
