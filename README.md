# Optimus: optimizador para Windows 10 con 4 GB de RAM

Script de PowerShell con menú que aplica ajustes de rendimiento **seguros y reversibles**, pensado para equipos con poca memoria.

## Uso

Descargar y ejecutar **`Optimizador-W10.exe`** (autoextraíble) o `Iniciar.bat`, y aceptar los permisos de administrador.

| Opción | Descripción |
|---|---|
| 1. Optimización completa | Limpieza, energía, efectos visuales, telemetría, memoria y disco |
| 2. Solo limpieza | Temporales, caché de Windows Update y Liberador de espacio |
| 3. Diagnóstico | Qué consume memoria, programas de inicio y recomendaciones |
| 4. Revertir | Deja todo exactamente como estaba |

Parámetros: `Iniciar.bat -Auto` (sin preguntas), `-Diagnostico` y `-Revertir`.

## Seguridad

- Crea un punto de restauración antes de empezar.
- Guarda el valor original de cada ajuste en `%ProgramData%\OptimizadorW10\respaldo.json`, así que *Revertir* restaura el estado previo real y no valores genéricos.
- **No** toca Windows Update, Defender ni el firewall.
- **No** desactiva SysMain por defecto, porque la compresión de memoria depende de él.

Detalle completo en [LEEME.txt](LEEME.txt).

## Generar el .exe

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```
