# WallSakura

Fondos de escritorio animados para macOS, sin apps de terceros.

![Ventana de WallSakura con la biblioteca de fondos](docs/captura.jpg)

**Tecnologías:** Swift, SwiftUI, AppKit, AVFoundation, VideoToolbox, WebKit, Python (filtros) y Bash (compilación).

## Qué hace

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

## Cómo lo hice

Empecé con lo básico: una ventana sin bordes al nivel del escritorio que reproduce un vídeo en bucle con AVFoundation, por debajo de los iconos. Después añadí la pausa automática para no gastar batería cuando el fondo no se ve.

La parte más difícil fue la pantalla de bloqueo. macOS no deja poner un vídeo propio ahí, así que la app sustituye el vídeo de un aéreo de Apple por el tuyo. Para que el sistema lo acepte hay que recodificarlo igual que los aéreos originales (HEVC de 10 bits, 4K y 5 minutos), y como eso tarda, la app guarda las conversiones en caché.

Al final añadí el navegador de fondos con WebKit, con un bloqueador de anuncios que convierte las listas de uBlock Origin al formato de WebKit con un script de Python.

## Qué aprendí

- Cómo gestiona macOS las ventanas del escritorio y los fondos aéreos.
- Codificar vídeo con VideoToolbox y por qué el formato exacto importa.
- Juntar SwiftUI y AppKit en la misma app.
- Usar WebKit con reglas de contenido propias para bloquear anuncios.

## Qué mejoraría

- Publicar una versión ya compilada (.dmg) para no necesitar Xcode.
- Separar el código en varios archivos (ahora es uno solo de unas 2000 líneas).
- Probarla en más versiones de macOS y con varias pantallas.

## Créditos

Las listas de filtros vienen de [uBlock Origin Lite](https://github.com/uBlockOrigin/uBOL-home) (GPLv3) y se descargan aparte; no se incluyen en este repositorio.
