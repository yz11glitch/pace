const BUILD="20260922-1";
const CACHE_NAME=`pace-${BUILD}`;
const APP_SHELL=["/","/index.html",`/tokens.css?v=${BUILD}`,`/styles.css?v=${BUILD}`,`/ui-core.js?v=${BUILD}`,`/icons.js?v=${BUILD}`,`/app.js?v=${BUILD}`,"/fonts/hanken-grotesk-latin.woff2","/fonts/bricolage-grotesque-latin.woff2","/pcm-capture-worklet.js","/manifest.webmanifest","/pace-mark.svg","/pace-icon.svg","/pace-icon-small.svg","/pace-icon-favicon.svg","/favicon-32.png","/icon-192.png","/icon-512.png","/apple-touch-icon.png"];
self.addEventListener("install",event=>event.waitUntil(caches.open(CACHE_NAME).then(cache=>cache.addAll(APP_SHELL)).then(()=>self.skipWaiting())));
self.addEventListener("activate",event=>event.waitUntil((async()=>{const names=await caches.keys();await Promise.all(names.filter(name=>name!==CACHE_NAME).map(name=>caches.delete(name)));await self.clients.claim();const clients=await self.clients.matchAll({type:"window",includeUncontrolled:true});clients.forEach(client=>client.postMessage({type:"NOTED_ASSETS_UPDATED",build:BUILD}))})()));
self.addEventListener("fetch",event=>{if(event.request.method!=="GET")return;event.respondWith(fetch(event.request).catch(()=>caches.match(event.request)))});
