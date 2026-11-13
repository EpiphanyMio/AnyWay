"""Verify the Windows entry points have the intended PE subsystems."""

from pathlib import Path
import struct
import sys


def subsystem(path: Path) -> int:
    data = path.read_bytes()
    if data[:2] != b"MZ":
        raise ValueError(f"Not a Windows executable: {path}")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"Invalid PE header: {path}")
    return struct.unpack_from("<H", data, pe + 4 + 20 + 68)[0]


if __name__ == "__main__":
    folder = Path(sys.argv[1])
    assert subsystem(folder / "AnyWay.exe") == 2, "GUI must have no console"
    assert subsystem(folder / "AnyWayBridge.exe") == 3, "bridge needs standard I/O"
    assert (folder / "runtime").is_dir(), "shared runtime is missing"
    size = sum(path.stat().st_size for path in folder.rglob("*") if path.is_file())
    print(f"AnyWay bundle verified: {size / (1024 ** 2):.1f} MiB")
