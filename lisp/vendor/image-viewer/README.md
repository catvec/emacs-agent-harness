# image-viewer

View an image with the zoom that image viewers tend to make hard: fitted
to the window, then a key press away from larger, smaller, or its own
size.

```elisp
(image-viewer-open "~/pictures/screenshot.png")
```

The image fills the window.  The header line names it, its size, how
large it shows, and the keys:

| Key | Does |
| --- | --- |
| `+`, `=`, wheel up | Zoom in. |
| `-`, wheel down | Zoom out. |
| `0`, `f` | Fit it to the window again. |
| `1` | Show it at its own size (100%). |
| `w`, `h` | Fit its width, or its height. |
| `F` | Fit the window showing it, and keep it fitted there. |
| arrows, `SPC`, `S-SPC`, `DEL` | Pan while it is larger than the window. |
| `r`, `R` | Turn it a quarter turn clockwise, or back. |
| `H`, `V` | Flip it horizontally, or vertically. |
| `n`, `p` | The next, or previous, image of the same directory. |
| `y` | Copy its file name to the kill ring. |
| `q` | Close its window. |

`image-viewer-mode` fits the image again when its window changes size,
so a frame that grows shows more of the image, not the same image with
a bigger margin.  A prefix argument to `+` or `-` takes as many zoom
steps: `C-u +` zooms in four steps, `C--` zooms out.  Zooming a small
image never enlarges it past `image-viewer-max-zoom`, and fitting never
enlarges it past `image-viewer-fit-max-scale`, one by default: fitting
shrinks a large image and leaves a small one at its own size.

The size is read from the image's header, not from a display.  PNG,
JPEG, GIF, BMP, WebP, SVG and ICO are read, so an image can be
measured and fitted in a batch Emacs, or before it is drawn.  A type
whose header is not known is measured with `image-size` where a display
can answer.

## Images in a buffer of your own

The same zoom works on an image shown in any buffer, not only in the
viewer's own.  `image-viewer-image-string` returns text that displays
an image and carries its zoom state and keys; `image-viewer-insert-image`
inserts one at point:

```elisp
(insert (image-viewer-image-string "diagram.png"
          :max-width 600 :max-height 400
          :keymap (my-view-keymap)))
```

The image fits the box it is given, and `+`, `-`, `0`, `1`, `w` and
`h` act on it where it is.  `C-wheel` zooms too; `image-viewer-wheel-map`
adds the plain wheel, for a window where the wheel has nothing else to
scroll.  `image-viewer-image-keymap` composes the right map with keys
of your own, which are used for everything the image does not bind:
a click can open a larger view, say, while `+` still zooms.  An image's
state travels in the `image-viewer-state` text property, shared by
every character of its label, so a copy of the string and the buffer it
is inserted into zoom together.

| Function | Does |
| --- | --- |
| `image-viewer-image-string SOURCE &rest PROPS` | Return a propertized string showing the image, or nil. |
| `image-viewer-insert-image SOURCE &rest PROPS` | Insert one at point; return its image object, or nil. |
| `image-viewer-image-keymap &optional EXTRA WHEEL` | The keymap to put on its text. |
| `image-viewer-zoom-in`, `-zoom-out`, `-fit`, `-fit-width`, `-fit-height`, `-fit-window`, `-actual-size`, `-rotate`, `-flip-horizontal`, `-flip-vertical` | Act on the image at point. |
| `image-viewer-status`, `image-viewer-status-string` | How the image at point shows. |
| `image-viewer-mode-line-status` | A mode line segment for it. |
| `image-viewer-pixel-size SOURCE` | Its own pixels, from its header. |

`SOURCE` is a file name or a plist `(:data BASE64 [:type TYPE :mime MIME])`.
`PROPS` are `:label`, `:max-width`, `:max-height`, `:max-scale`,
`:keymap`, `:help-echo`, `:foreground`, `:background`, `:rotation` and
`:properties` (other text properties); `image-viewer-insert-image`
also takes `:text-properties`.  Foreground and background are how an
SVG or a transparent image is drawn, as `create-image` takes them.

## Installing

If you use the Emacs agent harness, you have it already: the harness
ships this library in `lisp/vendor/image-viewer` and loads it.

Otherwise, until it has a repository of its own, install it from the
harness's, taking only its file.

With [Doom Emacs](https://github.com/doomemacs/doomemacs), in
`packages.el`:

```elisp
(package! image-viewer
  :recipe (:host sourcehut :repo "catvec/emacs-agent-harness"
           :files ("lisp/vendor/image-viewer/image-viewer.el")))
```

With [straight.el](https://github.com/radian-software/straight.el):

```elisp
(straight-use-package
 '(image-viewer :host sourcehut :repo "catvec/emacs-agent-harness"
                :files ("lisp/vendor/image-viewer/image-viewer.el")))
```

With [Elpaca](https://github.com/progfolio/elpaca):

```elisp
(elpaca (image-viewer :host sourcehut :repo "catvec/emacs-agent-harness"
                      :files ("lisp/vendor/image-viewer/image-viewer.el")))
```

Or by hand, from a clone:

```elisp
(add-to-list 'load-path "~/src/emacs-agent-harness/lisp/vendor/image-viewer")
(require 'image-viewer)
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
