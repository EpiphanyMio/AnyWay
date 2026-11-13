# AnyWay application icon

`app-icon.svg` is the unmasked source of the selected location pin design. Its route uses
`M285 730C470 730 490 353 700 353`, the version immediately before the
larger curve experiment. `app-icon-source.png` is the square raster source.
Run `python scripts/render_app_icon.py` with Pillow installed to regenerate
the transparent rounded `app-icon.png`, Windows `app-icon.ico`, and padded
macOS `app-icon-macos.png` from that source.

Windows uses the ICO for the executable and installer, and the PNG for the
running window. The macOS build converts the padded macOS PNG to `AnyWay.icns` and places it
in the application bundle.
