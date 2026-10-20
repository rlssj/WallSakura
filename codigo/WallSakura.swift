// WallSakura: fondo de escritorio animado.
// - Reproduce el vídeo elegido en bucle detrás de los iconos y lo pausa cuando hay ventanas a la vista.
// - Al cambiar de fondo también lo pone en la pantalla de bloqueo (sustituye el aéreo "Tahoe Day").
// - Sin icono en la barra de menús: al abrir la app aparece una ventana para elegir fondo; al cerrarla
//   el fondo sigue funcionando por detrás.
// - "Explorar fondos" abre webs de live wallpapers; lo que descargues se convierte y se añade solo.
// Los vídeos viven en ~/Movies/WallSakura; ajustes.json y registro.log junto a la app.
import AppKit
import AVFoundation
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox
import WebKit

// Datos de la app (ajustes, registro, bloqueador de anuncios): ~/Library/Application Support/WallSakura
let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WallSakura")
let carpetaFondos = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/WallSakura")
let ajustesURL = base.appendingPathComponent("ajustes.json")
let registroURL = base.appendingPathComponent("registro.log")
let aereo = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/com.apple.wallpaper/aerials/videos/4C108785-A7BA-422E-9C79-B0129F1D5550.mov")
let extensiones = ["mov", "mp4", "m4v"]
let carpetaFiltros = base.appendingPathComponent("extensiones/filtros")
let carpetaCompilados = base.appendingPathComponent("extensiones/compilados")

// Bloqueador de anuncios: las listas de uBlock Origin (uBlock filters, EasyList, EasyPrivacy) convertidas
// por codigo/filtros.py al bloqueador de contenido de WebKit. Se compilan una vez y se guardan en extensiones/compilados.
func cargarFiltros() async -> [WKContentRuleList] {
    try? FileManager.default.createDirectory(at: carpetaCompilados, withIntermediateDirectories: true)
    guard let store = WKContentRuleListStore(url: carpetaCompilados) else { return [] }
    let archivos = ((try? FileManager.default.contentsOfDirectory(at: carpetaFiltros, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        .filter { $0.pathExtension == "json" }
    var listas: [WKContentRuleList] = []
    for f in archivos {
        let fecha = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let id = "\(f.deletingPathExtension().lastPathComponent)-\(Int(fecha))"
        if let lista = try? await store.contentRuleList(forIdentifier: id) {
            listas.append(lista)
            continue
        }
        do {
            let json = try String(contentsOf: f, encoding: .utf8)
            if let lista = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { listas.append(lista) }
        } catch {
            delegado.log("bloqueador: \(f.lastPathComponent) no compila (\(error.localizedDescription))")
        }
    }
    // Borra compilaciones viejas
    let vigentes = Set(listas.map(\.identifier))
    for id in (await store.availableIdentifiers()) ?? [] where !vigentes.contains(id) { try? await store.removeContentRuleList(forIdentifier: id) }
    return listas
}

let sitios = [("MoeWalls", "https://moewalls.com/"), ("MotionBgs", "https://motionbgs.com/"), ("DesktopHut", "https://www.desktophut.com/"),
              ("WallsFlow", "https://wallsflow.com/")]

// "yoru-from-chainsaw-man.3840x2160" → "Yoru from chainsaw man"
func nombreBonito(_ s: String) -> String {
    var n = s.replacingOccurrences(of: #"\.\d+x\d+$"#, with: "", options: .regularExpression)
    n = n.replacingOccurrences(of: #"[-_ ]?live[-_ ]?wallpaper$"#, with: "", options: [.regularExpression, .caseInsensitive])
    n = n.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    return n.isEmpty ? "Fondo" : n.prefix(1).uppercased() + n.dropFirst()
}

// Ruta en la carpeta de fondos que no pise otro vídeo
func rutaLibre(_ nombre: String, en carpeta: URL = carpetaFondos, extension ext: String = "mov") -> URL {
    let conPunto = ext.isEmpty ? "" : "." + ext
    var url = carpeta.appendingPathComponent(nombre + conPunto)
    var i = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = carpeta.appendingPathComponent("\(nombre) \(i)\(conPunto)")
        i += 1
    }
    return url
}

// Ruta dentro de la carpeta de fondos, p. ej. "Anime/Sora.mov" (así se guarda cuál está puesto)
func rutaRelativa(_ u: URL) -> String {
    let base = carpetaFondos.standardizedFileURL.path + "/"
    let p = u.standardizedFileURL.path
    return p.hasPrefix(base) ? String(p.dropFirst(base.count)) : u.lastPathComponent
}

func esCarpeta(_ u: URL) -> Bool {
    (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}

// Todos los vídeos, también los que están dentro de carpetas
func todosLosFondos() -> [URL] {
    let e = FileManager.default.enumerator(at: carpetaFondos, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    return (e?.allObjects as? [URL] ?? []).filter { extensiones.contains($0.pathExtension.lowercased()) }
}

// Carpetas creadas en la app (un nivel, dentro de la carpeta de fondos)
func carpetasDeFondos() -> [URL] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: carpetaFondos, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    return urls.filter(esCarpeta).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

struct Ajustes: Codable {
    var actual: String?
    var inicioConfigurado: Bool?
    var firma: String?
    var bloqueo: String?   // qué vídeo (y versión del formato) hay en la pantalla de bloqueo
    var pausarConVentanas: Bool?   // nil = sí (lo de siempre)
    var orden: [String: [String]]?   // orden puesto a mano en cada carpeta ("" = Todos los fondos): nombres de archivo
}

let formatoBloqueo = "v2-hevc10-4k"


// Huella de la firma de este ejecutable (cambia cada vez que se recompila)
func firmaActual() -> String? {
    var code: SecCode?
    var estatico: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &estatico) == errSecSuccess, let estatico,
          SecCodeCopySigningInformation(estatico, [], &info) == errSecSuccess,
          let unico = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
    return unico.map { String(format: "%02x", $0) }.joined()
}

// Recodifica en HEVC al tamaño indicado (rellenando y recortando, como se ve en pantalla), repitiendo el clip hasta "total".
func recodificar(_ asset: AVURLAsset, pista: AVAssetTrack, duracion: CMTime, hasta total: CMTime, en salida: URL,
                 ancho: Int, alto: Int, bitrate: Int, diezBits: Bool) async throws {
    try? FileManager.default.removeItem(at: salida)
    let writer = try AVAssetWriter(outputURL: salida, fileType: .mov)
    let entrada = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: ancho,
        AVVideoHeightKey: alto,
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoProfileLevelKey: (diezBits ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String,
        ],
    ])
    entrada.expectsMediaDataInRealTime = false
    writer.add(entrada)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    let formato = diezBits ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    var desfase = CMTime.zero
    vueltas: while desfase < total {
        let reader = try AVAssetReader(asset: asset)
        let lectura = AVAssetReaderTrackOutput(track: pista, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: formato])
        reader.add(lectura)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        while let muestra = lectura.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = CMSampleBufferGetPresentationTimeStamp(muestra) + desfase
            if t >= total { reader.cancelReading(); break vueltas }
            var tiempo = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(muestra), presentationTimeStamp: t, decodeTimeStamp: .invalid)
            var copia: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: muestra, sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &tiempo, sampleBufferOut: &copia)
            while !entrada.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            if let copia, !entrada.append(copia) { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        desfase = desfase + duracion
    }
    entrada.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

// Resolución real de la pantalla principal (la nativa del panel, p. ej. 2560×1664), en números pares
func resolucionPantalla() -> (ancho: Int, alto: Int) {
    let opciones = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modos = (CGDisplayCopyAllDisplayModes(CGMainDisplayID(), opciones) as? [CGDisplayMode]) ?? []
    let p = NSScreen.main ?? NSScreen.screens[0]
    if let nativo = modos.filter({ $0.pixelWidth == $0.width }).max(by: { $0.width < $1.width }) {
        // El alto sale de la forma real de la pantalla (en los MacBook con notch el modo nativo no cuenta esa franja)
        let alto = Double(nativo.width) * p.frame.height / p.frame.width
        return (nativo.width / 2 * 2, Int(alto.rounded()) / 2 * 2)
    }
    return (Int(p.frame.width * p.backingScaleFactor) / 2 * 2, Int(p.frame.height * p.backingScaleFactor) / 2 * 2)
}

// Recodifica una vuelta del vídeo en HEVC 10 bits 4K (como los aéreos de Apple) y luego la repite
// sin recodificar hasta 5 min: así tarda segundos en vez de minutos.
func crearVideoBloqueo(desde url: URL, en salida: URL) async throws {
    try? FileManager.default.removeItem(at: salida)
    let vuelta = salida.deletingPathExtension().appendingPathExtension("vuelta.mov")
    try? FileManager.default.removeItem(at: vuelta)
    defer { try? FileManager.default.removeItem(at: vuelta) }
    let asset = AVURLAsset(url: url)
    guard let pista = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
    let duracion = try await asset.load(.duration)
    let cinco = CMTime(seconds: 300, preferredTimescale: 600)
    let total = CMTimeMinimum(duracion, cinco)

    try await recodificar(asset, pista: pista, duracion: duracion, hasta: total, en: vuelta,
                          ancho: 3840, alto: 2160, bitrate: 14_000_000, diezBits: true)

    // Repetir la vuelta ya codificada hasta llegar a 5 min
    let codificado = AVURLAsset(url: vuelta)
    guard let pistaVuelta = try await codificado.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
    let durVuelta = try await codificado.load(.duration)
    let comp = AVMutableComposition()
    guard let destino = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.fileWriteUnknown) }
    var t = CMTime.zero
    while t < cinco {
        try Task.checkCancellation()
        try destino.insertTimeRange(CMTimeRange(start: .zero, duration: durVuelta), of: pistaVuelta, at: t)
        t = t + durVuelta
    }
    guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.fileWriteUnknown) }
    try await export.export(to: salida, as: .mov)
}

