#!/bin/bash

COMPONENT_DIR="resources/views/components"
COMPONENT_FILE="$COMPONENT_DIR/google-layout.blade.php"

# Crear directorio de componentes si no existe
if [ ! -d "$COMPONENT_DIR" ]; then
  mkdir -p "$COMPONENT_DIR"
  echo "[OK] Directorio $COMPONENT_DIR creado."
fi

echo "======================================================="
echo " Pega aquí el código HTML/JS de Google Ads:"
echo " (Cuando termines de pegar, presiona INTRO y luego CTRL+D)"
echo "======================================================="

# Lee todo el bloque de texto hasta recibir EOF (Ctrl+D)
GTAG_CODE=$(cat)

if [ -z "$GTAG_CODE" ]; then
  echo "[WARN] No se ha ingresado ningún código. Generando componente sin Google Ads..."
fi

# Generar el componente app-layout.blade.php
cat << 'EOF_BLADE' > "$COMPONENT_FILE"
<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{ $title ?? config('app.name', 'Laravel') }}</title>

  <!-- Google Ads Tag -->
EOF_BLADE

# Insertar el código capturado
echo "$GTAG_CODE" >> "$COMPONENT_FILE"

cat << 'EOF_BLADE' >> "$COMPONENT_FILE"

  @vite(['resources/css/app.css', 'resources/js/app.js'])
</head>
<body class="font-sans antialiased">
  {{ $slot }}
</body>
</html>
EOF_BLADE

echo ""
echo "======================================================="
echo "¡Hecho! Componente creado en:"
echo " -> $COMPONENT_FILE"
echo "======================================================="