#!/usr/bin/env python3
"""Generate the Phantom app icon — bold P monogram with terminal DNA.

Design: Geometric "P" letterform where the stem doubles as a terminal cursor.
The bowl has a subtle break at the bottom (the "phantom gap").
White-to-teal vertical gradient on a deep dark background with soft glow.
"""

from PIL import Image, ImageDraw, ImageFilter
import os
import shutil
import json
import math

SIZE = 1024
RENDER_SCALE = 3  # Supersample at 3072px for crisp anti-aliasing
PADDING = 28
CORNER = 220

# Brand palette
BG_COLOR = (12, 12, 24)           # #0C0C18 — deep charcoal-blue
LETTER_TOP = (225, 225, 250)      # Near-white, cool tone
LETTER_BOT = (0, 210, 155)        # #00D29B — phantom teal
GLOW_COLOR = (0, 180, 130)        # Teal for ambient glow
GLOW_BRIGHT = (0, 230, 170)       # Brighter teal for cursor glow


def lerp(a, b, t):
    """Linear interpolation."""
    return a + (b - a) * t


def lerp_color(c1, c2, t):
    """Linear interpolation between two RGB tuples."""
    return tuple(int(lerp(a, b, t)) for a, b in zip(c1, c2))


def generate_icon(output_path, size=SIZE):
    """Generate the 1024px master icon PNG."""
    S = size * RENDER_SCALE
    PAD = PADDING * S // SIZE
    COR = CORNER * S // SIZE
    content = S - 2 * PAD
    cx, cy = S // 2, S // 2

    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # ── Background rounded rect ──────────────────────────────────────────
    bg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(bg).rounded_rectangle(
        [PAD, PAD, S - PAD, S - PAD], radius=COR, fill=BG_COLOR
    )
    img = Image.alpha_composite(img, bg)

    # Background mask (reused for clipping layers)
    bg_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(bg_mask).rounded_rectangle(
        [PAD, PAD, S - PAD, S - PAD], radius=COR, fill=255
    )

    # ── Subtle top-light gradient ─────────────────────────────────────────
    grad = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(PAD, S - PAD):
        t = (y - PAD) / content
        a = int(20 * (1 - t))
        gd.line([(PAD, y), (S - PAD, y)], fill=(255, 255, 255, a))
    grad_clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    grad_clipped.paste(grad, mask=bg_mask)
    img = Image.alpha_composite(img, grad_clipped)

    # ── Ambient radial glow behind the letter ─────────────────────────────
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    r_glow = int(content * 0.18)
    ImageDraw.Draw(glow).ellipse(
        [cx - r_glow, cy - r_glow, cx + r_glow, cy + r_glow],
        fill=(*GLOW_COLOR, 60),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=int(content * 0.16)))
    glow_clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow_clipped.paste(glow, mask=bg_mask)
    img = Image.alpha_composite(img, glow_clipped)

    # ── Build the P letterform as a mask ──────────────────────────────────
    # Proportions tuned for bold, geometric feel
    letter_h = content * 0.54
    stem_w = content * 0.115
    bowl_extent = content * 0.27   # how far bowl extends right from stem
    bowl_h = letter_h * 0.54       # bowl occupies top ~54% of letter
    bowl_thick = content * 0.095   # wall thickness of the bowl

    # Optical centering: shift left slightly to balance the bowl overhang
    lx = cx - content * 0.045
    ly = cy

    letter_top = ly - letter_h / 2
    letter_bot = ly + letter_h / 2
    stem_l = lx - stem_w / 2
    stem_r = lx + stem_w / 2

    # Bowl arc geometry
    bowl_cx = stem_r
    bowl_cy = letter_top + bowl_h / 2
    bowl_outer_rx = bowl_extent
    bowl_outer_ry = bowl_h / 2
    bowl_inner_rx = bowl_extent - bowl_thick
    bowl_inner_ry = bowl_h / 2 - bowl_thick

    # The phantom gap: bowl arc doesn't reach all the way back to the stem
    arc_start = -90   # degrees — top
    arc_end = 68      # degrees — stops before closing, leaving a gap

    n_pts = 50  # points per arc for smooth curves

    # Build outer arc points
    outer_arc = []
    for i in range(n_pts + 1):
        t = i / n_pts
        angle = math.radians(arc_start + t * (arc_end - arc_start))
        x = bowl_cx + bowl_outer_rx * math.cos(angle)
        y = bowl_cy + bowl_outer_ry * math.sin(angle)
        outer_arc.append((x, y))

    # Build inner arc points (reversed for polygon winding)
    inner_arc = []
    for i in range(n_pts, -1, -1):
        t = i / n_pts
        angle = math.radians(arc_start + t * (arc_end - arc_start))
        x = bowl_cx + bowl_inner_rx * math.cos(angle)
        y = bowl_cy + bowl_inner_ry * math.sin(angle)
        inner_arc.append((x, y))

    crescent_pts = outer_arc + inner_arc

    # Render the letter mask
    letter_mask = Image.new("L", (S, S), 0)
    ld = ImageDraw.Draw(letter_mask)

    # Stem: tall vertical rectangle
    ld.rectangle(
        [int(stem_l), int(letter_top), int(stem_r), int(letter_bot)],
        fill=255,
    )

    # Bowl: thick crescent arc
    ld.polygon(
        [tuple(int(c) for c in p) for p in crescent_pts],
        fill=255,
    )

    # ── Letter outer glow ─────────────────────────────────────────────────
    glow_radius = int(content * 0.018)
    letter_glow_mask = letter_mask.filter(
        ImageFilter.GaussianBlur(radius=glow_radius)
    )
    letter_glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    letter_glow.paste(
        Image.new("RGBA", (S, S), (*GLOW_COLOR, 90)),
        mask=letter_glow_mask,
    )
    glow2_clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    glow2_clipped.paste(letter_glow, mask=bg_mask)
    img = Image.alpha_composite(img, glow2_clipped)

    # ── Gradient-colored letter ───────────────────────────────────────────
    letter_gradient = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    lgd = ImageDraw.Draw(letter_gradient)
    for y in range(S):
        if letter_h > 0:
            t = max(0.0, min(1.0, (y - letter_top) / letter_h))
        else:
            t = 0.0
        color = lerp_color(LETTER_TOP, LETTER_BOT, t)
        lgd.line([(0, y), (S, y)], fill=(*color, 245))

    letter_colored = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    letter_colored.paste(letter_gradient, mask=letter_mask)
    img = Image.alpha_composite(img, letter_colored)

    # ── Bright cursor accent at stem bottom ───────────────────────────────
    cursor_h = content * 0.032
    cursor_region = Image.new("L", (S, S), 0)
    ImageDraw.Draw(cursor_region).rectangle(
        [int(stem_l), int(letter_bot - cursor_h), int(stem_r), int(letter_bot)],
        fill=255,
    )
    # Combine: only where the stem exists
    cursor_mask = Image.new("L", (S, S), 0)
    cursor_mask.paste(cursor_region, mask=letter_mask)

    cursor_glow_img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(cursor_glow_img).rectangle(
        [int(stem_l - content * 0.01), int(letter_bot - cursor_h - content * 0.01),
         int(stem_r + content * 0.01), int(letter_bot + content * 0.01)],
        fill=(*GLOW_BRIGHT, 60),
    )
    cursor_glow_img = cursor_glow_img.filter(
        ImageFilter.GaussianBlur(radius=int(content * 0.015))
    )
    cursor_glow_clipped = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cursor_glow_clipped.paste(cursor_glow_img, mask=bg_mask)
    img = Image.alpha_composite(img, cursor_glow_clipped)

    # Bright cursor block over the stem bottom
    cursor_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cursor_layer.paste(
        Image.new("RGBA", (S, S), (*GLOW_BRIGHT, 255)),
        mask=cursor_mask,
    )
    img = Image.alpha_composite(img, cursor_layer)

    # ── Downscale with Lanczos for final output ───────────────────────────
    final = img.resize((size, size), Image.LANCZOS)
    final.save(output_path, "PNG")
    print(f"Icon saved: {output_path}")
    return output_path


