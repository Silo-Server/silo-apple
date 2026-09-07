"""Generate Silo's original, deliberately distinctive test glyph. Requires fonttools."""
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

builder = FontBuilder(1000, isTTF=True)
builder.setupGlyphOrder(['.notdef', 'space', 'X'])
builder.setupCharacterMap({32: 'space', 88: 'X'})
glyphs = {}
for name in ['.notdef', 'space', 'X']:
    pen = TTGlyphPen(None)
    if name == 'X':
        pen.moveTo((0, 0))
        pen.lineTo((900, 0))
        pen.lineTo((900, 700))
        pen.lineTo((0, 700))
        pen.closePath()
    glyphs[name] = pen.glyph()
builder.setupGlyf(glyphs)
builder.setupHorizontalMetrics({name: (1000, 0) for name in glyphs})
builder.setupHorizontalHeader(ascent=800, descent=-200)
builder.setupNameTable({'familyName': 'Silo ASS Fixture', 'styleName': 'Regular',
                        'uniqueFontIdentifier': 'SiloASSFixture-Regular',
                        'fullName': 'Silo ASS Fixture Regular', 'psName': 'SiloASSFixture-Regular'})
builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
builder.setupPost()
builder.setupMaxp()
builder.save(Path(__file__).with_name('SiloASSFixture.ttf'))
