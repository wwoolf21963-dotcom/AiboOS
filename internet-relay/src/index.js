// AiboOS Internet Relay — Cloudflare Worker + D1
// Internet messaging across Wi-Fi and cellular. Stores plain-text messages; NOT E2EE.
// Do not advertise as a private/production messenger until abuse prevention and
// security review have been completed.
const ID = /^[1-9][0-9]{6}$/;
const PICTURE = /^data:image\/(?:jpeg|png|webp);base64,[A-Za-z0-9+/=]+$/;
const NO_STORE = {"Content-Type":"application/json; charset=utf-8",
  "Cache-Control":"no-store", "Access-Control-Allow-Origin":"*",
  "Access-Control-Allow-Headers":"Authorization, Content-Type",
  "Access-Control-Allow-Methods":"GET, POST, DELETE, OPTIONS"};
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
  const url=new URL(request.url),path=url.pathname;
  try{
   if(request.method==="GET"&&path==="/v1/health")return reply({ok:true,service:"AiboOS Internet Relay",version:1});
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
      if(await hitLimit(env.DB,"msg:"+me.id,50,60000))
        return reply({error:"Message limit reached. Try again shortly."},429);
      const dest=await env.DB.prepare("SELECT id FROM accounts WHERE id=?").bind(m.to).first();
      if(!dest)return reply({error:"That Aibo ID doesn't exist"},404);
      await env.DB.prepare(
        "INSERT OR IGNORE INTO messages(client_id,from_id,to_id,text,ts) VALUES(?,?,?,?,?)"
      ).bind(m.clientId,me.id,m.to,m.text.trim(),Date.now()).run();
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
        "WHERE m.to_id=? AND m.id>? ORDER BY m.id LIMIT 100"
      ).bind(me.id,cursor).all();
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
      await env.DB.prepare(
        "UPDATE messages SET delivered_at=COALESCE(delivered_at,?) WHERE id=? AND to_id=?"
      ).bind(Date.now(),messageID,me.id).run();
      return reply({ok:true});
   }
   if(request.method==="DELETE"&&path==="/v1/account"){
      await env.DB.batch([
        env.DB.prepare("DELETE FROM messages WHERE from_id=? OR to_id=?").bind(me.id,me.id),
        env.DB.prepare("DELETE FROM accounts WHERE id=?").bind(me.id)
      ]);
      return reply({deleted:true});
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
