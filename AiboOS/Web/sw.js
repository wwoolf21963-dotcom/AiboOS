/* AiboOS 1.8 offline app shell. No message/API responses are cached. */
const CACHE="aiboos-v18-shell-20261120-2";
const CORE=["./index.html","./install.html","./manifest.webmanifest",
 "./icon-192.png","./icon-512.png","./aibo-icon.svg","./touch-icon.png","./logo.svg"];
self.addEventListener("install",event=>{
 event.waitUntil((async()=>{
  const cache=await caches.open(CACHE);
  await Promise.all(CORE.map(async path=>{
   try{
    const response=await fetch(path,{cache:"reload"});
    if(response.ok)await cache.put(path,response.clone());
   }catch(e){/* Install still works online if one optional asset fails. */}
  }));
  await self.skipWaiting();
 })());
});
self.addEventListener("activate",event=>{
 event.waitUntil((async()=>{
  const all=await caches.keys();
  await Promise.all(all.filter(name=>name.startsWith("aiboos-v18-shell-")&&name!==CACHE).map(name=>caches.delete(name)));
  await self.clients.claim();
 })());
});
self.addEventListener("fetch",event=>{
 const req=event.request;
 if(req.method!=="GET")return;
 const url=new URL(req.url);
 if(url.origin!==self.location.origin)return;
 event.respondWith((async()=>{
  const cache=await caches.open(CACHE);
  try{
   const response=await fetch(req);
   if(response.ok && response.type!=="opaque")cache.put(req,response.clone()).catch(()=>{});
   return response;
  }catch(e){
   const cached=await cache.match(req);
   if(cached)return cached;
   return new Response("AiboOS is offline and this page has not been cached yet.",{status:503,headers:{"Content-Type":"text/plain"}});
  }
 })());
});
