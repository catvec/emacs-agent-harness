import json, sys
from PIL import Image, ImageDraw, ImageFont

# Draw an Emacs buffer as its faces have it: the harness's own faces,
# the text, and the colours they are drawn in.
data = json.load(open(sys.argv[1]))
out = sys.argv[2]
size = data.get('size', 30)
font = ImageFont.truetype('/usr/share/fonts/TTF/DejaVuSansMono.ttf', size)
bold = ImageFont.truetype('/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf', size)
italic = ImageFont.truetype('/usr/share/fonts/TTF/DejaVuSansMono-Oblique.ttf', size)
bolditalic = ImageFont.truetype('/usr/share/fonts/TTF/DejaVuSansMono-BoldOblique.ttf', size)

lines = [[r for r in (ln or [])] for ln in data['lines']]
char_w = font.getlength('M')
pad = data.get('pad', 26)
lh = int(size * 1.5)
cols = max([sum(len(r[0]) for r in ln) for ln in lines] or [0])
width = int(char_w * cols) + pad * 2
height = lh * len(lines) + pad * 2
im = Image.new('RGB', (width, height), data.get('background', '#ffffff'))
draw = ImageDraw.Draw(im)
y = pad
for ln in lines:
    x = pad
    for text, colour, weight, slant in ln:
        f = font
        if weight == 'bold' and slant == 'italic':
            f = bolditalic
        elif weight == 'bold':
            f = bold
        elif slant == 'italic':
            f = italic
        draw.text((x, y), text, font=f, fill=colour)
        x += char_w * len(text)
    y += lh
im.save(out)
print(im.size)
