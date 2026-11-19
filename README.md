# Monolitos: un mundo abierto dentro de un QR

Juego en primera persona (.COM de DOS, x86 de 16 bits con instrucciones 386 y FPU) que viaja
**entero dentro de un código QR**. Al escanearlo con el móvil se abre un enlace que lleva el juego
comprimido en la propia URL. Una página fija (la "consola") lo descomprime y lo ejecuta en DOSBox,
con controles táctiles. El juego ocupa 2.991 bytes (2.593 comprimidos) y cabe en un QR 38-L.

## El juego

Despiertas al atardecer en una tierra antigua, distinta en cada partida.

- Busca las **runas** (orbes de luz cian). Cada una suena una nota más aguda.
- Lleva **3 runas** a una de las 4 plataformas de piedra; los haces intermitentes marcan dónde están.
  El monolito se alza.
- **El sol se pone.** El mundo se va oscureciendo y, si llega la noche, esa tierra se pierde y nace
  otra. Cada monolito alzado sube el sol y te da tiempo.
- Combates con un **báculo de luz** (en primera persona, con retroceso al disparar): el orbe de luz
  sigue tu mirada.
- Las **sombras guardianas** rondan las plataformas dormidas y reaparecen con el tiempo. Tienen aura
  y ojos, y se abalanzan cuando estás cerca. Si te tocan, roban sol, se disuelven y esconden una de
  tus runas en otro lugar.
- Los **eclipses** (orbes de centro oscuro y halo brillante) te persiguen por todo el mundo. Si te
  tocan, **roban el doble de sol**. Si los alcanzas con la luz, dejan una **brasa de sol**: recógela
  y el sol sube.
- Cada plataforma es una explanada con un estrado. Al alzarse el monolito la tierra tiembla y
  **despierta**: se aclara en círculo y la piedra se ilumina. El monolito alzado lleva una **corona
  de luz**, su haz late y se convierte en **santuario**: deshace a las sombras y eclipses que se
  acercan (los eclipses dejan su brasa).
- Cada monolito alzado hace más rápidas a sombras y eclipses, y suena un arpegio.
- Al anochecer salen las estrellas. Con los 4 monolitos, la tierra despierta.

Controles: flechas o WASD para andar y girar, espacio para lanzar luz, Esc para salir.
En el móvil, cruceta y botón LUZ en pantalla.

## Cómo está hecho

| Pieza | Técnica |
|---|---|
| Mundo | Mapa de alturas toroidal de 256×256 por diamante-cuadrado, suavizado, centrado en su media y elevado al cuadrado. Lagos y 4 plataformas. Semilla tomada de la hora |
| Render | Un rayo por columna (320), de cerca a lejos, con paso que se duplica a 64, 128 y 192 celdas. **Altura y color bilineales** en las 40 primeras celdas (el color es un índice en una rampa, así que interpolarlo es interpolar el color). x/y empaquetadas en un registro de 32 bits |
| Luz y color | Paleta por fórmula: rampa de atardecer escalada por la altura del sol (del índigo de la noche al oro) y rampa cian de luz que no se apaga de noche. Niebla por tabla `[z/4][color]` |
| Objetos | Esferas sombreadas con z-buffer por píxel (estiradas en vertical para los haces de luz, con sombreado invertido para sombras y eclipses); proyección con FPU. Estrellas que giran con la vista |
| Tiempo | PIT reprogramado a 72,8 Hz + int 1Ch: la lógica va igual de rápida en un móvil lento que en un PC rápido; el render va tan rápido como pueda |
| Memoria | CS=SS código, tablas y variables vía BP (desplazamiento de 1 byte); DS profundidad + 1/z, entidades y plataformas en su cola; FS alturas; GS colores; ES pantalla oculta |
| Tamaño | Rutinas compartidas, tipos de entidad numerados para que abatir sea un desplazamiento, datos colocados para que los bucles terminen al desbordar, vectores de interrupción intercambiados con una sola rutina |
| QR | Deflate (zopfli) + base 43 (los 43 símbolos alfanuméricos del QR seguros en una URL) en un segmento alfanumérico; el prefijo de la URL en un segmento de bytes. Corrección L |

## Estructura

| Ruta | Qué es |
|---|---|
| `src/monolitos.asm` | El juego (NASM) |
| `src/monotest.asm` | Variante de prueba: empieza junto a una plataforma con 3 runas y 3 monolitos alzados, para ver el final |
| `web/play.html` | La consola: lee el juego del enlace (`#…`), lo descomprime y lo ejecuta con js-dos; controles táctiles y descarga del .COM |
| `build.py` | Compila, comprime, genera el QR, lo lee con zxing-cpp y comprueba que reconstruye el juego byte a byte |
| `build/` | Salida (no versionada): `.com`, `.lst`, `-qr.png` y `-url.txt` |

## Uso

Compilar y generar el QR:

```sh
.venv/bin/python build.py src/monolitos.asm --url=https://TU-SITIO/web/play.html#
```

Sin `--url`, el enlace apunta a `http://<IP local>:8512/web/play.html#`, para probar en casa con el
móvil. Para eso, sirve la carpeta en la red local:

```sh
.venv/bin/python -m http.server 8512 --bind 0.0.0.0
```

En el ordenador, abre el enlace de `build/monolitos-url.txt` en el navegador.
`--draft` escribe el enlace aunque el juego no quepa en el QR.

## Entorno

```sh
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python segno zxing-cpp pillow zopfli
```

NASM: descargar `nasm-2.16.03.tar.xz` de nasm.us y `./configure --prefix=$PWD/tools && make && make install`.
