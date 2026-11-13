"""Render the shared rounded desktop icon from the square source PNG."""
from pathlib import Path
import math

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets"
SIZE = 1024
SCALE = 4


def main() -> None:
    source = Image.open(ASSETS / "app-icon-source.png").convert("RGBA")
    if source.size != (SIZE, SIZE):
        raise ValueError("The icon source must be 1024 × 1024 pixels")

    # A continuous superellipse gives both platforms the same rounded silhouette.
    radius = SIZE * SCALE / 2
    points = []
    for step in range(1024):
        angle = 2 * math.pi * step / 1024
        cosine, sine = math.cos(angle), math.sin(angle)
        points.append((radius + radius * math.copysign(abs(cosine) ** 0.5, cosine),
                       radius + radius * math.copysign(abs(sine) ** 0.5, sine)))
    mask = Image.new("L", (SIZE * SCALE, SIZE * SCALE), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    mask = mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    source.putalpha(mask)
    source.save(ASSETS / "app-icon.png")
    source.save(ASSETS / "app-icon.ico", format="ICO",
                sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                       (64, 64), (128, 128), (256, 256)])


if __name__ == "__main__":
    main()
