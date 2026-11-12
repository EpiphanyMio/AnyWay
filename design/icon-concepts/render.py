"""Render the editable icon concepts and a small-size comparison board.

Run with the Windows project environment (which includes PySide6):
    windows/.venv/Scripts/python.exe design/icon-concepts/render.py
"""
from __future__ import annotations

import os
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QRectF, Qt
from PySide6.QtGui import (QColor, QFont, QFontDatabase, QGuiApplication, QImage,
                           QPainter, QPainterPath, QPen)
from PySide6.QtSvg import QSvgRenderer


HERE = Path(__file__).resolve().parent
CONCEPTS = (
    ("01-route-a", "ROUTE A", "Route as identity"),
    ("02-offset", "OFFSET", "Virtual position"),
    ("03-loop", "LOOP", "Route replay"),
    ("04-waymark", "WAYMARK", "Anywhere, any way"),
)
REFINEMENTS = (
    ("02-offset", "ORIGINAL", "Two virtual coordinates"),
    ("02-offset-pin", "LOCATION PIN", "The new point is a place"),
    ("02-offset-focus", "LOCATION FOCUS", "Precision at the destination"),
)


def render_icon(stem: str, size: int) -> QImage:
    renderer = QSvgRenderer(str(HERE / f"{stem}.svg"))
    if not renderer.isValid():
        raise ValueError(f"Cannot render {stem}.svg")
    image = QImage(size, size, QImage.Format.Format_ARGB32_Premultiplied)
    image.fill(Qt.GlobalColor.transparent)
    painter = QPainter(image)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    renderer.render(painter, QRectF(0, 0, size, size))
    painter.end()
    return image


def draw_masked_icon(painter: QPainter, icon: QImage, rect: QRectF, radius: float) -> None:
    clip = QPainterPath()
    clip.addRoundedRect(rect, radius, radius)
    painter.save()
    painter.setClipPath(clip)
    painter.drawImage(rect, icon, QRectF(0, 0, icon.width(), icon.height()))
    painter.restore()


def render_board(icons: list[QImage], font_family: str,
                 concepts: tuple[tuple[str, str, str], ...], filename: str,
                 title: str) -> None:
    width = 48 + len(concepts) * 300 + (len(concepts) - 1) * 28
    board = QImage(width, 464, QImage.Format.Format_ARGB32_Premultiplied)
    board.fill(QColor("#EDF1F4"))
    painter = QPainter(board)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
    painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, True)

    painter.setPen(QColor("#183445"))
    painter.setFont(QFont(font_family, 19, QFont.Weight.DemiBold))
    painter.drawText(QRectF(24, 15, width - 400, 50), Qt.AlignmentFlag.AlignVCenter, title)
    painter.setFont(QFont(font_family, 11))
    painter.setPen(QColor("#6C7D87"))
    painter.drawText(QRectF(width - 342, 18, 320, 45), Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignRight,
                     "1024px originals · 48px checks")

    for index, ((_, label, caption), icon) in enumerate(zip(concepts, icons)):
        left = 24 + index * 328
        card = QRectF(left, 80, 300, 360)
        painter.setBrush(QColor("#FFFFFF"))
        painter.setPen(QPen(QColor("#D7E0E5"), 1))
        painter.drawRoundedRect(card, 18, 18)
        draw_masked_icon(painter, icon, QRectF(left + 25, 99, 250, 250), 52)

        painter.setPen(QColor("#183445"))
        painter.setFont(QFont(font_family, 13, QFont.Weight.DemiBold))
        painter.drawText(QRectF(left + 25, 365, 204, 25), Qt.AlignmentFlag.AlignVCenter,
                         f"{index + 1:02d}  {label}")
        painter.setPen(QColor("#75868F"))
        painter.setFont(QFont(font_family, 10))
        painter.drawText(QRectF(left + 25, 397, 205, 21), Qt.AlignmentFlag.AlignVCenter, caption)
        draw_masked_icon(painter, icon, QRectF(left + 228, 370, 48, 48), 11)

    painter.end()
    if not board.save(str(HERE / filename)):
        raise OSError(f"Could not save {filename}")


def main() -> None:
    app = QGuiApplication([])
    font_family = "Arial"
    system_font = Path(os.environ.get("WINDIR", "")) / "Fonts" / "arial.ttf"
    if system_font.is_file():
        font_id = QFontDatabase.addApplicationFont(str(system_font))
        if font_id >= 0:
            font_family = QFontDatabase.applicationFontFamilies(font_id)[0]
    icons: list[QImage] = []
    for stem, _, _ in CONCEPTS:
        icon = render_icon(stem, 1024)
        if not icon.save(str(HERE / f"{stem}.png")):
            raise OSError(f"Could not save {stem}.png")
        small = render_icon(stem, 64)
        if not small.save(str(HERE / f"{stem}-64.png")):
            raise OSError(f"Could not save {stem}-64.png")
        icons.append(icon)
    render_board(icons, font_family, CONCEPTS, "preview-board.png",
                 "AnyWay  /  Icon directions")
    refined_icons = [icons[1]]
    for stem, _, _ in REFINEMENTS[1:]:
        icon = render_icon(stem, 1024)
        if not icon.save(str(HERE / f"{stem}.png")):
            raise OSError(f"Could not save {stem}.png")
        small = render_icon(stem, 64)
        if not small.save(str(HERE / f"{stem}-64.png")):
            raise OSError(f"Could not save {stem}-64.png")
        refined_icons.append(icon)
    render_board(refined_icons, font_family, REFINEMENTS, "offset-refinements.png",
                 "AnyWay  /  Offset refinements")
    app.quit()


if __name__ == "__main__":
    main()
