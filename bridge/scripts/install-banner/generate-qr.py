#!/usr/bin/env python3
"""Generate QR code with embedded CC Pocket icon."""

import argparse
import os
import sys

try:
    import qrcode
    from PIL import Image, ImageDraw
except ImportError:
    print("Required: pip3 install qrcode[pil]")
    sys.exit(1)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))

ICON_PATH = os.path.join(
    ROOT, "apps/mobile/fastlane/metadata/android/en-US/images/icon.png"
)
OUTPUT_QR = os.path.join(ROOT, "docs/images/install-qr.png")
INSTALL_URL = "https://k9i-0.github.io/ccpocket/install"


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--url",
        default=INSTALL_URL,
        help="URL to encode in the QR code",
    )
    parser.add_argument(
        "--output",
        default=OUTPUT_QR,
        help="Output image path",
    )
    parser.add_argument(
        "--fill-color",
        default="#e0e0e0",
        help="Foreground QR color",
    )
    parser.add_argument(
        "--back-color",
        default="#1a1a1a",
        help="Background color",
    )
    return parser.parse_args()


def generate(url: str, output: str, fill_color: str, back_color: str):
    # Generate QR code with high error correction (for icon overlay)
    qr = qrcode.QRCode(
        version=3,
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=12,
        border=2,
    )
    qr.add_data(url)
    qr.make(fit=True)
    qr_img = qr.make_image(fill_color=fill_color, back_color=back_color).convert("RGBA")

    # Load and resize icon
    icon = Image.open(ICON_PATH).convert("RGBA")
    qr_w, qr_h = qr_img.size
    icon_size = qr_w // 4
    icon_resized = icon.resize((icon_size, icon_size), Image.LANCZOS)

    # Rounded mask for icon
    mask = Image.new("L", (icon_size, icon_size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(0, 0), (icon_size, icon_size)], radius=icon_size // 5, fill=255
    )

    # Clear center of QR and paste icon
    icon_x = (qr_w - icon_size) // 2
    icon_y = (qr_h - icon_size) // 2
    padding = 8
    ImageDraw.Draw(qr_img).rectangle(
        [
            icon_x - padding,
            icon_y - padding,
            icon_x + icon_size + padding,
            icon_y + icon_size + padding,
        ],
        fill=back_color,
    )
    qr_img.paste(icon_resized, (icon_x, icon_y), mask)

    os.makedirs(os.path.dirname(output), exist_ok=True)
    qr_img.save(output)
    print(f"✅ QR code: {output}")


if __name__ == "__main__":
    args = parse_args()
    generate(args.url, args.output, args.fill_color, args.back_color)