def create_iconset(png_path, output_dir):
    """Create .iconset folder with Apple's canonical macOS sizes."""
    iconset_dir = os.path.join(output_dir, "AppIcon.iconset")
    if os.path.isdir(iconset_dir):
        shutil.rmtree(iconset_dir)
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [16, 32, 128, 256, 512]
    img = Image.open(png_path)

    for size in sizes:
        resized = img.resize((size, size), Image.LANCZOS)
        resized.save(os.path.join(iconset_dir, f"icon_{size}x{size}.png"))

        if size == 512:
            img.save(os.path.join(iconset_dir, "icon_512x512@2x.png"))
        else:
            resized2x = img.resize((size * 2, size * 2), Image.LANCZOS)
            resized2x.save(os.path.join(iconset_dir, f"icon_{size}x{size}@2x.png"))

    print(f"Iconset created: {iconset_dir}")
    return iconset_dir


def create_icns(png_path, icns_path):
    """Create a multi-size .icns directly with Pillow."""
    img = Image.open(png_path).convert("RGBA")
    img.save(
        icns_path,
        format="ICNS",
        sizes=[
            (16, 16), (32, 32), (64, 64), (128, 128),
            (256, 256), (512, 512), (1024, 1024),
        ],
    )
    print(f"ICNS created: {icns_path}")
    return icns_path


