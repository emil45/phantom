#!/usr/bin/env python3
"""Generate DMG background image with a drag-to-install arrow."""

from PIL import Image, ImageDraw
import os

# Match DMG window: bounds {100, 100, 640, 400} = 540x300
WIDTH, HEIGHT = 540, 300

# Icon centers (from AppleScript positioning)
APP_X, APPS_X = 140, 400
ICON_Y = 150
ICON_SIZE = 80


def draw_arrow(draw, x1, y1, x2, y2, color, thickness=3):
    """Draw arrow from (x1,y1) to (x2,y2)."""
    head_size = 16
    draw.rectangle(
        [x1, y1 - thickness, x2 - head_size, y1 + thickness],
        fill=color,
    )
    draw.polygon(
        [
            (x2 - head_size, y2 - head_size),
            (x2, y2),
            (x2 - head_size, y2 + head_size),
        ],
        fill=color,
    )


def main():
    img = Image.new("RGBA", (WIDTH, HEIGHT), (245, 245, 247, 255))
    draw = ImageDraw.Draw(img)

    # Subtle arrow between the two icon positions
    arrow_color = (195, 195, 200, 255)
    arrow_y = ICON_Y - 10
    arrow_x1 = APP_X + 55
    arrow_x2 = APPS_X - 55

    draw_arrow(draw, arrow_x1, arrow_y, arrow_x2, arrow_y, arrow_color)

    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "dmg-background.png")
    img.save(out_path)
    print(f"Background saved: {out_path}")


if __name__ == "__main__":
    main()
