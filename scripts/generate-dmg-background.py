#!/usr/bin/env python3
"""Generate DMG background image with drag-to-install arrow and Applications folder icon."""

from PIL import Image, ImageDraw, ImageFont
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


def draw_folder_icon(draw, cx, cy, size):
    """Draw a macOS-style folder icon."""
    half = size // 2
    x0, y0 = cx - half, cy - half
    x1, y1 = cx + half, cy + half

    # Folder body - blue rounded rect
    body_color = (100, 160, 255)
    body_dark = (70, 130, 230)
    tab_color = (80, 145, 245)

    r = size // 8  # corner radius

    # Folder tab (top-left portion)
    tab_w = size * 2 // 5
    tab_h = size // 8
    draw.rounded_rectangle(
        [x0, y0, x0 + tab_w, y0 + tab_h + r],
        radius=r // 2,
        fill=tab_color,
    )

    # Main folder body
    draw.rounded_rectangle(
        [x0, y0 + tab_h, x1, y1],
        radius=r,
        fill=body_color,
    )

    # Slight gradient: darker bottom half
    mid_y = cy + size // 8
    draw.rounded_rectangle(
        [x0 + 1, mid_y, x1 - 1, y1],
        radius=r,
        fill=body_dark,
    )

    # "A" letter for Applications
    a_size = size // 3
    a_cx, a_cy = cx, cy + size // 10
    a_color = (255, 255, 255, 200)

    # Draw a simple "A"
    # Left leg
    draw.line(
        [(a_cx - a_size // 2, a_cy + a_size // 2),
         (a_cx, a_cy - a_size // 2)],
        fill=a_color, width=max(3, size // 20),
    )
    # Right leg
    draw.line(
        [(a_cx + a_size // 2, a_cy + a_size // 2),
         (a_cx, a_cy - a_size // 2)],
        fill=a_color, width=max(3, size // 20),
    )
    # Crossbar
    bar_y = a_cy + a_size // 8
    draw.line(
        [(a_cx - a_size // 4, bar_y),
         (a_cx + a_size // 4, bar_y)],
        fill=a_color, width=max(2, size // 25),
    )


def main():
    img = Image.new("RGBA", (WIDTH, HEIGHT), (245, 245, 247, 255))
    draw = ImageDraw.Draw(img)

    # Draw Applications folder icon in background (fills behind the dashed overlay)
    draw_folder_icon(draw, APPS_X, ICON_Y - 12, ICON_SIZE - 4)

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
