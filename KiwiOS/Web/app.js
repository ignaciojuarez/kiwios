"use strict";
const state={snapshot:null,csrf:null,pending:null,connected:false,mutating:false,refreshing:false};
const el=id=>document.getElementById(id);
const node=(tag,className,text)=>{const n=document.createElement(tag);if(className)n.className=className;if(text!==undefined)n.textContent=String(text);return n};
const valueText=value=>value===null||value===undefined?"—":typeof value==="object"?JSON.stringify(value):String(value);

async function session(){const response=await fetch("/api/session",{credentials:"same-origin",cache:"no-store",signal:AbortSignal.timeout(20000),headers:{"X-KiwiOS-Session":"1"}});if(!response.ok)throw new Error(responseError(response.status));state.csrf=response.headers.get("X-KiwiOS-CSRF");return response.json()}
function responseError(status){return status===429?"Too many requests. Wait one minute and retry.":status===503?"Remote session capacity is full. Keep this browser session and retry later, or restart remote access on the Mac.":status===409?"This request was already received or configuration changed. Refresh before retrying.":"Request rejected. Check Events and Status & setup; source, permission, or confirmation changes may require attention on the Mac."}
async function api(path,options={},retry=true){const response=await fetch(path,{credentials:"same-origin",cache:"no-store",signal:AbortSignal.timeout(20000),...options});if(response.status===401&&retry){await session();return api(path,options,false)}if(!response.ok)throw new Error(responseError(response.status));return response}
async function mutationRequest(body,retry){const response=await fetch("/api/mutate",{method:"POST",credentials:"same-origin",cache:"no-store",headers:{"Content-Type":"application/json","X-KiwiOS-CSRF":state.csrf},body});state.csrf=response.headers.get("X-KiwiOS-CSRF")||state.csrf;if(response.status===401&&retry){await session();return mutationRequest(body,false)}if(!response.ok)throw new Error(responseError(response.status));return response.json()}
async function mutate(payload){return mutationRequest(JSON.stringify({requestID:crypto.randomUUID(),...payload}),true)}

function resultFor(plugin,source){return (plugin.liveResults&&plugin.liveResults[source])||(plugin.results&&plugin.results[source])}
function liveFor(plugin,source){return plugin.liveResults&&plugin.liveResults[source]}
function card(title,wide=false){const c=node("article","card"+(wide?" wide":""));c.append(node("h2","",title));return c}
function empty(title,detail){const box=node("div","empty");box.append(node("h2","",title),node("p","",detail));return box}
function statusDot(outcome){return node("span","dot "+(outcome||""))}