def create_ios_appiconset(png_path, output_dir):
    """Create iOS AppIcon.appiconset with a single 1024x1024 universal icon.

    Modern iOS (16+) uses a single 1024x1024 image and auto-generates all sizes.
    """
    appiconset_dir = os.path.join(output_dir, "AppIcon.appiconset")
    os.makedirs(appiconset_dir, exist_ok=True)

    # Copy the 1024px icon
    dest_png = os.path.join(appiconset_dir, "AppIcon.png")
    shutil.copy2(png_path, dest_png)

    # Write Contents.json
    contents = {
        "images": [
            {
                "filename": "AppIcon.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(appiconset_dir, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")

    print(f"iOS AppIcon set created: {appiconset_dir}")
    return appiconset_dir


def create_ios_assets_xcassets(project_root, png_path):
    """Create the full Assets.xcassets structure for the iOS project."""
    assets_dir = os.path.join(project_root, "ios", "Phantom", "Assets.xcassets")
    os.makedirs(assets_dir, exist_ok=True)

    # Root Contents.json
    root_contents = {"info": {"author": "xcode", "version": 1}}
    with open(os.path.join(assets_dir, "Contents.json"), "w") as f:
        json.dump(root_contents, f, indent=2)
        f.write("\n")

    # AppIcon set
    create_ios_appiconset(png_path, assets_dir)
    print(f"iOS Assets.xcassets created: {assets_dir}")


if __name__ == "__main__":
    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    build_dir = os.path.join(project_root, "build")
    os.makedirs(build_dir, exist_ok=True)

    # Generate master 1024px PNG
    png_path = os.path.join(build_dir, "phantom-icon.png")
    generate_icon(png_path)

    # macOS iconset
    create_iconset(png_path, build_dir)

    # macOS .icns
    icns_path = os.path.join(build_dir, "AppIcon.icns")
    create_icns(png_path, icns_path)

    # Copy to macOS resources
    resources_dir = os.path.join(project_root, "macos", "PhantomBar", "Resources")
    os.makedirs(resources_dir, exist_ok=True)
    dest = os.path.join(resources_dir, "AppIcon.icns")
    shutil.copy2(icns_path, dest)
    print(f"Copied to: {dest}")

    # iOS asset catalog
    create_ios_assets_xcassets(project_root, png_path)

    print("\nDone! Generated icons for macOS and iOS.")
