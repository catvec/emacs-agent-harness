# Emacs Agent Harness
This is the design document for the Emacs native agent harness. This document describes the indended features and technical architecture of the program. 

# Table Of Contents
- [Overview](#overview)
- [Technical Architecture](#technical-architecture)
- [Features](#features)

# Overview
The agentic experience in Emacs as of yet has been well served by generic tools but not specialized to the strengths of Emacs. Additionally Emacs provides a powerful environment in which programs can interact with source code, external programs (shell, build and test systems ect), and use pre-made tools and patterns to complete complex workflows.

The status quo is running a terminal emulator inside Emacs further inside which you run a harness which paints UI elements via curses style drawing commands. Although this gives you access to agentic tooling (Claude code, Pi, ect) it's obviously not an ideal experience (Many layers of indirection between UI, Emacs vterm is okay at best--doesn't compare to ghostty or kitty, curses GUIs aren't great to begin with).

The combination of opportunities to take agentic tooling to the next level with the power of Emacs, and the underserved user experience which sub-par tools like TUI harnesses offer, is what provide an excellent opportunity to make a tool to serve these needs.

# Technical Architecture
The architecture of this harness is inspired by the Pi coding agent, and other modular systems like very mod-able games, D-Bus + XDG + the whole linux desktop system, ect. The core of the harness should be entirely focused on loading modules and facilitating communication between modules. All functionality should be provided via addon modules (even if they are shipped in tree), a plain harness running with no modules shouldn't even show a UI or call a completion API. Different modules need to be able to communicate with the APIs of other modules. This includes making direct calls to enact an action, but also hooking into events which are caused by a module (ex., on question ask). 

> Lesson Learned: Pi's biggest architectural failure is not solving for the D-Bus problem of having many different services with many different API surfaces and events. Plugins never played nice with each other unless the plugins in question were custom made to work with other plugins. 

Typical concerns should be made like any user interface or business logic containing program. The business logic, state, and user interface should all be completely separate systems. They should have clearly defined boundaries (litnus test: can a module be easily tested without the presence of any of the other modules and without extensive mocks).

Broadly the systems from top (closest to user) to bottom are:

- Presentation 
- State 
- Completion provider 
- Tool calls

# Features
Most features specified here are standard to any agentic harness. 

## Sessions
At the core of any agentic session is a series of messages, and tool calls (from the agent), between the user and an agent. These messages are organized

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
