# WallSakura

Fondos de escritorio animados para macOS, sin apps de terceros.

- Reproduce un vídeo en bucle detrás de los iconos del escritorio y se pausa solo cuando hay ventanas encima (opcional), con la pantalla bloqueada o apagada.
- Pone el mismo fondo en la **pantalla de bloqueo**: sustituye el vídeo del aéreo de Apple «Tahoe Day» por el tuyo, recodificado en el formato de los aéreos (HEVC 10 bits, 4K, 5 min).
- **Explorar fondos**: navegador dentro de la propia ventana con MoeWalls, MotionBgs, DesktopHut y WallsFlow. Lo que descargas se convierte a la resolución de tu pantalla y se añade solo. Bloquea anuncios con las listas de uBlock Origin (uBlock filters, EasyList, EasyPrivacy).
- Barra lateral con Todos los fondos, Favoritos, tus carpetas, Explorar y Ajustes.
- Favoritos (corazón en cada fondo) y **cambio automático** cada cierto tiempo, al azar o en orden, de todos los fondos, de los favoritos o de una carpeta.
- **Un fondo distinto en cada pantalla** si tienes varios monitores; cada pantalla se pausa por su cuenta.
- Carpetas, orden por arrastre, renombrar en el sitio, clic derecho para mover, mostrar en Finder o eliminar.
- Interfaz rosa en modo claro y granate en modo oscuro. Icono hecho con Icon Composer, con versión clara y oscura.

## Requisitos

- macOS 15.4 o posterior (probado en macOS 27, Apple Silicon).
- Xcode (para compilar el icono `.icon` con `actool`) y Python 3.

## Compilar e instalar

```sh
codigo/descargar-filtros.sh   # opcional: listas de uBlock Origin Lite para el bloqueador de anuncios
codigo/compilar.sh            # compila e instala /Applications/WallSakura.app
open /Applications/WallSakura.app
```

## Dónde guarda las cosas

| Qué | Dónde |
| --- | --- |
| Tus fondos (y carpetas) | `~/Movies/WallSakura` |
| Ajustes, registro y filtros | `~/Library/Application Support/WallSakura` |
| Vídeo de la pantalla de bloqueo | `~/Library/Application Support/com.apple.wallpaper/aerials/videos/4C108785-…mov` (aéreo «Tahoe Day») |

Para que el fondo salga en la pantalla de bloqueo, en Ajustes del Sistema → Fondo de pantalla elige el aéreo **«Tahoe Day»**. Para recuperar el original de Apple, borra ese archivo y vuelve a descargar el aéreo desde Ajustes.

## Opciones de prueba

`--explorar`, `--abrir <url>`, `--buscar <texto>`, `--depurar`, `--sin-bloqueador`, `--zoom <x>`, `--medir`, `--probar-bloqueo`, `--importar <vídeo>`, `--captura <png> [claro|oscuro|cambio]`. El resultado se apunta en `~/Library/Application Support/WallSakura/registro.log`.

## Créditos

Las listas de filtros vienen de [uBlock Origin Lite](https://github.com/uBlockOrigin/uBOL-home) (GPLv3) y se descargan aparte; no se incluyen en este repositorio.
