;;; harness-ui-pet-models.el --- Low-poly 3D models of the companion pet and its hats  -*- lexical-binding: t; -*-

;;; Commentary:

;; Data only: the models `harness-ui-pet-3d' builds and draws when the
;; companion pet turns about.  Nothing here runs.
;;
;; A model
;; -------
;; `harness-ui-pet-models' is an alist from a species, a symbol named
;; as in `harness-ui-pet--sprites', to its model, a plist:
;;
;;   (capybara
;;    :palette ((fur . "#a8774a") (light . "#c99d6f") (dark . "#5a3b22"))
;;    :head (0.0 1.95 0.35 0.62)
;;    :start 0
;;    :parts
;;    ((ball :at (0 0.8 -0.1) :size (0.85 0.65 1.0) :color fur)
;;     (ball :at (0.32 1.42 0.98) :size 0.085 :color eye :mirror t :detail t)
;;     (tube :at (0.45 0.18 0.5) :radius 0.17 :height 0.36 :color dark :mirror t)))
;;
;; :palette  the model's own colours, (NAME . "#rrggbb"), two to four
;;           soft natural ones.  Three more are shared by every model:
;;           `eye' "#1d1a21", `shine' "#ffffff" and `blush' "#f4a3b4".
;; :head     (X Y Z RADIUS): the top of the head, where a hat sits, and
;;           the head's radius, by which a hat is scaled.
;; :start    the degrees the model is turned at rest: 0 faces the
;;           viewer, -90 the viewer's left, 90 the right.  It is how
;;           the species's text art faces: duck, snail and turtle -90,
;;           goose 90, all others 0.
;; :parts    the parts the model is made of, in any order.
;;
;; Coordinates are model units, and a model lies roughly in x -1 to 1,
;; y 0 to 2.4 and z -1.2 to 1.2; the renderer fits it to its box anyway.
;; Its feet are on y = 0 and +y is up.  The animal faces +z, toward the
;; viewer at angle 0, and +x is the viewer's right.
;;
;; A part
;; ------
;; (KIND KEY VALUE...), each KIND a closed mesh with outward normals:
;;
;;   ball  an ellipsoid.  :size is its radius R or (RX RY RZ).  :half t
;;         keeps the half above its centre, closed with a flat disk, for
;;         domes and caps.  :sides N is the segments around, 12 unless
;;         given, fewer for small parts; it has max(4, 0.6 N) rings.
;;   box   :size (HX HY HZ), the half extents.
;;   tube  a frustum along y, :at its centre.  :radius is that of the
;;         bottom, :top that of the top (the same unless given, and 0
;;         makes a cone), :height its height and :sides N the segments
;;         around, 10 unless given.
;;   ring  a torus around y.  :radius runs to the middle of the tube,
;;         :thickness is the tube's radius and :sides N the segments
;;         around the ring (12 unless given).
;;
;; The keys every part takes:
;;
;;   :at (X Y Z)        its centre; (0 0 0) unless given.
;;   :turn (RX RY RZ)   degrees about the part's own centre, first about
;;                      x, then y, then z, each right-handed: +RX tips
;;                      the top toward the front, +RY turns the front
;;                      toward the right and +RZ tips the right side up.
;;   :color             a palette name, a literal "#rrggbb" or a shared
;;                      colour (`eye', `shine', `blush').
;;   :mirror t          adds a copy mirrored across x = 0, its turn
;;                      mirrored to match.  Leave it off a part that
;;                      sits on the middle, or the copy lies on top of it.
;;   :detail t          a small surface feature such as an eye, a
;;                      nostril or a spot.  It is drawn as if 0.06 units
;;                      nearer the viewer so it shows over what it sits
;;                      on, and it hides nothing.
;;   :flat t            not shaded: the eye's shine, a blush, glowing
;;                      eyes.
;;
;; How parts combine
;; -----------------
;; Parts may overlap, and should, so that nothing floats and there are
;; no gaps where parts meet: a leg runs into the body, an eye is half
;; sunk in the head.  A face with every corner inside the volume of
;; another part (a ball, a half ball, a box or a tube, but not a ring or
;; a detail) is never drawn, so what is buried costs nothing; one that is
;; only partly inside stays, or a hole would open along the seam.  A face
;; is a flat polygon, shaded by the light from the upper left front; a
;; part is faceted as many sides as it has, so fewer sides look more
;; toy-like.
;;
;; Faces are drawn in the order of a BSP tree, which puts every face
;; after those it hides, from any side, even where parts run into each
;; other: what shows is what is nearest.  So a feature that lies flat on
;; another, a band round a hat or a spot on a back, is hidden by it as
;; much as it is sunk into it, and shows only where it stands out; mark
;; it :detail, and it shows over what it sits on as if 0.06 units nearer
;; the viewer, while the part under it, if thicker than that, still hides
;; it from behind.  Where details lie over each other with no other face
;; between them, the one named later is drawn over: name the shine after
;; the eye.  Look at the model from every side all the same.
;;
;; The style: a cute low-poly toy
;; ------------------------------
;; Chibi proportions: a big head (45 to 60% of the height for those
;; with one), a small round body and short stubby limbs.  Balls, and
;; boxes only where the species is boxy, as the robot.  10 to 14 sides
;; for big balls and 6 to 8 for small parts, at most about 600 faces
;; per species before the hidden ones go.
;;
;; Eyes are `eye' balls of about 0.14 to 0.16 of the head's radius on
;; the front of the head, a little below its equator and about half
;; the head's radius from the middle line, marked :detail, with their
;; middle on the head's surface or a little in it.  Each has a `shine'
;; dot (about 0.35 of the eye's radius, :flat and :detail) on the eye's
;; front, up and toward the viewer's left: its middle on the eye's
;; surface or a little in it, 0.85 to 1 eye radius from the eye's middle
;; toward (-0.3 0.34 0.89), or the eye's own faces cut it.  It must stay
;; inside the head's outline at 90 degrees.  The eyes show at 0 and 45
;; degrees, and one of them at 90.  Soft species have a `blush' on the
;; cheeks: flattened balls, :flat and :detail, their middle on the surface.
;;
;; Colours: two to four soft natural ones plus the shared ones, a
;; darker shade of the main one for ears, feet and accents and a
;; lighter for bellies and snouts, of medium lightness so that they
;; read on a dark and on a light background.  Only the eyes are black.
;;
;; Nothing floats but what should (a halo, a hovering ghost), nothing
;; pokes through where it should not.  `harness-ui-pet-3d-problems'
;; looks for what can be found by the numbers.
;;
;; A hat
;; -----
;; `harness-ui-pet-hat-models' is an alist from the name of a hat, one
;; of those of `harness-ui-pet--hats', to a plist with the hat's
;; :parts, parts as above.  The coordinates are in units of the head's
;; radius, with the origin at the model's :head point, y up and the hat
;; facing +z.  The renderer scales a hat by that radius and moves it
;; there.  Its colours are literal "#rrggbb" or shared ones (a hat may
;; have a :palette of its own).
;;
;; The hats are made for a round head of radius 1 whose top is the origin,
;; so its middle is at (0 -1 0): a hat hugs that ball.  Where it is a
;; little wide or flat, as the capybara's, the hat goes on its top and
;; the rim of a band or crown sinks into it, out of sight.  So choose the
;; :head radius so that the hats sit well: about the head's half width.
;; The halo hovers 0.4 above the head; nothing else floats.  A hat is
;; best a few parts, a hundred or two faces, drawn as a toy: a band
;; round a crown is a :detail, a pompom a ball.
;;
;; Looking at a model
;; ------------------
;; A model is judged by its picture.  `harness-ui-pet-3d-svg' draws it as
;; an SVG, which an image viewer or a converter turns into a picture, and
;; `harness-ui-pet-3d-print-previews' prints a text map of it from a batch
;; Emacs, for the cases where there is no viewer.  Look at the real size
;; (about 160 by 100 pixels) as well as larger, and at a turn: the
;; front, a side and the back, with every hat.

;;; Code:

(defconst harness-ui-pet-models
  '(
    ;; DUCK  yellow rubber duck, facing left at rest.  A round body, a big round
    ;; head high at the front, a flat orange bill, a darker yellow wing on each
    ;; side, two orange feet, a pointed tail tuft.  3 colours.  503 faces.
    ;; The head is 53% of the height.
    (duck
     :palette ((body . "#f4cc3c") (wing . "#e2ab2b") (bill . "#ef8b2b"))
     :head (0.0 2.12 0.46 0.59)
     :start -90
     :parts
     ((ball :at (0 0.74 -0.12) :size (0.78 0.66 0.88) :color body)
      (ball :at (0 1.56 0.46) :size (0.6 0.56 0.58) :color body)
      ;; the bill
      (ball :at (0 1.47 1.04) :size (0.28 0.09 0.3) :color bill :sides 8)
      ;; the eyes, 44 degrees round from the front, and their shines
      (ball :at (0.408 1.635 0.854) :size (0.115 0.115 0.052) :color eye :mirror t :detail t :turn (-8 44 0) :sides 8)
      (ball :at (0.383 1.681 0.924) :size 0.037 :color shine :flat t :detail t :sides 6)
      (ball :at (-0.434 1.681 0.889) :size 0.037 :color shine :flat t :detail t :sides 6)
      ;; the wings, the feet and the tail
      (ball :at (0.74 0.84 -0.2) :size (0.1 0.27 0.38) :color wing :mirror t :turn (12 0 0) :sides 8)
      (ball :at (0.3 0.1 0.2) :size (0.18 0.1 0.3) :color bill :mirror t :sides 8)
      (tube :at (0 1.12 -1.0) :radius 0.2 :top 0 :height 0.42 :color body :turn (-40 0 0) :sides 6)))

    ;; GOOSE  white, facing right at rest.  A plump body, a neck in two tubes that
    ;; lean forward and then rise, a round head, an orange cone beak, grey folded
    ;; wings, orange legs and feet, a tail wedge.  3 colours.  512 faces.
    ;; The neck is the long part: the head is 37% of the height.
    (goose
     :palette ((body . "#e6e1d4") (wing . "#cdc8ba") (bill . "#ef8d2b"))
     :head (0.0 2.35 0.6 0.48)
     :start 90
     :parts
     ((ball :at (0 0.78 -0.12) :size (0.72 0.58 0.92) :color body)
      ;; the neck: the upper tube reaches 0.08 down into the lower one, which
      ;; hides the lower's top cap that would show as a ledge
      (tube :at (0 1.238 0.494) :radius 0.3 :top 0.265 :height 0.45 :color body :turn (14 0 0))
      (tube :at (0 1.5765 0.5447) :radius 0.272 :top 0.235 :height 0.4 :color body :turn (-2 0 0))
      (ball :at (0 1.91 0.6) :size (0.48 0.44 0.5) :color body)
      (tube :at (0 1.87 1.24) :radius 0.16 :top 0 :height 0.4 :color bill :turn (90 0 0) :sides 8)
      ;; the eyes, 51 degrees round from the front, and their shines
      (ball :at (0.354 1.969 0.909) :size (0.095 0.095 0.043) :color eye :mirror t :detail t :turn (-9 51 0) :sides 8)
      (ball :at (0.333 2.007 0.973) :size 0.03 :color shine :flat t :detail t :sides 6)
      (ball :at (-0.375 2.007 0.938) :size 0.03 :color shine :flat t :detail t :sides 6)
      ;; the wings, the legs, the feet and the tail
      (ball :at (0.66 0.9 -0.2) :size (0.12 0.3 0.55) :color wing :mirror t :turn (8 0 0) :sides 8)
      (tube :at (0.26 0.17 0.0) :radius 0.09 :height 0.34 :color bill :mirror t :sides 6)
      (ball :at (0.26 0.05 0.12) :size (0.17 0.06 0.26) :color bill :mirror t :sides 8)
      (tube :at (0 0.95 -0.97) :radius 0.22 :top 0 :height 0.45 :color body :turn (-72 0 0) :sides 6)))

    ;; blob: mint gumdrop slime: a dome on a darker, wider puddle, a glossy highlight
    ;; on the left shoulder, big eyes, a smile of five beads, blush
    (blob
     :palette ((slime . "#6bd9b5") (deep . "#3fb494") (gloss . "#eafff6") (mouth . "#1f6b5a"))
     :head (0 1.94 0 0.78)
     :start 0
     :parts
     ;; a gumdrop of slime: a dome on a wider puddle
     ((ball :at (0 0.46 0) :size (1.1 0.46 1.04) :color deep :sides 12)
      (ball :at (0 0.98 0) :size (0.98 0.96 0.92) :color slime :sides 12)

      ;; a glossy highlight on the left shoulder, below where any hat reaches
      (ball :at (-0.699 1.432 0.546) :size (0.17 0.055 0.03) :color gloss :sides 6 :turn (23.063 -49.925 -63.065) :detail t :flat t)
      (ball :at (-0.86 1.223 0.457) :size (0.05 0.05 0.03) :color gloss :sides 4 :turn (-14.142 -58.896 0) :detail t :flat t)

      ;; big eyes with a shine each, a small smile, blush
      (ball :at (0.388 1.096 0.807) :size (0.17 0.19 0.12) :color eye :sides 8 :turn (-6.954 22.963 0) :mirror t :detail t)
      (ball :at (0.319 1.165 0.905) :size (0.051 0.051 0.02) :color shine :sides 5 :turn (-21.152 -13.697 0) :detail t :flat t)
      (ball :at (-0.445 1.154 0.888) :size (0.051 0.051 0.02) :color shine :sides 5 :turn (-16.757 -28.831 0) :detail t :flat t)
      (ball :at (-0.14 0.86 0.903) :size 0.045 :color mouth :sides 4 :turn (6.893 -7.778 0) :detail t)
      (ball :at (-0.07 0.815 0.904) :size 0.045 :color mouth :sides 4 :turn (9.495 -3.904 0) :detail t)
      (ball :at (0 0.8 0.904) :size 0.045 :color mouth :sides 4 :turn (10.367 0 0) :detail t)
      (ball :at (0.07 0.815 0.904) :size 0.045 :color mouth :sides 4 :turn (9.495 3.904 0) :detail t)
      (ball :at (0.14 0.86 0.903) :size 0.045 :color mouth :sides 4 :turn (6.893 7.778 0) :detail t)
      (ball :at (0.707 0.928 0.687) :size (0.15 0.085 0.03) :color blush :sides 6 :turn (2.947 42.207 0) :mirror t :detail t :flat t)))

    ;; cat: a grey tabby sitting, front on: big wide head, cone ears with pink insides, pale muzzle with a
    ;; pink nose, a tiny smile and whiskers, little forehead stripes, haunches, front legs with pale paws,
    ;; and a tail rising beside the body on the right.  Eyes sit wide (0.63 of the head's radius) so the
    ;; shines stay inside the head's outline at 90 degrees.
    (cat
     :palette ((fur . "#8f9ab3")
               (light . "#e4e7f0")
               (dark . "#66718f")
               (nose . "#e8899f"))
     :head (0.0 2.16 0.1 0.8)
     :start 0
     :parts
     (;; the head, big and wide
      (ball :at (0 1.52 0.1) :size (0.8 0.64 0.68) :color fur :sides 12)
      ;; the body: a round egg with the haunches at its sides
      (ball :at (0 0.62 -0.1) :size (0.66 0.62 0.62) :color fur :sides 8)
      (ball :at (0.5 0.32 -0.18) :size (0.28 0.32 0.42) :color fur :sides 7 :mirror t)
      ;; ears, with pink insides
      (tube :at (0.52 2.14 0.0) :radius 0.27 :height 0.52 :color fur :top 0.0 :sides 4 :turn (6 0 -18) :mirror t)
      (tube :at (0.496 2.066 0.067) :radius 0.17 :height 0.38 :color blush :top 0.0 :sides 4 :turn (6.0 0.0 -18.0) :mirror t :detail t)
      ;; the muzzle and its pink nose
      (ball :at (0 1.26 0.62) :size (0.3 0.2 0.22) :color light :sides 8)
      (ball :at (0 1.35 0.83) :size (0.07 0.05 0.05) :color nose :sides 6 :detail t)
      ;; eyes with their shine
      (ball :at (0.51 1.467 0.583) :size 0.125 :color eye :mirror t :detail t :sides 8)
      (ball :at (0.476 1.505 0.684) :size 0.045 :color shine :flat t :detail t :sides 4)
      (ball :at (-0.544 1.505 0.684) :size 0.045 :color shine :flat t :detail t :sides 4)
      ;; cheeks
      (ball :at (0.664 1.301 0.4) :size (0.1 0.06 0.03) :color blush :turn (23.598 57.972 0.0) :flat t :detail t :sides 4 :mirror t)
      ;; tabby stripes on the forehead
      (box :at (0.0 2.008 0.499) :size (0.03 0.095 0.012) :color dark :turn (-52.151 0.0 0.0) :detail t)
      (box :at (0.235 2.008 0.446) :size (0.03 0.085 0.012) :color dark :turn (-56.448 13.032 -9.77) :detail t :mirror t)
      ;; a tiny mouth
      (box :at (0.045 1.225 0.817) :size (0.035 0.011 0.008) :color eye :turn (0.0 0.0 35.0) :detail t :mirror t)
      ;; whiskers
      (box :at (0.47 1.31 0.72) :size (0.2 0.009 0.009) :color light :turn (0 -6 8) :mirror t)
      (box :at (0.47 1.22 0.71) :size (0.2 0.009 0.009) :color light :turn (0 -6 -10) :mirror t)
      ;; front legs and paws
      (tube :at (0.25 0.32 0.3) :radius 0.14 :height 0.64 :color fur :top 0.13 :sides 6 :mirror t)
      (ball :at (0.25 0.0 0.5) :size (0.19 0.17 0.24) :color light :half t :sides 6 :mirror t)
      ;; the tail rising beside the body on the right
      (tube :at (0.46 0.254 -0.516) :radius 0.14 :height 0.394 :color fur :top 0.134 :turn (-25.104 0.0 -88.242) :sides 6)
      (tube :at (0.707 0.307 -0.612) :radius 0.134 :height 0.324 :color fur :top 0.129 :turn (-14.835 0.0 -65.638) :sides 6)
      (tube :at (0.888 0.437 -0.648) :radius 0.129 :height 0.297 :color fur :top 0.123 :turn (-2.546 0.0 -41.922) :sides 6)
      (tube :at (1.0 0.623 -0.64) :radius 0.123 :height 0.297 :color fur :top 0.117 :turn (6.697 0.0 -20.594) :sides 6)
      (tube :at (1.043 0.842 -0.605) :radius 0.117 :height 0.306 :color fur :top 0.111 :turn (11.108 0.0 -2.077) :sides 6)
      (tube :at (1.016 1.074 -0.558) :radius 0.111 :height 0.312 :color fur :top 0.106 :turn (11.303 0.0 15.135) :sides 6)
      (tube :at (0.917 1.295 -0.517) :radius 0.106 :height 0.316 :color fur :top 0.1 :turn (7.733 0.0 32.636) :sides 6)
      (ball :at (0.85 1.4 -0.5) :size 0.105 :color dark :sides 6)))

    ;; dragon: a green baby dragon facing the viewer (:start 0), 533 faces, 444 drawn.
    ;; A big round head with two cream horns and a pale snout, two big eyes with shines, a pale round
    ;; tummy, two bat-like wings (two flat triangles each), spikes down the back, a tail that curls up
    ;; into a point and four stubby legs.  scale = body, dark = wings, spikes, nostrils and legs,
    ;; belly = tummy and snout, horn = the horns.  Hats sit between the horns.
    (dragon
     :palette ((scale . "#5cad5a") (dark . "#3b7f46") (belly . "#dfe08f") (horn . "#f0e2b4"))
     :head (0 2.28 0.12 0.66)
     :start 0
     :parts
     ((ball :at (0 0.82 -0.05) :size (0.7 0.72 0.72) :color scale :sides 10)
      ;; the head, big and round
      (ball :at (0 1.62 0.12) :size (0.72 0.66 0.68) :color scale :sides 12)
      ;; a pale round tummy; a pale snout with two nostrils
      (ball :at (0 0.74 0.3) :size (0.52 0.55 0.5) :color belly :sides 10)
      (ball :at (0 1.47 0.8) :size (0.34 0.25 0.27) :color belly :sides 8)
      (ball :at (0.1 1.56 1.03) :size (0.045 0.03 0.03) :color dark :mirror t :detail t :sides 4)
      ;; eyes with shines
      (ball :at (0.36 1.66 0.67) :size 0.105 :color eye :mirror t :detail t :sides 8)
      (ball :at (0.313 1.712 0.733) :size 0.037 :color shine :flat t :detail t :sides 4)
      (ball :at (-0.407 1.712 0.733) :size 0.037 :color shine :flat t :detail t :sides 4)
      ;; two horns, out and back
      (tube :at (0.452 2.294 -0.092) :radius 0.12 :top 0 :height 0.5 :turn (39 135 0) :color horn :sides 6
            :mirror t)
      ;; spikes down the back
      (tube :at (0 2.065 -0.546) :radius 0.1 :top 0 :height 0.3 :turn (40 180 0) :color dark :sides 6)
      (tube :at (0 1.364 -0.692) :radius 0.1 :top 0 :height 0.28 :turn (53 180 0) :color dark :sides 6)
      (tube :at (0 1.052 -0.848) :radius 0.1 :top 0 :height 0.26 :turn (56.5 180 0) :color dark :sides 6)
      (tube :at (0 0.735 -0.865) :radius 0.09 :top 0 :height 0.22 :turn (60 180 0) :color dark :sides 6)
      ;; little wings: flat triangles leaning out and back
      (tube :at (0.64 1.3 -0.5) :radius 0.56 :height 0.04 :sides 3 :color dark :mirror t :turn (90 25 -45))
      (tube :at (0.8 1.12 -0.47) :radius 0.36 :height 0.04 :sides 3 :color dark :mirror t :turn (90 25 -85))
      ;; stubby legs
      (tube :at (0.4 0.16 0.38) :radius 0.17 :height 0.34 :color dark :mirror t :sides 8)
      (tube :at (0.46 0.16 -0.35) :radius 0.18 :height 0.34 :color dark :mirror t :sides 8)
      ;; a tail that curls up into a point
      (tube :at (0 0.459 -0.872) :radius 0.3 :top 0.14 :height 0.55 :turn (98.5 180 0) :color scale :sides 8)
      (ball :at (0 0.417 -1.15) :size 0.14 :color scale :sides 6)
      (tube :at (0 0.672 -1.252) :radius 0.14 :top 0 :height 0.55 :turn (22 180 0) :color scale :sides 8)))

    ;; octopus: a purple-pink dome with eight curling tentacles (:start 0), 532 faces, 500 drawn.
    ;; A big round dome (the head and mantle in one, about three quarters of the height) with big
    ;; eyes low on its face, each with a shine, a small smile and a blush, and eight chunky
    ;; tentacles, each four tapering pieces that curl out and up at the tip, in four mirrored pairs.
    ;; skin = everything, dark = the smile.  The tentacle tips are on y = 0.02.
    (octopus
     :palette ((skin . "#c870b4") (dark . "#8a3f86"))
     :head (0 2.18 0 0.85)
     :start 0
     :parts
     ((ball :at (0 1.26 0) :size (0.85 0.92 0.85) :color skin :sides 12)
      ;; eyes low on the face, with shines
      (ball :at (0.42 1.09 0.665) :size 0.14 :color eye :mirror t :detail t :sides 8)
      (ball :at (0.357 1.159 0.749) :size 0.049 :color shine :flat t :detail t :sides 4)
      (ball :at (-0.483 1.159 0.749) :size 0.049 :color shine :flat t :detail t :sides 4)
      ;; a small smile and a blush
      (ball :at (0.075 0.83 0.74) :size (0.07 0.022 0.03) :color dark :detail t :sides 4 :mirror t
            :turn (0 0 25))
      (ball :at (0.62 0.93 0.49) :size (0.1 0.06 0.04) :color blush :flat t :detail t :mirror t
            :turn (0 55 0) :sides 6)
      ;; eight tentacles curling out and up
      (tube :at (0.156 0.458 0.377) :radius 0.23 :top 0.19 :height 0.28 :turn (160 22.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.214 0.24 0.517) :radius 0.19 :top 0.15 :height 0.27 :turn (130 22.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.303 0.135 0.731) :radius 0.15 :top 0.11 :height 0.26 :turn (98 22.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.395 0.182 0.954) :radius 0.11 :top 0.06 :height 0.26 :turn (60 22.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.377 0.458 0.156) :radius 0.23 :top 0.19 :height 0.28 :turn (160 67.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.517 0.24 0.214) :radius 0.19 :top 0.15 :height 0.27 :turn (130 67.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.731 0.135 0.303) :radius 0.15 :top 0.11 :height 0.26 :turn (98 67.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.954 0.182 0.395) :radius 0.11 :top 0.06 :height 0.26 :turn (60 67.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.377 0.458 -0.156) :radius 0.23 :top 0.19 :height 0.28 :turn (160 112.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.517 0.24 -0.214) :radius 0.19 :top 0.15 :height 0.27 :turn (130 112.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.731 0.135 -0.303) :radius 0.15 :top 0.11 :height 0.26 :turn (98 112.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.954 0.182 -0.395) :radius 0.11 :top 0.06 :height 0.26 :turn (60 112.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.156 0.458 -0.377) :radius 0.23 :top 0.19 :height 0.28 :turn (160 157.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.214 0.24 -0.517) :radius 0.19 :top 0.15 :height 0.27 :turn (130 157.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.303 0.135 -0.731) :radius 0.15 :top 0.11 :height 0.26 :turn (98 157.5 0) :color skin
            :sides 6 :mirror t)
      (tube :at (0.395 0.182 -0.954) :radius 0.11 :top 0.06 :height 0.26 :turn (60 157.5 0) :color skin
            :sides 6 :mirror t)))

    ;; OWL  a brown egg that is body and head at once.  Two cream facial discs with
    ;; big eyes, a small orange cone beak pointing down, a cream belly, two ear
    ;; tufts, a dark wing on each side, orange feet, a dark tail.  4 colours.
    ;; 520 faces.  The tufts are short, so that every hat covers them or has them
    ;; beside it, none pokes through a hat.
    (owl
     :palette ((fur . "#8d6641") (light . "#e6cfa3") (dark . "#5e4129") (orange . "#f0a030"))
     :head (0.0 2.08 0.0 0.8)
     :start 0
     :parts
     ((ball :at (0 1.1 0) :size (0.9 0.98 0.84) :color fur)
      ;; the belly and the facial discs, fat enough to poke 0.12 out
      (ball :at (0 0.72 0.6) :size (0.5 0.48 0.3) :color light :sides 8)
      (ball :at (0.4 1.5 0.52) :size (0.42 0.42 0.24) :color light :mirror t :turn (0 22 0) :sides 8)
      ;; the eyes on the discs, and their shines
      (ball :at (0.49 1.5 0.742) :size (0.17 0.17 0.102) :color eye :mirror t :detail t :turn (0 22 0) :sides 8)
      (ball :at (0.453 1.568 0.846) :size 0.054 :color shine :flat t :detail t :sides 6)
      (ball :at (-0.527 1.568 0.828) :size 0.054 :color shine :flat t :detail t :sides 6)
      ;; the beak, the tufts, the wings, the feet and the tail
      (tube :at (0 1.225 0.93) :radius 0.13 :top 0 :height 0.3 :color orange :turn (120 0 0) :sides 6)
      (tube :at (0.58 1.95 0.0) :radius 0.15 :top 0 :height 0.34 :color dark :mirror t :turn (0 0 -24) :sides 6)
      (ball :at (0.86 0.98 -0.06) :size (0.11 0.42 0.34) :color dark :mirror t :turn (0 0 -14) :sides 8)
      (ball :at (0.3 0.12 0.2) :size (0.18 0.12 0.3) :color orange :mirror t :sides 8)
      (tube :at (0 0.5 -0.76) :radius 0.25 :top 0 :height 0.42 :color dark :turn (-120 0 0) :sides 6)))

    ;; PENGUIN  a navy egg of a body with a big round head, a white belly, a white
    ;; patch round each eye, an orange beak and feet, a flipper on each side, a
    ;; small tail.  3 colours.  522 faces.  The head is 53% of the height.
    (penguin
     :palette ((navy . "#445889") (white . "#f1efe8") (orange . "#f2932b"))
     :head (0.0 2.32 0.06 0.76)
     :start 0
     :parts
     ((ball :at (0 0.95 -0.02) :size (0.82 0.88 0.74) :color navy)
      (ball :at (0 1.7 0.06) :size (0.78 0.62 0.72) :color navy :sides 10)
      ;; the belly and the white patches turned 22 degrees outward
      (ball :at (0 0.84 0.54) :size (0.56 0.7 0.34) :color white :sides 10)
      (ball :at (0.33 1.62 0.58) :size (0.3 0.3 0.2) :color white :mirror t :turn (0 22 0) :sides 8)
      ;; the eyes on the patches, and their shines
      (ball :at (0.405 1.62 0.765) :size (0.115 0.115 0.063) :color eye :mirror t :detail t :turn (0 22 0) :sides 8)
      (ball :at (0.38 1.666 0.831) :size 0.037 :color shine :flat t :detail t :sides 6)
      (ball :at (-0.43 1.666 0.817) :size 0.037 :color shine :flat t :detail t :sides 6)
      ;; the beak, the flippers, the feet and the tail
      (tube :at (0 1.55 0.9) :radius 0.14 :top 0 :height 0.32 :color orange :turn (100 0 0) :sides 6)
      (ball :at (0.86 1.0 0.0) :size (0.1 0.46 0.24) :color navy :mirror t :turn (0 0 20) :sides 6)
      (ball :at (0.3 0.1 0.2) :size (0.22 0.1 0.34) :color orange :mirror t :sides 6)
      (tube :at (0 0.3 -0.8) :radius 0.2 :top 0 :height 0.4 :color navy :turn (-107 0 0) :sides 6)))

    ;; turtle: seen from its side at rest, facing the viewer's left (:start -90), 373 faces,
    ;; 323 drawn.  A faceted dome shell (a 10-sided half ball) with a darker rim over a plump tan body,
    ;; a round head poking out in front with two eyes, each with a shine, and a small smile, four
    ;; stubby legs and a little tail.  shell = the dome, dark = the rim and the smile, skin = head,
    ;; legs and tail, belly = the body under the shell.  At 90 degrees it faces the viewer.
    ;; Hats sit on its head, not on the shell.  Centred along its length on the spin axis
    ;; (z -1.45 to 1.45), so that it sits in the middle of its box at rest.
    (turtle
     :palette ((shell . "#3f8a4c") (dark . "#2a5f38") (skin . "#9ccc70") (belly . "#e8dca0"))
     :head (0 1.25 1.01 0.42)
     :start -90
     ;; the plump body under the shell
     :parts
     ((ball :at (0 0.35 -0.19) :size (0.92 0.3 1.02) :color belly :sides 10)
      ;; the dome shell and its dark rim
      (ball :at (0 0.42 -0.19) :size (1 0.85 1.12) :half t :color shell :sides 10)
      (ball :at (0 0.38 -0.19) :size (1.06 0.2 1.18) :half t :color dark :sides 10)
      ;; the head poking out in front
      (ball :at (0 0.85 1.01) :size (0.42 0.4 0.46) :color skin :sides 10)
      ;; eyes, each with its shine
      (ball :at (0.27 0.885 1.36) :size 0.09 :color eye :mirror t :detail t :sides 8)
      (ball :at (0.324 0.93 1.4) :size 0.032 :color shine :flat t :detail t :sides 4)
      (ball :at (-0.216 0.93 1.4) :size 0.032 :color shine :flat t :detail t :sides 4)
      ;; a small smile
      (ball :at (0.07 0.69 1.425) :size (0.07 0.02 0.03) :color dark :detail t :sides 4 :mirror t
            :turn (0 0 25))
      ;; four stubby legs and a tail
      (tube :at (0.6 0.17 0.48) :radius 0.22 :height 0.35 :color skin :mirror t :sides 8)
      (tube :at (0.6 0.17 -0.84) :radius 0.22 :height 0.35 :color skin :mirror t :sides 8)
      (tube :at (0 0.327 -1.347) :radius 0.11 :top 0 :height 0.22 :turn (76 180 0) :color skin :sides 6)))

    ;; snail: facing the viewer's left at rest (:start -90), 492 faces, 451 drawn.
    ;; A soft low body, a round head with a small smile, two eye stalks standing up from the face
    ;; (the near one leaning further forward, so both eyes show from the side) with a big eye on
    ;; each end, and a brown-orange shell, a ball with two spiral rings on each side.  The stalks
    ;; are not mirror images, on purpose.  body = body, head and stalks, shell = the shell,
    ;; swirl = the rings and the smile.  Hats sit on the head between the stalks.  Centred along
    ;; its length on the spin axis (z -1.43 to 1.43), so that it sits in the middle of its box at rest.
    (snail
     :palette ((body . "#dcb98a") (shell . "#c4642c") (swirl . "#7e3b1d"))
     :head (0 1.12 0.71 0.37)
     :start -90
     ;; a soft low body and a round head
     :parts
     ((ball :at (0 0.34 -0.29) :size (0.5 0.36 1.2) :color body :sides 10)
      (ball :at (0 0.72 0.71) :size (0.4 0.4 0.42) :color body :sides 10)
      ;; eye stalks standing up from the face, the near one leaning further forward
      (tube :at (0.179 1.161 1.153) :radius 0.07 :top 0.055 :height 0.6 :turn (29.5 15.5 0) :color body
            :sides 6)
      (tube :at (-0.181 1.171 1.037) :radius 0.07 :top 0.055 :height 0.55 :turn (10 -56.5 0) :color body
            :sides 6)
      ;; eyes on the stalks' ends
      (ball :at (0.223 1.457 1.316) :size 0.13 :color eye :detail t :sides 8)
      (ball :at (-0.227 1.481 1.068) :size 0.13 :color eye :detail t :sides 8)
      (ball :at (0.301 1.521 1.374) :size 0.046 :color shine :flat t :detail t :sides 4)
      (ball :at (-0.149 1.545 1.126) :size 0.046 :color shine :flat t :detail t :sides 4)
      ;; a small smile
      (ball :at (0.065 0.575 1.085) :size (0.07 0.02 0.03) :color swirl :detail t :sides 4 :mirror t
            :turn (0 0 25))
      ;; the shell: a ball with spiral rings on both sides
      (ball :at (0 1 -0.54) :size (0.5 0.72 0.72) :color shell :sides 12)
      (ring :at (0.35 1 -0.54) :radius 0.5 :thickness 0.05 :color swirl :sides 8 :turn (0 0 90) :mirror t)
      (ring :at (0.46 1.04 -0.56) :radius 0.25 :thickness 0.05 :color swirl :sides 8 :turn (0 0 90)
            :mirror t)))

    ;; ghost: pale lilac, hovering a little over a flat shadow: a dome for head and
    ;; body, a flared skirt, a hem of eight hanging scallops, little arms up in the
    ;; air, tall oval eyes, an o, blush
    (ghost
     :palette ((body . "#c9cdf6") (shade . "#aeb3ec") (mouth . "#4b3f72") (floor . "#50546b"))
     :head (0 1.92 0 0.85)
     :start 0
     :parts
     ;; a pale ghost hovering over its shadow: a round dome for head and body, a skirt that
     ;; flares a little, and a hem of eight round scallops hanging from the skirt's rim
     ((ball :at (0 1.12 0) :size (0.86 0.8 0.86) :color body :sides 12)
      (tube :at (0 0.81 0) :radius 0.95 :top 0.838 :height 0.62 :color body :sides 12)
      (ball :at (0 0.5 0.62) :size (0.3 0.4 0.3) :color body :half t :sides 8 :turn (180 0 0))
      (ball :at (0.438 0.5 0.438) :size (0.3 0.4 0.3) :color body :half t :sides 8 :turn (180 0 0) :mirror t)
      (ball :at (0.62 0.5 0) :size (0.3 0.4 0.3) :color body :half t :sides 8 :turn (180 0 0) :mirror t)
      (ball :at (0.438 0.5 -0.438) :size (0.3 0.4 0.3) :color body :half t :sides 8 :turn (180 0 0) :mirror t)
      (ball :at (0 0.5 -0.62) :size (0.3 0.4 0.3) :color body :half t :sides 8 :turn (180 0 0))

      ;; little arms, up in the air
      (ball :at (0.95 1.16 0.05) :size (0.16 0.28 0.16) :color shade :sides 6 :turn (0 0 -38) :mirror t)

      ;; the face: tall oval eyes with a shine each, a little o, blush
      (ball :at (0.33 1.275 0.748) :size (0.14 0.2 0.11) :color eye :sides 8 :turn (-12.376 23.797 0) :mirror t :detail t)
      (ball :at (0.27 1.335 0.833) :size (0.042 0.042 0.017) :color shine :sides 5 :turn (-18.821 -18.236 0) :detail t :flat t)
      (ball :at (-0.381 1.327 0.821) :size (0.042 0.042 0.017) :color shine :sides 5 :turn (-17.912 -30.415 0) :detail t :flat t)
      (ball :at (0 0.92 0.833) :size (0.085 0.11 0.04) :color mouth :sides 6 :turn (15.513 0 0) :detail t :flat t)
      (ball :at (0.645 1.037 0.613) :size (0.14 0.08 0.03) :color blush :sides 6 :turn (6.166 46.432 0) :mirror t :detail t :flat t)

      ;; the shadow it hovers over: the hem is within a hair of it, so it counts as touching
      (tube :at (0 0.015 0) :radius 0.98 :height 0.03 :color floor :sides 16 :flat t)))

    ;; axolotl: pink, a wide low head with eyes set wide, a smile, blush, three feathery gills a side
    ;; (darker pink), a low body, four stubby legs, and a paddle tail with a darker fin on its top.
    (axolotl
     :palette ((skin . "#f4a9c4")
               (gill . "#e0709b")
               (deep . "#a83a66"))
     :head (0.0 1.42 0.3 0.8)
     :start 0
     :parts
     (;; wide head, low body, paddle tail
      (ball :at (0 0.8 0.3) :size (0.98 0.62 0.82) :color skin :sides 12)
      (ball :at (0 0.44 -0.4) :size (0.62 0.44 0.8) :color skin :sides 10)
      (ball :at (0 0.47 -0.95) :size (0.14 0.5 0.38) :color skin :sides 8 :turn (90 0 0))
      (ball :at (0 0.8 -0.95) :size (0.03 0.4 0.13) :color gill :sides 6 :turn (90 0 0))
      ;; four stubby legs
      (ball :at (0.6 0.0 0.55) :size (0.24 0.4 0.3) :color skin :half t :sides 6 :mirror t)
      (ball :at (0.52 0.0 -0.6) :size (0.24 0.34 0.3) :color skin :half t :sides 6 :mirror t)
      ;; three gills a side
      (ball :at (0.874 1.251 0.145) :size (0.09 0.31 0.09) :color gill :sides 6 :turn (-11.31 0.0 -28.0) :mirror t)
      (ball :at (1.043 0.959 0.037) :size (0.09 0.31 0.09) :color gill :sides 6 :turn (-11.31 0.0 -62.0) :mirror t)
      (ball :at (0.994 0.628 -0.044) :size (0.09 0.31 0.09) :color gill :sides 6 :turn (-11.31 0.0 -96.0) :mirror t)
      ;; eyes
      (ball :at (0.615 0.989 0.846) :size 0.13 :color eye :mirror t :detail t :sides 8)
      (ball :at (0.58 1.028 0.95) :size 0.047 :color shine :flat t :detail t :sides 4)
      (ball :at (-0.65 1.028 0.95) :size 0.047 :color shine :flat t :detail t :sides 4)
      ;; blush
      (ball :at (0.785 0.671 0.76) :size (0.1 0.06 0.03) :color blush :turn (17.461 50.076 0.0) :flat t :detail t :sides 4 :mirror t)
      ;; a smile, three strokes on the front facets
      (box :at (0.0 0.538 0.996) :size (0.2 0.03 0.012) :color deep :turn (31.601 0.0 0.0) :detail t)
      (box :at (0.416 0.538 0.903) :size (0.2 0.03 0.012) :color deep :turn (37.213 17.739 12.355) :detail t :mirror t)))

    ;; capybara: a brown barrel of a body, a big blunt head with a lighter snout and two
    ;; nostrils, tiny round ears and short legs.  Front on, as its text art is.
    (capybara
     :palette ((fur . "#a8774a") (light . "#c99d6f") (dark . "#5a3b22") (nose . "#2e1d14"))
     :head (0.0 1.93 0.42 0.72)
     :start 0
     :parts
     ((ball :at (0 0.88 -0.22) :size (0.80 0.70 0.90) :color fur)
      ;; the head, a wide blunt loaf
      (ball :at (0 1.35 0.42) :size (0.74 0.58 0.80) :color fur)
      ;; the muzzle, lighter, and its two nostrils on top of it
      (ball :at (0 1.19 1.12) :size (0.46 0.33 0.30) :color light :sides 10)
      (ball :at (0.14 1.37 1.32) :size (0.08 0.055 0.05) :color nose :mirror t :detail t :sides 6
            :turn (0 0 -20))
      ;; small eyes, high and wide, each with its shine: a dot a little in the
      ;; eye's surface, toward (-0.3 0.34 0.89) from the eye's middle
      (ball :at (0.40 1.47 1.03) :size 0.1 :color eye :mirror t :detail t :sides 8)
      (ball :at (0.3745 1.499 1.1057) :size 0.035 :color shine :flat t :detail t :sides 6)
      (ball :at (-0.4255 1.499 1.1057) :size 0.035 :color shine :flat t :detail t :sides 6)
      ;; a faint blush
      (ball :at (0.59 1.27 0.825) :size (0.09 0.055 0.035) :color blush :flat t :detail t :mirror t
            :turn (0 50 0) :sides 6)
      ;; tiny round ears
      (ball :at (0.56 1.76 0.15) :size (0.12 0.14 0.08) :color dark :mirror t :turn (0 0 -35) :sides 8)
      ;; four short legs
      (tube :at (0.42 0.17 0.30) :radius 0.17 :height 0.34 :color dark :mirror t :sides 8)
      (tube :at (0.44 0.17 -0.60) :radius 0.17 :height 0.34 :color dark :mirror t :sides 8)))

    ;; cactus: green ribbed barrel in a terracotta pot (rim, soil), two bent arms, cream
    ;; spine tufts, eyes with blush, a pink flower on the left arm's tip
    (cactus
     :palette ((green . "#4fa75e") (dark . "#24572b") (pot . "#c76a43") (rim . "#d9815a") (soil . "#6d4d3a") (bloom . "#f27ca4") (cream . "#f7e9a6"))
     :head (0 2.45 0 0.66)
     :start 0
     :parts
     ;; a terracotta pot with a rim and soil
     ((tube :at (0 0.28 0) :radius 0.56 :top 0.68 :height 0.56 :color pot :sides 10)
      (tube :at (0 0.56 0) :radius 0.76 :height 0.16 :color rim :sides 10)
      (tube :at (0 0.645 0) :radius 0.66 :height 0.03 :color soil :sides 10 :detail t)

      ;; a ribbed barrel of a cactus with a domed top, and two bent arms
      (tube :at (0 1.25 0) :radius 0.66 :height 1.2 :color green :sides 8)
      (ball :at (0 1.85 0) :size (0.66 0.6 0.66) :color green :half t :sides 8)
      (tube :at (0.775 1.05 0) :radius 0.2 :height 0.55 :color green :sides 8 :turn (0 0 90) :mirror t)
      (ball :at (1.05 1.05 0) :size 0.21 :color green :sides 6 :mirror t)
      (tube :at (1.05 1.42 0) :radius 0.2 :height 0.74 :color green :sides 8 :mirror t)
      (ball :at (1.05 1.79 0) :size (0.2 0.19 0.2) :color green :half t :sides 8 :mirror t)

      ;; the face, on the ribs of the barrel
      (ball :at (0.33 1.62 0.524) :size 0.11 :color eye :sides 8 :mirror t :detail t)
      (ball :at (0.281 1.67 0.595) :size (0.037 0.037 0.015) :color shine :sides 5 :turn (-30 -35 0) :detail t :flat t)
      (ball :at (-0.379 1.67 0.595) :size (0.037 0.037 0.015) :color shine :sides 5 :turn (-30 -35 0) :detail t :flat t)
      (ball :at (-0.09 1.39 0.615) :size 0.034 :color dark :sides 4 :detail t)
      (ball :at (0 1.355 0.615) :size 0.034 :color dark :sides 4 :detail t)
      (ball :at (0.09 1.39 0.615) :size 0.034 :color dark :sides 4 :detail t)
      (ball :at (0.508 1.45 0.371) :size (0.11 0.065 0.03) :color blush :sides 6 :turn (0 45 0) :mirror t :detail t :flat t)

      ;; cream tufts of spines on the ribs
      (box :at (0.256 0.98 0.619) :size (0.035 0.035 0.01) :color cream :turn (16.325 15.7 47.266) :mirror t :detail t :flat t)
      (box :at (0.256 1.2 0.619) :size (0.035 0.035 0.01) :color cream :turn (16.325 15.7 47.266) :mirror t :detail t :flat t)
      (box :at (0.619 0.98 0.256) :size (0.035 0.035 0.01) :color cream :turn (59.639 40.789 69.059) :mirror t :detail t :flat t)
      (box :at (0.619 1.2 0.256) :size (0.035 0.035 0.01) :color cream :turn (59.639 40.789 69.059) :mirror t :detail t :flat t)

      ;; a pink flower on the tip of the left arm
      (ball :at (-0.9 2.04 0.05) :size 0.095 :color bloom :sides 4)
      (ball :at (-1.004 2.126 -0.064) :size 0.095 :color bloom :sides 4)
      (ball :at (-1.171 2.093 -0.021) :size 0.095 :color bloom :sides 4)
      (ball :at (-1.171 1.987 0.121) :size 0.095 :color bloom :sides 4)
      (ball :at (-1.004 1.954 0.164) :size 0.095 :color bloom :sides 4)
      (ball :at (-1.05 2.064 0.068) :size 0.075 :color cream :sides 4)))

    ;; robot: grey toy robot: a flat-topped twelve-sided head on a box body, two dark
    ;; eye plates with glowing cyan eyes, a grille, a chest panel with three lights,
    ;; gold ears, a red-tipped antenna out of the head's left side, a wind-up key in the
    ;; back.  The head is a prism, not a box: a face is sorted by its middle, so the far
    ;; eye of a box head would be hidden as the robot turns; with twelve sides each eye
    ;; sits in the middle of a face of its own.
    (robot
     :palette ((steel . "#9aa4b2") (iron . "#6b7482") (panel . "#3a4152") (glow . "#5ee6f2") (red . "#e5484d") (gold . "#f2c230"))
     :head (0 2.2 0 0.8)
     :start 0
     :parts
     ;; a grey toy robot: a flat-topped faceted head on a small box body.  The head has twelve
     ;; sides, so each eye sits in the middle of a narrow face of its own; a flat box front would
     ;; hide the far eye as the robot turns, because a face is sorted by its middle.
     ((tube :at (0 1.56 0) :radius 0.98 :height 1.28 :color steel :sides 12)
      (box :at (0 0.58 0) :size (0.56 0.42 0.46) :color steel)
      (box :at (0.3 0.12 0.08) :size (0.24 0.12 0.34) :color iron :mirror t)

      ;; arms: a shoulder, a bar and a hand
      (ball :at (0.72 0.9 0) :size 0.16 :color iron :sides 8 :mirror t)
      (tube :at (0.76 0.62 0) :radius 0.13 :height 0.56 :color steel :sides 8 :mirror t)
      (ball :at (0.78 0.36 0) :size 0.16 :color iron :sides 8 :mirror t)

      ;; the face: two dark square eye plates, each with a glowing eye and its shine, and a
      ;; grille with bars on the middle face
      (box :at (0.488 1.68 0.846) :size (0.19 0.22 0.03) :color panel :turn (0 30 0) :mirror t :detail t)
      (ball :at (0.511 1.68 0.885) :size (0.14 0.14 0.05) :color glow :sides 8 :turn (0 30 0) :mirror t :detail t :flat t)
      (ball :at (0.465 1.727 0.951) :size (0.048 0.048 0.019) :color shine :sides 5 :turn (-9.541 14.702 0) :detail t :flat t)
      (ball :at (-0.537 1.706 0.922) :size (0.048 0.048 0.019) :color shine :sides 5 :turn (-4.228 -30.639 0) :detail t :flat t)
      (box :at (0 1.14 0.987) :size (0.2 0.11 0.04) :color panel :detail t)
      (box :at (-0.1 1.14 1.037) :size (0.017 0.08 0.012) :color steel :detail t)
      (box :at (-0.033 1.14 1.037) :size (0.017 0.08 0.012) :color steel :detail t)
      (box :at (0.033 1.14 1.037) :size (0.017 0.08 0.012) :color steel :detail t)
      (box :at (0.1 1.14 1.037) :size (0.017 0.08 0.012) :color steel :detail t)

      ;; a chest panel with three lights
      (box :at (0 0.66 0.465) :size (0.26 0.17 0.02) :color panel :detail t)
      (ball :at (-0.1 0.66 0.485) :size 0.06 :color red :sides 5 :detail t :flat t)
      (ball :at (0 0.66 0.485) :size 0.06 :color gold :sides 5 :detail t :flat t)
      (ball :at (0.1 0.66 0.485) :size 0.06 :color glow :sides 5 :detail t :flat t)

      ;; a wind-up key in the back
      (tube :at (0 0.7 -0.56) :radius 0.05 :height 0.2 :color iron :sides 6 :turn (90 0 0))
      (ring :at (0 0.7 -0.7) :radius 0.17 :thickness 0.045 :color gold :sides 8 :turn (90 0 0))

      ;; round ears on the sides, and an antenna out of the head's left side
      (tube :at (0.99 1.5 0) :radius 0.2 :height 0.24 :color gold :sides 8 :turn (0 0 90) :mirror t)
      (tube :at (-0.972 2.276 0) :radius 0.04 :height 0.5 :color iron :sides 6 :turn (0 0 36.87))
      (ball :at (-1.14 2.5 0) :size 0.12 :color red :sides 8)))

    ;; rabbit: cream, a round body under a bigger round head, long ears (pink inside) set well apart and
    ;; leaning back, a pink nose on a pale muzzle, blush, a cotton tail, big pale hind feet.  Its hats are
    ;; scaled small (:head radius 0.58) so they sit between the ears.
    (rabbit
     :palette ((fur . "#e8d7bc")
               (light . "#fbf5ea")
               (pink . "#f5aebf"))
     :head (0.0 2.25 0.12 0.58)
     :start 0
     :parts
     (;; round body, bigger round head
      (ball :at (0 0.66 -0.08) :size (0.76 0.68 0.72) :color fur :sides 10)
      (ball :at (0 1.55 0.12) :size (0.86 0.7 0.74) :color fur :sides 12)
      ;; ears, pink inside
      (ball :at (0.5 2.4 -0.02) :size (0.19 0.46 0.1) :color fur :sides 6 :turn (-8 0 -16) :mirror t)
      (ball :at (0.497 2.391 0.057) :size (0.105 0.34 0.045) :color pink :sides 6 :turn (-8.0 0.0 -16.0) :mirror t :detail t)
      ;; muzzle and nose
      (ball :at (0 1.4 0.68) :size (0.3 0.2 0.22) :color light :sides 8)
      (ball :at (0 1.5 0.88) :size (0.07 0.05 0.05) :color pink :sides 6 :detail t)
      ;; eyes
      (ball :at (0.535 1.527 0.662) :size 0.125 :color eye :mirror t :detail t :sides 8)
      (ball :at (0.501 1.565 0.762) :size 0.045 :color shine :flat t :detail t :sides 4)
      (ball :at (-0.569 1.565 0.762) :size 0.045 :color shine :flat t :detail t :sides 4)
      ;; cheeks
      (ball :at (0.694 1.334 0.493) :size (0.1 0.06 0.03) :color blush :turn (20.851 54.013 0.0) :flat t :detail t :sides 4 :mirror t)
      ;; cotton tail
      (ball :at (0 0.55 -0.82) :size 0.25 :color light :sides 8)
      ;; feet
      (ball :at (0.46 0.16 0.45) :size (0.22 0.17 0.42) :color light :sides 6 :mirror t)
      (ball :at (0.24 0.2 0.74) :size 0.15 :color fur :sides 6 :mirror t)))

    ;; mushroom: red cap with cream spots on a fat cream stem with the face on it and a
    ;; pale lip under the cap
    (mushroom
     :palette ((cap . "#d9473f") (cream . "#f9eed8") (lip . "#e3cba6") (mouth . "#8a4a3a"))
     :head (0 1.9 0 0.75)
     :start 0
     :parts
     ;; a fat cream stem, and a wide red cap with a pale lip under it
     ((tube :at (0 0.525 0) :radius 0.62 :top 0.5 :height 1.05 :color cream :sides 12)
      (tube :at (0 1.07 0) :radius 1.1 :top 1.1 :height 0.14 :color lip :sides 12)
      (ball :at (0 1.1 0) :size (1.12 0.8 1.08) :color cap :half t :sides 12)

      ;; white spots, flat on the cap's flanks: two staggered rings, all below the reach of a hat
      (ball :at (0 1.669 0.783) :size (0.15 0.135 0.015) :color cream :sides 6 :turn (-52.939 0 0) :detail t :flat t)
      (ball :at (0.757 1.678 0.246) :size (0.15 0.135 0.015) :color cream :sides 6 :turn (-54.722 70.739 0) :detail t :flat t)
      (ball :at (0.463 1.672 -0.637) :size (0.15 0.135 0.015) :color cream :sides 6 :turn (126.403 34.042 180) :detail t :flat t)
      (ball :at (-0.463 1.672 -0.637) :size (0.15 0.135 0.015) :color cream :sides 6 :turn (126.403 -34.042 180) :detail t :flat t)
      (ball :at (-0.757 1.678 0.246) :size (0.15 0.135 0.015) :color cream :sides 6 :turn (-54.722 -70.739 0) :detail t :flat t)
      (ball :at (0.602 1.413 0.828) :size (0.125 0.113 0.015) :color cream :sides 6 :turn (-29.713 34.042 0) :detail t :flat t)
      (ball :at (0.991 1.419 -0.322) :size (0.125 0.113 0.015) :color cream :sides 6 :turn (149.256 70.739 180) :detail t :flat t)
      (ball :at (0 1.41 -1.013) :size (0.125 0.113 0.015) :color cream :sides 6 :turn (150.874 0 180) :detail t :flat t)
      (ball :at (-0.991 1.419 -0.322) :size (0.125 0.113 0.015) :color cream :sides 6 :turn (149.256 -70.739 180) :detail t :flat t)
      (ball :at (-0.602 1.413 0.828) :size (0.125 0.113 0.015) :color cream :sides 6 :turn (-29.713 -34.042 0) :detail t :flat t)

      ;; the face on the stem
      (ball :at (0.22 0.6 0.483) :size 0.11 :color eye :sides 8 :mirror t :detail t)
      (ball :at (0.171 0.649 0.553) :size (0.037 0.037 0.015) :color shine :sides 5 :turn (-30 -35 0) :detail t :flat t)
      (ball :at (-0.269 0.649 0.553) :size (0.037 0.037 0.015) :color shine :sides 5 :turn (-30 -35 0) :detail t :flat t)
      (ball :at (-0.075 0.385 0.56) :size 0.03 :color mouth :sides 4 :detail t)
      (ball :at (0 0.355 0.564) :size 0.03 :color mouth :sides 4 :detail t)
      (ball :at (0.075 0.385 0.56) :size 0.03 :color mouth :sides 4 :detail t)
      (ball :at (0.386 0.46 0.424) :size (0.09 0.052 0.03) :color blush :sides 6 :turn (0 30 0) :mirror t :detail t :flat t)))

    ;; chonk: a very round fat orange cat, one big ball for head and body: cat ears with pink insides,
    ;; wide eyes, a cream muzzle with nose and whiskers, blush, tabby stripes on the forehead, flanks and
    ;; back, round paws, and a short tail curling up behind on the right.
    (chonk
     :palette ((fur . "#e8924a")
               (light . "#f7d9b0")
               (dark . "#b95f24")
               (nose . "#e8899f"))
     :head (0.0 1.88 0.0 1.0)
     :start 0
     :parts
     (;; one huge round ball of cat
      (ball :at (0 0.94 0.0) :size (1.12 0.94 1.0) :color fur :sides 14)
      ;; small cat ears, pink inside
      (tube :at (0.544 1.777 0.414) :radius 0.28 :height 0.46 :color fur :top 0.0 :sides 4 :turn (8 0 -26) :mirror t)
      (tube :at (0.513 1.714 0.48) :radius 0.18 :height 0.34 :color blush :top 0.0 :sides 4 :turn (8.0 0.0 -26.0) :mirror t :detail t)
      ;; muzzle and nose
      (ball :at (0 0.7 0.84) :size (0.32 0.2 0.2) :color light :sides 8)
      (ball :at (0 0.8 1.0) :size (0.08 0.06 0.06) :color nose :sides 6 :detail t)
      ;; eyes
      (ball :at (0.666 1.066 0.756) :size 0.15 :color eye :mirror t :detail t :sides 8)
      (ball :at (0.625 1.112 0.876) :size 0.054 :color shine :flat t :detail t :sides 6)
      (ball :at (-0.706 1.112 0.876) :size 0.054 :color shine :flat t :detail t :sides 6)
      ;; cheeks
      (ball :at (0.874 0.809 0.61) :size (0.12 0.07 0.03) :color blush :turn (9.086 48.813 0.0) :flat t :detail t :sides 6 :mirror t)
      ;; stripes: forehead, flanks and back
      (box :at (0.0 1.707 0.531) :size (0.045 0.13 0.012) :color dark :turn (-57.209 0.0 0.0) :detail t)
      (box :at (0.258 1.707 0.479) :size (0.04 0.12 0.012) :color dark :turn (-59.761 12.997 -6.544) :detail t :mirror t)
      (box :at (0.821 1.12 0.585) :size (0.035 0.15 0.012) :color dark :turn (-12.43 48.23 0.0) :detail t :mirror t)
      (box :at (1.024 1.12 0.209) :size (0.035 0.15 0.012) :color dark :turn (-12.932 75.66 0.0) :detail t :mirror t)
      (box :at (1.024 1.12 -0.209) :size (0.035 0.15 0.012) :color dark :turn (167.068 75.66 180.0) :detail t :mirror t)
      (box :at (0.0 1.452 -0.795) :size (0.045 0.14 0.012) :color dark :turn (145.278 0.0 180.0) :detail t)
      (box :at (0.386 1.452 -0.716) :size (0.04 0.13 0.012) :color dark :turn (141.318 16.031 169.824) :detail t :mirror t)
      ;; whiskers
      (box :at (0.54 0.805 0.935) :size (0.22 0.011 0.011) :color light :turn (0 -8 8) :mirror t)
      (box :at (0.54 0.715 0.925) :size (0.22 0.011 0.011) :color light :turn (0 -8 -10) :mirror t)
      ;; paws and back feet
      (ball :at (0.42 0.24 0.74) :size (0.25 0.22 0.28) :color light :sides 7 :mirror t)
      (ball :at (0.66 0.0 -0.4) :size (0.24 0.3 0.28) :color light :half t :sides 6 :mirror t)
      ;; the tail
      (tube :at (0.204 0.483 -0.975) :radius 0.19 :height 0.377 :color fur :top 0.178 :turn (-71.756 0.0 -35.624) :sides 5)
      (tube :at (0.252 0.608 -1.192) :radius 0.178 :height 0.37 :color fur :top 0.166 :turn (-44.047 0.0 -14.696) :sides 5)
      (tube :at (0.3 0.825 -1.317) :radius 0.166 :height 0.363 :color fur :top 0.154 :turn (-14.743 0.0 -10.869) :sides 5)
      (tube :at (0.348 1.075 -1.317) :radius 0.154 :height 0.356 :color fur :top 0.142 :turn (14.743 0.0 -10.869) :sides 5)
      (tube :at (0.396 1.292 -1.192) :radius 0.142 :height 0.348 :color dark :top 0.13 :turn (44.047 0.0 -14.696) :sides 5))))
  "The 3D model of each species of pet, an alist of species and model.
See the commentary of this file for the format.")

(defconst harness-ui-pet-hat-models
  '((tophat
     :parts ((tube :at (0 -0.02 0) :radius 1.2 :height 0.12 :color "#3d3947" :sides 12)
             (tube :at (0 0.5 0) :radius 0.66 :top 0.62 :height 0.9 :color "#3d3947" :sides 12)
             (tube :at (0 0.2 0) :radius 0.7 :top 0.69 :height 0.22 :color "#c9423f" :sides 12 :detail t)))

    (crown
     :parts ((tube :at (0 -0.05 0) :radius 0.76 :top 0.86 :height 0.7 :color "#e6b93c" :sides 10)
             (tube :at (0 0.52 0.78) :radius 0.16 :top 0 :height 0.45 :color "#e6b93c" :sides 6)
             (tube :at (0.742 0.52 0.241) :radius 0.16 :top 0 :height 0.45 :color "#e6b93c" :sides 6 :mirror t)
             (tube :at (0.458 0.52 -0.631) :radius 0.16 :top 0 :height 0.45 :color "#e6b93c" :sides 6 :mirror t)
             (ball :at (0 0.8 0.78) :size 0.075 :color "#f4efe6" :sides 4)
             (ball :at (0.742 0.8 0.241) :size 0.075 :color "#f4efe6" :sides 4 :mirror t)
             (ball :at (0.458 0.8 -0.631) :size 0.075 :color "#f4efe6" :sides 4 :mirror t)
             (ball :at (0 0.05 0.83) :size 0.11 :color "#d8404a" :sides 4 :detail t)
             (ball :at (0.63 0.05 0.53) :size 0.085 :color "#3f7fe0" :sides 4 :detail t :mirror t :turn (0 50 0))))

    (propeller
     :parts ((ball :at (0 -0.15 0) :size (0.88 0.62 0.92) :half t :color "#d9473f" :sides 12)
             (tube :at (0 -0.3 0) :radius 0.94 :top 0.88 :height 0.3 :color "#3f7fd9" :sides 12)
             (ball :at (0 0.46 0) :size 0.1 :color "#f2c230" :sides 6)
             (tube :at (0 0.56 0) :radius 0.035 :height 0.2 :color "#7a7a86" :sides 6)
             (box :at (0.36 0.68 0) :size (0.36 0.012 0.1) :color "#f2c230" :turn (14 0 0))
             (box :at (-0.36 0.68 0) :size (0.36 0.012 0.1) :color "#5fa8f5" :turn (-14 0 0))))

    (halo
     :parts ((ring :at (0 0.4 0) :radius 0.7 :thickness 0.075 :color "#f7d44c" :flat t :sides 16)))

    (wizard
     :parts ((tube :at (0 -0.02 0) :radius 1.22 :height 0.08 :color "#563d99" :sides 12)
             (tube :at (0 0.4 0) :radius 0.84 :top 0.42 :height 0.9 :color "#6a4fb0" :sides 12)
             (ball :at (0 0.85 0) :size 0.42 :color "#6a4fb0" :sides 8)
             (tube :at (0.127 1.122 0) :radius 0.42 :top 0 :height 0.6 :color "#6a4fb0" :sides 10 :turn (0 0 -25))
             ;; a star on the front
             (box :at (0 0.4 0.64) :size (0.15 0.035 0.01) :color "#f6d04d" :turn (-25 0 0) :detail t)
             (box :at (0 0.4 0.64) :size (0.035 0.15 0.01) :color "#f6d04d" :turn (-25 0 0) :detail t)
             (box :at (0 0.4 0.645) :size (0.10 0.03 0.01) :color "#f6d04d" :turn (-25 0 45) :detail t)
             (box :at (0 0.4 0.645) :size (0.03 0.10 0.01) :color "#f6d04d" :turn (-25 0 45) :detail t)))

    (beanie
     :parts ((ball :at (0 -0.4 0) :size (0.93 0.76 1.0) :half t :color "#4a8fd4" :sides 12)
             (tube :at (0 -0.34 0) :radius 0.97 :top 0.96 :height 0.3 :color "#3b78b8" :sides 12)
             (ball :at (0 0.4 0) :size 0.22 :color "#f4efe6" :sides 8)))

    (tinyduck
     :parts ((ball :at (0 0.14 -0.03) :size (0.4 0.33 0.45) :color "#f6d046" :sides 8)
             (ball :at (0 0.56 0.2) :size 0.24 :color "#f6d046" :sides 8)
             (ball :at (0 0.5 0.44) :size (0.13 0.045 0.11) :color "#f08a24" :sides 6)
             (ball :at (0.11 0.62 0.37) :size 0.04 :color eye :sides 6 :detail t :mirror t)
             (ball :at (0.36 0.2 -0.03) :size (0.08 0.18 0.26) :color "#e6b93c" :sides 6 :mirror t))))
  "The 3D model of each hat, an alist of the hat's name and a plist.
The plist has the hat's `:parts'.  See the commentary of this file for
the format, and `harness-ui-pet--hats' for the names.")

(provide 'harness-ui-pet-models)
;;; harness-ui-pet-models.el ends here