// El clip repetido hasta ~10 min dentro de una sola composición: así no hay salto (ni negro) entre vueltas
func itemEnBucle(_ url: URL) async -> AVPlayerItem {
    let asset = AVURLAsset(url: url)
    guard let pista = try? await asset.loadTracks(withMediaType: .video).first,
          let duracion = try? await asset.load(.duration), duracion.seconds > 0.5 else { return AVPlayerItem(url: url) }
    let comp = AVMutableComposition()
    guard let destino = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return AVPlayerItem(url: url) }
    destino.preferredTransform = (try? await pista.load(.preferredTransform)) ?? .identity
    let objetivo = CMTime(seconds: 600, preferredTimescale: 600)
    var t = CMTime.zero
    while t < objetivo {
        guard (try? destino.insertTimeRange(CMTimeRange(start: .zero, duration: duracion), of: pista, at: t)) != nil else { break }
        t = t + duracion
    }
    return AVPlayerItem(asset: comp)
}

final class Fondo: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let player = AVQueuePlayer()
    var tareaVideo: Task<Void, Never>?
    var ventanas: [NSWindow] = []
    var observadores: [NSKeyValueObservation] = []
    var panel: NSWindow?
    var navegador: NSWindow?
    var nav: Navegador?
    var bloqueado = false
    var tareaBloqueo: Task<Void, Never>?
    var miniaturas: [URL: NSImage] = [:]
    @Published var ajustes = Ajustes()
    @Published var lista: [URL] = []
    @Published var pausaManual = false
    @Published var inicio = false
    @Published var estado = "Pantalla de bloqueo: lista"
    @Published var renombrando: URL?   // fondo o carpeta cuyo nombre se está editando en su tarjeta
    @Published var carpetaActual = carpetaFondos   // carpeta que se está viendo en la ventana
    @Published var carpetas: [URL] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        // "WallSakura --quitar-inicio": solo se borra de Ítems de inicio y se cierra
        if CommandLine.arguments.contains("--quitar-inicio") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        try? FileManager.default.createDirectory(at: carpetaFondos, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? "".write(to: registroURL, atomically: true, encoding: .utf8)
        // Restos de preparaciones de la pantalla de bloqueo que se quedaron a medias
        for f in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix(".bloqueo-") { try? FileManager.default.removeItem(at: f) }
        if let d = try? Data(contentsOf: ajustesURL), let a = try? JSONDecoder().decode(Ajustes.self, from: d) { ajustes = a }

        // La primera vez se apunta solo para abrirse al iniciar sesión (se puede quitar desde la ventana)
        if ajustes.inicioConfigurado != true {
            try? SMAppService.mainApp.register()
            ajustes.inicioConfigurado = true
        }
        // Tras recompilar, macOS deja de reconocer la app en Ítems de inicio: se vuelve a apuntar con la firma nueva
        let firma = firmaActual()
        if firma != ajustes.firma {
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
                try? SMAppService.mainApp.register()
            }
            ajustes.firma = firma
            if let d = try? JSONEncoder().encode(ajustes) { try? d.write(to: ajustesURL) }
        }
        inicio = SMAppService.mainApp.status == .enabled

        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        // El bucle va dentro de un solo vídeo largo; al llegar al final (cada ~10 min) vuelve al principio sin cambiar de vídeo
        player.actionAtItemEnd = .none
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
            self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        for nombre in [AVPlayerItem.playbackStalledNotification, AVPlayerItem.failedToPlayToEndTimeNotification] {
            NotificationCenter.default.addObserver(forName: nombre, object: nil, queue: .main) { [weak self] n in
                self?.log("vídeo: \(n.name.rawValue) \((n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "")")
            }
        }
        crearVentanas()
        crearMenu()

        NotificationCenter.default.addObserver(self, selector: #selector(pantallasCambiadas),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        for (nombre, valor) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
                                (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            wnc.addObserver(forName: nombre, object: nil, queue: .main) { [weak self] _ in self?.bloqueado = valor; self?.actualizar() }
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.actualizar() }
        // Por si has metido o borrado vídeos a mano en la carpeta
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refrescar()
        }

        refrescar()
        if let a = ajustes.actual, let url = todosLosFondos().first(where: { rutaRelativa($0) == a }) {
            poner(url, bloqueo: ajustes.bloqueo != "\(a)#\(formatoBloqueo)")
        } else if let url = lista.first {
            poner(url, bloqueo: true)
        }

        // Al encender el Mac arranca en silencio; si lo abres tú, enseña la ventana
        if ProcessInfo.processInfo.systemUptime > 180 { mostrarPanel() }
        if CommandLine.arguments.contains("--explorar") { mostrarNavegador() }
        // "WallSakura --captura <png> [oscuro]": guarda una imagen de la ventana principal (para pruebas)
        if let i = CommandLine.arguments.firstIndex(of: "--captura"), i + 1 < CommandLine.arguments.count {
            let destino = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            if CommandLine.arguments.contains("oscuro") { panel?.appearance = NSAppearance(named: .darkAqua) }
            if CommandLine.arguments.contains("claro") { panel?.appearance = NSAppearance(named: .aqua) }
            // "cambio": empieza en oscuro y a los 2 s pasa a claro, para ver si la ventana sigue el cambio de modo
            if CommandLine.arguments.contains("cambio") {
                panel?.appearance = NSAppearance(named: .darkAqua)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.panel?.appearance = nil; NSApp.appearance = NSAppearance(named: .aqua) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let v = self?.panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: destino)
            }
        }
        // "WallSakura --importar <vídeo>": añade ese vídeo a la lista (para pruebas)
        if let i = CommandLine.arguments.firstIndex(of: "--importar"), i + 1 < CommandLine.arguments.count {
            importar(URL(fileURLWithPath: CommandLine.arguments[i + 1]), poner: false)
        }
    }

    // Abrir la app cuando ya está funcionando (doble clic, Spotlight, Launchpad…)
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mostrarPanel()
        return true
    }

    // MARK: Ventana de la app

    func mostrarPanel() {
        refrescar()
        inicio = SMAppService.mainApp.status == .enabled
        if panel == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "WallSakura"
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: Panel(fondo: self))
            w.center()
            panel = w
        }
        NSApp.setActivationPolicy(.regular)
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func mostrarNavegador() {
        guard navegador == nil else {
            // Al volver a abrirlo empieza en la página principal de la última web elegida
            if navegador?.isVisible == false, let nav { nav.ir(nav.inicio) }
            NSApp.setActivationPolicy(.regular)
            navegador?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Task { @MainActor in
            let bloqueador = CommandLine.arguments.contains("--sin-bloqueador") ? [] : await cargarFiltros()
            log("bloqueador: \(bloqueador.count) listas de filtros activas")
            guard navegador == nil else { return }
            let n = Navegador(fondo: self, bloqueador: bloqueador)
            // Ancha por defecto: muchas webs (p. ej. WallsFlow) esconden su barra lateral por debajo de ~1300 px
            let pantalla = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let tam = NSSize(width: min(1500, pantalla.width * 0.95), height: min(950, pantalla.height * 0.92))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: tam),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Explorar fondos"
            if let i = CommandLine.arguments.firstIndex(of: "--ancho"), i + 1 < CommandLine.arguments.count, let a = Double(CommandLine.arguments[i + 1]) {
                w.setContentSize(NSSize(width: a, height: 750))
            }
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: Explorador(nav: n))
            w.center()
            nav = n
            navegador = w
            NSApp.setActivationPolicy(.regular)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Al cerrar las ventanas la app desaparece del Dock pero el fondo sigue
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === panel || w === navegador else { return }
        let otras = [panel, navegador].compactMap { $0 }.filter { $0 !== w && $0.isVisible }
        if otras.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    // ⌘Q y ⌘W solo cierran la ventana; para apagar el fondo está el botón "Apagar"
    func crearMenu() {
        let principal = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
        appMenu.addItem(withTitle: "Cerrar ventana", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appItem.submenu = appMenu
        principal.addItem(appItem)
        // Edición, para poder copiar y pegar en las webs
        let editarItem = NSMenuItem()
        let editar = NSMenu(title: "Edición")
        editar.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editar.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editar.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editar.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editarItem.submenu = editar
        principal.addItem(editarItem)
        NSApp.mainMenu = principal
    }

    // MARK: Ventanas del escritorio

    // macOS avisa de "cambio de pantalla" muchas veces (al abrir apps, cambiar de escritorio…). Si siguen las mismas
    // pantallas solo se recolocan las ventanas; destruirlas y crearlas de nuevo hacía parpadear el fondo en negro.
    @objc func pantallasCambiadas() {
        let pantallas = NSScreen.screens
        if pantallas.count == ventanas.count {
            for (w, p) in zip(ventanas, pantallas) where w.frame != p.frame {
                w.setFrame(p.frame, display: true)
            }
        } else {
            log("pantallas: \(ventanas.count) → \(pantallas.count), recreando ventanas del fondo")
            crearVentanas()
        }
    }

    func crearVentanas() {
        ventanas.forEach { $0.close() }
        observadores = []
        ventanas = NSScreen.screens.map { pantalla in
            let w = NSWindow(contentRect: pantalla.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            // Transparente hasta que haya imagen: así no sale negro al iniciar sesión
            w.isOpaque = false
            w.backgroundColor = .clear
            w.alphaValue = 0
            let vista = NSView(frame: pantalla.frame)
            let capa = AVPlayerLayer(player: player)
            capa.videoGravity = .resizeAspectFill
            observadores.append(capa.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak w] capa, _ in
                guard capa.isReadyForDisplay else { return }
                DispatchQueue.main.async {
                    guard let w, w.alphaValue < 1 else { return }
                    NSAnimationContext.runAnimationGroup { $0.duration = 0.8; w.animator().alphaValue = 1 }
                }
            })
            vista.layer = capa
            vista.wantsLayer = true
            w.contentView = vista
            w.setFrame(pantalla.frame, display: true)
            w.orderBack(nil)
            return w
        }
    }

    // MARK: Pausa automática

    var ultimo = ""
    func log(_ t: String) {
        guard t != ultimo else { return }
        ultimo = t
        guard let h = try? FileHandle(forWritingTo: registroURL) else { return }
        h.seekToEndOfFile()
        h.write("\(Date()) \(t)\n".data(using: .utf8)!)
        try? h.close()
    }

    // ¿Hay alguna ventana normal (de cualquier app, también la nuestra) a la vista?
    func ventanaQueTapa() -> String? {
        guard let lista = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let fondosPropios = Set(ventanas.map { $0.windowNumber })
        var n: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &n)
        let pantallas = ids.prefix(Int(n)).map { CGDisplayBounds($0) }
        let tapa = lista.first { v in
            guard (v[kCGWindowLayer as String] as? Int) == 0,
                  !fondosPropios.contains(v[kCGWindowNumber as String] as? Int ?? -1),
                  (v[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let d = v[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d) else { return false }
            // Solo cuenta la parte visible: "Mostrar escritorio" aparta las ventanas a los bordes
            let visible = pantallas.map { $0.intersection(b) }.filter { !$0.isNull }
            return visible.contains { $0.width > 200 && $0.height > 200 }
        }
        return tapa.map { $0[kCGWindowOwnerName as String] as? String ?? "?" }
    }

    func actualizar() {
        let tapa = ajustes.pausarConVentanas == false ? nil : ventanaQueTapa()
        let motivo = bloqueado ? "pantalla bloqueada/apagada" : pausaManual ? "pausa manual" : tapa.map { "ventana de \($0)" }
        log(motivo.map { "pausa: \($0)" } ?? "reproduciendo")
        if motivo != nil {
            if player.rate != 0 { player.pause() }
        } else if player.rate == 0 {
            player.play()
        }
    }

    // MARK: Cambiar de fondo

    func refrescar() {
        if !FileManager.default.fileExists(atPath: carpetaActual.path) { carpetaActual = carpetaFondos }
        carpetas = carpetaActual == carpetaFondos ? carpetasDeFondos() : []
        lista = fondos()
    }

    // Vídeos de la carpeta que se está viendo, de más reciente a más antiguo (según cuándo se añadieron)
    // Los recién llegados (descargados, añadidos o movidos aquí) van primero, del más reciente al más antiguo;
    // después, los demás en el orden que hayas puesto arrastrando.
    func fondos(en carpeta: URL? = nil) -> [URL] {
        let carpeta = carpeta ?? carpetaActual
        let claves: Set<URLResourceKey> = [.addedToDirectoryDateKey, .creationDateKey]
        let urls = ((try? FileManager.default.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: Array(claves))) ?? [])
            .filter { extensiones.contains($0.pathExtension.lowercased()) }
        func fecha(_ u: URL) -> Date {
            let v = try? u.resourceValues(forKeys: claves)
            return v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
        }
        let guardado = ajustes.orden?[claveOrden(carpeta)] ?? []
        let porNombre = Dictionary(urls.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        let conocidos = guardado.compactMap { porNombre[$0] }
        let nuevos = urls.filter { !guardado.contains($0.lastPathComponent) }
            .map { ($0, fecha($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
        return nuevos + conocidos
    }

    func claveOrden(_ carpeta: URL) -> String {
        carpeta.standardizedFileURL == carpetaFondos.standardizedFileURL ? "" : rutaRelativa(carpeta)
    }

    func guardarOrden(_ nombres: [String], en carpeta: URL) {
        var o = ajustes.orden ?? [:]
        o[claveOrden(carpeta)] = nombres
        ajustes.orden = o
        if let d = try? JSONEncoder().encode(ajustes) { try? d.write(to: ajustesURL) }
    }

    // Pone un fondo el primero de su carpeta (al moverlo allí)
    func ponerPrimero(_ url: URL) {
        let carpeta = url.deletingLastPathComponent()
        var nombres = fondos(en: carpeta).map(\.lastPathComponent).filter { $0 != url.lastPathComponent }
        nombres.insert(url.lastPathComponent, at: 0)
        guardarOrden(nombres, en: carpeta)
    }

    // Arrastrar un fondo sobre otro: se coloca en su sitio (o se mueve a esta carpeta si venía de otra)
    func soltar(_ urls: [URL], sobre destino: URL) -> Bool {
        let carpeta = destino.deletingLastPathComponent()
        let dentro = carpetaFondos.standardizedFileURL.path + "/"
        for u in urls {
            var u = u
            guard u.standardizedFileURL != destino.standardizedFileURL else { continue }
            if !u.standardizedFileURL.path.hasPrefix(dentro) {
                _ = soltar([u], en: carpeta)   // viene de Finder: se añade
                continue
            }
            if esCarpeta(u) { continue }
            if u.deletingLastPathComponent().standardizedFileURL != carpeta.standardizedFileURL {
                guard let movido = mover(u, a: carpeta) else { continue }
                u = movido
            }
            let antes = fondos(en: carpeta).map(\.lastPathComponent)
            let desde = antes.firstIndex(of: u.lastPathComponent) ?? 0
            let hasta = antes.firstIndex(of: destino.lastPathComponent) ?? 0
            var nombres = antes.filter { $0 != u.lastPathComponent }
            // Arrastrado hacia delante (derecha/abajo) queda detrás del fondo donde lo sueltas; hacia atrás, delante
            let i = (nombres.firstIndex(of: destino.lastPathComponent) ?? 0) + (desde < hasta ? 1 : 0)
            nombres.insert(u.lastPathComponent, at: min(i, nombres.count))
            guardarOrden(nombres, en: carpeta)
        }
        refrescar()
        return true
    }

    func elegir(_ url: URL) {
        guard rutaRelativa(url) != ajustes.actual else { return }
        poner(url, bloqueo: true)
    }

    func poner(_ url: URL, bloqueo: Bool) {
        tareaVideo?.cancel()
        tareaVideo = Task { @MainActor in
            let item = await itemEnBucle(url)
            guard !Task.isCancelled else { return }
            player.replaceCurrentItem(with: item)
            actualizar()
        }
        ajustes.actual = rutaRelativa(url)
        if let d = try? JSONEncoder().encode(ajustes) { try? d.write(to: ajustesURL) }
        player.pause()
        actualizar()
        if bloqueo { prepararBloqueo(url) }
    }

    // Crea el vídeo de la pantalla de bloqueo con el formato de los aéreos de Apple
    // (HEVC 10 bits, 3840×2160, ~5 min) y lo pone en el aéreo "Tahoe Day".
    func prepararBloqueo(_ url: URL) {
        tareaBloqueo?.cancel()
        let marca = "\(rutaRelativa(url))#\(formatoBloqueo)"
        estado = "Pantalla de bloqueo: preparando… (tarda un poco)"
        // Nombre único: si cambias de fondo rápido, la tarea cancelada no borra el archivo de la nueva
        let temp = base.appendingPathComponent(".bloqueo-\(UUID().uuidString).mov")
        tareaBloqueo = Task.detached(priority: .utility) { [weak self] in
            do {
                try await crearVideoBloqueo(desde: url, en: temp)
                try Task.checkCancellation()
                await MainActor.run { self?.instalarBloqueo(temp, marca) }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: temp)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                await MainActor.run {
                    self?.log("bloqueo: error al crear el vídeo: \(error as NSError)")
                    self?.estado = "Pantalla de bloqueo: error (\(error.localizedDescription))"
                }
            }
        }
    }

    func instalarBloqueo(_ temp: URL, _ marca: String) {
        do {
            try FileManager.default.createDirectory(at: aereo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: aereo)
            try FileManager.default.moveItem(at: temp, to: aereo)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            p.arguments = ["WallpaperAgent"]
            try? p.run()
            ajustes.bloqueo = marca
            if let d = try? JSONEncoder().encode(ajustes) { try? d.write(to: ajustesURL) }
            estado = "Pantalla de bloqueo: lista"
        } catch {
            log("bloqueo: error al instalar el vídeo: \(error as NSError)")
            estado = "Pantalla de bloqueo: error (\(error.localizedDescription))"
        }
    }

    // Guarda el vídeo sin audio en la carpeta de fondos, ajustado a la resolución de la pantalla
    // (rellenándola y recortando lo que no se vería). Solo si ya tiene justo ese tamaño se guarda tal cual.
    func importar(_ origen: URL, en carpeta: URL? = nil, poner ponerlo: Bool = true, borrarOrigen: Bool = false, terminado: ((Bool) -> Void)? = nil) {
        let nombre = nombreBonito(origen.deletingPathExtension().lastPathComponent)
        estado = "Añadiendo \(nombre)…"
        let asset = AVURLAsset(url: origen)
        try? FileManager.default.createDirectory(at: carpetaFondos, withIntermediateDirectories: true)
        let salida = rutaLibre(nombre, en: carpeta ?? carpetaActual)
        Task { @MainActor in
            var aviso = ""
            do {
                guard let pista = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
                let duracion = try await asset.load(.duration)
                let giro = try await pista.load(.preferredTransform)
                let tam = try await pista.load(.naturalSize).applying(giro)
                let fps = Double(try await pista.load(.nominalFrameRate))
                let bitrate = Double(try await pista.load(.estimatedDataRate))
                let ancho = Int(abs(tam.width)), alto = Int(abs(tam.height))
                let pantalla = resolucionPantalla()
                log("importar \(origen.lastPathComponent): \(ancho)×\(alto) a \(Int(fps)) fps, \(Int(bitrate / 1_000_000)) Mbps → pantalla \(pantalla.ancho)×\(pantalla.alto)")
                if min(ancho, alto) < 720 {
                    aviso = " — ⚠︎ baja calidad (\(ancho)×\(alto)): la web solo daba esa versión o era la vista previa"
                }
                let exacto = ancho == pantalla.ancho && alto == pantalla.alto
                if exacto && bitrate <= 30_000_000 {
                    // Ya tiene la resolución de la pantalla: se copia tal cual
                    let comp = AVMutableComposition()
                    guard let destino = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                          let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.fileWriteUnknown) }
                    try destino.insertTimeRange(CMTimeRange(start: .zero, duration: duracion), of: pista, at: .zero)
                    destino.preferredTransform = giro
                    try await export.export(to: salida, as: .mov)
                } else {
                    // Calidad alta para el tamaño: ~0,08 bits por píxel, entre 8 y 30 Mbps
                    let objetivo = Double(pantalla.ancho * pantalla.alto) * max(fps, 24) * 0.08
                    let tasa = Int(min(max(objetivo, 8_000_000), 30_000_000))
                    estado = "Ajustando \(nombre) a \(pantalla.ancho)×\(pantalla.alto)…"
                    try await recodificar(asset, pista: pista, duracion: duracion, hasta: duracion, en: salida,
                                          ancho: pantalla.ancho, alto: pantalla.alto, bitrate: tasa, diezBits: false)
                }
                if borrarOrigen { try? FileManager.default.removeItem(at: origen) }
                miniaturas[salida] = nil
                refrescar()
                estado = "Añadido: \(nombre)\(aviso)"
                if ponerlo { poner(salida, bloqueo: true) }
                terminado?(true)
            } catch {
                log("importar: error \(error as NSError)")
                if borrarOrigen { try? FileManager.default.removeItem(at: origen) }
                try? FileManager.default.removeItem(at: salida)
                estado = "No se pudo añadir el vídeo"
                terminado?(false)
            }
        }
    }

    // MARK: Acciones de la ventana

    func miniatura(_ url: URL) -> NSImage? {
        if let m = miniaturas[url] { return m }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 270)
        guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        miniaturas[url] = img
        return img
    }

    func anadir() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = "Elige un vídeo para el fondo"
        if panel.runModal() == .OK, let url = panel.url { importar(url) }
    }

    func abrirCarpeta() { NSWorkspace.shared.open(carpetaActual) }

    func renombrar(_ url: URL, a texto: String) {
        renombrando = nil
        let viejo = url.deletingPathExtension().lastPathComponent
        let nuevo = texto.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !nuevo.isEmpty, nuevo != viejo else { return }
        let carpeta = esCarpeta(url)
        let destino = url.deletingLastPathComponent().appendingPathComponent(carpeta ? nuevo : nuevo + "." + url.pathExtension)
        guard !FileManager.default.fileExists(atPath: destino.path) else {
            estado = "Ya hay \(carpeta ? "una carpeta" : "un fondo") que se llama \(nuevo)"
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: destino)
        } catch {
            estado = "No se pudo renombrar \(viejo)"
            return
        }
        reubicado(de: url, a: destino)
        refrescar()
        estado = "Renombrado a \(nuevo)"
    }

    // Tras mover o renombrar: que el fondo puesto y la pantalla de bloqueo lo sigan reconociendo
    func reubicado(de viejo: URL, a nuevo: URL) {
        let rv = rutaRelativa(viejo), rn = rutaRelativa(nuevo)
        func cambiar(_ r: String) -> String? {
            if r == rv { return rn }
            if r.hasPrefix(rv + "/") { return rn + r.dropFirst(rv.count) }
            if r.hasPrefix(rv + "#") { return rn + r.dropFirst(rv.count) }
            return nil
        }
        if let a = ajustes.actual, let n = cambiar(a) { ajustes.actual = n }
        if let b = ajustes.bloqueo, let n = cambiar(b) { ajustes.bloqueo = n }
        if var o = ajustes.orden {
            // Renombrado en la misma carpeta: conserva su sitio
            if viejo.deletingLastPathComponent() == nuevo.deletingLastPathComponent() {
                let k = claveOrden(viejo.deletingLastPathComponent())
                o[k] = o[k]?.map { $0 == viejo.lastPathComponent ? nuevo.lastPathComponent : $0 }
            }
            // Carpeta renombrada: su orden pasa a la clave nueva
            if let lista = o.removeValue(forKey: rv) { o[rn] = lista }
            ajustes.orden = o
        }
        if let d = try? JSONEncoder().encode(ajustes) { try? d.write(to: ajustesURL) }
        miniaturas = miniaturas.filter { !$0.key.path.hasPrefix(viejo.path) }
    }

    // MARK: Carpetas

    func nuevaCarpeta() {
        let url = rutaLibre("Carpeta nueva", en: carpetaFondos, extension: "")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            estado = "No se pudo crear la carpeta"
            return
        }
        refrescar()
        renombrando = url
    }

    func abrir(_ carpeta: URL) {
        renombrando = nil
        carpetaActual = carpeta
        refrescar()
    }

    @discardableResult
    func mover(_ url: URL, a carpeta: URL) -> URL? {
        guard url.deletingLastPathComponent().standardizedFileURL != carpeta.standardizedFileURL else { return nil }
        let nombre = url.deletingPathExtension().lastPathComponent
        let destino = rutaLibre(nombre, en: carpeta, extension: url.pathExtension)
        do {
            try FileManager.default.moveItem(at: url, to: destino)
        } catch {
            estado = "No se pudo mover \(nombre)"
            return nil
        }
        reubicado(de: url, a: destino)
        ponerPrimero(destino)
        refrescar()
        estado = "\(nombre) movido a \(carpeta == carpetaFondos ? "Todos los fondos" : carpeta.lastPathComponent)"
        return destino
    }

    // Lo que se suelta en una carpeta: si ya es un fondo se mueve; si viene de fuera (Finder) se añade
    func soltar(_ urls: [URL], en carpeta: URL) -> Bool {
        let dentro = carpetaFondos.standardizedFileURL.path + "/"
        for u in urls {
            if u.standardizedFileURL.path.hasPrefix(dentro) {
                if !esCarpeta(u) { mover(u, a: carpeta) }
            } else if extensiones.contains(u.pathExtension.lowercased()) || (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .movie)) == true {
                importar(u, en: carpeta, poner: false)
            }
        }
        return true
    }

    // Borra la carpeta y sus fondos para siempre
    func eliminarCarpeta(_ carpeta: URL) {
        let n = fondos(en: carpeta).count
        guard confirmarBorrado("¿Eliminar la carpeta «\(carpeta.lastPathComponent)»" + (n > 0 ? " y sus \(n) fondos?" : "?")) else { return }
        let teniaActual = ajustes.actual?.hasPrefix(rutaRelativa(carpeta) + "/") == true
        do {
            try FileManager.default.removeItem(at: carpeta)
        } catch {
            estado = "No se pudo eliminar la carpeta"
            return
        }
        refrescar()
        estado = "Carpeta \(carpeta.lastPathComponent) eliminada"
        if teniaActual { siguienteFondo() }
    }

    // Si se quita el fondo puesto, pasa a otro; si no queda ninguno, deja el escritorio normal
    func siguienteFondo() {
        if let otro = lista.first ?? todosLosFondos().first {
            poner(otro, bloqueo: true)
        } else {
            tareaVideo?.cancel()
            player.removeAllItems()
            ajustes.actual = nil
            if let d = try? JSONEncoder().encode(ajustes) { try? d.write(to: ajustesURL) }
        }
    }

    func confirmarBorrado(_ titulo: String) -> Bool {
        let a = NSAlert()
        a.messageText = titulo
        a.informativeText = "Se borra para siempre, no va a la Papelera."
        a.alertStyle = .warning
        a.addButton(withTitle: "Eliminar")
        a.addButton(withTitle: "Cancelar")
        a.buttons.first?.hasDestructiveAction = true
        return a.runModal() == .alertFirstButtonReturn
    }

    // Borra el vídeo para siempre; si era el fondo puesto, pasa al siguiente de la lista
    func eliminar(_ url: URL) {
        let nombre = url.deletingPathExtension().lastPathComponent
        guard confirmarBorrado("¿Eliminar «\(nombre)»?") else { return }
        let eraActual = rutaRelativa(url) == ajustes.actual
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            estado = "No se pudo eliminar \(nombre)"
            return
        }
        miniaturas[url] = nil
        refrescar()
        estado = "\(nombre) eliminado"
        if eraActual { siguienteFondo() }
    }

    func cambiarPausaConVentanas(_ si: Bool) {
        ajustes.pausarConVentanas = si
        if let d = try? JSONEncoder().encode(ajustes) { try? d.write(to: ajustesURL) }
        actualizar()
    }

    func alternarPausa() {
        pausaManual.toggle()
        actualizar()
    }

    func alternarInicio() {
        let s = SMAppService.mainApp
        do {
            if s.status == .enabled { try s.unregister() } else { try s.register() }
        } catch {
            estado = "No se pudo cambiar el inicio: \(error.localizedDescription)"
        }
        inicio = s.status == .enabled
    }

    func salir() { NSApp.terminate(nil) }
}

