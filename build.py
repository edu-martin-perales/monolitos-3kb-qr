#!/usr/bin/env python3
"""Compila el juego, lo mete en un QR y lo verifica.

Uso:  .venv/bin/python build.py [src/archivo.asm] [--url=PREFIJO] [--draft]

El QR contiene una URL  PREFIJO + juego, donde el juego va comprimido (deflate)
y codificado en base 43 (alfabeto alfanumérico del QR que es seguro en URLs).
El prefijo apunta a web/play.html#; la página descomprime el juego y lo ejecuta
en DOSBox. Al escanearlo con el móvil, se abre y se juega.
  - QR versión <= 40, corrección L; prefijo en modo byte, juego en modo alfanumérico.
  - PREFIJO por defecto: http://<IP local>:8512/web/play.html#  (pruebas en la red de casa).
    Para publicar, p. ej.  --url=https://usuario.github.io/monolitos/web/play.html#

Lee el PNG con un decodificador independiente (zxing-cpp) y comprueba que el
enlace reconstruye exactamente el juego. Salida en build/: <nombre>.com, .lst
(listado de NASM), -qr.png y -url.txt (el enlace, para probar en el navegador).
--draft: si no cabe en el QR, avisa pero escribe el enlace igualmente.
"""
import socket
import subprocess
import sys
import zlib
from pathlib import Path

import segno
import zxingcpp
from PIL import Image

ROOT = Path(__file__).resolve().parent
NASM = ROOT / "tools" / "bin" / "nasm"
BUILD = ROOT / "build"

QR_BITS_40L = 2956 * 8  # bits de datos de un QR 40-L
B43 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ$*+-./:"   # sin espacio ni %
SCALE = 8              # píxeles por módulo en el PNG
BORDER = 4             # zona en blanco obligatoria, en módulos


def fail(msg: str) -> None:
    print(f"ERROR: {msg}")
    sys.exit(1)


def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))   # no envía nada; solo elige la interfaz
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def b43_encode(data: bytes) -> str:
    n = int.from_bytes(b"\x01" + data, "big")   # el 1 inicial conserva los ceros de cabeza
    out = []
    while n:
        n, r = divmod(n, 43)
        out.append(B43[r])
    return "".join(reversed(out))


def b43_decode(text: str) -> bytes:
    n = 0
    for ch in text:
        n = n * 43 + B43.index(ch)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return raw[1:]


def deflate(data: bytes) -> bytes:
    """Deflate crudo lo más pequeño posible: zopfli (si está) frente a zlib -9."""
    c = zlib.compressobj(9, zlib.DEFLATED, -15, 9)
    best = c.compress(data) + c.flush()
    try:
        from zopfli.zopfli import compress   # contenedor zlib: 2 bytes de cabecera + 4 de Adler-32
        z = compress(data, numiterations=5000)[2:-4]
        if len(z) < len(best) and zlib.decompress(z, -15) == data:
            best = z
    except ImportError:
        print("AVISO: sin zopfli (uv pip install --python .venv/bin/python zopfli); uso zlib")
    return best


def main() -> None:
    opts = {a.split("=")[0]: a.split("=", 1)[1] if "=" in a else True for a in sys.argv[1:] if a.startswith("--")}
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src = Path(args[0]) if args else ROOT / "src" / "monolitos.asm"
    name = src.stem
    BUILD.mkdir(exist_ok=True)
    com = BUILD / f"{name}.com"

    result = subprocess.run(
        [str(NASM), "-f", "bin", "-i", f"{src.parent}/", "-o", str(com), "-l", str(BUILD / f"{name}.lst"), str(src)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        fail("NASM:\n" + result.stderr)
    data = com.read_bytes()

    prefix = opts.get("--url") or f"http://{lan_ip()}:8512/web/play.html#"
    packed = deflate(data)
    payload = b43_encode(packed)
    assert b43_decode(payload) == packed and zlib.decompress(packed, -15) == data
    link = prefix + payload
    (BUILD / f"{name}-url.txt").write_text(link + "\n")

    used = 4 + 16 + 8 * len(prefix.encode()) + 4 + 13 + (11 * (len(payload) // 2) + 6 * (len(payload) % 2))
    spare_bytes = int((QR_BITS_40L - used) / 5.5 * 5.426 / 8)   # margen en bytes comprimidos
    print(f"Binario:   {com.relative_to(ROOT)}  {len(data)} bytes; comprimido {len(packed)}; "
          f"{len(payload)} caracteres base 43")
    print(f"Margen:    unos {spare_bytes} bytes comprimidos (~{int(spare_bytes * len(data) / len(packed))} de binario)")
    print(f"Enlace:    build/{name}-url.txt  ({len(link)} caracteres)")
    if spare_bytes < 0:
        if "--draft" not in opts:
            fail(f"no cabe en un QR 40-L (faltan ~{-spare_bytes} bytes comprimidos)")
        print("AVISO: borrador; no se genera QR")
        return

    qr = segno.make([(prefix, segno.consts.MODE_BYTE), (payload, segno.consts.MODE_ALPHANUMERIC)], error="l", boost_error=False)
    png = BUILD / f"{name}-qr.png"
    qr.save(png, scale=SCALE, border=BORDER)
    modules = qr.symbol_size(scale=1, border=BORDER)[0]
    print(f"QR:        {png.relative_to(ROOT)}  versión {qr.version}-{qr.error}, "
          f"{modules} módulos con margen; a 0,5 mm/módulo mide {modules * 0.5 / 10:.1f} cm")

    decoded = zxingcpp.read_barcodes(Image.open(png))
    if not decoded:
        fail("zxing-cpp no ha podido leer el QR")
    got = decoded[0].bytes
    if got != link.encode():
        fail(f"el QR no devuelve el enlace esperado (leídos {len(got)} bytes)")
    if zlib.decompress(b43_decode(got.decode()[len(prefix):]), -15) != data:
        fail("el enlace leído no reconstruye el binario")
    print("Verificado: el QR se lee y reconstruye el juego byte a byte")


if __name__ == "__main__":
    main()
