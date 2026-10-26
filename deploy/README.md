# Deploy

Push a `main` → `.github/workflows/deploy.yml` en el runner self-hosted de `wefaber` →
`bun install --frozen-lockfile`, `typecheck` + `lint`, `bun run build`, `deploy/colectivo-static.sh <sha>`.

El script vive en el repo (antes era `/home/hermes/deploy/elcolectivo.sh`, fuera de control de
versiones, publicando a `/var/www` — ver _Por qué cambió_).

Publica en **`colectivo.eternum.lat`**, el apex.

## Cómo funciona

Un sitio estático no necesita systemd: blue/green son dos docroots y un snippet de nginx que apunta a uno.

```
/home/hermes/colectivo-static/blue/dist             slot azul
/home/hermes/colectivo-static/green/dist            slot verde
/etc/nginx/snippets/colectivo-static-active.conf    `set $colectivo_static_root <slot>/dist;`  ← lo que sirve el vhost del apex
/home/hermes/deploy/state/colectivo-static/active   `blue` o `green`
```

1. El slot **ocioso** se borra y se rellena con `dist/` (el vivo no se toca nunca mientras sirve).
2. Se verifica que el `index.html` copiado apunte a un asset que exista en ese slot.
3. Se reescribe el snippet hacia el slot nuevo, `nginx -t` y `reload`. Si `nginx -t` falla, se
   restaura el snippet anterior y se aborta.
4. Health check en dos capas: **origen** (`--resolve colectivo.eternum.lat:443:167.114.2.210`, sin
   Cloudflare en el medio) y después **público**. Las dos tienen que servir el `index-<hash>.js` nuevo.
5. Si algo falla, el snippet vuelve solo al slot anterior. `--rollback` es un flip, no un rebuild.

Comandos:

```bash
deploy/colectivo-static.sh <sha>        # deploy (lo llama el workflow)
deploy/colectivo-static.sh --rollback   # volver al slot anterior
deploy/colectivo-static.sh --status      # qué slot está vivo y con qué revisión
DRY_RUN=1 deploy/colectivo-static.sh <sha>   # arma el slot y verifica; no toca nginx
```

En `DRY_RUN` el libro de slots (el archivo `active`) sí se mueve, para que dos corridas seguidas
alternen igual que un deploy real y `--rollback` se pueda ensayar sin tocar el servidor.

El preflight es de solo lectura y corre **antes** de tocar nada: lista lo que falta del setup inicial
y sale con **exit 2**. Un `exit 2` en el workflow significa "el host no está provisionado", no
"el código está roto".

## Setup inicial en el VPS (una sola vez)

Los números son los que imprime el preflight.

1. Puertos: no aplica, es estático (nginx sirve archivos).
2. Directorios:
   ```bash
   mkdir -p /home/hermes/colectivo-static /home/hermes/deploy/state/colectivo-static
   ```
3. Vhost del apex — **esto es el traspaso**: reemplaza el vhost actual de `colectivo-site`
   (`include snippets/colectivo-active.conf` + `proxy_pass` a `:4151`).
   ```bash
   sudo cp /etc/nginx/sites-available/colectivo.eternum.lat \
           /etc/nginx/sites-available/colectivo.eternum.lat.bak-colectivo-site-$(date +%Y%m%d)
   sudo cp deploy/nginx/colectivo.conf /etc/nginx/sites-available/colectivo.eternum.lat
   ```
   (el symlink de `sites-enabled` ya existe y apunta a ese archivo).
4. Snippet inicial:
   ```bash
   printf 'set $colectivo_static_root /home/hermes/colectivo-static/blue/dist;\n' \
     | sudo tee /etc/nginx/snippets/colectivo-static-active.conf >/dev/null
   mkdir -p /home/hermes/colectivo-static/blue/dist
   ```
5. DNS y TLS: nada que hacer. `colectivo.eternum.lat` ya resuelve y el certificado ya existe
   (`/etc/letsencrypt/live/colectivo.eternum.lat/`); el vhost nuevo usa las mismas rutas.