// MARK: Interfaz

// Colores de WallSakura: rosa en modo claro, rosa oscuro en modo oscuro
func rgb(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

extension Color {
    static func segunModo(claro: UInt32, oscuro: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(oscuro) : rgb(claro)
        })
    }
    static let rosa = segunModo(claro: 0xE5487F, oscuro: 0xC2386E)          // botones, selección, casillas
    static let fondoArriba = segunModo(claro: 0xFFF6F9, oscuro: 0x1D1016)   // degradado de la ventana
    static let fondoAbajo = segunModo(claro: 0xFCE3ED, oscuro: 0x2B1320)
    static let panelRosa = segunModo(claro: 0xFFFFFF, oscuro: 0x3A1A2A)     // tarjetas de carpeta y barra de abajo
}

struct FondoRosa: View {
    var body: some View {
        LinearGradient(colors: [.fondoArriba, .fondoAbajo], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }
}

struct Panel: View {
    @ObservedObject var fondo: Fondo
    let columnas = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    @ViewBuilder var menuVacio: some View {
        if fondo.carpetaActual == carpetaFondos {
            Button("Nueva carpeta") { fondo.nuevaCarpeta() }
        }
        Button("Añadir vídeo…") { fondo.anadir() }
        Button("Explorar fondos…") { fondo.mostrarNavegador() }
        Divider()
        Button("Abrir en Finder") { fondo.abrirCarpeta() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if fondo.carpetaActual != carpetaFondos {
                    Button { fondo.abrir(carpetaFondos) } label: { Label("Todos los fondos", systemImage: "chevron.left") }
                        // Soltar aquí un fondo lo saca de la carpeta
                        .dropDestination(for: URL.self) { urls, _ in fondo.soltar(urls, en: carpetaFondos) }
                    Text(fondo.carpetaActual.lastPathComponent).font(.title2.bold())
                } else {
                    Text("Todos los fondos").font(.title2.bold())
                }
                Spacer()
            }
            if fondo.lista.isEmpty && fondo.carpetas.isEmpty {
                Text(fondo.carpetaActual == carpetaFondos
                     ? "No hay vídeos. Pulsa «Explorar fondos…» o «Añadir vídeo…» para empezar."
                     : "Carpeta vacía. Arrastra fondos aquí o al nombre de la carpeta.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .contextMenu { menuVacio }
            } else {
                ScrollView {
                    LazyVGrid(columns: columnas, spacing: 16) {
                        ForEach(fondo.carpetas, id: \.self) { carpeta in
                            TarjetaCarpeta(fondo: fondo, url: carpeta)
                        }
                        ForEach(fondo.lista, id: \.self) { url in
                            Tarjeta(fondo: fondo, url: url)
                        }
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, minHeight: 300, alignment: .top)
                    .contentShape(Rectangle())
                }
                // Clic derecho en el espacio libre (en una tarjeta sale su propio menú)
                .contextMenu { menuVacio }
            }
            Text(fondo.estado)
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button("Explorar fondos…") { fondo.mostrarNavegador() }
                        .buttonStyle(.borderedProminent)
                    Button("Añadir vídeo…") { fondo.anadir() }
                    Button("Abrir carpeta") { fondo.abrirCarpeta() }
                    Spacer()
                    Button("Apagar WallSakura") { fondo.salir() }
                }
                HStack(spacing: 18) {
                    Toggle("Pausado", isOn: Binding(get: { fondo.pausaManual }, set: { _ in fondo.alternarPausa() }))
                    Toggle("Pausar con ventanas abiertas", isOn: Binding(get: { fondo.ajustes.pausarConVentanas != false }, set: { fondo.cambiarPausaConVentanas($0) }))
                        .help("Si lo quitas, el fondo se mueve siempre aunque tengas ventanas encima (gasta algo más de batería)")
                    Toggle("Abrir al iniciar sesión", isOn: Binding(get: { fondo.inicio }, set: { _ in fondo.alternarInicio() }))
                    Spacer()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(Color.panelRosa.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 400)
        .background(FondoRosa())
        .tint(.rosa)
        // Vídeos arrastrados desde Finder a la ventana: se añaden a la carpeta abierta
        .dropDestination(for: URL.self) { urls, _ in fondo.soltar(urls, en: fondo.carpetaActual) }
    }
}

// Nombre editable en el sitio (Intro guarda, Esc cancela, clic fuera también guarda)
struct NombreEditable: View {
    @ObservedObject var fondo: Fondo
    let url: URL
    let nombre: String
    let negrita: Bool
    @State private var texto = ""
    @FocusState private var enfocado: Bool

