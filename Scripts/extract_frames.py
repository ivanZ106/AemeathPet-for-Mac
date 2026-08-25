#!/usr/bin/env python3
"""
Aemeath Pet —— 构建期资源提取脚本
将状态 GIF 逐帧提取为 RGBA PNG，并生成帧清单 manifest.json、
菜单栏图标与 App 图标。

用法: python3 Scripts/extract_frames.py [项目根目录]
"""
import json
import os
import sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
RES = os.path.join(ROOT, "Resources")

STATES = ["move", "idle1", "idle2", "idle3", "idle4", "drag"]


def content_bbox(img: Image.Image) -> tuple:
    """返回非透明像素的包围盒 (left, top, right, bottom)。"""
    alpha = img.split()[-1]
    bbox = alpha.getbbox()
    if bbox is None:
        return (0, 0, img.width, img.height)
    return bbox


def main() -> None:
    os.makedirs(os.path.join(RES, "frames"), exist_ok=True)
    manifest = {"states": {}, "delay_ms": 110, "canvas": 200}

    for state in STATES:
        src = os.path.join(ASSETS, f"{state}.gif")
        out_dir = os.path.join(RES, "frames", state)
        os.makedirs(out_dir, exist_ok=True)
        im = Image.open(src)
        frames = []
        delays = []
        for i in range(im.n_frames):
            im.seek(i)
            frame = im.convert("RGBA")
            # 去掉每帧周围的透明边，统一为 200x200 画布（中心对齐），减少存储
            if frame.size != (200, 200):
                canvas = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
                canvas.paste(frame, ((200 - frame.width) // 2, (200 - frame.height) // 2))
                frame = canvas
            name = f"frame_{i:03d}.png"
            frame.save(os.path.join(out_dir, name), optimize=True)
            frames.append(name)
            delays.append(int(im.info.get("duration", 110)))
        manifest["states"][state] = {"frames": frames, "delays": delays}
        print(f"{state}: {len(frames)} frames")

    # 菜单栏图标（取 ameath.gif 首帧，裁剪到内容再缩放）
    icon_src = Image.open(os.path.join(ASSETS, "ameath.gif"))
    icon_src.seek(0)
    icon_rgba = icon_src.convert("RGBA")
    l, t, r, b = content_bbox(icon_rgba)
    cropped = icon_rgba.crop((l, t, r, b))
    # 保证正方形
    side = max(cropped.width, cropped.height)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(cropped, ((side - cropped.width) // 2, (side - cropped.height) // 2))
    icon_dir = os.path.join(RES, "icon")
    os.makedirs(icon_dir, exist_ok=True)
    for name, size in [("menubar_16.png", 16), ("menubar_32.png", 32),
                       ("menubar_48.png", 48), ("app_icon_1024.png", 1024)]:
        icon = square.resize((size, size), Image.LANCZOS)
        icon.save(os.path.join(icon_dir, name), optimize=True)
    print("icons done")

    with open(os.path.join(RES, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    print("manifest written")


if __name__ == "__main__":
    main()
