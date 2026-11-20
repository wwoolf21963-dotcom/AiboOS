// AiboOS Internet Relay — Cloudflare Worker + D1
// Internet messaging across Wi-Fi and cellular. Text is encrypted at rest; media is private in R2. NOT E2EE.
// Do not advertise as a private/production messenger until abuse prevention and
// security review have been completed.

// AES-256-GCM protects newly stored message bodies in D1. The secret is
// configured with wrangler secret put AIBO_MESSAGE_ENCRYPTION_KEY.
// Do NOT commit the secret or put it in the browser app. NOT end-to-end encryption.
const ENC_PREFIX="enc:v1:";
const encoder=new TextEncoder(),decoder=new TextDecoder();
function hexKey(env) {
  const hex=String(env.AIBO_MESSAGE_ENCRYPTION_KEY||"");
  if(!/^[0-9a-fA-F]{64}$/.test(hex))throw Error("Encryption secret missing or invalid");
  return Uint8Array.from(hex.match(/../g),v=>parseInt(v,16));
}
async function cryptoKey(env) {
  return crypto.subtle.importKey("raw",hexKey(env),{name:"AES-GCM"},false,["encrypt","decrypt"]);
}
function b64(bytes) {
  let result="";
  for(let i=0;i<bytes.length;i+=4096)
    result+=String.fromCharCode(...bytes.subarray(i,i+4096));
  return btoa(result);
}
function unb64(encoded) {
  return Uint8Array.from(atob(encoded),c=>c.charCodeAt(0));
}
function context(id,from,to) {return encoder.encode(id+"|"+from+"|"+to);}
async function encryptMessage(text,id,from,to,env) {
  const nonce=crypto.getRandomValues(new Uint8Array(12));
  const ciphertext=new Uint8Array(await crypto.subtle.encrypt(
    {name:"AES-GCM",iv:nonce,additionalData:context(id,from,to)},
    await cryptoKey(env),encoder.encode(text)
  ));
  const payload=new Uint8Array(nonce.length+ciphertext.length);
  payload.set(nonce);payload.set(ciphertext,nonce.length);
  return ENC_PREFIX+b64(payload);
}
async function decryptMessage(message,env) {
  // Older test messages were stored unencrypted. They are still legacy data
  // until erased or migrated; never claim encryption protected those rows.
  if(!message.text.startsWith(ENC_PREFIX))return message.text;
  const payload=unb64(message.text.slice(ENC_PREFIX.length));
  if(payload.length<29)throw Error("Invalid encrypted message");
  const plain=await crypto.subtle.decrypt(
    {name:"AES-GCM",iv:payload.subarray(0,12),
     additionalData:context(message.clientId,message.sender,message.recipient)},
    await cryptoKey(env),payload.subarray(12)
  );
  return decoder.decode(plain);
}
const ID = /^[1-9][0-9]{6}$/;
const MEDIA_ID = /^[1-9][0-9]{6}-[a-f0-9]{32}$/;
const MEDIA_PREFIX = "aibo:media:v1:";
const MEDIA_LIMITS = {photo:6*1024*1024,voice:4*1024*1024,video:24*1024*1024};
const MEDIA_TYPES = {
 photo:["image/jpeg","image/png","image/webp","image/heic","image/heif"],
 voice:["audio/mp4","audio/webm","audio/aac","audio/ogg","audio/mpeg","audio/wav","audio/x-m4a"],
 video:["video/mp4","video/quicktime","video/webm","video/3gpp"]
};
function parseMediaEnvelope(text) {
 if(!text.startsWith(MEDIA_PREFIX))return null;
 try {
  const obj=JSON.parse(text.slice(MEDIA_PREFIX.length)),a=obj.attachment;
  if(!a||!["photo","voice","video"].includes(a.kind)||!MEDIA_ID.test(String(a.id||""))||
     typeof obj.text!=="string"||typeof a.type!=="string"||!MEDIA_TYPES[a.kind].includes(a.type)||
     !Number.isSafeInteger(a.size)||a.size<1||a.size>MEDIA_LIMITS[a.kind])return null;
  return obj;
 }catch(e){return null;}
}
function newMediaId(owner) {
 const bytes=crypto.getRandomValues(new Uint8Array(16));
 return owner+"-"+[...bytes].map(x=>x.toString(16).padStart(2,"0")).join("");
}
const PICTURE = /^data:image\/(?:jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/;
const NO_STORE = {"Content-Type":"application/json; charset=utf-8",
  "Cache-Control":"no-store", "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"Authorization, Content-Type, X-Aibo-Recipient, X-Aibo-Media-Kind",
  "Access-Control-Allow-Methods":"GET, POST, PUT, DELETE, OPTIONS"};
function reply(data,status=200){return new Response(JSON.stringify(data),{status,headers:NO_STORE});}
async function body(request,limit=10000){
  if(Number(request.headers.get("content-length")||0)>limit)throw new Error("Request too large");
  const txt=await request.text();if(txt.length>limit)throw new Error("Request too large");
  return JSON.parse(txt);
}
async function digest(str){
  let b=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(str));
  return [...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,"0")).join("");
}
function validName(name){return typeof name==="string"&&name.trim().length>0&&name.trim().length<=48;}
function validPhoto(photo){return typeof photo==="string"&&(photo===""||(photo.length<25000&&PICTURE.test(photo)));}
function cleanName(s){return String(s).trim();}
function randomID(){let v=new Uint32Array(1);crypto.getRandomValues(v);return String(1000000+v[0]%9000000);}
async function signedIn(request,env){
  const authorization=request.headers.get("Authorization")||"";
  if(!/^Bearer [a-fA-F0-9]{64}$/.test(authorization))return null;
  let hash=await digest(authorization.slice(7).toLowerCase());
  return await env.DB.prepare("SELECT id,name,photo FROM accounts WHERE token_hash=?").bind(hash).first();
}
async function hitLimit(db,key,max,windowMs){
  let now=Date.now(), row=await db.prepare(
    "INSERT INTO rate_limits(key,window_start,hits) VALUES(?,?,1) "+
    "ON CONFLICT(key) DO UPDATE SET "+
    "hits=CASE WHEN window_start<? THEN 1 ELSE hits+1 END, "+
    "window_start=CASE WHEN window_start<? THEN excluded.window_start ELSE window_start END "+
    "RETURNING hits"
  ).bind(key,now,now-windowMs,now-windowMs).first();
  return (row?.hits||100000)>max;
}
export default {
 async fetch(request,env){
  if(request.method==="OPTIONS")return new Response(null,{status:204,headers:NO_STORE});
  if(!env.DB)return reply({error:"Database binding missing"},503);
  if(!/^[0-9a-fA-F]{64}$/.test(String(env.AIBO_MESSAGE_ENCRYPTION_KEY||"")))
    return reply({error:"Message encryption not configured"},503);
  const url=new URL(request.url),path=url.pathname;
  try{
   if(request.method==="GET"&&path==="/v1/health")return reply({ok:true,service:"AiboOS Internet Relay",version:3,messageEncryption:"AES-256-GCM at rest",mediaEnabled:!!env.MEDIA});
   if(request.method==="POST"&&path==="/v1/register"){
      const authorization=request.headers.get("Authorization")||"";
      if(!/^Bearer [a-fA-F0-9]{64}$/.test(authorization))return reply({error:"A private device key is required"},401);
      const info=await body(request,30000),name=info.name,photo=info.photo??"";
      if(!validName(name)||!validPhoto(photo))return reply({error:"Enter a name (1–48 characters) and optional small profile image"},400);
      const hash=await digest(authorization.slice(7).toLowerCase()),now=Date.now();
      let account=await env.DB.prepare("SELECT id FROM accounts WHERE token_hash=?").bind(hash).first();
      if(account){
        await env.DB.prepare("UPDATE accounts SET name=?,photo=?,updated_at=? WHERE id=?")
          .bind(cleanName(name),photo,now,account.id).run();
        return reply({id:account.id,name:cleanName(name),photo});
      }
      const ipHash=await digest("registration:"+String(request.headers.get("CF-Connecting-IP")||"unknown"));
      if(await hitLimit(env.DB,"reg:"+ipHash,8,3600000))return reply({error:"Too many new accounts from this network. Try later."},429);
      const preferred=ID.test(String(info.id||""))?String(info.id):null;
      // Collision-resistant, unique account ID enforced in D1.
      let assigned=null;
      for(let i=0;i<20;i++){
        let candidate=i===0&&preferred?preferred:randomID();
        try{
          await env.DB.prepare("INSERT INTO accounts(id,token_hash,name,photo,created_at,updated_at) VALUES(?,?,?,?,?,?)")
            .bind(candidate,hash,cleanName(name),photo,now,now).run();
          assigned=candidate;break;
        }catch(e){
          const used=await env.DB.prepare("SELECT id FROM accounts WHERE id=? OR token_hash=?")
            .bind(candidate,hash).first();
          if(!used)throw e;
          if(used.id!==candidate){
            assigned=used.id;break;
          }
        }
      }
      if(!assigned)return reply({error:"Could not assign an AiboID. Try again."},503);
      return reply({id:assigned,name:cleanName(name),photo});
   }
   let me=await signedIn(request,env);
   if(!me)return reply({error:"Aibo ID not registered. Connect your phone first."},401);
   if(request.method==="PUT"&&path==="/v1/media"){
      if(!env.MEDIA)return reply({error:"Media storage not configured; add R2 bucket binding MEDIA"},503);
      const kind=String(request.headers.get("X-Aibo-Media-Kind")||"");
      const recipient=String(request.headers.get("X-Aibo-Recipient")||"");
      const type=String(request.headers.get("Content-Type")||"").toLowerCase().split(";")[0].trim();
      const size=Number(request.headers.get("Content-Length"));
      if(!MEDIA_LIMITS[kind]||!MEDIA_TYPES[kind].includes(type)||
         !ID.test(recipient)||recipient===me.id||
         !Number.isSafeInteger(size)||size<1||size>MEDIA_LIMITS[kind]||!request.body)
        return reply({error:"Unsupported media or file too large (photos 6 MB, voice 4 MB, videos 24 MB)"},413);
      if(await hitLimit(env.DB,"media:"+me.id,30,3600000))
        return reply({error:"Media upload limit reached, try again later"},429);
      const dest=await env.DB.prepare("SELECT id FROM accounts WHERE id=?").bind(recipient).first();
      if(!dest)return reply({error:"Recipient AiboID not found"},404);
      const assetId=newMediaId(me.id);
      await env.MEDIA.put(assetId,request.body,{
        httpMetadata:{contentType:type},
        customMetadata:{sender:me.id,recipient,kind,size:String(size),created:String(Date.now())}
      });
      return reply({id:assetId,kind,type,size},201);
   }
   const mediaPath=path.match(/^\/v1\/media\/([1-9][0-9]{6}-[a-f0-9]{32})$/);
   if(request.method==="GET"&&mediaPath){
      if(!env.MEDIA)return reply({error:"Media storage not configured"},503);
      const object=await env.MEDIA.get(mediaPath[1]);
      if(!object)return reply({error:"Media is no longer available"},404);
      const meta=object.customMetadata||{};
      if(me.id!==meta.sender && me.id!==meta.recipient)
        return reply({error:"Not authorized to view this attachment"},403);
      return new Response(object.body,{headers:{
        ...NO_STORE,"Content-Type":object.httpMetadata?.contentType||"application/octet-stream",
        "X-Content-Type-Options":"nosniff"
      }});
   }
   if(request.method==="GET"&&/^\/v1\/profile\/[1-9][0-9]{6}$/.test(path)){
      const id=path.slice("/v1/profile/".length);
      if(await hitLimit(env.DB,"find:"+me.id,45,60000))return reply({error:"Please slow down your ID searches"},429);
      const row=await env.DB.prepare("SELECT id,name,photo FROM accounts WHERE id=?").bind(id).first();
      return reply(row?{found:true,profile:row}:{found:false});
   }
   if(request.method==="POST"&&path==="/v1/messages"){
      const m=await body(request,6500);
      if(!ID.test(String(m.to||""))||m.to===me.id||
         typeof m.text!=="string"||m.text.trim().length===0||m.text.length>4000||
         typeof m.clientId!=="string"||!/^[a-zA-Z0-9_-]{5,64}$/.test(m.clientId))
        return reply({error:"Invalid recipient or message"},400);
      const containsMedia=m.text.trim().startsWith(MEDIA_PREFIX),media=containsMedia?parseMediaEnvelope(m.text.trim()):null;
      if(containsMedia&&!media)return reply({error:"Invalid media message"},400);
      if(media){
        if(!env.MEDIA)return reply({error:"Media storage not configured"},503);
        if(!media.attachment.id.startsWith(me.id+"-"))
          return reply({error:"Media must belong to sender"},403);
        const asset=await env.MEDIA.head(media.attachment.id);
        if(!asset || asset.customMetadata?.sender!==me.id ||
           asset.customMetadata?.recipient!==m.to ||
           asset.customMetadata?.kind!==media.attachment.kind ||
           Number(asset.customMetadata?.size)!==media.attachment.size)
          return reply({error:"Attachment not uploaded for this recipient"},400);
      }
      if(await hitLimit(env.DB,"msg:"+me.id,50,60000))
        return reply({error:"Message limit reached. Try again shortly."},429);
      const dest=await env.DB.prepare("SELECT id FROM accounts WHERE id=?").bind(m.to).first();
      if(!dest)return reply({error:"That Aibo ID doesn't exist"},404);
      const encrypted=await encryptMessage(m.text.trim(),m.clientId,me.id,m.to,env);
      await env.DB.prepare(
        "INSERT OR IGNORE INTO messages(client_id,from_id,to_id,text,ts) VALUES(?,?,?,?,?)"
      ).bind(m.clientId,me.id,m.to,encrypted,Date.now()).run();
      const saved=await env.DB.prepare("SELECT id,delivered_at FROM messages WHERE from_id=? AND client_id=?")
        .bind(me.id,m.clientId).first();
      return reply({queued:true,serverId:saved.id,delivered:!!saved.delivered_at});
   }
   if(request.method==="GET"&&path==="/v1/sync"){
      const cursor=Math.max(0,Math.min(9007199254740991,Number(url.searchParams.get("cursor")||0)||0));
      const since=Math.max(0,Number(url.searchParams.get("receiptSince")||0)||0);
      if(await hitLimit(env.DB,"sync:"+me.id,120,60000))return reply({error:"Polling too fast"},429);
      const messages=await env.DB.prepare(
        "SELECT m.id AS serverId,m.client_id AS clientId,m.from_id AS sender,m.to_id AS recipient,"+
        "m.text,m.ts,a.name,a.photo FROM messages m JOIN accounts a ON a.id=m.from_id "+
        "WHERE m.to_id=? AND m.delivered_at IS NULL ORDER BY m.id LIMIT 100"
      ).bind(me.id).all();
      for(const message of messages.results||[])message.text=await decryptMessage(message,env);
      const receipts=await env.DB.prepare(
        "SELECT client_id AS clientId,delivered_at AS deliveredAt FROM messages "+
        "WHERE from_id=? AND delivered_at IS NOT NULL AND delivered_at>? ORDER BY delivered_at LIMIT 100"
      ).bind(me.id,since).all();
      return reply({messages:messages.results||[],receipts:receipts.results||[],
        timestamp:Date.now()});
   }
   if(request.method==="POST"&&path==="/v1/ack"){
      const data=await body(request,256);
      const messageID=Number(data.serverId);
      if(!Number.isSafeInteger(messageID)||messageID<=0)return reply({error:"Invalid message"},400);
      const stored=await env.DB.prepare(
        "SELECT client_id AS clientId,from_id AS sender,to_id AS recipient,text FROM messages WHERE id=? AND to_id=? AND delivered_at IS NULL"
      ).bind(messageID,me.id).first();
      if(!stored)return reply({ok:true});
      const readable=await decryptMessage(stored,env);
      const media=parseMediaEnvelope(readable);
      await env.DB.prepare(
        "UPDATE messages SET delivered_at=COALESCE(delivered_at,?), text='' WHERE id=? AND to_id=?"
      ).bind(Date.now(),messageID,me.id).run();
      // Files have been downloaded to recipient's phone before ACK.
      // Configure an R2 lifecycle rule too, in case a cleanup request fails.
      if(media && env.MEDIA && media.attachment.id.startsWith(stored.sender+"-")){
        try{await env.MEDIA.delete(media.attachment.id);}
        catch(e){console.warn("Could not delete delivered R2 attachment",e.message);}
      }
      return reply({ok:true});
   }
   if(request.method==="DELETE"&&path==="/v1/account"){
      await env.DB.batch([
        env.DB.prepare("DELETE FROM messages WHERE from_id=? OR to_id=?").bind(me.id,me.id),
        env.DB.prepare("DELETE FROM accounts WHERE id=?").bind(me.id)
      ]);
      return reply({deleted:true,id:me.id});
   }
   return reply({error:"Not found"},404);
  }catch(e){
   if(e instanceof SyntaxError)return reply({error:"Invalid JSON"},400);
   if(e.message==="Request too large")return reply({error:e.message},413);
   console.error("AiboOS Relay request failed",e.message);
   return reply({error:"Relay temporarily unavailable"},503);
  }
 }
};
