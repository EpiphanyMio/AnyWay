"""Restore the pinned Gradle wrapper JAR from its text representation."""
from pathlib import Path
import base64
import hashlib

folder = Path(__file__).resolve().parent / "gradle" / "wrapper"
encoded = folder / "gradle-wrapper.jar.b64"
target = folder / "gradle-wrapper.jar"
data = base64.b64decode(encoded.read_text(encoding="ascii"), validate=False)
expected = "498495120a03b9a6ab5d155f5de3c8f0d986a449153702fb80fc80e134484f17"
if hashlib.sha256(data).hexdigest() != expected:
    raise SystemExit("Gradle wrapper checksum mismatch")
target.write_bytes(data)
print(target)
