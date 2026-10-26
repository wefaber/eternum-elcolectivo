# Deploy

Push a `main` → `.github/workflows/deploy.yml` en el runner self-hosted de `wefaber` →
`bun install --frozen-lockfile`, `typecheck` + `lint`, `bun run build`, `deploy/colectivo-static.sh <sha>`.

El script vive en el repo (antes era `/home/hermes/deploy/elcolectivo.sh`, fuera de control de
versiones, publicando a `/var/www` — ver _Por qué cambió_).

## Cómo funciona

Un sitio estático no necesita systemd: blue/green son dos docroots y un snippet de nginx que apunta a uno.

```
/home/hermes/colectivo-static/blue/dist      slot azul
/home/hermes/colectivo-static/green/dist     slot verde
/etc/nginx/snippets/colectivo-static-active.conf   `set $colectivo_static_root <slot>/dist;`  ← lo que sirve nginx
/home/hermes/deploy/state/colectivo-static/active  `blue` o `green`
```

1. El slot **ocioso** se borra y se rellena con `dist/` (el vivo no se toca nunca mientras sirve).
2. Se verifica que el `index.html` copiado apunte a un asset que exista en ese slot.
3. Se reescribe el snippet hacia el slot nuevo, `nginx -t` y `reload`. Si `nginx -t` falla, se
   restaura el snippet anterior y se aborta.
4. Health check en dos capas: **origen** (`--resolve <dominio>:443:167.114.2.210`, sin Cloudflare
   en el medio) y después **público**. Las dos tienen que servir el `index-<hash>.js` nuevo.
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
3. Vhost: `sudo cp deploy/nginx/colectivo-static.conf /etc/nginx/sites-available/colectivo-static.eternum.lat`
   y `sudo ln -s ../sites-available/colectivo-static.eternum.lat /etc/nginx/sites-enabled/`.
4. Snippet inicial:
   ```bash
   printf 'set $colectivo_static_root /home/hermes/colectivo-static/blue/dist;\n' \
     | sudo tee /etc/nginx/snippets/colectivo-static-active.conf >/dev/null
   mkdir -p /home/hermes/colectivo-static/blue/dist
   ```
5. DNS + TLS: `colectivo-static.eternum.lat` como CNAME al apex de la zona `eternum.lat`
   (proxied), y `sudo certbot certonly --dns-cloudflare -d colectivo-static.eternum.lat`
   (la credencial ya está en `/etc/letsencrypt/cloudflare.ini`).
6. Sudoers: `hermes` ya tiene `NOPASSWD: ALL` en este VPS; el preflight lo verifica igual
   (`tee` del snippet, `nginx -t`, `systemctl reload nginx`).
7. `sudo nginx -t && sudo systemctl reload nginx`.

Recién después de 1-7 el primer push a `main` puede pasar el preflight.

## Rollback

`--rollback` voltea el snippet al slot anterior y verifica que sirva su propio `index-<hash>.js`.
También está como `workflow_dispatch` con `mode: rollback` (no reconstruye nada). El slot anterior
se conserva hasta el deploy siguiente, que lo pisa.

## Por qué cambió (run 40395606912)

El 2026-10-17 `colectivo.eternum.lat` pasó a `wefaber/colectivo-site` (SSR + SQLite, slots
`/home/hermes/colectivo/{blue,green}`, snippet `colectivo-active.conf`; ver el README de ese repo).
El `Deploy` de este repo siguió apuntando a `/var/www/colectivo.eternum.lat`, que ya no es el
`root` de ningún vhost: solo queda como `/etc/nginx/sites-available/colectivo.eternum.lat.bak-static-20261017`.

Resultado: el build y el swap del symlink salían bien, y el health check contra el dominio público
recibía 200 con el HTML de **otro** proyecto, así que nunca encontraba el `index-<hash>.js` nuevo,
hacía rollback y salía 1. Determinista en cada push a `main`.

Por eso este sistema:

- publica en un host propio (`colectivo-static.eternum.lat`) y no pelea el apex con `colectivo-site`;
- tiene el script **en el repo**, versionado junto al workflow;
- hace el health check contra el origen _y_ contra el público, así un vhost mal apuntado se ve en
  el primer intento y no como "200 inesperado";
- se niega a correr si `COLECTIVO_STATIC_SNIPPET` no termina en `colectivo-static-active.conf`, para
  que un typo no pueda escribir el snippet de `colectivo-site`.

Si el objetivo fuera devolver el estático al apex, alcanza con cambiar `SITE`/`DOMAIN`/`SNIPPET`/
`VHOST` en el script, el `server_name` del vhost y el `hostname` de `vite-plugin-sitemap` en
`vite.config.ts` — pero eso retira `colectivo-site` de producción, así que es decisión de Faku, no
de un deploy.
