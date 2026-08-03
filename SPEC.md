# Spec v1 — App de Grabación Automática de Clavados (iOS)

## Objetivo
Grabar automáticamente los clavados de Juan Manuel durante entrenamiento en equipo, sin operador humano, identificándolo por el color de su pantaloneta como marcador interino (fase 2: identificación por cuerpo, usando el dataset que este v1 genera).

## Máquina de estados

**1. STANDBY (bajo consumo)**
- Cámara activa, muestreo de frames a 2-3 fps (no framerate completo)
- Vision (`VNDetectHumanBodyPoseRequest`) corre solo sobre la ROI del trampolín/plataforma
- Si detecta una persona en pose "de pie/lista" dentro de la ROI → pasa a IDENTIFICANDO

**2. IDENTIFICANDO**
- Sobre el bounding box de la persona detectada, recorta la región torso-piernas usando los keypoints de Vision (cadera, rodilla)
- Compara el color dominante de esa región (histograma HSV) contra el color de referencia calibrado
- Coincide dentro del umbral → ARMADO. No coincide o pasan X segundos → vuelve a STANDBY (es otro clavadista)

**3. ARMADO → GRABANDO**
- Arranca grabación a framerate completo (30/60fps, para poder ver en cámara lenta después)

**4. FIN DE GRABACIÓN (mientras graba)**
- `PoseDetector` sigue corriendo sobre el ROI del trampolín/plataforma (a una fracción de los
  frames, no todos, para no competir con la codificación del video)
- Cuando deja de detectar a la persona ahí durante 2-3 frames analizados seguidos (evita
  falsos positivos por un parpadeo momentáneo de la detección) → marca ese instante como
  "salió del trampolín" y arranca una cuenta regresiva fija ("Tiempo de vuelo", ajustable en
  Calibración, 3.5s por defecto)
- Al cumplirse la cuenta regresiva → corta la grabación
- Failsafe: timer máximo (ajustable en Calibración, 7s por defecto) por si nunca se detecta la
  salida del trampolín, para no grabar indefinidamente

**5. Guarda el clip localmente → vuelve a STANDBY**

## Componentes técnicos

**Captura**
- `AVCaptureSession` con `AVCaptureVideoDataOutput` para inspeccionar frames en vivo + grabación a archivo (`AVAssetWriter` si necesitas control fino sobre qué frames exactos se guardan)
- Un único `AVCaptureVideoPreviewLayer` compartido entre la pantalla principal y la de
  Calibración (reparentado, no recreado, entre una y otra)

**Detección de pose (standby, identificando y mientras graba)**
- Corre directo sobre el `CVPixelBuffer` del delegate de `AVCaptureVideoDataOutput`, sin pasar por disco
- Filtra detecciones fuera de la ROI calibrada
- Mientras graba, corre a una fracción de los frames (no todos), solo para saber si la persona
  sigue en el ROI del trampolín

**Calibración (una sola vez, al montar la cámara)**
- Pantalla donde defines: (a) rectángulo ROI del trampolín/plataforma, (b) foto de la pantaloneta para fijar el color de referencia

**Identificación por color**
- Crop torso-piernas con keypoints de Vision → conversión a HSV (más robusto que RGB a cambios de luz de la piscina) → distancia de histograma contra la referencia

## Estructura de proyecto sugerida
```
DiveRecorder/
├── Camera/
│   └── CaptureManager.swift       (AVCaptureSession + delegates + preview layer compartido)
├── Vision/
│   ├── PoseDetector.swift         (VNDetectHumanBodyPoseRequest wrapper)
│   └── ColorMatcher.swift         (HSV histogram matching)
├── StateMachine/
│   └── RecordingStateMachine.swift
├── Calibration/
│   └── CalibrationView.swift      (ROI + color de referencia)
└── Library/
    └── ClipStorage.swift          (guardar/organizar clips)
```

## Parámetros a afinar con pruebas reales (medir, no adivinar)
- Frecuencia de muestreo en standby (arrancar en 2-3fps, ajustar según consumo real de batería)
- Umbral de similitud de color (la luz de la piscina altera el color percibido — probar en la piscina real, no en casa)
- Tiempo de vuelo (cuenta regresiva fija desde que sale del trampolín hasta cortar)
- Timer failsafe

## Restricción de iOS a tener presente
No es posible grabar con la cámara mientras la pantalla está bloqueada/apagada — el brillo se puede bajar a 0 con la app en primer plano, pero "pantalla apagada" no es viable de forma nativa en iOS.

## Fuera de alcance v1 (fase 2)
- Identificación por re-identificación de cuerpo (usa el dataset que este v1 genera)
- Múltiples clavadistas identificados simultáneamente
- Nube / compartir clips