function renderKind(plugin,descriptor,widget=false){const c=card(descriptor.title||descriptor.label||descriptor.id,descriptor.size==="2x1");const source=descriptor.source;const result=resultFor(plugin,source);const kind=descriptor.kind;if(plugin.lifecycle!=="active")c.append(node("p","detail",plugin.message||"Complete setup in the native app."));const date=plugin.resultDates&&plugin.resultDates[source];if(date&&!widget)c.append(node("p","age",`Last result: ${new Date(date).toLocaleString()}`));
  if(kind==="stat"){const data=(liveFor(plugin,source)&&liveFor(plugin,source).state)||(plugin.results&&plugin.results[source]&&plugin.results[source].state);if(!validStat(data)){c.append(node("p","muted","Unavailable"));return c}const line=node("div","stat-value",valueText(data.value));if(data.unit)line.append(" "+data.unit);c.append(line);if(data.detail&&!widget)c.append(node("p","detail",data.detail));if(data.delta&&!widget)c.append(node("p","detail",data.delta));return c}
  if(kind==="checks"){const rows=node("div","rows");const checks=(plugin.checks||[]).filter(x=>source==="checks"||source===`checks.${x.id}`);checks.forEach(check=>{const key=`checks.${check.id}`,live=liveFor(plugin,key),r=live||(plugin.results&&plugin.results[key]);const row=node("div","row"),main=node("div","row-main");main.append(node("div","row-title",check.label),node("div","detail",live?"Running…":r&&r.message||"Unavailable"));if(check.every)main.append(node("div","age",`Every ${check.every} seconds`));const button=node("button","",live?"Running":"Run");button.dataset.unavailable=String(!!live||plugin.lifecycle!=="active"||contributionBusy(plugin.id,key));button.onclick=()=>perform({operation:"refreshCheck",pluginID:plugin.id,contributionID:check.id});row.append(statusDot(live?"":r&&r.outcome),main,button);rows.append(row)});c.append(checks.length?rows:node("p","muted","No checks"));return c}
  if(kind==="actions"){const rows=node("div","rows");const actions=(plugin.actions||[]).filter(x=>source==="actions"||source===`actions.${x.id}`);actions.forEach(action=>{const key=`actions.${action.id}`,live=liveFor(plugin,key),r=live||(plugin.results&&plugin.results[key]);const row=node("div","row"),main=node("div","row-main");main.append(node("div","row-title",action.label),node("div","detail",live?"Running…":r&&r.message||"Not run yet"));const button=node("button","",live?"Running":action.confirm?"Review…":"Run");button.dataset.unavailable=String(!!live||plugin.lifecycle!=="active"||contributionBusy(plugin.id,key));button.onclick=()=>perform({operation:"requestAction",pluginID:plugin.id,contributionID:action.id});row.append(statusDot(live?"":r&&r.outcome),main,button);rows.append(row)});c.append(actions.length?rows:node("p","muted","No actions"));return c}
  if(kind==="table"){const data=result&&result.state;if(!validTable(data)){c.append(node("p","muted","Table data unavailable"));return c}const wrap=node("div","table-wrap"),table=node("table"),head=node("thead"),tr=node("tr");data.columns.forEach(column=>tr.append(node("th","",column.label)));head.append(tr);const body=node("tbody");data.rows.forEach(row=>{const line=node("tr");data.columns.forEach(column=>line.append(node("td","",valueText(row[column.id]))));body.append(line)});table.append(head,body);wrap.append(table);c.append(wrap);return c}
  if(kind==="log"){const logs=result&&result.logs||[];c.append(logs.length?node("pre","",logs.map(item=>`[${item.source}] ${item.message}`).join("\n")):node("p","muted","No log output"));return c}
  if(kind==="watchers"){
    const rows=node("div","rows"),sessions=(state.snapshot.plugins||[]).filter(item=>item.lifecycle==="active"&&item.watch);
    for(const session of sessions){
      const key=`checks.${session.watch.status}`,live=liveFor(session,key),result=live||(session.results&&session.results[key]),row=node("div","row"),main=node("div","row-main");
      const start=session.watch.start,action=start&&(session.actions||[]).find(item=>item.id===start),actionKey=start&&`actions.${start}`,actionLive=actionKey&&liveFor(session,actionKey),message=actionLive?"Starting…":live?"Checking…":result&&result.message||"Status unavailable";
      main.append(node("div","row-title",session.name),node("div","detail",message));
      const logs=actionLive&&actionLive.logs||result&&result.logs||[];if(logs.length&&logs.at(-1).message!==message)main.append(node("div","age",logs.at(-1).message));
      const progress=actionLive&&actionLive.progress||result&&result.progress;
      if(progress&&progress.message)main.append(node("div","age",progress.message));
      if(progress&&typeof progress.percentage==="number"){const meter=node("progress");meter.max=100;meter.value=progress.percentage;main.append(meter)}
      row.append(statusDot(live||actionLive?"":result&&result.outcome),main);
      if(action&&!live&&!["succeeded","warning"].includes(result&&result.outcome)){const button=node("button","",actionLive?"Starting…":"Start");button.dataset.unavailable=String(!!actionLive||contributionBusy(session.id,actionKey));button.onclick=()=>perform({operation:"requestAction",pluginID:session.id,contributionID:start});row.append(button)}
      rows.append(row);
    }
    c.append(sessions.length?rows:node("p","muted","No active plugins declare a watched session"));return c
  }
  if(kind==="form"){
    const schema=plugin.configSchema&&plugin.configSchema.properties||{},form=node("form","form"),initialValues={};
    for(const [key,field] of Object.entries(schema)){
      const wrap=node("div","field");
      if(field.writeOnly){wrap.append(node("span","",field.title||key),node("span","detail","Secret: configure or replace in attended setup on the Mac."));form.append(wrap);continue}
      const label=node("label","",field.title||key);label.htmlFor=`field-${plugin.id}-${descriptor.id}-${key}`;
      let input;
      if(Array.isArray(field.enumValues)){
        input=node("select");
        const blank=node("option","",field.required?"Choose…":"Keep current value or default");blank.value="";input.append(blank);
        field.enumValues.forEach((v,index)=>{const option=node("option","",valueText(v));option.value=String(index);input.append(option)})
      }else{
        input=node("input");input.type=field.type==="boolean"?"checkbox":field.type==="number"||field.type==="integer"?"number":"text";
        if(input.type==="number"){input.step=field.type==="integer"?"1":"any";input.placeholder="Blank keeps saved value";if(field.type==="integer"){input.min=String(Number.MIN_SAFE_INTEGER);input.max=String(Number.MAX_SAFE_INTEGER)}}
      }
      input.id=label.htmlFor;input.name=key;input.required=!!field.required&&input.type!=="checkbox";
      const initial=plugin.config&&plugin.config[key]!==undefined?plugin.config[key]:field.defaultValue;
      if(initial!==null&&initial!==undefined){
        if(Array.isArray(field.enumValues))input.value=String(field.enumValues.findIndex(v=>v===initial));
        else if(input.type==="checkbox")input.checked=!!initial;else input.value=initial;
      }
      initialValues[key]=input.type==="checkbox"?input.checked:input.value;
      wrap.append(label,input);if(field.description)wrap.append(node("span","detail",field.description));form.append(wrap);
    }
    form.addEventListener("input",()=>{form.dataset.dirty="true"});
    const save=node("button","","Save configuration");save.type="submit";form.append(save);
    form.onsubmit=event=>{
      event.preventDefault();const values={};
      for(const control of form.elements){
        if(!control.name)continue;const field=schema[control.name];
        const current=control.type==="checkbox"?control.checked:control.value;
        if(current===initialValues[control.name])continue;
        if(Array.isArray(field.enumValues)){if(control.value!=="")values[control.name]=field.enumValues[Number(control.value)]}
        else if(control.type==="checkbox")values[control.name]=control.checked;
        else if(control.type==="number"){if(control.value!==""){const value=Number(control.value);if(!Number.isFinite(value)||(field.type==="integer"&&!Number.isSafeInteger(value))){showNotice(`Enter a valid ${field.type} for ${field.title||control.name}.`);return}values[control.name]=value}}
        else values[control.name]=control.value;
      }
      if(!Object.keys(values).length){showNotice("No configuration changes to save.");return}
      perform({operation:"saveConfig",pluginID:plugin.id,values,configRevision:plugin.configRevision});
    };
    c.append(form);return c;
  }
  c.append(node("p","muted","This contribution is unavailable"));return c
}

