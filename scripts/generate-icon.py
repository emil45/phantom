#!/usr/bin/env python3
"""Generate the Phantom app icon — dark rounded rect with a ghost/terminal motif."""

from PIL import Image, ImageDraw, ImageFont
import math
import os

SIZE = 1024
PADDING = 100  # macOS icon inset from edges
CORNER = 220   # rounded rect corner radius

def rounded_rect_mask(size, radius):
    """Create an anti-aliased rounded rectangle mask."""
    # Render at 2x for anti-aliasing
    scale = 2
    s = size * scale
    r = radius * scale
    mask = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, s - 1, s - 1], radius=r, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def draw_ghost(draw, cx, cy, w, h):
    """Draw a cute ghost shape — rounded top, wavy bottom."""
    # Ghost body color
    ghost_color = (240, 240, 250)
    ghost_shadow = (200, 200, 220)

    # Body dimensions
    body_top = cy - h // 2
    body_bottom = cy + h // 2
    body_left = cx - w // 2
    body_right = cx + w // 2

    # Head: ellipse for the rounded top
    head_h = int(h * 0.55)
    draw.ellipse(
        [body_left, body_top, body_right, body_top + head_h * 2],
        fill=ghost_color,
    )

    # Body rectangle connecting head to bottom
    draw.rectangle(
        [body_left, body_top + head_h, body_right, body_bottom],
        fill=ghost_color,
    )

    # Wavy bottom — three "tails"
    wave_h = int(h * 0.15)
    num_waves = 3
    wave_w = w // num_waves

    # Draw the wavy bottom using triangles
    for i in range(num_waves):
        x_start = body_left + i * wave_w
        x_mid = x_start + wave_w // 2
        x_end = x_start + wave_w

        if i % 2 == 0:
            # Point down
            draw.polygon(
                [(x_start, body_bottom), (x_mid, body_bottom + wave_h), (x_end, body_bottom)],
                fill=ghost_color,
            )
        else:
            # Cut up (draw background color to create indent)
            draw.polygon(
                [(x_start, body_bottom), (x_mid, body_bottom - wave_h), (x_end, body_bottom)],
                fill=(30, 30, 40),  # background color
            )

    return body_top, head_h


def draw_terminal_face(draw, cx, cy, w, h):
    """Draw terminal-style 'eyes' on the ghost — a > prompt and cursor."""
    eye_color = (80, 220, 160)  # Terminal green

    # Left eye: > prompt
    prompt_x = cx - w // 5
    prompt_y = cy
    prompt_size = w // 8

    # Draw > as two lines
    draw.line(
        [(prompt_x - prompt_size, prompt_y - prompt_size),
         (prompt_x, prompt_y)],
        fill=eye_color, width=max(12, w // 30),
    )
    draw.line(
        [(prompt_x - prompt_size, prompt_y + prompt_size),
         (prompt_x, prompt_y)],
        fill=eye_color, width=max(12, w // 30),
    )

    # Right: cursor block
    cursor_x = cx + w // 10
    cursor_w = w // 6
    cursor_h = int(prompt_size * 1.8)
    draw.rectangle(
        [cursor_x, prompt_y - cursor_h // 2, cursor_x + cursor_w, prompt_y + cursor_h // 2],
        fill=eye_color,
    )


def generate_icon(output_path):
    """Generate the full icon."""
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Background: dark gradient rounded rect
    bg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)

    # Draw filled rounded rect
    inset = PADDING
    bg_draw.rounded_rectangle(
        [inset, inset, SIZE - inset, SIZE - inset],
        radius=CORNER,
        fill=(30, 30, 40),
    )

    # Add subtle gradient overlay (lighter at top)
    gradient = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gradient)
    for y in range(inset, SIZE - inset):
        alpha = int(40 * (1 - (y - inset) / (SIZE - 2 * inset)))
        gd.line([(inset, y), (SIZE - inset, y)], fill=(255, 255, 255, alpha))

    # Mask gradient to rounded rect
    mask = rounded_rect_mask(SIZE, CORNER)
    # Shift mask to account for padding
    mask_padded = Image.new("L", (SIZE, SIZE), 0)
    inner_size = SIZE - 2 * inset
    inner_mask = rounded_rect_mask(inner_size, CORNER)
    mask_padded.paste(inner_mask, (inset, inset))

    gradient_masked = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gradient_masked.paste(gradient, mask=mask_padded)

    img = Image.alpha_composite(img, bg)
    img = Image.alpha_composite(img, gradient_masked)

    draw = ImageDraw.Draw(img)

    # Ghost
    ghost_w = int(SIZE * 0.48)
    ghost_h = int(SIZE * 0.52)
    ghost_cx = SIZE // 2
    ghost_cy = SIZE // 2 + 10

    draw_ghost(draw, ghost_cx, ghost_cy, ghost_w, ghost_h)

    # Terminal face on the ghost
    face_cy = ghost_cy - ghost_h // 8
    draw_terminal_face(draw, ghost_cx, face_cy, ghost_w, ghost_h)

    # Add subtle glow around the ghost
    # (skip for now — keep it clean)

    img.save(output_path, "PNG")
    print(f"Icon saved: {output_path}")
    return output_path


def create_iconset(png_path, output_dir):
    """Create .iconset folder with all required sizes."""
    iconset_dir = os.path.join(output_dir, "AppIcon.iconset")
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [16, 32, 64, 128, 256, 512, 1024]
    img = Image.open(png_path)

    for size in sizes:
        # 1x
        resized = img.resize((size, size), Image.LANCZOS)
        if size == 1024:
            resized.save(os.path.join(iconset_dir, f"icon_512x512@2x.png"))
        else:
            resized.save(os.path.join(iconset_dir, f"icon_{size}x{size}.png"))

        # 2x (except 1024 which IS the 512@2x)
        if size <= 512 and size * 2 <= 1024:
            resized2x = img.resize((size * 2, size * 2), Image.LANCZOS)
            resized2x.save(os.path.join(iconset_dir, f"icon_{size}x{size}@2x.png"))

    print(f"Iconset created: {iconset_dir}")
    return iconset_dir


if __name__ == "__main__":
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    build_dir = os.path.join(project_root, "build")
    os.makedirs(build_dir, exist_ok=True)

    png_path = os.path.join(build_dir, "phantom-icon.png")
    generate_icon(png_path)

    iconset_dir = create_iconset(png_path, build_dir)

    # Convert to .icns using iconutil
    icns_path = os.path.join(build_dir, "AppIcon.icns")
    os.system(f"iconutil -c icns '{iconset_dir}' -o '{icns_path}'")
    print(f"ICNS created: {icns_path}")

    # Copy to macos resources
    resources_dir = os.path.join(project_root, "macos", "PhantomBar", "Resources")
    os.makedirs(resources_dir, exist_ok=True)
    dest = os.path.join(resources_dir, "AppIcon.icns")
    os.system(f"cp '{icns_path}' '{dest}'")
    print(f"Copied to: {dest}")