    var body: some View {
        if fondo.renombrando == url {
            TextField("Nombre", text: $texto)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .focused($enfocado)
                .onAppear {
                    texto = nombre
                    DispatchQueue.main.async { enfocado = true }
                }
                .onSubmit { fondo.renombrar(url, a: texto) }
                .onExitCommand { fondo.renombrando = nil }
                .onChange(of: enfocado) { _, ahora in
                    if !ahora && fondo.renombrando == url { fondo.renombrar(url, a: texto) }
                }
        } else {
            Text(nombre).fontWeight(negrita ? .semibold : .regular)
        }
    }
}

struct TarjetaCarpeta: View {
    @ObservedObject var fondo: Fondo
    let url: URL
    @State private var encima = false

    var body: some View {
        let videos = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { extensiones.contains($0.pathExtension.lowercased()) }
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.panelRosa.opacity(encima ? 0.95 : 0.6))
                VStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.system(size: 44)).foregroundStyle(Color.rosa)
                    Text(videos.count == 1 ? "1 fondo" : "\(videos.count) fondos").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(encima ? Color.rosa : .clear, lineWidth: 3))
            NombreEditable(fondo: fondo, url: url, nombre: url.lastPathComponent, negrita: false)
        }
        .contentShape(Rectangle())
        .onTapGesture { if fondo.renombrando != url { fondo.abrir(url) } }
        // Arrastra un fondo encima para meterlo en la carpeta
        .dropDestination(for: URL.self) { urls, _ in fondo.soltar(urls, en: url) } isTargeted: { encima = $0 }
        .contextMenu {
            Button("Abrir") { fondo.abrir(url) }
            Button("Renombrar") { fondo.renombrando = url }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Eliminar carpeta", role: .destructive) { fondo.eliminarCarpeta(url) }
        }
    }
}

