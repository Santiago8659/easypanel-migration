# Storage de Chatwoot (adjuntos)

Hoy Chatwoot usa **Active Storage local**: los adjuntos viven en un volumen del host.
Esta migración los trata como un `tar.gz` que se sube a B2 y se restaura en el destino
(`scripts/20-dump-storage.sh` / `scripts/40-restore-storage.sh`).

## Migrar la BD primero, el storage después

El orden recomendado es: BD → arrancar Chatwoot en destino → migrar storage. Si la BD ya
referencia adjuntos que aún no están en disco, Chatwoot mostrará enlaces rotos hasta que
restaures el storage. No hay pérdida: en cuanto extraes el `tar.gz` en la ruta correcta,
los adjuntos vuelven a resolver.

## Encontrar la ruta del storage en EasyPanel

Dentro del contenedor de Chatwoot, Active Storage local guarda en `storage/` (relativo a la
app, normalmente `/app/storage`). En el host suele ser un volumen montado del proyecto. Para
ubicarlo:

```bash
docker inspect <contenedor_chatwoot> --format '{{json .Mounts}}' | tr ',' '\n' | grep -i storage
```

Pon esa ruta del host en `CHATWOOT_STORAGE_PATH` (o pásala con `--path`).

## A futuro: mover el storage a B2/S3 nativo

En lugar de archivos locales, Chatwoot puede usar S3 (B2 es S3-compatible) directamente.
Variables relevantes:

```
ACTIVE_STORAGE_SERVICE=amazon
STORAGE_BUCKET_NAME=...
STORAGE_ACCESS_KEY_ID=...
STORAGE_SECRET_ACCESS_KEY=...
STORAGE_REGION=us-west-004
STORAGE_ENDPOINT=https://s3.us-west-004.backblazeb2.com
```

Ventaja en un servidor flojo: **el disco del server deja de crecer** con cada adjunto.
Para migrar adjuntos existentes al bucket se pueden sincronizar los archivos locales con
`aws s3 sync` respetando la estructura de carpetas de Active Storage. Esto es un paso
posterior y opcional; no bloquea la migración de servicio.
