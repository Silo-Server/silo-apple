These are original synthetic playback fixtures for Silo's ASS renderer tests.
The font contains one solid rectangular X so a pixel assertion can distinguish
an attached font from a system fallback. Regenerate it with `generate-font.py`
and fonttools. The ASS scripts exercise simultaneous dialogue/sign layers,
authored colors and positions, and a second embedded track.

To regenerate the MKV from this directory:

```sh
ffmpeg -f lavfi -i color=c=black:s=320x180:r=24:d=8 \
  -f lavfi -i anullsrc=r=48000:cl=stereo \
  -i authored.ass -i alternate.ass \
  -map 0:v -map 1:a -map 2:s -map 3:s \
  -c:v libx264 -preset ultrafast -crf 35 -c:a aac -c:s copy -t 8 \
  -attach SiloASSFixture.ttf -metadata:s:t mimetype=font/ttf \
  -metadata:s:t filename=SiloASSFixture.ttf -y authored.mkv
```

The fixtures are included only in the test bundle.
