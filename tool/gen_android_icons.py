#!/usr/bin/env python3
"""生成安卓启动图标（legacy PNG + adaptive icon 双套）。

源图：macOS/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png（即用户选定的图标方案 H）。
为什么两套都要：minSdk 走 flutter 默认（<26），老机型读 mipmap-*/ic_launcher.png；
API 26+ 读 mipmap-anydpi-v26/ic_launcher.xml，此时四个角由系统裁形状，
所以 foreground 只画内缩 72/108 的图案，外圈留给 background 色（取源图四角的底色，无缝衔接）。

用法：python3 tool/gen_android_icons.py   （可重复执行，幂等覆盖）
"""
from PIL import Image
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"
RES = ROOT / "android/app/src/main/res"

# 密度 → (legacy 边长, adaptive 画布边长)
DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}

ADAPTIVE_DIR = RES / "mipmap-anydpi-v26"
VALUES_DIR = RES / "values"


def corner_color(img: Image.Image) -> str:
    """取左上角外侧像素作为 background 色（源图外圈底色）。"""
    px = img.convert("RGBA").getpixel((2, 2))
    return "#{:02X}{:02X}{:02X}".format(*px[:3])


def main() -> None:
    img = Image.open(SRC)
    if img.size != (1024, 1024):
        raise SystemExit(f"源图尺寸异常: {img.size}，期望 1024x1024")
    bg = corner_color(img)

    for name, (legacy, canvas) in DENSITIES.items():
        d = RES / f"mipmap-{name}"
        d.mkdir(parents=True, exist_ok=True)

        # 1) legacy：整图等比缩放（圆角/外圈保留，老机型直接用）
        icon = img.resize((legacy, legacy), Image.LANCZOS).convert("RGB")
        icon.save(d / "ic_launcher.png")
        icon.save(d / "ic_launcher_round.png")  # 圆形启动器由系统裁，Flutter 模板同样复用同图

        # 2) adaptive foreground：内缩到 72/108 安全区，外圈透明（由 background 色补上）
        art = img.resize((canvas * 2 // 3, canvas * 2 // 3), Image.LANCZOS).convert("RGBA")
        fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        fg.paste(art, ((canvas - art.width) // 2, (canvas - art.height) // 2), art)
        fg.save(d / "ic_launcher_foreground.png")

    # 3) adaptive icon 描述 + background 色
    ADAPTIVE_DIR.mkdir(parents=True, exist_ok=True)
    for fname in ("ic_launcher.xml", "ic_launcher_round.xml"):
        (ADAPTIVE_DIR / fname).write_text(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            "<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n"
            "    <background android:drawable=\"@color/ic_launcher_background\" />\n"
            "    <foreground android:drawable=\"@mipmap/ic_launcher_foreground\" />\n"
            "</adaptive-icon>\n",
            encoding="utf-8",
        )
    VALUES_DIR.mkdir(parents=True, exist_ok=True)
    (VALUES_DIR / "ic_launcher_background.xml").write_text(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<resources>\n"
        f'    <color name="ic_launcher_background">{bg}</color>\n'
        "</resources>\n",
        encoding="utf-8",
    )
    print(f"background={bg}")
    print("已生成 legacy 与 adaptive 图标:", ", ".join(DENSITIES))


if __name__ == "__main__":
    main()
