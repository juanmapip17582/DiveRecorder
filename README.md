# DiveRecorder

App de iOS que graba automáticamente los clavados de Juan Manuel durante entrenamiento en
equipo, sin operador humano, identificándolo por el color de su pantaloneta. Ver `SPEC.md`
(o el mensaje original) para el diseño completo.

## Por qué el proyecto se ve así

Este repo se escribe y edita desde Windows (sin Xcode), y se compila/prueba en la Mac de un
amigo + un iPhone físico. Por eso:

- El `.xcodeproj` **no está commiteado** — se genera con [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  a partir de `project.yml`, que sí es texto plano y versionable.
- Todos los umbrales que el spec marca como "afinar con pruebas reales" (ver
  `DiveRecorder/Calibration/CalibrationSettings.swift`) son ajustables **dentro de la app**
  (pantalla de Calibración, ícono de sliders) y se guardan con `UserDefaults`. La idea es que la
  mayoría de las sesiones de ajuste en la piscina se puedan hacer solo con el iPhone, sin
  necesitar la Mac cerca — solo hace falta la Mac para instalar el build inicial y cuando cambie
  lógica real (no solo números).

## Setup en la Mac del amigo (primera vez)

1. Instalar Xcode desde la App Store (gratis, pero pesado — dejarlo descargando con tiempo).
2. Instalar [Homebrew](https://brew.sh) si no lo tienen.
3. `brew install xcodegen`
4. Clonar este repo y generar el proyecto:
   ```
   git clone <url-del-repo>
   cd DiveRecorder
   xcodegen generate
   open DiveRecorder.xcodeproj
   ```
5. En Xcode: seleccionar el target `DiveRecorder` → pestaña **Signing & Capabilities** →
   marcar **Automatically manage signing** → elegir como Team el Apple ID de quien sea
   (puede ser el del amigo; con cuenta gratis alcanza para instalar en un iPhone conectado por
   cable, el build expira a los 7 días y hay que reinstalar).
6. Conectar el iPhone por cable, confiar en el certificado de desarrollador cuando lo pida
   (Ajustes → General → VPN y gestión de dispositivos, en el iPhone).
7. Elegir el iPhone como destino de build (arriba, junto al botón de Play) y correr ▶️.

Después de este primer cable, si Mac e iPhone están en la misma red WiFi, Xcode permite debug
inalámbrico (Window → Devices and Simulators → marcar "Connect via network").

## Si quien tiene la Mac usa Claude Code

Este código se escribió desde Windows sin poder compilarlo ni una vez, así que es esperable que
la primera build tenga algún error. Si la persona con la Mac tiene Claude Code instalado, puede
validar (y arreglar) la compilación de forma independiente, sin necesitar el iPhone conectado ni
pasar capturas de pantalla de un lado a otro:

```
git clone https://github.com/juanmapip17582/DiveRecorder.git
cd DiveRecorder
xcodegen generate
claude
```

Y dentro de esa sesión de Claude Code (que arranca sin memoria de ninguna conversación previa,
pero con suficiente contexto leyendo este README y `SPEC.md`):

> Compila este proyecto de iOS contra el Simulator (`xcodebuild`), arregla cualquier error de
> compilación que encuentres, y cuando compile limpio haz commit y push a GitHub.

Esto resuelve el "¿compila o no?" antes de siquiera juntarse con el iPhone — la sesión con el
teléfono conectado queda solo para probar el comportamiento real (detección, grabación, splash).

## Actualizar cuando hay cambios de código

```
git pull
xcodegen generate   # regenera el .xcodeproj si project.yml o los archivos cambiaron
```
Luego build & run de nuevo en Xcode.

## Estructura

```
DiveRecorder/
├── App/                 SwiftUI entry point + pantalla principal (preview + estado + overlay debug)
├── Camera/              AVCaptureSession + preview layer compartido (CaptureManager)
├── Vision/               VNDetectHumanBodyPoseRequest (PoseDetector) + matching HSV (ColorMatcher)
├── StateMachine/        Orquestador: STANDBY -> IDENTIFICANDO -> ARMADO -> GRABANDO -> STANDBY
├── Calibration/         ROI, color de referencia y sliders de todos los umbrales ajustables
├── Library/              Guardado/listado de clips grabados + descarga a Fotos
└── Resources/           Info.plist, Assets.xcassets
```

## Flujo de calibración en la app

1. Abrir la app, dar permiso de cámara.
2. Tocar el ícono de sliders (calibración).
3. Dibujar (arrastrando sobre el preview) el ROI del trampolín/plataforma.
4. Pararse dentro del ROI del trampolín con la pantaloneta puesta y tocar "Capturar color
   ahora".
5. Ajustar los sliders de umbral (color, tiempo de vuelo, failsafe, fps) según lo que se observe
   en pruebas reales — todo se guarda solo.

## Notas técnicas

- Grabación vía `AVCaptureMovieFileOutput` en vez de `AVAssetWriter` manual — más simple para
  v1; si más adelante hace falta control cuadro a cuadro, ese es el upgrade natural. La sesión
  no tiene input de audio, así que los clips se graban sin sonido.
- Fin de grabación: mientras GRABANDO, `PoseDetector` sigue vigilando el ROI del trampolín (a
  una fracción de los frames, no todos — ver `RecordingStateMachine.recordingFrameStride`). En
  cuanto deja de detectar a la persona ahí por unos frames seguidos (para no dispararse con un
  parpadeo momentáneo), arranca la cuenta regresiva fija de "Tiempo de vuelo" y corta al
  cumplirse. El timer failsafe de Calibración sigue como respaldo, por si la salida nunca se
  detecta.
- `CaptureManager` expone un único `AVCaptureVideoPreviewLayer` compartido; `CameraPreviewView`
  lo reparenta entre la pantalla principal y la de Calibración en vez de crear una capa nueva
  cada vez — evita tanto que la vista principal se quede en negro al volver de Calibración como
  la demora al abrirla (antes negociaba una conexión de AVFoundation nueva cada vez).
- Los clips se guardan en `Documents/Clips/` dentro del sandbox de la app (ver `ClipStorage`) —
  no son visibles fuera de la app hasta que se tocan "Descargar" en la Librería, que los copia a
  Fotos vía `PHPhotoLibrary` (`NSPhotoLibraryAddUsageDescription`, acceso solo de escritura).
- Todas las decisiones de la máquina de estados corren en una cola serial propia
  (`RecordingStateMachine.stateQueue`), separada de las colas de AVFoundation, para evitar
  condiciones de carrera entre los distintos callbacks (frames de video, fin de grabación).
- Bundle id / nombre están en `project.yml` (`com.juanma.diverecorder` / `DiveRecorder`) —
  cambiar ahí si hace falta, no en Xcode directamente (se pierde al regenerar).

## Pendiente / decisiones abiertas (ver spec)

- Umbrales de calibración: arrancar con los valores por defecto y medir en la piscina real.
- Fase 2 (fuera de alcance v1): identificación por re-identificación de cuerpo, múltiples
  clavadistas, nube/compartir clips.
