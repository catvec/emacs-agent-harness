---
name: freeform-board
description: Work the freeform agent board with the board tools: list and create boards, read a scene, edit with explicit operations, preview and commit a patch, undo, pin a delivered revision and discuss a place. Load it when the board tools are available and a drawing, diagram or note is what the answer needs.
---

# The freeform board

A board is a shared freeform canvas: notes, ink, shapes, frames,
connectors, resource links and diagrams.  A person draws on it in the
Flutter client or in Emacs; an agent works it with the same tools and the
same grammar.  The board is a place to think, not a task and not a
review: nothing here creates a task, approves code or decides what a
drawing means.  A person decides that.

Every board tool is one bus method of the board module and answers what
that method answers.  Nothing is guessed for you: the grammar says what
can be drawn, the scene says exactly where everything is, and a patch is
validated against the document as it will be after the operations before
it.

## The loop

1. `board.list` -- the boards there are, with the id every other tool
   names.  A board of the calling session's project is listed by default;
   name a project, or `all`, for another's.
2. `board.create` -- a new, empty board: a name, optionally an id, a
   project, a theme.  Its answer names the board, its one empty diagram
   and its link.  An id already in use is refused, never emptied.
3. `grammar.describe` -- the shape kinds and their fields, the operations
   and what each does, the style keys, the colour roles, the themes, the
   resource kinds, the evidence roles, the units and limits, and the ways
   an operation is refused.  Read it before drawing: it is the only list
   of what a board can hold.
4. `scene.read` -- one board: the revision, the diagram with its viewport,
   selection and portals, every object with its exact geometry, text,
   frame and anchors, its resources and the state each resolved to, and
   the objects near a selection.  Ask for a picture with `image` when a
   drawing is the answer.
5. `scene.edit` -- an ordered batch of explicit operations, validated and
   returned as a patch: the expanded operations, the ids it creates and
   changes, the preimages it would replace and the diagnostics.  Nothing
   is written.
6. `patch.preview` -- the same batch rendered and diagnosed without
   making a revision.  Use it when the geometry matters: it reports
   objects that would move and by how much, text that would overflow, a
   reference that would break and a constraint that would refuse.
7. `patch.commit` -- apply the validated patch as one atomic revision.
   Name the patch id and content hash, or the same operations again, and
   the revision you read; an `idempotencyKey` makes a retry after a lost
   answer commit once.
8. `history.undo` -- take back the newest commit, or the one you name, as
   a compensating edit built from the preimages that commit kept.  An
   object somebody else changed since is left as it is and reported as a
   conflict.  `dryRun` returns the operations without committing them.
9. `board.pin` -- keep the board's revision as a task's delivered
   artifact, with its landing diagram and an optional place to open.  The
   pin is a copy: edits after it cannot rewrite what was handed in.
   `board.pins` lists a board's pins, or answers one with the document it
   kept and its picture.
10. `board.discuss` -- start or answer a thread on a node, a connector or
    the diagram itself.  The thread is a native thread of a task's
    review, so it is replied to and resolved there.  `board.discussions`
    lists a board's threads and says whether the drawing has moved since.
11. `board.delete` -- remove a board made by mistake, with the client
    state navigation kept for it.  A board a task delivered a pin of is
    refused unless `force` is set.  Deleting is not an edit: nothing is
    left to undo.

## Units and geometry

- `x` is right, `y` is down, angles are clockwise degrees, scale is
  positive; all in canvas units.
- A transform is a 2x3 affine matrix `[a b c d e f]`, the same six
  numbers SVG uses.  A zero determinant, a non-finite number or a number
  past the limits is refused.
- `move` translates a view about its own origin and takes an optional
  `budget`, the furthest it may go.
- `transform` rotates, scales, reflects or applies an affine matrix about
  a `pivot`: `rotate` with `angle`, `scale` with `sx` and `sy`, `reflect`
  with `axis` (`x`, `y` or `[ux,uy]`), `affine` with `matrix`.
- `attach` places a child so its `child-anchor` lands on the parent's
  `parent-anchor`: reflect across the child's growth axis when `mirror`
  is set, then scale, then rotate, then translate.  It expands to a
  `set-transform`.
- Text is never mirrored by a transform, and a reflection of a text
  object is refused unless the operation asks for it explicitly.

## Objects, views and diagrams

A component is one `object` with one id and one history.  Each diagram
holds a *view* of it: local geometry, transform, style and layer.  So the
same object can appear in several diagrams without a second meaning, and
a drill-down is a view plus a portal, not a copy.

- `create` makes an object with its first view.  `view.add` puts the same
  object in another diagram; `view.remove` takes one representation away
  and never the object.
- `diagram.add` makes another diagram, optionally a child of this one;
  `diagram.parent` says where it sits in the breadcrumb.
- `diagram.portal` adds or removes one drill-down (the object that leads
  into another diagram, `on: false` to take it away);
  `diagram.portals` replaces the whole list.
- `select` and `viewport` are navigation a client stores; they change no
  drawing and make no revision when a client writes them.
- `detach` makes a copy of one view an object of its own, with `new-id`.
- `delete` removes an object with its views and relationships.

## Evidence, not decoration

An object's `role` says what its drawing claims: `observed` (measured),
`declared` (said to be so), `proposed` (not built yet) or `unknown`.
Use them honestly; a diagram that marks a plan as observed is a lie a
reader cannot see.

`resources` are precise links: `task`, `message`, `call`, `thread`,
`diagram`, `document`, `symbol`, `screen`, `board`.  Each resolves to
`resolved`, `stale` or `unsupported`, and `scene.read` reports that state
rather than a generic page in place of a precise one.

## Refusals

Every refusal carries one code, and the tool's answer says which:

| Code | When |
| --- | --- |
| `invalid-parameter` | a non-finite or out-of-range number, zero scale, a missing field, an unknown style key |
| `unknown-id` | an object, diagram, relationship or patch that is not there |
| `stale-revision` | the revision you read is not the document's revision |
| `unsupported-operation` | an operation or shape kind this grammar lacks |
| `precondition` | the operation does not fit its object |
| `hard-constraint` | a locked object, a scope violation, a movement over its budget |
| `invalid-reference` | a resource or an endpoint that names nothing |
| `permission` | this session may not write this board |

Diagnostics are warnings, not refusals: a text likely to overflow, an
object moving far, an overlap nobody declared.  The patch still stands.

## Traps worth knowing

- **The revision is the read set.** Read, edit and commit against the
  revision you actually read.  A commit whose read set moved is refused
  as `stale-revision` rather than applied over somebody else's work; read
  again and redo the batch on what is there.
- **A patch is not a commit.** `scene.edit` and `patch.preview` write
  nothing.  Nothing is on the board until `patch.commit` lands it.
- **The idempotency key is for retries.** After a lost answer, retry with
  the same `idempotencyKey` and the batch commits once.
- **`scope` holds you to a selection.** When a patch names `scope`, every
  object an operation touches must be in it, or the whole batch is
  refused before anything is written.  It is how unrelated geometry stays
  unmoved.
- **A pin is not an approval.** Pinning keeps a revision as a delivered
  artifact; it neither accepts the drawing nor approves code, and
  resolving a thread stays a third, separate action.
- **There is no search.** No tool generates, ranks or searches
  candidates, and nothing re-arranges a board on its own.  An agent
  reads, decides and edits.
- **Ids are yours to choose, or the tool's.** An object or diagram id is
  letters, digits and `.:-`; a fresh one is made when an operation leaves
  it out, and the patch answer says which.
