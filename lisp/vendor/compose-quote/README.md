# compose-quote

Compose a reply against the text it answers: quote what you answer, then
answer it inline, a part at a time.

`C-c >` quotes the region, or the message at point, into the reply as a
Markdown block quote, its lines after `> `, with point under it ready
for your answer. Inside the quote, `M-RET` splits it where point is, to
answer that part right there, and `C-c [` cuts what you do not answer
down to `[...]`, keeping a bit of the front matter for context:

```
> The release is ready, but two things are open.
>
> First, the changelog still lists the old flag.

Fixed, thanks.

> Second, the migration [...]

Let's ship it without that.
```

It works in any Emacs buffer: a mail body, a scratch buffer, or the
input box of a chat that composes under a read-only transcript.

compose-quote is developed inside the
[Emacs agent harness](https://git.sr.ht/~catvec/emacs-agent-harness)
repository for now, in `lisp/vendor/compose-quote`, laid out as its own
repository will be once it is split out. It needs nothing of the
harness, and nothing but Emacs 29.1 or later.

## Keys

| Key | Where | Command | Does |
| --- | --- | --- | --- |
| `C-c >` | `compose-quote-mode` | `compose-quote-reply` | Quote the region, or the message at point, ready to reply under it. |
| `M-RET` | in a quote | `compose-quote-split` | Split the quote where point is: the part above, an empty line for your answer, the part below. |
| `C-c [` | in a quote | `compose-quote-elide` | Replace the region, or the rest of the paragraph from point, with `[...]`; with `C-u`, the rest of the quote. |

`M-RET` and `C-c [` belong to `compose-quote-inline-mode`, which is on
while point is in a quote (the mode line shows `Quote`) and off
elsewhere. Its map binds nothing else, so every other key of the buffer
works in a quote as it does outside one. As point enters a quote the
echo area names the keys, unless `compose-quote-inline-hint` is nil.

Splitting at the start of a line, or in its `>` prefix, splits before
that line; at its end, after it; anywhere else, the line itself is split
and its second half keeps the same prefix. Bare `>` lines where the two
parts meet go. Eliding joins what stays on one line around the `[...]`,
merges with a `[...]` already next to it, and selecting whole lines
leaves one `> [...]` line for them. One undo undoes either.

`C-c [`, for the `[...]` it leaves, follows the convention that `C-c`
and most punctuation characters are a minor mode's to bind. `C-c >`
breaks it, as `>` is among the few kept for major modes: it is bound
because quoting is what `compose-quote-mode` is for. Bind other keys in
`compose-quote-mode-map` and `compose-quote-inline-mode-map` to change
them. `compose-quote-elision` sets the text that stands for what was
cut.

## Turning it on

```elisp
(add-hook 'message-mode-hook #'compose-quote-mode)
```

`compose-quote-mode` binds `C-c >` and turns the inline mode on and off
as point moves. In `message-mode`, `M-RET` already splits a citation
(`message-newline-and-reformat`); in a `>` quote, compose-quote's
`M-RET` takes over.

## In a buffer of your own

By default the whole buffer is the composition: the reply is composed
anywhere in it, and text is quoted as it is. A buffer that composes in
only a part of itself, or shows text otherwise than as it was written,
says so with buffer-local variables:

- `compose-quote-area-function` returns where the composition is, as
  `(START END [FRONT])`, or nil when there is none right now. `START`
  and `END` bound its text; `FRONT`, `START` by default, is where it
  shows to start when something precedes `START` on its line, such as a
  prompt. A region above `FRONT` is quoted at the composition's end; a
  region in the composition becomes a quote in place.
- `compose-quote-source-function` reads text outside the composition
  back for quoting, given `BEG` and `END`; for instance Markdown drawn
  with faces, back into its markup.
- `compose-quote-function` returns the text of the message at point, to
  quote when there is no region. Text can also name the message it
  stands for with a `compose-quote` text property, a string, which wins.
- `compose-quote-insert-hook` runs after a quote goes in, point where the
  reply goes.

A chat that composes in a box under its transcript:

```elisp
(defvar-local my-chat-input-start nil
  "Marker where the input starts: text inserted there goes in.")
(defvar-local my-chat-input-end nil
  "Marker where the input ends, advancing as text goes in there.")

(defun my-chat--quote-area ()
  (and my-chat-input-start
       (list my-chat-input-start my-chat-input-end)))

(defun my-chat--setup-quoting ()
  (setq-local compose-quote-area-function #'my-chat--quote-area)
  ;; The transcript shows rendered Markdown: read it back.
  (setq-local compose-quote-source-function #'my-chat-markdown-source)
  ;; Without a region, C-c > quotes the message at point.
  (setq-local compose-quote-function #'my-chat-message-at-point)
  (compose-quote-mode 1))
```

Make `my-chat-input-end` with `(copy-marker pos t)`, so that what is
inserted at the end of the input stays in it. Quotes are found from
their lines alone, those of the composition starting with `>`: a quote
typed or yanked in counts as much as one put there by `C-c >`, and a
`>` line of the transcript never does.

The library's functions are there to build on: `compose-quote-string`
turns text into a quote, `compose-quote-insert` inserts one,
`compose-quote-at-point` returns the message at point, and
`compose-quote-bounds` the quote around a position.

## Installing

If you use the Emacs agent harness, you have it already: the harness
ships it and loads it.

Otherwise, until it has a repository of its own, install it from the
harness's, taking only its file.

With [Doom Emacs](https://github.com/doomemacs/doomemacs), in
`packages.el`:

```elisp
(package! compose-quote
  :recipe (:host sourcehut :repo "catvec/emacs-agent-harness"
           :files ("lisp/vendor/compose-quote/compose-quote.el")))
```

With [straight.el](https://github.com/radian-software/straight.el):

```elisp
(straight-use-package
 '(compose-quote :host sourcehut :repo "catvec/emacs-agent-harness"
                 :files ("lisp/vendor/compose-quote/compose-quote.el")))
```

With [Elpaca](https://github.com/progfolio/elpaca):

```elisp
(elpaca (compose-quote :host sourcehut :repo "catvec/emacs-agent-harness"
                       :files ("lisp/vendor/compose-quote/compose-quote.el")))
```

Or by hand, from a clone:

```elisp
(add-to-list 'load-path "~/src/emacs-agent-harness/lisp/vendor/compose-quote")
(require 'compose-quote)
```

Once it is split out into a repository of its own, the recipes name
that repository instead, with no `:files`.

## Developing

```sh
make test      # the tests, in an Emacs with nothing but this directory
make compile   # byte-compile, warnings as errors
```

## License

GPL-3.0-or-later: see [LICENSE](LICENSE).
