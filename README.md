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

## Actualizar cuando hay cambios de código

```
git pull
xcodegen generate   # regenera el .xcodeproj si project.yml o los archivos cambiaron
```
Luego build & run de nuevo en Xcode.

## Estructura

```
DiveRecorder/
├── App/                 SwiftUI entry point + pantalla principal (preview + estado)
├── Camera/              AVCaptureSession (CaptureManager) + AVAudioEngine tap (AudioMonitor)
├── Vision/               VNDetectHumanBodyPoseRequest (PoseDetector) + matching HSV (ColorMatcher)
├── SplashDetection/     Frame differencing en la ROI del agua (SplashDetector)
├── StateMachine/        Orquestador: STANDBY -> IDENTIFICANDO -> ARMADO -> GRABANDO -> STANDBY
├── Calibration/         ROIs, color de referencia y sliders de todos los umbrales ajustables
├── Library/              Guardado/listado de clips grabados
└── Resources/           Info.plist, Assets.xcassets
```

## Flujo de calibración en la app

1. Abrir la app, dar permiso de cámara/micrófono.
2. Tocar el ícono de sliders (calibración).
3. Dibujar (arrastrando sobre el preview) el ROI del trampolín/plataforma y el ROI del agua.
4. Pararse dentro del ROI del trampolín con la pantaloneta puesta y tocar "Capturar color
   ahora".
5. Ajustar los sliders de umbral (color, movimiento de splash, audio, padding, failsafe, fps)
   según lo que se observe en pruebas reales — todo se guarda solo.

## Notas técnicas

- Grabación vía `AVCaptureMovieFileOutput` (mux de audio+video automático) en vez de
  `AVAssetWriter` manual — más simple para v1; si más adelante hace falta control cuadro a
  cuadro, ese es el upgrade natural.
- El audio de splash se captura por separado vía `AVAudioEngine` (no por el output de audio de
  la sesión de captura), para poder calcular energía/onset en tiempo real sin pasar por disco.
- Todas las decisiones de la máquina de estados corren en una cola serial propia
  (`RecordingStateMachine.stateQueue`), separada de las colas de AVFoundation, para evitar
  condiciones de carrera entre los distintos callbacks (frames de video, fin de grabación, audio).
- Bundle id / nombre están en `project.yml` (`com.juanma.diverecorder` / `DiveRecorder`) —
  cambiar ahí si hace falta, no en Xcode directamente (se pierde al regenerar).

## Pendiente / decisiones abiertas (ver spec)

- Umbrales de calibración: arrancar con los valores por defecto y medir en la piscina real.
- Fase 2 (fuera de alcance v1): identificación por re-identificación de cuerpo, múltiples
  clavadistas, nube/compartir clips.
