import Foundation

/// Self-contained admin portal served at `/` by `avm serve`. No external assets (works offline,
/// strict CSP). The API token is read from the URL fragment (never sent to the server in logs).
public enum WebPortal {
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AltVM Console</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--ink:#14171c;--muted:#5d6672;--line:#e3e6ea;--accent:#2f6fed;--ok:#1f9d55;--warn:#c27c0e;--bad:#d64545;--chip:#eef1f5}
@media (prefers-color-scheme:dark){:root{--bg:#0f1115;--card:#171a20;--ink:#e8ebef;--muted:#99a2ad;--line:#272c34;--accent:#6b9bff;--ok:#3ccf7f;--warn:#e7a53a;--bad:#ff6b6b;--chip:#20252d}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,system-ui,sans-serif}
header{display:flex;align-items:center;gap:16px;padding:14px 20px;border-bottom:1px solid var(--line);background:var(--card);position:sticky;top:0;z-index:2}
header h1{font-size:16px;margin:0;font-weight:650;letter-spacing:-.01em}
nav{display:flex;gap:4px;flex-wrap:wrap}nav button{background:none;border:0;color:var(--muted);padding:6px 10px;border-radius:6px;cursor:pointer;font:inherit}
nav button.on{background:var(--chip);color:var(--ink)}
main{max-width:1200px;margin:0 auto;padding:20px 16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px}
.k{color:var(--muted);font-size:12px}.v{font-size:22px;font-weight:650;font-variant-numeric:tabular-nums}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);vertical-align:middle}th{font-size:12px;color:var(--muted);font-weight:600}
tr:last-child td{border-bottom:0}.num{font-variant-numeric:tabular-nums}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 8px;border-radius:99px;background:var(--chip);font-size:12px}
.dot{width:7px;height:7px;border-radius:50%;background:var(--muted)}.running .dot{background:var(--ok)}.suspended .dot,.paused .dot{background:var(--warn)}.locked .dot{background:var(--bad)}
.btn{border:1px solid var(--line);background:var(--card);color:var(--ink);border-radius:6px;padding:4px 9px;cursor:pointer;font:inherit;font-size:12px}
.btn:hover{border-color:var(--accent)}.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.actions{display:flex;gap:6px;flex-wrap:wrap}
.tag{font-size:11px;color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:0 5px;margin-right:4px}
pre{background:var(--chip);padding:12px;border-radius:8px;overflow:auto;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
input,select{background:var(--card);color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:6px 8px;font:inherit}
form.row{display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin-bottom:14px}label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:var(--muted)}
#toast{position:fixed;bottom:16px;right:16px;max-width:420px;background:var(--ink);color:var(--bg);padding:10px 14px;border-radius:8px;display:none}
.wrap{overflow-x:auto}h2{font-size:15px;margin:22px 0 10px}
.ok{color:var(--ok)}.bad{color:var(--bad)}
#login{max-width:420px;margin:60px auto}
</style>
</head>
<body>
<header><h1>AltVM Console</h1><nav id="nav"></nav><span style="flex:1"></span><span class="k" id="hostname"></span></header>
<main id="app"></main>
<div id="toast"></div>
<script>
const tabs=["Machines","Create","Networks","Policy","Audit"];let tab="Machines";
let token=(location.hash.match(/token=([a-f0-9]+)/)||[])[1]||sessionStorage.getItem("altvm-token")||"";
if(token){try{sessionStorage.setItem("altvm-token",token)}catch(e){}history.replaceState(null,"",location.pathname)}
const $=s=>document.querySelector(s);const esc=s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const gb=b=>(b/1073741824).toFixed(1)+" GB";
function toast(m){const t=$("#toast");t.textContent=m;t.style.display="block";clearTimeout(t._h);t._h=setTimeout(()=>t.style.display="none",4000)}
async function api(method,path,body){const r=await fetch("/api/v1"+path,{method,headers:{"Authorization":"Bearer "+token,"Content-Type":"application/json"},body:body?JSON.stringify(body):undefined});
const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.error||r.statusText);return j}
function nav(){$("#nav").innerHTML=tabs.map(t=>`<button class="${t==tab?"on":""}" onclick="go('${t}')">${t}</button>`).join("")}
function go(t){tab=t;nav();render()}
async function act(name,a,body){try{toast(a+" "+name+"…");await api("POST",`/vms/${encodeURIComponent(name)}/${a}`,body);toast(a+" "+name+" ✓");render()}catch(e){toast(e.message)}}
async function del(name){if(!confirm("Delete "+name+" permanently?"))return;try{await api("DELETE","/vms/"+encodeURIComponent(name));render()}catch(e){toast(e.message)}}
async function snap(name){const l=prompt("Snapshot name","checkpoint");if(l)act(name,"snapshot",{name:l})}
async function clone(name){const l=prompt("Name for the clone",name+"-clone");if(l)act(name,"clone",{name:l})}
async function machines(){const [host,vms]=await Promise.all([api("GET","/host"),api("GET","/vms")]);
$("#hostname").textContent=host.osVersion;
const running=vms.filter(v=>v.state=="running").length;const used=vms.reduce((a,v)=>a+(v.diskPhysicalBytes||0),0);
let h=`<div class="grid">
<div class="card"><div class="k">Machines</div><div class="v">${vms.length}</div></div>
<div class="card"><div class="k">Running</div><div class="v">${running}</div></div>
<div class="card"><div class="k">Host CPU / RAM</div><div class="v">${host.cpuCount} · ${(host.memoryMiB/1024).toFixed(0)} GB</div></div>
<div class="card"><div class="k">Disk actually used</div><div class="v">${gb(used)}</div></div>
<div class="card"><div class="k">Power</div><div class="v">${host.onBattery?"Battery "+(host.batteryPercent??"")+"%":"AC"}</div></div></div>`;
h+=`<div class="wrap"><table><tr><th>Name</th><th>State</th><th>OS</th><th class="num">vCPU</th><th class="num">RAM</th><th class="num">Disk used / size</th><th class="num">Snaps</th><th>Actions</th></tr>`;
for(const v of vms){const tags=[v.isolated&&"isolated",v.disposable&&"disposable",v.encrypted&&"encrypted"].filter(Boolean).map(t=>`<span class="tag">${t}</span>`).join("");
const n=esc(v.name),q=JSON.stringify(v.name).replace(/"/g,"&quot;");
const btns=v.state=="running"?`<button class="btn" onclick="act(${q},'stop')">Stop</button><button class="btn" onclick="act(${q},'suspend')">Suspend</button><button class="btn" onclick="act(${q},'pause')">Pause</button>`
:v.state=="paused"?`<button class="btn" onclick="act(${q},'resume')">Resume</button>`
:v.state=="locked"?``:`<button class="btn primary" onclick="act(${q},'start')">Start</button><button class="btn" onclick="clone(${q})">Clone</button><button class="btn" onclick="del(${q})">Delete</button>`;
h+=`<tr><td><b>${n}</b><br>${tags}</td><td><span class="pill ${esc(v.state)}"><span class="dot"></span>${esc(v.state)}</span></td><td>${esc(v.os||"")}</td>
<td class="num">${v.cpus??""}</td><td class="num">${v.memoryMiB?(v.memoryMiB/1024).toFixed(1)+" GB":""}</td>
<td class="num">${v.diskPhysicalBytes!=null?gb(v.diskPhysicalBytes)+" / "+gb(v.diskLogicalBytes):""}</td><td class="num">${v.snapshots??""}</td>
<td><div class="actions">${btns}${v.state!="locked"?`<button class="btn" onclick="snap(${q})">Snapshot</button>`:""}</div></td></tr>`}
if(!vms.length)h+=`<tr><td colspan="8" class="k">No machines yet — use Create.</td></tr>`;
return h+"</table></div>"}
async function create(){const cat=await api("GET","/catalog");
return `<h2>Create a machine</h2><form class="row" onsubmit="doCreate(event)">
<label>Name<input name="name" required pattern="[A-Za-z0-9][A-Za-z0-9._-]*" placeholder="dev-box"></label>
<label>Source<select name="from">${cat.filter(c=>c.kind=="cloudImage"||c.kind=="iso").map(c=>`<option value="catalog:${esc(c.id)}">${esc(c.title)}</option>`).join("")}<option value="blank">Blank (EFI)</option></select></label>
<label>Profile<select name="profile">${["productivity","development","design","gaming","server","travel"].map(p=>`<option>${p}</option>`).join("")}</select></label>
<label>vCPU<input name="cpus" type="number" min="1" placeholder="auto" style="width:80px"></label>
<label>RAM (MiB)<input name="memoryMiB" type="number" min="512" step="256" placeholder="auto" style="width:110px"></label>
<label>Disk (GiB)<input name="diskGiB" type="number" min="8" placeholder="64" style="width:90px"></label>
<label>Start<select name="state"><option value="running">yes</option><option value="stopped">no</option></select></label>
<button class="btn primary">Create</button></form><p class="k">Cloud images boot fully provisioned (your user + SSH keys, guest agent, shared folders, Rosetta). macOS guests and Windows ISOs: use the AltVM app or <code>avm create</code>.</p>`}
async function doCreate(e){e.preventDefault();const f=new FormData(e.target);const b={};for(const [k,v] of f){if(v!=="")b[k]=["cpus","memoryMiB","diskGiB"].includes(k)?Number(v):v}
try{toast("Creating "+b.name+" (first download may take a while)…");await api("POST","/vms",b);toast(b.name+" created");go("Machines")}catch(err){toast(err.message)}}
async function networks(){const sw=await api("GET","/switches");const presets=["perfect","lan","wifi","dsl","4g","3g","edge","satellite","lossy","very-bad"];
let h=`<h2>Virtual switches</h2><p class="k">Private L2 networks between VMs with built-in DHCP and live network conditioning.</p><div class="wrap"><table><tr><th>Switch</th><th>Subnet</th><th class="num">Latency</th><th class="num">Jitter</th><th class="num">Loss</th><th class="num">Bandwidth</th><th>Apply preset</th></tr>`;
for(const s of sw){const c=s.conditions,q=JSON.stringify(s.name).replace(/"/g,"&quot;");h+=`<tr><td><b>${esc(s.name)}</b></td><td>${esc(s.subnet)}.0/24</td><td class="num">${c.latencyMs} ms</td><td class="num">${c.jitterMs} ms</td><td class="num">${c.lossPercent}%</td><td class="num">${c.bandwidthKbps?c.bandwidthKbps+" kbps":"∞"}</td>
<td><select onchange="preset(${q},this.value)"><option value="">—</option>${presets.map(p=>`<option>${p}</option>`).join("")}</select></td></tr>`}
if(!sw.length)h+=`<tr><td colspan="7" class="k">No switches. Create one: <code>avm switch create lab</code></td></tr>`;return h+"</table></div>"}
async function preset(n,p){if(!p)return;try{await api("PUT",`/switches/${encodeURIComponent(n)}/conditions`,{preset:p});toast(n+" → "+p);render()}catch(e){toast(e.message)}}
async function policy(){const p=await api("GET","/policy");if(!p.installed)return `<h2>Policy</h2><p class="k">No signed policy installed. IT can create one with <code>avm policy init</code>, sign it with <code>avm policy sign</code> and deploy via MDM.</p>`;
return `<h2>Active policy — ${esc(p.policy.organization)}</h2><pre>${esc(JSON.stringify(p.policy,null,2))}</pre>`}
async function audit(){const [v,es]=await Promise.all([api("GET","/audit/verify"),api("GET","/audit?limit=300")]);
let h=`<h2>Audit trail <span class="${v.intact?"ok":"bad"}">${v.intact?"● chain intact":"● TAMPERED: "+esc(v.problem)}</span></h2><div class="wrap"><table><tr><th class="num">#</th><th>Time</th><th>User</th><th>Event</th><th>VM</th><th>Details</th></tr>`;
for(const e of es.reverse())h+=`<tr><td class="num">${e.seq}</td><td class="num">${esc(new Date(e.ts).toLocaleString())}</td><td>${esc(e.user)}</td><td>${esc(e.event)}</td><td>${esc(e.vm||"")}</td><td class="k">${esc(Object.entries(e.details||{}).map(([k,v])=>k+"="+v).join(" "))}</td></tr>`;
return h+"</table></div>"}
async function render(){if(!token){$("#app").innerHTML=`<div id="login" class="card"><h2>Sign in</h2><p class="k">Paste the API token printed by <code>avm serve</code>.</p><form onsubmit="token=this.t.value.trim();try{sessionStorage.setItem('altvm-token',token)}catch(e){};render();return false"><input name="t" style="width:100%" autofocus><p><button class="btn primary">Continue</button></p></form></div>`;return}
try{$("#app").innerHTML=await ({Machines:machines,Create:create,Networks:networks,Policy:policy,Audit:audit})[tab]()}catch(e){if(/unauthorized/.test(e.message)){token="";try{sessionStorage.removeItem("altvm-token")}catch(_){}}$("#app").innerHTML=`<p class="bad">${esc(e.message)}</p>`}}
nav();render();setInterval(()=>{if(tab=="Machines"&&token&&!document.hidden)render()},5000);
</script>
</body>
</html>
"""#
}
