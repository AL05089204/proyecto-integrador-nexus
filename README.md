# Nexus – Plataforma de Transferencia Audiovisual para Medios de Comunicación

Nexus es una solución diseñada para agilizar el flujo de trabajo entre los **reporteros en campo** y la **redacción** de un medio de comunicación.  
Permite capturar, etiquetar y enviar contenido audiovisual directamente desde un iPhone, garantizando rapidez, seguridad y trazabilidad.

Este repositorio forma parte del **Proyecto Integrador** del programa académico, e implementa la arquitectura modular del sistema:  
**App iOS + API Backend + Panel Web + Integración con sistemas del medio.**

---

## Objetivo del proyecto

- Reducir los tiempos de transferencia de fotos y videos desde campo.  
- Centralizar la recepción de contenido.  
- Proveer trazabilidad y metadatos completos.  
- Evitar pérdidas, duplicidad y compresión destructiva.  
- Facilitar la publicación en TV, web, app y redes sociales.

---

# Arquitectura General

[Reportero iPhone]
        │
        ▼
[App Nexus iOS]
        │
        ▼
[API / Backend]
        │
        ▼
[Almacenamiento Nube + BD]
        │
        ▼
    [Panel Web]
        │ │
        ▼ ▼
[Sistema TV] [CMS / Redes]


---

#  Modelo de Branches

### Branch principal  
- `main` → versión estable / entrega final

### Desarrollo  
- `develop` → integración continua

### Ramas de funcionalidad  
- `feature/app-ios-auth`
- `feature/app-ios-captura`
- `feature/app-ios-offline`
- `feature/backend-api-uploads`
- `feature/panel-web-listado`

### Ramas de release  
- `release/beta`
- `release/rc`

### Hotfix  
- `hotfix/...`

---

#  Milestones

### `v0.9.0-beta`
- MVP funcional
- Captura → envío → visualización en panel
- Modo offline básico

### `v1.0.0-rc`
- Corrección de errores de beta
- Optimización de rendimiento
- Pulido de interfaz

### `v1.0.0`
- Entrega final  
- Documentación completa  
- Manual de usuario  
- Despliegue

---

# Issues como Requerimientos

Cada requerimiento funcional (RF) y no funcional (RNF) está registrado como un **issue** con:

- Descripción  
- Análisis  
- Solución propuesta  
- Criterios de aceptación  
- Labels (RF, RNF, Backend, iOS, Web, Bug)

### Ejemplo:

RF-01 Captura de fotos y videos

Descripción:
La app debe permitir capturar fotos y videos directamente desde Nexus.

Análisis:
El flujo actual usa apps externas (WhatsApp, Telegram), lo que causa pérdida de calidad.

Solución:
Implementar módulo de cámara con AVFoundation.

Criterios de aceptación:
El usuario puede tomar fotos y videos sin salir de la app.

---

# 🛠 Tecnologías utilizadas

### App Nexus (iOS)
- Swift / SwiftUI  
- AVFoundation  
- URLSession  
- Keychain  

### Backend
- Node.js / Express  
- MongoDB / PostgreSQL (dependiendo de versión)  
- S3 o equivalente para almacenamiento  

### Panel Web
- PayloadCMS
---

# Instalación y ejecución

### Backend
```bash
cd backend-api
npm install
npm run dev