function object(value){return value!==null&&typeof value==="object"&&!Array.isArray(value)}
function scalar(value){return value===null||["string","number","boolean"].includes(typeof value)}
function validStat(data){
  return object(data)&&["string","number"].includes(typeof data.value)&&Object.keys(data).every(key=>["value","unit","detail","delta"].includes(key))&&["unit","detail","delta"].every(key=>data[key]===undefined||typeof data[key]==="string");
}
function validTable(data){
  if(!object(data)||Object.keys(data).length!==2||!Array.isArray(data.columns)||!Array.isArray(data.rows)||data.columns.length<1||data.columns.length>12||data.rows.length>100)return false;
  const validID=id=>typeof id==="string"&&/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id);
  if(!data.columns.every(column=>object(column)&&Object.keys(column).length===2&&validID(column.id)&&column.id!=="id"&&typeof column.label==="string"&&column.label.trim()))return false;
  const keys=data.columns.map(column=>column.id);if(new Set(keys).size!==keys.length)return false;
  const ids=new Set();
  return data.rows.every(row=>{
    if(!object(row)||!validID(row.id)||ids.has(row.id)||Object.keys(row).length!==keys.length+1||!keys.every(key=>Object.hasOwn(row,key)&&scalar(row[key])))return false;
    ids.add(row.id);return true;
  });
}
function route(){const hash=location.hash.slice(1)||"home";if(["home","events","status"].includes(hash))return {type:hash};const match=/^plugin\/([a-z0-9.-]+)\/page\/([a-z0-9-]+)$/.exec(hash);return match?{type:"page",pluginID:decodeURIComponent(match[1]),pageID:decodeURIComponent(match[2])}:{type:"home"}}
function contribution(key,collection){const parts=key.split("/",2),plugin=(state.snapshot.plugins||[]).find(p=>p.id===parts[0]&&p.lifecycle==="active");return plugin&&{plugin,item:(plugin[collection]||[]).find(item=>item.id===parts[1])}}
function render(){const snapshot=state.snapshot;if(!snapshot)return;const r=route(),content=el("content");content.replaceChildren();el("back").classList.toggle("hidden",r.type==="home");if(["events","status"].includes(r.type)){el("eyebrow").textContent="Mac mini hub";el("title").textContent=r.type==="events"?"Events":"Status & setup";content.append(r.type==="events"?renderEvents():renderStatus())}else if(r.type==="home"){el("eyebrow").textContent="Mac mini hub";el("title").textContent="Home";const grid=node("div","grid"),layout=snapshot.layout||{},keys=layout.widgets||[];for(const key of keys){if((layout.hiddenWidgets||[]).includes(key))continue;const found=contribution(key,"widgets");if(found&&found.item)grid.append(renderKind(found.plugin,{...found.item,size:(layout.wideWidgets||[]).includes(key)?"2x1":"1x1"},true))}content.append(grid.children.length?grid:empty("No widgets","Choose widgets in the native KiwiOS app."))}else{const plugin=(snapshot.plugins||[]).find(p=>p.id===r.pluginID),page=plugin&&(plugin.pages||[]).find(p=>p.id===r.pageID);if(!plugin||!page){content.append(empty("Page unavailable","The plugin or page is no longer available."));return}el("eyebrow").textContent=plugin.name;el("title").textContent=page.title;const pages=node("nav","page-navigation");pages.setAttribute("aria-label",`${plugin.name} pages`);for(const item of plugin.pages||[]){const link=node("a",item.id===page.id?"active":"",item.title);link.href=`#plugin/${encodeURIComponent(plugin.id)}/page/${encodeURIComponent(item.id)}`;pages.append(link)}content.append(pages,renderKind(plugin,page))}content.setAttribute("aria-busy","false");renderNavigation();updateAvailability()}
function renderNavigation(){const nav=el("navigation");nav.replaceChildren();const home=node("a",route().type==="home"?"active":"","Home");home.href="#home";nav.append(home);for(const [id,title] of [["events","Events"],["status","Status & setup"]]){const link=node("a",route().type===id?"active":"",title);link.href=`#${id}`;nav.append(link)}for(const key of ((state.snapshot.layout&&state.snapshot.layout.sidebar)||[])){const found=contribution(key,"sidebar");if(!found||!found.item)continue;const a=node("a","",found.item.label);a.href=`#plugin/${encodeURIComponent(found.plugin.id)}/page/${encodeURIComponent(found.item.page)}`;if(location.hash===a.getAttribute("href"))a.className="active";nav.append(a)}}
function contributionBusy(pluginID,source){
  const plugin=(state.snapshot.plugins||[]).find(item=>item.id===pluginID);
  const action=source.startsWith("actions.")&&plugin&&(plugin.actions||[]).find(item=>`actions.${item.id}`===source);
  return (state.snapshot.jobs||[]).some(job=>job.pluginID===pluginID&&(action?job.resource===action.resource:`${job.kind==="check"?"checks":"actions"}.${job.contributionID}`===source));
}
function updateAvailability(){
  document.querySelectorAll("#content button").forEach(control=>{
    control.disabled=!state.connected||state.mutating||control.dataset.unavailable==="true";
  });
  // Drafts remain editable offline; only submission requires a live connection.
  document.querySelectorAll("#content input,#content select").forEach(control=>{control.disabled=state.mutating});
  el("confirm-action").disabled=!state.connected||state.mutating;
}
function renderEvents(){
  const lines=[];
  for(const plugin of state.snapshot.plugins||[]){
    const live=Object.values(plugin.liveResults||{}).find(item=>(item.logs&&item.logs.length)||(item.protocolWarnings&&item.protocolWarnings.length)),dated=Object.entries(plugin.resultDates||{}).sort((a,b)=>new Date(b[1])-new Date(a[1]))[0],source=dated&&dated[0],result=source&&plugin.results&&plugin.results[source],logs=live&&live.logs||result&&result.logs||[],log=logs.at(-1),warning=(live&&live.protocolWarnings||result&&result.protocolWarnings||[]).at(-1),failed=result&&!['succeeded','warning'].includes(result.outcome);
    const time=live?"--:--:--":dated?new Date(dated[1]).toLocaleTimeString():"--:--:--",level=warning?"WARN":failed?"ERROR":result&&result.outcome==="warning"?"WARN":log&&log.level?log.level.toUpperCase():result?"OK":plugin.lifecycle==="active"?"INFO":plugin.lifecycle==="disabled"?"OFF":"WARN",message=warning||failed&&result.message||result&&result.outcome==="warning"&&result.message||log&&log.message||result&&result.message||plugin.message;
    lines.push(`${time} [${level}] ${plugin.id} ${message}`);
  }
  return lines.length?node("pre","",lines.join("\n")):empty("No plugin events","Add a plugin to see its latest status line.");
}
function renderStatus(){
  const box=node("div","rows");
  const availability=card("Remote availability");
  availability.append(node("p","",state.snapshot.availability),node("p","detail","For missing permissions, source reviews, secret changes, or Tailscale recovery, open KiwiOS on the Mac and use Settings. Access stops when the owning user logs out."));box.append(availability);
  const doctor=card("Doctor");
  if(!(state.snapshot.doctor||[]).length)doctor.append(node("p","muted","No Doctor findings are available. Refresh Doctor in the native app."));
  for(const finding of state.snapshot.doctor||[]){const row=node("div","row"),main=node("div","row-main");main.append(node("div","row-title",`${finding.title} · ${finding.status}`),node("p","detail",finding.detail));row.append(main);doctor.append(row)}
  box.append(doctor);
  if(!(state.snapshot.plugins||[]).length)box.append(empty("No plugins available","Review a bundled plugin or install one using the native app."));
  for(const plugin of state.snapshot.plugins||[]){
    const item=card(plugin.name);item.append(node("p","",`${plugin.lifecycle}: ${plugin.message}`));
    box.append(item);
  }
  return box;
}
async function perform(payload){
  if(!state.connected||state.mutating){showNotice("Wait for a live connection and the current request to finish.");return}
  state.mutating=true;updateAvailability();
  try{
    const result=await mutate(payload);
    if(result.confirmationToken&&result.label){
      state.pending={operation:"confirmAction",confirmationToken:result.confirmationToken};
      el("confirmation-title").textContent=result.label;
      el("confirmation-detail").textContent="Confirm this action within 60 seconds. Its source and permissions will be checked again before it runs.";
      el("confirmation").returnValue="";el("confirmation").showModal();return;
    }
    await refresh(true);
  }catch(error){showNotice(error.message)}
  finally{state.mutating=false;updateAvailability()}
}
async function refresh(force=false){
  if(state.refreshing)return;
  state.refreshing=true;
  try{
    const response=await api("/api/snapshot"),snapshot=await response.json();
    if(snapshot.api!=="kiwios.remote/1")throw new Error("Unsupported remote API; update KiwiOS on the Mac.");
    state.snapshot=snapshot;state.connected=true;
    el("connection").textContent="Online";el("connection").className="connection online";
    const viewer=snapshot.viewer||{};
    el("viewer").replaceChildren(node("strong","",viewer.displayName||viewer.loginName||"Tailnet user"),node("span","",viewer.loginName||""));
    // Polling must not erase a configuration edit or replace a focused control.
    const editing=document.querySelector("#content form[data-dirty=\"true\"]")||document.activeElement.closest("#content form");
    if(force||!editing)render();
    if(!state.mutating)el("notice").classList.add("hidden");
  }catch(error){
    state.connected=false;
    el("connection").textContent=navigator.onLine?"Unavailable":"Offline";el("connection").className="connection";
    if(!state.snapshot)el("content").replaceChildren(empty("KiwiOS is unavailable","On the Mac, open KiwiOS after login. Connect this device to Tailscale, then retry the displayed HTTPS address. This page will reconnect automatically."));
    showNotice("Live status is unavailable; displayed results may be old. Check that the Mac is logged in, KiwiOS is open, and both devices are connected to Tailscale. Actions are disabled until reconnection.");
  }finally{state.refreshing=false;updateAvailability();el("content").setAttribute("aria-busy","false")}
}
function showNotice(message){el("notice").textContent=message;el("notice").classList.remove("hidden")}
el("back").onclick=()=>{location.hash="home"};
el("confirmation").addEventListener("cancel",()=>{el("confirmation").returnValue="";state.pending=null});
el("confirmation").addEventListener("close",()=>{const pending=state.pending;state.pending=null;if(el("confirmation").returnValue==="default"&&pending)perform(pending)});
addEventListener("hashchange",render);addEventListener("online",()=>refresh());
addEventListener("offline",()=>{state.connected=false;updateAvailability();showNotice("Offline. Displayed results may be old; actions require a live connection.")});
(async()=>{
  await refresh();
  if("serviceWorker" in navigator)navigator.serviceWorker.register("/service-worker.js").catch(()=>{if(state.connected)showNotice("Offline app installation is unavailable; the live UI still works.")});
  setInterval(()=>refresh(),5000);
})();
