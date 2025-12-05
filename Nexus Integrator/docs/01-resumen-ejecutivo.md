# Resumen ejecutivo

## Producto
Nexus App (iOS) es una aplicación móvil para reporteros y colaboradores que permite:

- Capturar fotos, videos y audio desde el dispositivo.
- Adjuntar metadatos editoriales (asignación, lugar, crédito, notas, GPS).
- Trabajar en modo offline, almacenando las subidas en una cola local.
- Enviar el contenido al backend (Payload CMS) y notificar a canales de Slack.
- Consultar el historial de archivos enviados en una galería.

## Problema que resuelve
En las coberturas de campo se generan fotos y videos que se comparten por canales informales (WhatsApp, correo, etc.), lo que provoca:

- Pérdida de material.
- Falta de trazabilidad (no se sabe quién tomó qué, ni dónde).
- Retrasos en la publicación.

## Solución propuesta
Nexus App centraliza la captura y el envío de contenido:

- Todo el material llega a un solo backend (Payload CMS).
- Cada archivo lleva metadatos obligatorios (autor, lugar, asignación, GPS).
- Si no hay red, la app guarda el envío en una cola offline y reintenta luego.
- El medio recibe una notificación en Slack cuando el asset está listo en el CMS.

## Alcance funcional (RF cubiertos)

- **RF-01** Captura de fotos y videos en App Nexus (iOS).  
- **RF-02** Subir contenido capturado al backend.  
- **RF-03** Agregar metadatos obligatorios para asegurar trazabilidad.  
- **RF-04** Implementar modo offline para áreas sin conectividad.  
- **RF-05** Implementar reintentos automáticos de subida.  
- **RF-06** Mostrar historial de archivos enviados.  
- **RF-07** Validar usuario antes de cualquier operación en la App.

## Arquitectura resumida

- **App móvil:** SwiftUI + UIKit (iOS).  
- **Backend:** Payload CMS (Node.js) con colección de `media` y `posts`.  
- **Infra extra:**  
  - Slack Webhook para notificación de assets.  
  - Servicio de ingest para video (Akta / JWPlayer).  

La documentación técnica detallada se encuentra en los archivos de instalación y uso.
