"""Build a macOS ICNS from the checked-in PNG using macOS sips."""

from pathlib import Path
import struct
import subprocess
import sys
from tempfile import TemporaryDirectory


SIZES = ((16, b"icp4"), (32, b"icp5"), (64, b"icp6"),
         (128, b"ic07"), (256, b"ic08"), (512, b"ic09"),
         (1024, b"ic10"))


def build(source: Path, destination: Path) -> None:
    chunks = []
    with TemporaryDirectory() as temp:
        for size, kind in SIZES:
            png = Path(temp) / f"{size}.png"
            subprocess.run(["sips", "-s", "format", "png", "-z", str(size),
                            str(size), str(source), "--out", str(png)],
                           check=True, stdout=subprocess.DEVNULL)
            data = png.read_bytes()
            chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
    body = b"".join(chunks)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: build_icns.py SOURCE.png DESTINATION.icns")
    build(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
