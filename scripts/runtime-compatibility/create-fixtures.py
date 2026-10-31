#!/usr/bin/env python3
"""Generate only synthetic codec/PDF inputs; never read a browser profile."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import wave


def pdf(blank=False):
    # Own vector document. Only the PDF renderer can supply these page colours.
    content = b"" if blank else b"0 0 1 rg 0 0 144 72 re f 1 1 0 rg 0 72 144 72 re f\n"
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 144 144] /Resources << >> /Contents 4 0 R >>",
        b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"endstream",
    ]
    out = bytearray(b"%PDF-1.4\n"); offsets = [0]
    for number, body in enumerate(objects, 1):
        offsets.append(len(out)); out.extend(f"{number} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = len(out); out.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        out.extend(f"{offset:010d} 00000 n \n".encode())
    out.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(out)


def create(output, ffmpeg):
    if output.exists():
        raise ValueError("Fixture output must be new")
    output.mkdir(mode=0o700)
    cases = []
    commands = []
    for codec, extension, encoder, mime in (
        ("vp8", "webm", "libvpx", 'video/webm; codecs="vp8"'),
        ("vp9", "webm", "libvpx-vp9", 'video/webm; codecs="vp09.00.10.08"'),
        ("h264", "mp4", "libx264", 'video/mp4; codecs="avc1.42C00A"'),
    ):
        name = f"solid-{codec}.{extension}"
        args = [ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=c=red:s=64x48:r=20:d=1", "-an", "-c:v", encoder, "-threads", "2", "-filter_threads", "1", "-pix_fmt", "yuv420p"]
        if codec == "h264":
            args += ["-profile:v", "baseline", "-level:v", "1.0", "-movflags", "+faststart"]
        commands.append((args + [str(output / name)], name))
        cases.append(dict(id=codec, file=name, kind="video", mime=mime))
    with wave.open(str(output / "tone.wav"), "wb") as writer:
        writer.setnchannels(1); writer.setsampwidth(2); writer.setframerate(48000)
        writer.writeframes(b"".join(struct.pack("<h", round(8192 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(48000)))
    cases.append(dict(id="pcm", file="tone.wav", kind="audio", mime='audio/wav; codecs="1"'))
    for codec, encoder, extension, mime in (
        ("opus", "libopus", "webm", 'audio/webm; codecs="opus"'),
        ("aac", "aac", "m4a", 'audio/mp4; codecs="mp4a.40.2"'),
    ):
        name = f"tone-{codec}.{extension}"
        commands.append(([ffmpeg, "-nostdin", "-v", "error", "-i", str(output / "tone.wav"), "-vn", "-c:a", encoder, "-threads", "2", str(output / name)], name))
        cases.append(dict(id=codec, file=name, kind="audio", mime=mime))
    for command, name in commands:
        run = subprocess.run(command, capture_output=True, timeout=30, env={"PATH": os.defpath})
        if run.returncode:
            raise ValueError("Synthetic media generation failed: " + name)
    (output / "colours.pdf").write_bytes(pdf())
    (output / "blank.pdf").write_bytes(pdf(blank=True))
    (output / "invalid.webm").write_bytes(b"OWN INVALID MEDIA NEGATIVE CONTROL\n")
    files = {}
    for file in sorted(output.iterdir()):
        raw = file.read_bytes()
        if len(raw) > 1024 * 1024:
            raise ValueError("Synthetic fixture exceeds size limit")
        file.chmod(0o600)
        files[file.name] = dict(size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
    manifest = dict(schemaVersion=1, kind="own-media-and-vector-pdf", cases=cases, files=files,
                    ffmpegSHA256=hashlib.sha256(Path(ffmpeg).read_bytes()).hexdigest())
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "manifest.json").chmod(0o600)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--ffmpeg", type=Path, default=Path("/opt/homebrew/bin/ffmpeg"))
    args = parser.parse_args()
    manifest = create(args.output, str(args.ffmpeg))
    print(json.dumps(dict(status="fixtures-created", files=len(manifest["files"]), actualBrowser=False)))
