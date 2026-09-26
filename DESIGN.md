# Emacs Agent Harness
This is the design document for the Emacs native agent harness. This document describes the indended features and technical architecture of the program. 

# Table Of Contents
- [Overview](#overview)
- [Development Guidance](#development-guidance)
- [Technical Architecture](#technical-architecture)
- [User Experience](#user-experience)
- [Features](#features)

# Overview
The agentic experience in Emacs as of yet has been well served by generic tools but not specialized to the strengths of Emacs. Additionally Emacs provides a powerful environment in which programs can interact with source code, external programs (shell, build and test systems ect), and use pre-made tools and patterns to complete complex workflows.

The status quo is running a terminal emulator inside Emacs further inside which you run a harness which paints UI elements via curses style drawing commands. Although this gives you access to agentic tooling (Claude code, Pi, ect) it's obviously not an ideal experience (Many layers of indirection between UI, Emacs vterm is okay at best--doesn't compare to ghostty or kitty, curses GUIs aren't great to begin with).

The combination of opportunities to take agentic tooling to the next level with the power of Emacs, and the underserved user experience which sub-par tools like TUI harnesses offer, is what provide an excellent opportunity to make a tool to serve these needs.

# Development Guidance
The first priority is to develop a workflow (set of tools, skills, docs, ect) which facilitate a closed loop hands on development cycle. An Emacs instance should be launched which can be manipulated and inspected / screenshot so that the agent can verify live that the code is working as intended. The code simply appearing implemented is not enough.

It is very important to verify features as they are created. You should not create multiple features without testing each one before going on to the next.

The architecture of this project is such that all modules should be developable in parallel once the core loader logic and API contracts are defined.

Make sure both local emacs and remote client ACP are tested whenever new feature are added or when verifying functionality. 

# Technical Architecture
The architecture of this harness is inspired by the Pi coding agent, and other modular systems like very mod-able games, D-Bus + XDG + the whole linux desktop system, ect. The core of the harness should be entirely focused on loading modules and facilitating communication between modules. All functionality should be provided via addon modules (even if they are shipped in tree), a plain harness running with no modules shouldn't even show a UI or call a completion API. Different modules need to be able to communicate with the APIs of other modules. This includes making direct calls to enact an action, but also hooking into events which are caused by a module (ex., on question ask). 

> Lesson Learned: Pi's biggest architectural failure is not solving for the D-Bus problem of having many different services with many different API surfaces and events. Plugins never played nice with each other unless the plugins in question were custom made to work with other plugins. 

Typical concerns should be made like any user interface or business logic containing program. The business logic, state, and user interface should all be completely separate systems. They should have clearly defined boundaries (litnus test: can a module be easily tested without the presence of any of the other modules and without extensive mocks).

Broadly the systems from top (closest to user) to bottom are:

- Presentation 
- State 
- Completion provider 
- Tool calls

All implementation must follow Emacs and elisp best practices. Code should avoid running on the main UI thread by any means necessary, responsiveness is a top priority. Use built in Emacs functionality when available and allow for users to configure and customize the harness just like any other piece of standard Emacs functionality.

The separation of presentation and state allows the harness to facilitate remote control of sessions. This should be done over an implementation of the Agent Client Protocol (ACP). This protocol should be used to communicate between the state / business layer and the presentation layer. The Emacs UI is simply a client talking ACP to the core of the harness. Make sure that all pieces of functionality can be exercised via the ACP. Make sure that the implementation of the ACP is Emacs optimized and does not slow down the harness nor the Emacs main UI thread. Over ACP the harness should feel snappy. This could be done via different transport mechanisms (for real servers use TCP messages and JSON, but for local maybe no server and just send lisp objects which are ACP messages directly to a callback handler function).

# User Experience 
The user experience of the harness must be amazing and designed with great care.

- Minimal elegance: Choose what information will be shown on the UI and display it stylishly, choose specific user stories and serve them well with simple but powerful workflows, design as few number of features as possible which can be composed together to service multiple complex patterns
- Always user built in Emacs UI tools, do not settle for using ASCII or UTF-8 tricks to create the UI which is needed
- Responsiveness is a priority: Use UI pattnerns which make the harness feel snappy and quick, if an operation is going to take more than an instant show a loading state while it occurs and then show if it was a success or failure
- Every action with a keyboard shortcut should have a place in the UI where you can click with your mouse to perform the same action

# Features
Most features specified here are standard to any agentic harness. 

## Sessions
At the core of any agentic session is a series of messages, and tool calls (from the agent), between the user and an agent. 

- Sessions hold state about a single conversation: current project, its directory, the messages in the conversation, the model, permission mode, number of tokens consumed, total cost
- Sessions can be either active because they are open in the user's harness (even if obscured by another session and running in the background, even when idle) or inactive because the user does not have them active 
- Sessions can be resumed
- Sessions can be forked 
- Sessions are scoped to a specific project (auto-detected) 
- Sessions can be idle (waiting for user to send next message), running (agent is generating tokens or ingesting tool calls, ect), blocked (waiting for user response to tool call or for permission)
- Sessions can have a parent child relationship with another session 

## Chat Interface
Session messages should show up like a chat app, where older messages are at the top of the screen and newer messages are at the bottom. The sender and type of the message is identified by the styling of the message (human messages have a slightly lighter background, agent messages use the default background color, agent tool messages have a slightly styled colored background). The chat interface is also where the user can send new chat messages to the agent.

Functional requirements:

- All messages in session are visible in chat UI
- Older messages can be viewed by scrolling up, you can return to newer messages by scrolling down
- Text from all messages is aligned in the user's language direction (english is left to right)
- The sender (agent or user) and type () of a message 
- The sender of a message is identifiable by the background color of the message text (agents have a darker background color, users have a lighter background color)
- If messages are too long they wrap to the next line matching the original line's indentation
- Messages are formatted in Markdown and rendered as such
- A message composition box should be displayed at the bottom of the chat history view
- The message composition box supports multi-lined input, but by default is 1 line, and only expands to a maximum height if the user types a message which spans multiple lines
- History of all messages can contain up to more or more than 1 million tokens, UI must remain responsive and performant with this high amount
- Tool calls from the agent are shown in the correct chronological place in the chat history 
- Tool calls are differentiable from agent and user text messages 
- Tool call messages should show which tool was used, parameters of the tool, and the output of the tool 
- The chat interface should automatically scroll down to show new messages when they arrive, unless the user has explicitly scrolled up and is viewing history in which case do not scroll
- Some models output thinking text which should be visible in a darked text color as to lessen its importance in the conversation
- Non-text messages (like thinking and tools) can be collapsed to just show the name of the tool / summary label, they can be uncollapsed to show details of the tool call and output / thinking text
- Non-text messages can be coalesced into a summary block which indicates what and how many tools / thinking was used, this can be uncollapsed to show the tools in their collapsed state, and further uncollapsed to show tool output, only tools / non-text message types which are on an explicit allow list can be coalesced like this in order to prevent hiding of essential tools which block a session
- The chat interface must be aware of how it opens in Emacs and what position it takes up, presets to open in several convenient places like on the right hand side vertically split
- Only one session must be visible in each position, if a session is already open in a position and a different session must be opened with the same position preset--then that different session should replace the existing session, so that you can switch between sessions
- System hint messages can be shown from the harness to tell the user when harness configuration (like session info: name, model, permission mode, ect) change, the text should be muted like thinking but distinct
- Messages from the agent, the user, and thinking / tool messages should all have their contents be searchable

### Image Video Audio Support 
Modern models are multimodal and can declare capabilities such as understanding data in the form of text (common), image, video, and audio. This could include the support of each of those modes on input and / or output. A common configuration for coding agents is text and image input and text output. Especially key is the ability to handle uncommon MIME types in the user's clipboard. If you don't know what it is pass the data and the MIME type all of which are considered somewhat hostile user inputs, to the agent and see what it thinks.

The conversation UI must be able to display images if the Emacs instance is capable. Ideally video is playable in emacs or at least a command to open the video and also do thumbnails w builtin emacs functionality. Audio should also be supported if the model supports it. Allow for audio input and audio output. Have good user interfaces which show what is clearly happening with all these modes (playback bars, volume, audio mic monitoring).

### Queued Messages 
If the agent is mid-turn and the user wants to send a message that message can be queued for sending. The message should be shown at the bottom of the chat interface right above the compose message box. Queued messages can be edited before they are sent by selecting the queued message from the queued message list and re-composing it. Queued messages should all be sent at the next possible turn in the session all at once.

### File References
Allow user messages to have references to files, who's absolute path and size in bytes will be attached in the user's message. These files are referenced by putting an at symbol followed by the file name. The harness should perform fuzzy searching for files matching the contents after the at symbol.

If the user is in GUI mode of Emacs make use of the operating system drag file on to application behavior to attach that file to the message.

Show attached files near the compose message box, use their relative path to the project root and shorten in the middle if needed, allow via this ui to open that file as a buffer or remove it from the message.

### Skill References
Allow user messages to have explicit reference to a skill, who's contents will be attached to the user's message.

## Conversation Tree 
The history of messages, tool calls, ect should be represented as a directed graph. A view should be provided which shows the nodes of this directed graph (only showing a short amount of the content from each message node) so you can navigate back in time and between forks of the conversation. The graph view should mirror a Git representation of commits and and branches.

## Compaction
As a conversation approaches the maximum number of tokens a model can fit in its context window it must be compacted down to a smaller size. Enough headroom must be left in the conversation so that the compaction output can be generated and swapped out for the previous full context. As a conversation approaches the compaction limit start highlighting the token count of the session in progressive warning colors.

## Session List
View sessions and switch between them.

- Display list of sessions scoped to current project
- Show name of session, all status types, tokens, model
- Filter and sort list by any attribute of session
- Child sessions should be shown in a tree under sessions

## Session Blocked Notifier
There should be a UI element placed outside of the harness UI to display how many sessions are blocked needing user input or idle or working. This should be visible from any other buffer when there is at least one session active in the current project or any other project (aka if there is an active session in the current emacs instance). The purpose of this indicator is to tell the user when they are needed (either to answer a question / approve something or to direct the agent on to the next task). So it should be a small but noticable and trackable UI element which has in mind the concept that users may be rapidly switching between projects and sessions.

## Session Auto Naming 
If a name is not provided when a session is made (not mandatory) then an agent will be used to name the conversation. This ability can be triggered at any time during the conversation, but it will auto trigger after the first initial message from the user. This should be done by forking the conversation using the same model (since the user's prompt will be cached after the first response from the model). A system hint from the harness should be shown to indicate renaming has started and then when it is done.

## Permissions 
Tool calls should have a permission hook which is responsible for performing some process (be it asking the user, automatically approving due to the tool, or a more advanced decision) to determine if the tool is allowed to run or not. Using this many advanced permission systems can be created. 

### Directory Jail
By default session should not be given permission to files outside of the current directory. Enforce this with read, write, search, ect commands. If a session wants to add another directory to its allow list the user must give permission. If an automatic tool call deny is required provide constructive information to the agent so it succeeds and doesn't require user intervention to use the correct directories, work with what you have.

### Auto Mode
User a cheap LLM to determine if a tool call is allowed. Give the details of the tool call (description as seen by agent) as well as the parameters and any other supporting context. The cheap LLM outputs a decision along with a reason.

### Non-Interactive Mode 
Using this hook system a mode can be enabled which forces the model to attempt to not get blocked waiting for user input. If enabled and a tool call would be disabled an automatic steering message is sent to the agent telling it that it should do everything in its power to find a different approach which respects the permission denial but also achieves the goal. The user of this mode is for when users start a task and know they will be stepping away for a while and want the session to get work done.

## Completion API
Model providers are generic. There is a set of API methods which model providers must implement in order to provide functionality needed for all the harness's usage. Provide a built in implementation of the OpenAI compatible completion API. Providers can provide extra optional capabilities enable features in the harness (like knowing your plan's quota, if a session is still in the KV cache, dynamic pricing).

### Claude SDK
To support users with subscription plans a completion API provider should be implemented which uses the official Claude Code SDK. This is in line with Anthropic's policy's on how external tools can use Claude.

## Cost Tracking
Each completion API call should be associated with a usage cost. Usage cost should be tracked for the session down to the message. Cost should be tracked across sessions and projects to provide aggregate information. 

### Cost and Usage Overview
A page should exist which shows graphs and stats about model, token, and cost usage broken down by project and other associated dimensions. 

### Budgeting
Budgets can be set on a per-session, per-project, and per time period basis. Budgets can be set as informational or as hard quotas. For time period based budgets planning tools should be provided to split the budget across the time period by days (configurable between business days or all days) or hours.

## Git Worktree Aware 
Sessions can be associated with a git worktree. The session's working directory should be set to the git worktree's directory. The harness should have the ability to manage the worktrees.

## BTW
Allow for side conversations to be quickly started to check on quick informal details about the conversation. This uses the fork functionality but presets a UI which shows the forked btw conversation over the current session. This way you can keep your current session running and not leave its output while also seeing the response to a btw conversation and even following up. When you are done this btw conversation can be easily closed and you can return to your main session as if nothing changed. Btw conversations, like any fork, should be visible in the converstaion tree.

## Cache Aware
The harness should use provider APIs to determine when tokens from a conversation are in the KV cache. This applies not only to the cache hit rate of token generation but also awareness of when a conversation's tokens have left a KV cache and replying with a new message would result in entire conversation being run through at full cost again. Workflows should be based around the reality of LLM inference, its auto-regressive nature, and how caching makes it better to fork a session then to start a sub-agent which needs to gather all the context again with new costly tokens.

## Fork
A new session can be created using the context and settings of another existing session. This lets new tasks or lines of thought be persued by parallel agents all sharing some initial state. This also leverages the auto-regressive LLM caching price model. Where tokens you already have are better than a fresh context in many cases. Forks should record their parent session and show up on the session list.

## Sub-agents 
Sub-agents should be able to be created by an agent as a tool call. Sub-agents just create a new fully fledged session with the context they are provided. Sub-agents should be able to be viewed using the normal session viewing UI. Sub-agents should have their session parent be recorded. A sub-agent can also be made out of a fork of a conversation if choosen.

## Emacs MCP/Tool
A tool should be provided to the agent to interact with the current Emacs session. This allows the agent to view buffers, emacs variables, eval functions, control emacs, help the user drive.

## Emacs Native Tools
All operating system modification tools should be implemented using built in Emacs functionality. Common tools like read, write, list, search should all use the built in Emacs tools which a user might use for those workflows. An elisp terminal should also be made available as an alternative for Bash. Additional tools like a bash tool or things not implementable in Emacs are allowed by the first choice is to implement a tool in Emacs. The implementation of a tool in Emacs must be fast and not block the main UI thread.

## TRAMP
The Emacs TRAMP functionality should be supported. A powerful part of Emacs is all the Emacs native workflows for reading, writing, listing, searching, ect files can also take place transparently on another system. This lets you use the power and familiar Emacs tools on remote machines. Tool calls can be configured to act on other hosts this way.

## Merge Queue 
Forked sessions can elect to try and submit their changes back to a main session. This is useful in cases where a small bug was found and a git worktree and session fork was spun up to fix the issue. Instead of submitting the change as a formal PR with overhead the changes from the worktree can be merged back into the parent sessions working directory. A queue of sessions who want to merge into a parent session is maintained, and only one session gets access to merge into the parent session at a time (this means the parent session itself may stop at points to allow another session to access its files). If any merge conflicts occur the child session is responsible for resolving them. 

## Configuration File
The global configuration must be overridable by project specific permissions which should be overridable by directory specific permissions. Files must persist these configuration options. A built in Emacs way for doing this must be used. If a setting like the permission mode or the model is set by the user it should be persisted in the most specific configuration file, preferring project configuration over directory configuration unless a directory configuration file is found or a project is not found.

## Skills
Should look in common locations for skill files. Should provide tooling to the model to search for skills to use. Should provide tooling to load a skill.

## Model Switcher
Provide a user interface to switch between models. The available models should be fetched by enumerating over all providers and asking for available models. The list of models should be searchable. Model names should indicate the provider of the model (Anthropic, Open Router, ect) and the name and version of the model.

## Thinking Toggle 
For models which provide a setting to set the thinking level provide an interface which can be used to switch between thinking levels.

## Remote Session Connect 
Using the Agent Client Protocol (ACP) the harness can connect to a harness server running on another host and control it fully using the UI running on the user's current machine. By default when the harness starts it should start an ACP server which the local harness UI then talks to. This should be configured for optimal local use, but can be relaxed to allow remote connections.

## Plan Mode
A tool which allows the agent to propose a detailed plan for a complex task. Gives the agent a way to gather its thoughts and lay out the full plan. The plan should include superpowers guidance and details on how it will be implemented. The unique presence of forking tools, sub-agents, and merge queues should be taken into account when planning the implementation.

## Todo Tool
Track todo items and allow the agent to update todo statuses.

## Websearch Tool
Allow the agent to search the web for content. This is a generic tool which should be implemented by a drop in provider. To start provide a built in implementation of the brave websearch API.

## Context Bomb Protection
If a tool output, file read, ect any type would cause an output of too large of a size which would screw up your context do not output it and instead require the use of range parameters to get the output. 