struct Tarjeta: View {
    @ObservedObject var fondo: Fondo
    let url: URL
    @State private var encima = false

    var body: some View {
        let elegido = rutaRelativa(url) == fondo.ajustes.actual
        VStack(spacing: 8) {
            Group {
                if let img = fondo.miniatura(url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.black
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(elegido ? Color.rosa : .clear, lineWidth: 3))
            NombreEditable(fondo: fondo, url: url, nombre: url.deletingPathExtension().lastPathComponent, negrita: elegido)
        }
        .contentShape(Rectangle())
        .onTapGesture { if fondo.renombrando != url { fondo.elegir(url) } }
        .draggable(url)
        // Suelta otro fondo encima para ponerlo en este sitio
        .dropDestination(for: URL.self) { urls, _ in fondo.soltar(urls, sobre: url) } isTargeted: { encima = $0 }
        .overlay {
            if encima { RoundedRectangle(cornerRadius: 12).stroke(Color.rosa, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(-4) }
        }
        .contextMenu {
            Button("Poner de fondo") { fondo.elegir(url) }
            Button("Renombrar") { fondo.renombrando = url }
            Menu("Mover a") {
                if fondo.carpetaActual != carpetaFondos {
                    Button("Todos los fondos (sin carpeta)") { fondo.mover(url, a: carpetaFondos) }
                }
                ForEach(carpetasDeFondos().filter { $0 != fondo.carpetaActual }, id: \.self) { c in
                    Button(c.lastPathComponent) { fondo.mover(url, a: c) }
                }
                Divider()
                Button("Nueva carpeta…") {
                    fondo.nuevaCarpeta()
                    if let nueva = fondo.renombrando { fondo.mover(url, a: nueva) }
                }
            }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Eliminar fondo", role: .destructive) { fondo.eliminar(url) }
        }
    }
}

// MARK: Explorar fondos (navegador)

final class Navegador: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let web: WKWebView
    weak var fondo: Fondo?
    @Published var puedeAtras = false
    @Published var puedeAdelante = false
    @Published var sitio = ""
    @Published var descarga: String?
    @Published var progreso = 1.0
    var observaciones: [NSKeyValueObservation] = []
    var destinos: [ObjectIdentifier: URL] = [:]
    var inicio = sitios[0].1   // página principal de la última web elegida
    var buscado = false
    var empiezo = Date()
    var medir: [String] = CommandLine.arguments.contains("--medir")
        ? sitios.dropFirst().map(\.1) : []   // "--medir": carga cada web y apunta cuánto tarda

    init(fondo: Fondo, bloqueador: [WKContentRuleList]) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // sin cookies ni caché guardadas en el Mac
        bloqueador.forEach(config.userContentController.add)
        web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        self.fondo = fondo
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        observaciones = [
            web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] w, _ in self?.puedeAtras = w.canGoBack },
            web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] w, _ in self?.puedeAdelante = w.canGoForward },
            web.observe(\.url, options: [.initial, .new]) { [weak self] w, _ in self?.sitio = w.url?.host ?? "" },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in self?.progreso = w.isLoading ? w.estimatedProgress : 1 },
            web.observe(\.isLoading, options: [.new]) { [weak self] w, _ in if !w.isLoading { self?.progreso = 1 } },
        ]
        if let i = CommandLine.arguments.firstIndex(of: "--zoom"), i + 1 < CommandLine.arguments.count, let z = Double(CommandLine.arguments[i + 1]) {
            web.pageZoom = z
        }
        // "--abrir <web>": empieza en esa web (para pruebas)
        if let i = CommandLine.arguments.firstIndex(of: "--abrir"), i + 1 < CommandLine.arguments.count {
            ir(CommandLine.arguments[i + 1])
        } else {
            ir(sitios[0].1)
        }
    }

    func ir(_ direccion: String) {
        if let u = URL(string: direccion) { web.load(URLRequest(url: u)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        fondo?.log(String(format: "web cargada en %.1f s: %@", Date().timeIntervalSince(empiezo), webView.url?.absoluteString ?? "?"))
        if !medir.isEmpty { ir(medir.removeFirst()) }
        // "--buscar <texto>": rellena el buscador de la web, pulsa Intro y apunta adónde va (para pruebas)
        if let i = CommandLine.arguments.firstIndex(of: "--buscar"), i + 1 < CommandLine.arguments.count, !buscado,
           webView.title?.hasPrefix("Un momento") != true {
            buscado = true
            let js = """
            for (let i = 0; i < 40 && document.title.startsWith('Un momento'); i++) await new Promise(r => setTimeout(r, 500));
            if (document.title.startsWith('Un momento')) return 'sigue en Cloudflare';
            await new Promise(r => setTimeout(r, 2500));
            const boton = [...document.querySelectorAll('button, a, div, span')].find(e => /^\\s*search/i.test(e.textContent || '') && e.children.length < 4 && e.offsetParent !== null);
            if (boton && ![...document.querySelectorAll('input')].some(e => e.offsetParent !== null)) { boton.click(); await new Promise(r => setTimeout(r, 1000)); }
            const c = [...document.querySelectorAll('input')].find(e => /search|text/.test(e.type) && e.offsetParent !== null) || document.querySelector('input[type=search], input[name=s], input[name=q]');
            if (!c) return 'sin buscador';
            c.focus(); c.value = texto; c.dispatchEvent(new Event('input', {bubbles: true}));
            for (const t of ['keydown', 'keypress', 'keyup']) c.dispatchEvent(new KeyboardEvent(t, {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true}));
            const f = c.form; if (f) { f.requestSubmit ? f.requestSubmit() : f.submit(); }
            return 'buscador ' + (c.name || c.id || c.className) + ' formulario=' + (f ? (f.method + ' ' + f.action + ' target=' + f.target) : 'ninguno');
            """
            webView.callAsyncJavaScript(js, arguments: ["texto": CommandLine.arguments[i + 1]], in: nil, in: .page) { [weak self] r in
                switch r {
                case .success(let v): self?.fondo?.log("buscar: \(v ?? "")")
                case .failure(let e): self?.fondo?.log("buscar fallo: \(e)")
                }
            }
        }
        // "--depurar": apunta qué barras laterales hay en la página y si se ven
        if CommandLine.arguments.contains("--depurar") {
            let js = """
            await new Promise(r => setTimeout(r, 3000));
            const els = [...document.querySelectorAll('body *')].filter(e => { const b = e.getBoundingClientRect(); return b.x < 40 && b.height > innerHeight * 0.6 && b.width > 40 && b.width < innerWidth * 0.5; }).slice(0, 8)
              .concat([...document.querySelectorAll('aside, nav, [class*=sidebar i], [class*=side-bar i], [id*=sidebar i], [class*=drawer i]')].slice(0, 8));
            const medias = new Set();
            for (const h of document.styleSheets) { try { for (const r of h.cssRules) { if (r.media && r.cssText.includes('sidebar')) medias.add(r.media.mediaText); } } catch (e) {} }
            return 'medias=' + [...medias].join(' ; ') + ' ancho=' + innerWidth + ' titulo=' + document.title + ' elementos=' + document.querySelectorAll('*').length + ' texto=' + document.body.innerText.slice(0, 300).replace(/\\s+/g, ' ') + ' | ' + els.map(e => {
              const b = e.getBoundingClientRect(), c = getComputedStyle(e);
              return e.tagName + '.' + String(e.className).slice(0, 50) + ' display=' + c.display + ' vis=' + c.visibility + ' x=' + (b.x|0) + ' w=' + (b.width|0) + ' h=' + (b.height|0);
            }).join(' | ');
            """
            webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] r in
                if case .success(let v) = r { self?.fondo?.log("depurar: \(v ?? "")") }
                if case .failure(let e) = r { self?.fondo?.log("depurar fallo: \(e)") }
            }
        }
        if CommandLine.arguments.contains("--probar-bloqueo") {
            let js = """
            return await fetch('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js', {mode: 'no-cors'})
              .then(() => 'anuncio NO bloqueado').catch(() => 'anuncio bloqueado');
            """
            webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] r in
                switch r {
                case .success(let v):
                    self?.fondo?.log("prueba: \(v)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { webView.reload() }
                case .failure(let e): self?.fondo?.log("prueba fallo: \(e.localizedDescription)")
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fondo?.log("web error: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fondo?.log("web no carga: \(error.localizedDescription) \(webView.url?.absoluteString ?? "")")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fondo?.log("web: el proceso de la página se cerró, recargando")
        webView.reload()
    }

    func pareceDescarga(_ u: URL) -> Bool {
        extensiones.contains(u.pathExtension.lowercased()) || u.absoluteString.lowercased().contains("download")
    }

    // Ventanas nuevas: se abren aquí mismo si vienen de un clic en un enlace o son descargas; el resto (anuncios) se ignora
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated || action.navigationType == .formSubmitted || action.request.url.map(pareceDescarga) == true {
            webView.load(action.request)
        } else {
            fondo?.log("ventana emergente bloqueada (\(action.navigationType.rawValue)): \(action.request.url?.absoluteString ?? "")")
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true { empiezo = Date() }
        if CommandLine.arguments.contains("--buscar") {
            fondo?.log("navegar (\(action.navigationType.rawValue), principal=\(action.targetFrame?.isMainFrame ?? false)): \(action.request.url?.absoluteString ?? "")")
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    // Un vídeo o un archivo adjunto se descarga en vez de abrirse
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let mime = response.response.mimeType ?? ""
        let disposicion = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let descargar = response.isForMainFrame && (mime.hasPrefix("video/") || disposicion.lowercased().contains("attachment") || !response.canShowMIMEType)
        decisionHandler(descargar ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { empezar(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { empezar(download) }

    func empezar(_ d: WKDownload) {
        d.delegate = self
        descarga = "Descargando…"
        observaciones.append(d.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let pct = Int(p.fractionCompleted * 100)
            DispatchQueue.main.async { self?.descarga = "Descargando… \(pct) %" }
        })
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let carpeta = carpetaFondos.appendingPathComponent(".descargas")
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let destino = carpeta.appendingPathComponent(suggestedFilename)
        try? FileManager.default.removeItem(at: destino)
        destinos[ObjectIdentifier(download)] = destino
        completionHandler(destino)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard var u = destinos.removeValue(forKey: ObjectIdentifier(download)) else { return }
        // Algunas webs (p. ej. Wallpaper Engine) dan un .zip: se descomprime y se usa el vídeo más grande de dentro
        if u.pathExtension.lowercased() == "zip" {
            guard let video = videoDentroDeZip(u) else {
                descarga = "Ese .zip no tiene ningún vídeo (puede ser un fondo de tipo escena, que no es vídeo)"
                return
            }
            u = video
        }
        guard extensiones.contains(u.pathExtension.lowercased()) else {
            try? FileManager.default.removeItem(at: u)
            descarga = "Eso no era un vídeo (\(u.pathExtension))"
            return
        }
        descarga = "Convirtiendo \(nombreBonito(u.deletingPathExtension().lastPathComponent))…"
        fondo?.importar(u, poner: false, borrarOrigen: true) { [weak self] ok in
            self?.descarga = ok ? (self?.fondo?.estado.contains("⚠︎") == true ? self?.fondo?.estado : "Añadido a tus fondos ✓") : "No se pudo convertir el vídeo"
        }
    }

    func videoDentroDeZip(_ zip: URL) -> URL? {
        let carpeta = zip.deletingPathExtension()
        try? FileManager.default.removeItem(at: carpeta)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, carpeta.path]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: zip)
        let videos = (FileManager.default.enumerator(at: carpeta, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? [])
            .filter { extensiones.contains($0.pathExtension.lowercased()) && !$0.path.contains("__MACOSX") }
        guard let mayor = videos.max(by: {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }) else {
            try? FileManager.default.removeItem(at: carpeta)
            return nil
        }
        // Sacar el vídeo junto al zip con el nombre del zip y borrar lo demás
        let destino = carpeta.deletingLastPathComponent().appendingPathComponent(carpeta.lastPathComponent).appendingPathExtension(mayor.pathExtension)
        try? FileManager.default.removeItem(at: destino)
        try? FileManager.default.moveItem(at: mayor, to: destino)
        try? FileManager.default.removeItem(at: carpeta)
        return destino
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let u = destinos.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: u) }
        descarga = "Error al descargar"
    }
}

struct VistaWeb: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct Explorador: View {
    @ObservedObject var nav: Navegador

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { nav.web.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!nav.puedeAtras)
                Button { nav.web.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!nav.puedeAdelante)
                Button { nav.web.reload() } label: { Image(systemName: "arrow.clockwise") }
                Divider().frame(height: 18)
                ForEach(sitios, id: \.0) { s in
                    Button(s.0) {
                        nav.inicio = s.1
                        nav.ir(s.1)
                    }
                }
                Spacer()
                Text(nav.descarga ?? "Descarga un fondo y se añadirá a WallSakura")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(FondoRosa())
            // Barra de carga fina: se ve en cuanto pulsas un enlace
            ProgressView(value: nav.progreso)
                .progressViewStyle(.linear)
                .frame(height: 2)
                .opacity(nav.progreso < 1 ? 1 : 0)
            VistaWeb(web: nav.web)
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(.rosa)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegado = Fondo()
app.delegate = delegado
app.run()