6. Sudoers: `hermes` ya tiene `NOPASSWD: ALL` en este VPS; el preflight lo verifica igual
   (`tee` del snippet, `nginx -t`, `systemctl reload nginx`).
7. `sudo nginx -t && sudo systemctl reload nginx`.

Los pasos 3, 4 y 7 cambian producción (`colectivo-site` deja de servir el apex), así que van con el
OK de Faku en ese momento, no como parte de un `git push`.

## Traspaso del apex: qué pasa con `wefaber/colectivo-site`

Hasta el traspaso, `colectivo.eternum.lat` lo servía `colectivo-site` (SSR + SQLite) desde
`/home/hermes/colectivo/{blue,green}` con el snippet `colectivo-active.conf`. Después del paso 3:

- El vhost del apex incluye `colectivo-static-active.conf` y ya no proxyea `/graphql`, `/health` ni
  `/ready`. La app de `colectivo-site` sigue viva en sus slots (puerto 4151) pero nadie la enruta
  por el apex.
- `colectivo-next.eternum.lat` **conserva** su vhost e incluye `colectivo-active.conf`, así que la app
  queda alcanzable ahí sin tocar nada.
- Su workflow `Deploy` sigue haciendo health check contra `colectivo.eternum.lat` (default de
  `COLECTIVO_DOMAIN`), así que a partir del traspaso va a fallar y a hacer rollback de su snippet.
  Se arregla de su lado, sin tocar este repo: `COLECTIVO_DOMAIN=colectivo-next.eternum.lat` en
  `~/deploy/env/colectivo.env`, o retirando ese workflow. No lo cambiamos desde acá.
- La base SQLite (`/home/hermes/data/colectivo/colectivo.db`) y sus backups quedan intactos: el
  deploy estático no los toca.

El preflight detecta el traspaso a medias: si el vhost del apex todavía incluye `colectivo-active.conf`,
falla con "still serves wefaber/colectivo-site" en vez de publicar un snippet que nginx no lee.

## Rollback

`--rollback` voltea el snippet al slot anterior y verifica que sirva su propio `index-<hash>.js`.
También está como `workflow_dispatch` con `mode: rollback` (no reconstruye nada). El slot anterior
se conserva hasta el deploy siguiente, que lo pisa.

Para volver atrás el **traspaso** (devolver el apex a `colectivo-site`): restaurar el vhost desde el
`.bak-colectivo-site-<fecha>` del paso 3 y `sudo nginx -t && sudo systemctl reload nginx`. El snippet
de ellos nunca se tocó, así que su app vuelve a quedar en el apex tal como estaba.

## Por qué cambió (run 40395606912)

El 2026-10-17 `colectivo.eternum.lat` pasó a `wefaber/colectivo-site`. El `Deploy` de este repo
siguió apuntando a `/var/www/colectivo.eternum.lat`, que ya no era el `root` de ningún vhost: solo
quedó como `/etc/nginx/sites-available/colectivo.eternum.lat.bak-static-20261017`.

Resultado: el build y el swap del symlink salían bien, y el health check contra el dominio público
recibía 200 con el HTML de **otro** proyecto, así que nunca encontraba el `index-<hash>.js` nuevo,
hacía rollback y salía 1. Determinista en cada push a `main`.

Por eso este sistema:

- tiene el script **en el repo**, versionado junto al workflow, y publica en el docroot que el vhost
  realmente incluye (una variable de nginx, no un path suelto en `/var/www`);
- hace el health check contra el origen _y_ contra el público, así un vhost mal apuntado se ve en
  el primer intento y no como "200 inesperado";
- se niega a correr si el snippet no termina en `colectivo-static-active.conf`, para que un typo no
  pueda escribir el snippet de `colectivo-site`;
- se niega a correr si el vhost del apex todavía sirve `colectivo-site`: nunca más un deploy que
  "funciona" mientras el dominio muestra otra cosa.
