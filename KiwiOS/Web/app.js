"use strict";
const state={snapshot:null,snapshotWire:null,csrf:null,pending:null,connected:false,mutating:false,refreshPromise:null,homeEditing:false,draggedWidget:null};
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
function statusDot(outcome){const dot=node("span","dot "+(outcome||""));dot.setAttribute("aria-hidden","true");return dot}
function outcomeText(outcome){return (outcome||"unavailable").replaceAll("-"," ")}
function relativeAge(date){const seconds=Math.max(0,Math.round((Date.now()-new Date(date).getTime())/1000));if(seconds<60)return "now";if(seconds<3600)return `${Math.floor(seconds/60)}m ago`;if(seconds<86400)return `${Math.floor(seconds/3600)}h ago`;return `${Math.floor(seconds/86400)}d ago`}
function appendProgress(parent,progress,label){
  if(!progress)return;
  const percentage=typeof progress.percentage==="number"?progress.percentage:null;
  if(progress.message||percentage!==null)parent.append(node("div","progress-meta",progress.message||`${percentage}%`));
  if(percentage!==null){const meter=node("progress");meter.max=100;meter.value=percentage;meter.setAttribute("aria-label",label);parent.append(meter)}
}

function repeatsPluginMessage(plugin,descriptor){
  if(!plugin.message||!["checks","actions"].includes(descriptor.kind))return false;
  const prefix=descriptor.kind+".",sources=descriptor.source===descriptor.kind?(plugin[descriptor.kind]||[]).map(item=>prefix+item.id):[descriptor.source];
  return sources.some(source=>resultFor(plugin,source)?.message===plugin.message);
}
function renderKind(plugin,descriptor,widget=false){const c=card(descriptor.title||descriptor.label||descriptor.id,descriptor.size==="2x1");const source=descriptor.source;const result=resultFor(plugin,source);const kind=descriptor.kind;if(plugin.lifecycle!=="active"&&!repeatsPluginMessage(plugin,descriptor))c.append(node("p","detail",plugin.message||"Complete setup on the Mac."));const date=plugin.resultDates&&plugin.resultDates[source];if(date&&!widget)c.append(node("p","age",`Updated ${relativeAge(date)}`));
  if(kind==="stat"){const data=(liveFor(plugin,source)&&liveFor(plugin,source).state)||(plugin.results&&plugin.results[source]&&plugin.results[source].state);if(!validStat(data)){c.append(node("p","muted","Unavailable"));return c}const line=node("div","stat-value",valueText(data.value));if(data.unit)line.append(" "+data.unit);c.append(line);if(data.detail&&!widget)c.append(node("p","detail",data.detail));if(data.delta&&!widget)c.append(node("p","detail",data.delta));return c}
  if(kind==="checks"){const rows=node("div","rows");const checks=(plugin.checks||[]).filter(x=>source==="checks"||source===`checks.${x.id}`);checks.forEach(check=>{const key=`checks.${check.id}`,job=activeJob(plugin.id,key),live=liveFor(plugin,key),r=live||(plugin.results&&plugin.results[key]),running=!!live||!!job;const row=node("div","row"),main=node("div","row-main"),outcome=running?"running":r&&r.outcome;main.append(node("div","row-title",check.label),node("div","status-label",outcomeText(outcome)));if(r&&r.message)main.append(node("div","detail",r.message));appendProgress(main,r&&r.progress,`${check.label} progress`);const button=node("button",job?"danger":"",job?"Cancel":running?"Running":"Run");button.dataset.unavailable=String(!job&&(running||plugin.lifecycle!=="active"));button.onclick=()=>job?perform({operation:"cancelJob",jobID:job.id}):perform({operation:"refreshCheck",pluginID:plugin.id,contributionID:check.id});row.append(statusDot(outcome),main,button);rows.append(row)});c.append(checks.length?rows:node("p","muted","No checks"));return c}
  if(kind==="actions"){const rows=node("div","rows");const actions=(plugin.actions||[]).filter(x=>source==="actions"||source===`actions.${x.id}`);actions.forEach(action=>{const key=`actions.${action.id}`,job=activeJob(plugin.id,key),live=liveFor(plugin,key),r=live||(plugin.results&&plugin.results[key]),running=!!live||!!job;const row=node("div","row"),main=node("div","row-main"),outcome=running?"running":r&&r.outcome;main.append(node("div","row-title",action.label),node("div","status-label",outcomeText(outcome)));if(r&&r.message)main.append(node("div","detail",r.message));appendProgress(main,r&&r.progress,`${action.label} progress`);const button=node("button",job?"danger":"",job?"Cancel":running?"Running":action.confirm?"Review":"Run");button.dataset.unavailable=String(!job&&(running||plugin.lifecycle!=="active"));button.onclick=()=>job?perform({operation:"cancelJob",jobID:job.id}):perform({operation:"requestAction",pluginID:plugin.id,contributionID:action.id});row.append(statusDot(outcome),main,button);rows.append(row)});c.append(actions.length?rows:node("p","muted","No actions"));return c}
  if(kind==="table"){const data=result&&result.state;if(!validTable(data)){c.append(node("p","muted","Table data unavailable"));return c}const wrap=node("div","table-wrap"),table=node("table"),head=node("thead"),tr=node("tr");wrap.tabIndex=0;wrap.setAttribute("aria-label",`${descriptor.title||descriptor.label||descriptor.id} table`);data.columns.forEach(column=>{const heading=node("th","",column.label);heading.scope="col";tr.append(heading)});head.append(tr);const body=node("tbody");data.rows.forEach(row=>{const line=node("tr");data.columns.forEach(column=>line.append(node("td","",valueText(row[column.id]))));body.append(line)});table.append(head,body);wrap.append(table);c.append(wrap);return c}
  if(kind==="log"){const logs=result&&result.logs||[];c.append(logs.length?node("pre","",logs.map(item=>`[${item.source}] ${item.message}`).join("\n")):node("p","muted","No log output"));return c}
  if(kind==="watchers"){
    const rows=node("div","rows"),sessions=(state.snapshot.plugins||[]).filter(item=>item.lifecycle==="active"&&item.watch);
    for(const session of sessions){
      const key=`checks.${session.watch.status}`,live=liveFor(session,key),result=live||(session.results&&session.results[key]),row=node("div","row"),main=node("div","row-main");
      const start=session.watch.start,action=start&&(session.actions||[]).find(item=>item.id===start),actionKey=start&&`actions.${start}`,actionJob=actionKey&&activeJob(session.id,actionKey),actionLive=actionKey&&liveFor(session,actionKey),message=actionJob||actionLive?"Starting…":live?"Checking…":result&&result.message||"Status unavailable";
      main.append(node("div","row-title",session.name),node("div","detail",message));
      const logs=actionLive&&actionLive.logs||result&&result.logs||[];if(logs.length&&logs.at(-1).message!==message)main.append(node("div","age",logs.at(-1).message));
      const progress=actionLive&&actionLive.progress||result&&result.progress;
      appendProgress(main,progress,`${session.name} progress`);
      row.append(statusDot(live||actionJob||actionLive?"running":result&&result.outcome),main);
      if(actionJob){const button=node("button","danger","Cancel");button.onclick=()=>perform({operation:"cancelJob",jobID:actionJob.id});row.append(button)}
      else if(action&&!live&&!["succeeded","warning"].includes(result&&result.outcome)){const button=node("button","",actionLive?"Starting…":"Start");button.dataset.unavailable=String(!!actionLive);button.onclick=()=>perform({operation:"requestAction",pluginID:session.id,contributionID:start});row.append(button)}
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
    const save=node("button","","Save");save.type="submit";form.append(save);
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
function route(){const hash=location.hash.slice(1)||"home";if(hash==="status")return {type:"settings"};if(["home","tools","brew","plugins","events","settings"].includes(hash))return {type:hash};const match=/^plugin\/([a-z0-9.-]+)\/page\/([a-z0-9-]+)$/.exec(hash);return match?{type:"page",pluginID:decodeURIComponent(match[1]),pageID:decodeURIComponent(match[2])}:{type:"home"}}
function contribution(key,collection){const parts=key.split("/",2),plugin=(state.snapshot.plugins||[]).find(p=>p.id===parts[0]&&p.lifecycle==="active");return plugin&&{plugin,item:(plugin[collection]||[]).find(item=>item.id===parts[1])}}
function render(){
  const snapshot=state.snapshot;if(!snapshot)return;
  const r=route(),content=el("content"),builtins={
    tools:["Host tools",renderTools],
    brew:["Homebrew",renderBrew],
    plugins:["Plugins",renderPlugins],
    events:["Events",renderEvents],
    settings:["Settings",renderSettings]
  };
  content.replaceChildren();el("back").classList.toggle("hidden",r.type!=="page");
  if(builtins[r.type]){
    el("eyebrow").textContent="System";
    el("title").textContent=builtins[r.type][0];
    content.append(builtins[r.type][1]());
  }else if(r.type==="home"){
    el("eyebrow").textContent="System / Overview";el("title").textContent="Home";
    content.append(renderHome());
  }else{
    const plugin=(snapshot.plugins||[]).find(p=>p.id===r.pluginID),page=plugin&&(plugin.pages||[]).find(p=>p.id===r.pageID);
    if(!plugin||!page){content.append(empty("Page unavailable","The plugin or page is no longer available."));return}
    el("eyebrow").textContent=plugin.name;el("title").textContent=page.title;
    const pages=node("nav","page-navigation");pages.setAttribute("aria-label",`${plugin.name} pages`);
    for(const item of plugin.pages||[]){const link=node("a",item.id===page.id?"active":"",item.title);link.href=`#plugin/${encodeURIComponent(plugin.id)}/page/${encodeURIComponent(item.id)}`;pages.append(link)}
    content.append(pages,renderKind(plugin,page));
  }
  content.setAttribute("aria-busy","false");renderNavigation();updateAvailability();
}
function renderNavigation(){
  const nav=el("navigation");nav.replaceChildren();
  for(const [id,title] of [["home","Home"],["tools","Tools"],["brew","Brew"],["plugins","Plugins"],["events","Events"],["settings","Settings"]]){
    const link=node("a",route().type===id?"active":"",title);link.href=`#${id}`;nav.append(link);
  }
  for(const key of ((state.snapshot.layout&&state.snapshot.layout.sidebar)||[])){
    const found=contribution(key,"sidebar");if(!found||!found.item)continue;
    const link=node("a","",found.item.label);link.href=`#plugin/${encodeURIComponent(found.plugin.id)}/page/${encodeURIComponent(found.item.page)}`;
    if(location.hash===link.getAttribute("href"))link.className="active";nav.append(link);
  }
}
function contributionBusy(pluginID,source){
  return !!activeJob(pluginID,source);
}
function activeJob(pluginID,source){
  const [collection,contributionID]=source.split(".",2),kind=collection==="checks"?"check":"action";
  return (state.snapshot.jobs||[]).find(job=>job.pluginID===pluginID&&job.kind===kind&&job.contributionID===contributionID);
}
function updateAvailability(){
  document.querySelectorAll("#content button,#widget-picker button[data-mutation]").forEach(control=>{
    control.disabled=!state.connected||state.mutating||control.dataset.unavailable==="true";
  });
  // Drafts remain editable offline; only submission requires a live connection.
  document.querySelectorAll("#content input,#content select").forEach(control=>{control.disabled=state.mutating});
  el("confirm-action").disabled=!state.connected||state.mutating;
}
function eventLevel(level){
  const value=String(level||"").toUpperCase();
  if(["ERROR","FAILED","FAIL"].includes(value))return "ERROR";
  if(["WARN","WARNING"].includes(value))return "WARN";
  if(["OK","SUCCESS","SUCCEEDED"].includes(value))return "OK";
  return value==="OFF"?"OFF":"INFO";
}
function renderEvents(){
  const terminal=node("pre","events-terminal");terminal.setAttribute("aria-label","Plugin events");
  for(const plugin of state.snapshot.plugins||[]){
    const live=Object.values(plugin.liveResults||{}).find(item=>(item.logs&&item.logs.length)||(item.protocolWarnings&&item.protocolWarnings.length)),dated=Object.entries(plugin.resultDates||{}).sort((a,b)=>new Date(b[1])-new Date(a[1]))[0],source=dated&&dated[0],result=source&&plugin.results&&plugin.results[source],logs=live&&live.logs||result&&result.logs||[],log=logs.at(-1),warning=(live&&live.protocolWarnings||result&&result.protocolWarnings||[]).at(-1),failed=result&&!['succeeded','warning'].includes(result.outcome);
    const time=live?"--:--:--":dated?new Date(dated[1]).toLocaleTimeString():"--:--:--",rawLevel=warning?"WARN":failed?"ERROR":result&&result.outcome==="warning"?"WARN":log&&log.level?log.level:result?"OK":plugin.lifecycle==="active"?"INFO":plugin.lifecycle==="disabled"?"OFF":"WARN",level=eventLevel(rawLevel),message=warning||failed&&result.message||result&&result.outcome==="warning"&&result.message||log&&log.message||result&&result.message||plugin.message;
    const line=node("span",`event-line event-${level.toLowerCase()}`);line.append(node("span","event-level",`[${level}]`),document.createTextNode(` ${time} ${plugin.id} ${message||"—"}`));terminal.append(line);
  }
  return terminal.children.length?terminal:empty("No plugin events","Add a plugin to see its latest status line.");
}
function renderSettings(){
  const box=node("div","stack");
  const availability=card("Remote availability");
  const settings=state.snapshot.settings||{},remote=settings.remoteAccess||{};
  availability.append(node("p","",remote.message||state.snapshot.availability),node("p","detail","Available after the Mac owner logs in and unlocks FileVault."));box.append(availability);
  const doctor=card("Doctor");
  const refresh=node("button","quiet","Refresh");refresh.onclick=()=>perform({operation:"refreshDoctor"});doctor.append(refresh);
  if(!(state.snapshot.doctor||[]).length)doctor.append(node("p","muted","No Doctor findings are available."));
  for(const finding of state.snapshot.doctor||[]){const row=node("div","row"),main=node("div","row-main");main.append(node("div","row-title",finding.title),node("span","status-label",finding.status),node("p","detail",finding.detail));row.append(statusDot(finding.status==="passed"?"succeeded":finding.status==="blocked"?"failed":"warning"),main);doctor.append(row)}
  box.append(doctor);
  const attended=card("Attended setup");
  const mode=settings.operationMode||{},login=settings.launchAtLogin||{},development=settings.developmentPlugins||{},secrets=settings.namedSecrets||{};
  for(const [title,value,detail] of [
    ["Operation mode",mode.value||state.snapshot.mode,mode.guidance],
    ["Launch at login",login.status||"unknown",[login.detail,login.guidance].filter(Boolean).join(" ")],
    ["Development plugins",development.configured?"Directory configured":"No directory configured",development.guidance],
    ["Named Keychain secrets","Values never shown",secrets.guidance]
  ]){const row=node("div","row"),main=node("div","row-main");main.append(node("div","row-title",title),node("span","status-label",value),node("p","detail",detail||"Manage on the Mac."));row.append(main);attended.append(row)}
  box.append(attended);
  return box;
}
function renderPlugins(){
  const box=node("div","stack"),sources=card("Plugin sources"),reload=node("button","quiet","Reload");
  reload.onclick=()=>perform({operation:"reloadPlugins"});sources.append(node("p","detail","Reload validates configured sources without executing changed code."),pluginInstallForm(),reload);box.append(sources);
  if(!(state.snapshot.plugins||[]).length)box.append(empty("No plugins available","Stage an immutable GitHub revision to inspect and install it."));
  for(const plugin of state.snapshot.plugins||[]){
    const item=card(plugin.name),status=node("span","status-label",plugin.lifecycle==="installed"?"not added":outcomeText(plugin.lifecycle)),controls=node("div","button-row");item.append(status,node("p","detail",plugin.message));
    if(["active","needs-setup","missing-dependency"].includes(plugin.lifecycle)){const disable=node("button","danger","Disable");disable.onclick=()=>perform({operation:"disablePlugin",pluginID:plugin.id});controls.append(disable)}
    if(["disabled","error"].includes(plugin.lifecycle)){
      if(plugin.canEnableRemotely&&!plugin.enableBlocker){
        const missing=plugin.missingBrew||[],enable=node("button","",plugin.lifecycle==="error"?"Retry":"Enable");
        enable.onclick=()=>missing.length?showDependencyAlert(plugin,missing):perform({operation:"enablePlugin",pluginID:plugin.id});controls.append(enable);
      }else item.append(node("p","detail",plugin.enableBlocker||"Enable is unavailable until this source is reviewed in Attended Setup on the Mac."));
    }
    const update=node("button","quiet",plugin.lifecycle==="installed"?"Review & add":"Update");
    update.onclick=()=>{const input=el("plugin-repository");input.focus();showNotice(`Enter the exact GitHub revision for ${plugin.name}, then stage its review.`)};controls.append(update);
    if(plugin.lifecycle!=="installed"){
      const remove=node("button","danger","Remove");
      remove.onclick=()=>perform({operation:"requestPluginRemoval",pluginID:plugin.id});controls.append(remove);
    }
    item.append(controls);box.append(item);
    if(plugin.configSchema&&["active","needs-setup","missing-dependency"].includes(plugin.lifecycle))box.append(renderKind(plugin,{id:"configuration",title:`${plugin.name} configuration`,kind:"form",source:"config"}));
  }
  return box;
}
function pluginInstallForm(){
  const form=node("form","form"),repository=node("input"),commit=node("input"),path=node("input"),repositoryField=node("div","field"),commitField=node("div","field"),pathField=node("div","field"),submit=node("button","","Stage review");
  repository.id="plugin-repository";repository.type="url";repository.required=true;repository.autocomplete="off";repository.maxLength=256;repository.placeholder="https://github.com/owner/repository";
  commit.id="plugin-commit";commit.required=true;commit.autocomplete="off";commit.maxLength=40;commit.placeholder="40-character commit SHA";
  path.id="plugin-path";path.required=true;path.autocomplete="off";path.maxLength=512;path.value=".";path.placeholder="Plugin subfolder (.)";
  for(const [field,label,input] of [[repositoryField,"GitHub repository",repository],[commitField,"Exact commit",commit],[pathField,"Plugin subfolder",path]]){const text=node("label","",label);text.htmlFor=input.id;field.append(text,input);form.append(field)}
  submit.type="submit";form.append(node("p","detail","Only a public GitHub HTTPS repository, full immutable SHA, and safe subfolder are accepted. Review disclosures before installing trusted code."),submit);
  form.addEventListener("input",()=>{form.dataset.dirty="true"});
  form.onsubmit=event=>{event.preventDefault();const sha=commit.value.trim();if(!/^[0-9a-f]{40}$/i.test(sha)){showNotice("Enter a complete 40-character hexadecimal commit SHA.");commit.focus();return}perform({operation:"requestPluginInstall",repository:repository.value.trim(),commit:sha,pluginPath:path.value.trim()})};
  return form;
}
function showDependencyAlert(plugin,packages){
  el("dependency-title").textContent=`Install ${packages.length===1?"a dependency":"dependencies"} on the Mac`;
  el("dependency-detail").textContent=`${plugin.name} needs ${packages.join(", ")}. Open Attended Setup on the Mac, review the Homebrew install, then return here to enable it.`;
  el("dependency-alert").showModal();
}
function homeLayout(){
  const layout=state.snapshot.layout||{},hidden=new Set(layout.hiddenWidgets||[]),widgets=(layout.widgets||[]).filter(key=>!hidden.has(key));
  const wideWidgets=activeWidgets().filter(({item})=>item.size==="2x1").map(({key})=>key).filter(key=>widgets.includes(key));
  return {widgets,hiddenWidgets:[],wideWidgets,sidebar:layout.sidebar||[]};
}
function saveHomeLayout(changed){
  const layout=homeLayout();
  perform({operation:"saveLayout",widgets:changed.widgets??layout.widgets,hiddenWidgets:changed.hiddenWidgets??layout.hiddenWidgets,wideWidgets:changed.wideWidgets??layout.wideWidgets,sidebar:changed.sidebar??layout.sidebar});
}
function activeWidgets(){
  return (state.snapshot.plugins||[]).filter(plugin=>plugin.lifecycle==="active").flatMap(plugin=>(plugin.widgets||[]).map(item=>({key:`${plugin.id}/${item.id}`,plugin,item})));
}
function renderHome(){
  const dashboard=node("div","home-dashboard"),toolbar=node("div","home-toolbar"),copy=node("div"),edit=node("button","quiet",state.homeEditing?"Done":"Edit layout"),layout=homeLayout(),grid=node("div",`grid home-grid${state.homeEditing?" editing":""}`);
  const hint=node("p","detail",state.homeEditing?"Drag tiles to reorder. Keyboard: Space to pick up, then an arrow key to move.":"Compact widgets stay out of the way until you need them.");
  hint.id="home-edit-instructions";edit.setAttribute("aria-pressed",String(state.homeEditing));copy.append(hint);edit.onclick=()=>{state.homeEditing=!state.homeEditing;render()};toolbar.append(copy,edit);dashboard.append(toolbar);
  for(const key of layout.widgets){
    const found=contribution(key,"widgets");
    if(found&&found.item)grid.append(renderHomeWidget(key,found));
  }
  if(state.homeEditing)grid.append(renderAddWidgetTile());
  if(!grid.children.length)grid.append(empty("No widgets","Choose Edit layout to add a widget."));
  dashboard.append(grid);if(state.homeEditing)dashboard.append(renderSidebarSettings());return dashboard;
}
function renderHomeWidget(key,found){
  const title=found.item.title||found.item.label||found.item.id,widget=renderKind(found.plugin,found.item,true);
  widget.classList.add("home-widget");widget.dataset.widgetKey=key;
  if(!state.homeEditing)return widget;
  widget.draggable=true;widget.tabIndex=0;widget.setAttribute("aria-label",`${title}. Drag to reorder. Press Space to pick up.`);widget.setAttribute("aria-describedby","home-edit-instructions");
  widget.addEventListener("dragstart",event=>{
    if(event.target.closest("button")){event.preventDefault();return}
    state.draggedWidget=key;event.dataTransfer.effectAllowed="move";event.dataTransfer.setData("text/plain",key);widget.classList.add("dragging");
  });
  widget.addEventListener("dragend",()=>{state.draggedWidget=null;widget.classList.remove("dragging","drop-target")});
  widget.addEventListener("dragover",event=>{if(state.draggedWidget&&state.draggedWidget!==key){event.preventDefault();event.dataTransfer.dropEffect="move";widget.classList.add("drop-target")}});
  widget.addEventListener("dragleave",event=>{if(!widget.contains(event.relatedTarget))widget.classList.remove("drop-target")});
  widget.addEventListener("drop",event=>{event.preventDefault();widget.classList.remove("drop-target");const dragged=state.draggedWidget||event.dataTransfer.getData("text/plain");if(dragged&&dragged!==key)dropHomeWidget(dragged,key)});
  widget.addEventListener("pointerdown",event=>{if(event.pointerType==="mouse"||event.target.closest("button"))return;state.draggedWidget=key;widget.setPointerCapture(event.pointerId);widget.classList.add("dragging")});
  widget.addEventListener("pointermove",event=>{if(state.draggedWidget!==key)return;const target=document.elementFromPoint(event.clientX,event.clientY)?.closest(".home-widget");document.querySelectorAll(".home-widget.drop-target").forEach(item=>item.classList.remove("drop-target"));if(target&&target!==widget)target.classList.add("drop-target")});
  widget.addEventListener("pointerup",event=>{if(state.draggedWidget!==key)return;const target=document.elementFromPoint(event.clientX,event.clientY)?.closest(".home-widget");state.draggedWidget=null;widget.classList.remove("dragging");document.querySelectorAll(".home-widget.drop-target").forEach(item=>item.classList.remove("drop-target"));if(target&&target!==widget)dropHomeWidget(key,target.dataset.widgetKey)});
  widget.addEventListener("pointercancel",()=>{state.draggedWidget=null;widget.classList.remove("dragging")});
  widget.addEventListener("keydown",event=>{if(event.key==="Escape"&&state.draggedWidget===key){state.draggedWidget=null;widget.classList.remove("dragging");return}if(event.key===" "||event.key==="Enter"){event.preventDefault();if(state.draggedWidget===key){state.draggedWidget=null;widget.classList.remove("dragging")}else{state.draggedWidget=key;widget.classList.add("dragging")}return}if(state.draggedWidget!==key||!["ArrowUp","ArrowLeft","ArrowDown","ArrowRight"].includes(event.key))return;event.preventDefault();const layout=homeLayout(),index=layout.widgets.indexOf(key),direction=["ArrowUp","ArrowLeft"].includes(event.key)?-1:1,target=layout.widgets[index+direction];if(target)dropHomeWidget(key,target)});
  const remove=node("button","widget-control","×");remove.type="button";remove.setAttribute("aria-label",`Remove ${title} from Home`);remove.title=`Remove ${title} from Home`;remove.onclick=()=>saveHomeLayout({widgets:homeLayout().widgets.filter(item=>item!==key)});widget.append(remove);return widget;
}
function dropHomeWidget(dragged,target){
  state.draggedWidget=null;const layout=homeLayout(),widgets=layout.widgets.filter(key=>key!==dragged),index=widgets.indexOf(target);if(index<0)return;
  widgets.splice(index,0,dragged);saveHomeLayout({widgets});
}
function renderAddWidgetTile(){
  const tile=node("button","widget-add"),plus=node("span","widget-add-mark","+");tile.type="button";tile.setAttribute("aria-label","Add a widget");tile.append(plus,node("span","widget-add-copy","Add widget"));tile.onclick=openWidgetPicker;return tile;
}
function openWidgetPicker(){
  const picker=el("widget-picker"),list=el("widget-picker-list"),selected=new Set(homeLayout().widgets);list.replaceChildren();
  for(const option of activeWidgets()){
    const choice=node("button","widget-choice"),name=node("span","widget-choice-name",`${option.plugin.name}: ${option.item.title||option.item.label||option.item.id}`),detail=node("span","widget-choice-detail",option.item.size==="2x1"?"Wide by default":"Compact");
    const alreadySelected=selected.has(option.key);choice.type="button";choice.disabled=alreadySelected;choice.dataset.mutation="true";choice.dataset.unavailable=String(alreadySelected);choice.setAttribute("aria-label",alreadySelected?`${name.textContent}, already on Home`:`Add ${name.textContent}`);choice.append(name,detail);choice.onclick=()=>addHomeWidget(option);list.append(choice);
  }
  if(!list.children.length)list.append(node("p","muted","No active plugin widgets are available."));
  if(!picker.open)picker.showModal();
}
function addHomeWidget(option){
  const layout=homeLayout(),widgets=[...layout.widgets,option.key];
  el("widget-picker").close();saveHomeLayout({widgets});
}
function renderSidebarSettings(){
  const layout=homeLayout(),section=node("details","sidebar-layout"),summary=node("summary","","Sidebar pages"),rows=node("div","rows");section.append(summary,node("p","detail","Show, hide, and order plugin pages in the sidebar."));
  for(const plugin of state.snapshot.plugins||[])for(const item of plugin.sidebar||[]){
    const key=`${plugin.id}/${item.id}`,shown=layout.sidebar.includes(key),row=node("div","row"),main=node("div","row-main"),toggle=node("button","",shown?"Hide":"Show"),up=node("button","","Move up"),down=node("button","","Move down"),index=layout.sidebar.indexOf(key);
    main.append(node("div","row-title",`${plugin.name}: ${item.label}`),node("div","detail",shown?"Shown":"Hidden"));toggle.onclick=()=>saveHomeLayout({sidebar:shown?layout.sidebar.filter(value=>value!==key):[...layout.sidebar,key]});up.dataset.unavailable=String(index<=0);down.dataset.unavailable=String(index<0||index>=layout.sidebar.length-1);up.onclick=()=>moveSidebarPage(key,-1);down.onclick=()=>moveSidebarPage(key,1);row.append(main,toggle,up,down);rows.append(row);
  }
  section.append(rows.children.length?rows:node("p","muted","No plugin sidebar pages are available."));return section;
}
function moveSidebarPage(key,direction){
  const layout=homeLayout(),index=layout.sidebar.indexOf(key),target=index+direction;if(target<0||target>=layout.sidebar.length)return;
  const sidebar=[...layout.sidebar];[sidebar[index],sidebar[target]]=[sidebar[target],sidebar[index]];saveHomeLayout({sidebar});
}
function nativeBusy(contributionID){
  return !!nativeJob(contributionID);
}
function nativeJob(contributionID,resource){
  return (state.snapshot.jobs||[]).find(job=>job.pluginID==="@native"&&job.contributionID===contributionID&&(!resource||job.resource===`@native/${resource}`));
}
function nativeRefresh(){
  const refreshing=!!state.snapshot.nativeToolsRefreshing,button=node("button","quiet",refreshing?"Refreshing…":"Refresh");
  button.dataset.unavailable=String(refreshing);
  button.onclick=()=>perform({operation:"refreshNativeTools"});
  return button;
}
function renderTools(){
  const tools=state.snapshot.nativeTools,box=node("div","stack");
  if(!tools){const refreshing=!!state.snapshot.nativeToolsRefreshing,unavailable=empty(refreshing?"Collecting host snapshot":"No host snapshot",refreshing?"This can take a moment.":"Refresh to inspect prompt-free host capabilities.");unavailable.append(nativeRefresh());return unavailable}
  const toolbar=node("div","toolbar");toolbar.append(node("span","age",`Sampled ${relativeAge(tools.sampledAt)}`),nativeRefresh());box.append(toolbar);

  const power=card("Power"),metrics=node("div","metric-grid");
  for(const [label,value] of [["Low power mode",tools.power.lowPowerModeEnabled?"On":"Off"],["FileVault",tools.power.fileVault]]){
    const metric=node("div","metric");metric.append(node("div","metric-label",label),node("div","metric-value",value));metrics.append(metric);
  }
  power.append(metrics,node("p","detail",tools.power.restartSupport));box.append(power);

  const apps=card("Applications");
  if(!tools.processes.length)apps.append(node("p","muted","No regular applications found."));
  for(const process of tools.processes){
    const row=node("div","row"),main=node("div","row-main"),job=nativeJob(`process-terminate-${process.pid}`,`process/${process.pid}`);
    main.append(node("div","row-title",process.displayName),node("div","detail",`PID ${process.pid}${process.bundleIdentifier?` · ${process.bundleIdentifier}`:""}`));
    const quit=node("button","danger",job?"Cancel":"Quit");quit.dataset.unavailable=String(!job&&!process.canTerminate);quit.onclick=()=>job?perform({operation:"cancelJob",jobID:job.id}):perform({operation:"requestProcessTermination",pid:process.pid});
    row.append(statusDot(process.canTerminate?"succeeded":""),main,quit);apps.append(row);
  }
  box.append(apps);

  const agents=card("User launch agents");
  if(tools.launchAgentWarning)agents.append(node("p","detail",tools.launchAgentWarning));
  if(!tools.launchAgents.length)agents.append(node("p","muted","No owned user agents found."));
  for(const agent of tools.launchAgents){
    const row=node("div","row"),main=node("div","row-main"),status=agent.isLoaded===true?"loaded":agent.isLoaded===false?"not loaded":"unknown";
    const job=nativeJob("launch-agent-kickstart",`launchd/${agent.label}`),restart=node("button",job?"danger":"",job?"Cancel":"Restart");
    restart.dataset.unavailable=String(!job&&!!agent.issue);restart.onclick=()=>job?perform({operation:"cancelJob",jobID:job.id}):perform({operation:"requestLaunchAgentRestart",launchAgentLabel:agent.label});
    main.append(node("div","row-title",agent.label),node("span","status-label",status),node("div","detail",agent.issue||agent.plistPath));row.append(statusDot(agent.isLoaded===true?"succeeded":agent.issue?"warning":""),main,restart);agents.append(row);
  }
  agents.append(node("p","detail","Restart is a confirmation-bound, prompt-free action. Invalid, changed, duplicate, or unowned plists cannot be restarted."));box.append(agents);

  const peers=card("Named SSH peers");
  if(!tools.sshPeers.length)peers.append(node("p","muted","No peers configured."));
  for(const peer of tools.sshPeers){
    const row=node("div","row"),main=node("div","row-main");main.append(node("div","row-title",peer.name));
    const job=nativeJob("ssh-probe",`ssh/${peer.name}`),check=node("button",job?"danger":"",job?"Cancel":"Check");check.onclick=()=>job?perform({operation:"cancelJob",jobID:job.id}):perform({operation:"probeSSH",peerName:peer.name});row.append(main,check);peers.append(row);
  }
  peers.append(node("p","detail","Add or remove peers in Attended Setup."));box.append(peers);

  const notifications=card("Notification outbox"),authorization=tools.notifications.authorization;
  notifications.append(node("span","status-label",authorization));
  if(authorization==="authorized"){
    const form=node("form","form"),title=node("input"),body=node("input"),titleField=node("div","field"),bodyField=node("div","field");
    const titleLabel=node("label","","Title"),bodyLabel=node("label","","Message");titleLabel.htmlFor="notification-title";bodyLabel.htmlFor="notification-body";
    title.id=titleLabel.htmlFor;title.name="title";title.maxLength=160;title.value="KiwiOS";
    body.id=bodyLabel.htmlFor;body.name="body";body.maxLength=4096;body.value="This Mac is reachable.";
    titleField.append(titleLabel,title);bodyField.append(bodyLabel,body);form.append(titleField,bodyField);
    form.addEventListener("input",()=>{form.dataset.dirty="true"});
    const job=nativeJob("notification-delivery","notifications"),send=node("button","","Send");send.type="submit";send.dataset.unavailable=String(!!job);form.append(send);
    if(job){const cancel=node("button","danger","Cancel");cancel.type="button";cancel.onclick=()=>perform({operation:"cancelJob",jobID:job.id});form.append(cancel)}
    form.onsubmit=event=>{event.preventDefault();if(!title.value.trim()){showNotice("Enter a notification title.");return}perform({operation:"deliverNotification",title:title.value,body:body.value})};
    notifications.append(form);
  }else notifications.append(node("p","detail","Grant notification access in Attended Setup."));
  box.append(notifications);
  return box;
}
function renderBrew(){
  const tools=state.snapshot.nativeTools,box=node("div","stack");
  if(!tools){const unavailable=empty("No Homebrew snapshot","Refresh to inspect installed packages.");unavailable.append(nativeRefresh());return unavailable}
  const brew=tools.homebrew;
  if(brew.status==="unavailable"){const unavailable=empty("Homebrew not found","Supported at /opt/homebrew or /usr/local.");unavailable.append(nativeRefresh());return unavailable}
  if(brew.status==="error"){const error=card("Homebrew error");error.append(node("p","detail",brew.path||""),node("p","",brew.message||"Inventory unavailable."),nativeRefresh());return error}
  const packages=brew.packages||[],outdated=packages.filter(item=>item.outdated),formulae=packages.filter(item=>item.kind==="formula");
  const summary=card("Installed inventory"),metrics=node("div","metric-grid");
  for(const [label,value] of [["Formulae",formulae.length],["Casks",packages.length-formulae.length],["Outdated",outdated.length]]){
    const metric=node("div","metric");metric.append(node("div","metric-label",label),node("div","metric-value",value));metrics.append(metric);
  }
  summary.append(node("p","detail",brew.path||""),metrics,node("p","detail","Updates and upgrades stay in Attended Setup."));box.append(summary);
  const inventory=card("Packages"),form=node("form","form"),searchField=node("div","field"),label=node("label","","Filter packages"),input=node("input"),wrap=node("div","table-wrap"),table=node("table"),head=node("thead"),header=node("tr"),body=node("tbody");
  input.id="brew-search";input.type="search";label.htmlFor=input.id;searchField.append(label,input);form.append(searchField);form.addEventListener("input",()=>{form.dataset.dirty="true";draw()});inventory.append(form);
  for(const title of ["Package","Type","Installed","State"]){const heading=node("th","",title);heading.scope="col";header.append(heading)}head.append(header);table.append(head,body);wrap.append(table);wrap.tabIndex=0;wrap.setAttribute("aria-label","Installed Homebrew packages");inventory.append(wrap);box.append(inventory);
  function draw(){body.replaceChildren();const query=input.value.trim().toLowerCase();for(const item of packages.filter(item=>!query||[item.displayName,item.name,item.description,item.tap].filter(Boolean).some(value=>value.toLowerCase().includes(query)))){const row=node("tr");row.append(node("td","",item.displayName),node("td","",item.kind),node("td","",(item.installedVersions||[]).join(", ")||"—"),node("td","",item.outdated?"Outdated":item.pinned?"Pinned":"Current"));body.append(row)}if(!body.children.length){const row=node("tr"),cell=node("td","muted","No matching packages");cell.colSpan=4;row.append(cell);body.append(row)}}
  draw();return box;
}
async function perform(payload){
  if(!state.connected||state.mutating){showNotice("Wait for a live connection and the current request to finish.");return}
  state.mutating=true;updateAvailability();
  const message={reloadPlugins:"Reloading plugins…",saveConfig:"Saving configuration…",saveLayout:"Saving layout…",disablePlugin:"Disabling plugin…"}[payload.operation];
  if(message)showNotice(message);
  try{
    const result=await mutate(payload);
    if(result.confirmationToken&&result.label){
      state.pending={operation:result.confirmationOperation||"confirmAction",confirmationToken:result.confirmationToken};
      el("confirmation-title").textContent=result.label;
      el("confirmation-detail").textContent=result.review?reviewDetail(result.review):"Confirm within 60 seconds. The target and policy are checked again before execution.";
      el("confirm-action").textContent=state.pending.operation==="confirmPluginRemoval"?"Remove plugin":state.pending.operation==="confirmPluginInstall"?"Install plugin":"Run action";
      el("confirmation").returnValue="";el("confirmation").showModal();return;
    }
    await refresh(true);
    if(state.connected)el("notice").classList.add("hidden");
  }catch(error){showNotice(error.message)}
  finally{state.mutating=false;updateAvailability()}
}
function reviewDetail(review){
  const lines=[];
  if(review.repository)lines.push(`Repository: ${review.repository}`,`Commit: ${review.commit}`,`Subfolder: ${review.pluginPath||"."}`);
  if(review.pluginID)lines.push(`Plugin: ${review.name||review.pluginID} (${review.pluginID})`);
  if(review.version)lines.push(`Version: ${review.version} · ${review.license||"license unavailable"}`);
  if(review.manifestDigest)lines.push(`Manifest SHA-256: ${review.manifestDigest}`,`Content SHA-256: ${review.contentDigest}`);
  const dependencies=Object.entries(review.dependencies||{});if(dependencies.length)lines.push(`Dependencies: ${dependencies.map(([id,version])=>`${id} ${version}`).join(", ")}`);
  if((review.permissions||[]).length)lines.push(`Declared access: ${review.permissions.join("; ")}`);
  if((review.brew||[]).length)lines.push(`Homebrew requirements: ${review.brew.join(", ")}`);
  if(review.permissionChanges){const changes=[...(review.permissionChanges.added||[]).map(value=>`Added ${value}`),...(review.permissionChanges.removed||[]).map(value=>`Removed ${value}`)];if(changes.length)lines.push(`Disclosure changes: ${changes.join("; ")}`)}
  if((review.homebrew||[]).length)lines.push(`Homebrew retained: ${review.homebrew.map(item=>item.formula).join(", ")}`);
  if(review.warning)lines.push(review.warning);
  if(review.destruction)lines.push(review.destruction);
  if(review.retention)lines.push(review.retention);
  lines.push("Confirm within 60 seconds. The review and policy are checked again before execution.");return lines.join("\n");
}
async function refresh(force=false){
  const active=state.refreshPromise;
  if(active){await active;if(!force)return}
  const request=refreshOnce(force);state.refreshPromise=request;
  try{await request}finally{if(state.refreshPromise===request)state.refreshPromise=null}
}
async function refreshOnce(force){
  try{
    const response=await api("/api/snapshot"),wire=await response.text(),snapshot=JSON.parse(wire),changed=wire!==state.snapshotWire;
    if(snapshot.api!=="kiwios.remote/1")throw new Error("Unsupported remote API; update KiwiOS on the Mac.");
    state.snapshot=snapshot;state.snapshotWire=wire;state.connected=true;
    el("connection").textContent="Online";el("connection").className="connection online";
    const viewer=snapshot.viewer||{};
    el("viewer").replaceChildren(node("strong","",viewer.displayName||viewer.loginName||"Tailnet user"),node("span","",viewer.loginName||""));
    // Polling must not erase a configuration edit or replace a focused control.
    const editing=state.homeEditing||document.querySelector("#content form[data-dirty=\"true\"]")||document.activeElement.closest("#content form");
    if(force||changed&&!editing)render();
    if(!state.mutating)el("notice").classList.add("hidden");
  }catch(error){
    state.connected=false;
    el("connection").textContent=navigator.onLine?"Unavailable":"Offline";el("connection").className="connection";
    if(!state.snapshot)el("content").replaceChildren(empty("KiwiOS is unavailable","On the Mac, open KiwiOS after login. Connect this device to Tailscale, then retry the displayed HTTPS address. This page will reconnect automatically."));
    showNotice("Live status is unavailable; displayed results may be old. Check that the Mac is logged in, KiwiOS is open, and both devices are connected to Tailscale. Actions are disabled until reconnection.");
  }finally{updateAvailability();el("content").setAttribute("aria-busy","false")}
}
function showNotice(message){el("notice").textContent=message;el("notice").classList.remove("hidden")}
el("back").onclick=()=>{location.hash="home"};
el("confirmation").addEventListener("cancel",()=>{el("confirmation").returnValue="";state.pending=null});
el("confirmation").addEventListener("close",()=>{const pending=state.pending;state.pending=null;if(el("confirmation").returnValue==="default"&&pending)perform(pending)});
el("widget-picker").addEventListener("close",()=>{state.draggedWidget=null});
addEventListener("hashchange",()=>{if(route().type!=="home"){state.homeEditing=false;if(el("widget-picker").open)el("widget-picker").close()}render()});addEventListener("online",()=>refresh());
addEventListener("offline",()=>{state.connected=false;updateAvailability();showNotice("Offline. Displayed results may be old; actions require a live connection.")});
(async()=>{
  await refresh();
  if("serviceWorker" in navigator)navigator.serviceWorker.register("/service-worker.js").catch(()=>{if(state.connected)showNotice("Offline app installation is unavailable; the live UI still works.")});
  setInterval(()=>{if(!state.mutating)refresh()},5000);
})();
