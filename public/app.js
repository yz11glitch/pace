import{
  CATEGORY_META,FLOW_LABELS,PRIMARY_MANUAL_TYPES,amountMinor,captureResultKind,historyQuery,keypadAmount,
  changeTransactionType,manualCategoryChoices,manualPayload,manualStartScreen,money,newSubmission,noteFields,primaryTypeSelected,profilePayload,refundOptionVisible,requestHeaders,sheetReleaseMotion,
  sparseTransactionPatch,timezone,validLocalDate,validManualAmount,
}from"/ui-core.js?v=20260922-1";
import{icon}from"/icons.js?v=20260922-1";

const BUILD="20260922-1";
const app=document.querySelector("#app");
const captureButton=document.querySelector("#capture-button");
const navbar=document.querySelector(".navbar");
const sheet=document.querySelector("#sheet");
const sheetBody=document.querySelector("#sheet-body");
const sheetFooter=document.querySelector("#sheet-footer");
const sheetTitle=document.querySelector("#sheet-title");
const backButton=document.querySelector("#sheet-back");
const closeButton=document.querySelector("#sheet-close");
const scrim=document.querySelector("#scrim");
const toast=document.querySelector("#toast");
const cache={home:null,recent:null,history:new Map()};
const state={
  route:"home",sheet:false,busy:false,recording:null,timer:null,pending:null,
  historyMonth:localMonth(),historyFilter:"all",historyQ:"",historySearchOpen:false,
  setupIntent:false,scrollTop:0,manual:null,pendingManual:null,sheetHistoryDepth:0,historyResetView:null,resultTimer:null,resultViewId:0,sheetOpener:null,
};
const esc=value=>String(value??"").replace(/[&<>'"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;",'"':"&quot;"}[c]));

function localMonth(d=new Date()){return`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,"0")}`}
function localDate(d=new Date()){return`${localMonth(d)}-${String(d.getDate()).padStart(2,"0")}`}
function friendlyDate(date){
  if(date===localDate())return"Today";
  const yesterday=new Date();yesterday.setDate(yesterday.getDate()-1);
  if(date===localDate(yesterday))return"Yesterday";
  const value=new Date(`${date}T12:00`),options={day:"numeric",month:"short"};if(value.getFullYear()!==new Date().getFullYear())options.year="numeric";return value.toLocaleDateString("en-MY",options);
}
function greeting(){const hour=new Date().getHours();return hour<12?"Good morning":hour<18?"Good afternoon":"Good evening"}
function dateTitle(date=localDate()){return new Date(`${date}T12:00`).toLocaleDateString("en-MY",{weekday:"long",day:"numeric",month:"short"})}
function route(){const name=location.hash.replace("#/","");return["home","history","settings"].includes(name)?name:"home"}

async function api(url,options={}){
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),12000);
  try{
    const response=await fetch(url,{cache:"no-store",...options,signal:controller.signal});
    const data=response.status===204?null:await response.json().catch(()=>null);
    if(!response.ok){const error=new Error(data?.detail?.[0]?.msg||data?.detail||data?.error||`HTTP ${response.status}`);error.status=response.status;error.data=data;throw error}
    return data;
  }finally{clearTimeout(timer)}
}

function setTheme(choice=localStorage.getItem("pace-theme")||"system"){
  localStorage.setItem("pace-theme",choice);
  const dark=choice==="dark"||(choice==="system"&&matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme=dark?"dark":"light";
  document.querySelector('meta[name="theme-color"]').content=dark?"#191C1A":"#FBF6EF";
}
function showToast(text,name="check"){
  toast.innerHTML=`${icon(name,{size:17,sw:2.2})}<span>${esc(text)}</span>`;
  toast.classList.add("show");clearTimeout(showToast.timer);
  showToast.timer=setTimeout(()=>toast.classList.remove("show"),2200);
}
function emptyState(name,title,sub,action="",label=""){
  return`<div class="empty"><div class="empty-title">${esc(title)}</div><div class="empty-sub">${esc(sub)}</div>${action?`<button class="text-button press" data-action="${action}">${esc(label)}</button>`:""}</div>`;
}
function errorBox(text,retry){return`<div class="error-bar" role="status">${icon("alert",{size:20})}<span>${esc(text)}</span><button class="text-button press" data-action="${retry}">Retry</button></div>`}
function homeLoading(){return'<div class="home-loading" aria-hidden="true"><div class="skeleton money-skel"></div><div class="skeleton line-skel"></div><div class="skeleton row-skel"></div><div class="skeleton row-skel"></div></div>'}
function historyLoading(){return`<div class="ledger-loading">${Array.from({length:4},()=>'<div class="skeleton skeleton-row" aria-hidden="true"></div>').join("")}</div>`}

function categoryFor(t){
  if(t.type==="contribution"||!t.category)return{icon:"save",ink:"--ink",bg:"--bg-2"};
  return CATEGORY_META[t.category]||CATEGORY_META.Other;
}
function transactionRow(t,showDate=true){
  const label=t.merchant||t.description||t.category||FLOW_LABELS[t.type];
  const meta=categoryFor(t),category=t.category||FLOW_LABELS[t.type];
  const sign=t.type==="expense"?"−":t.type==="contribution"?"↑":"+";
  const context=t.type==="refund"?`Refund · ${category}`:t.type==="contribution"?"Set aside":t.type==="income"?"Earned":category;
  return`<button class="txn press" type="button" data-edit="${esc(t.id)}" aria-label="Edit ${esc(label)}, ${esc(context)}, ${sign} ${esc(money(t.amount_minor))}"><span class="txn-ico">${icon(meta.icon,{size:22})}</span><span class="txn-main"><span class="txn-name">${esc(label)}</span><span class="txn-meta">${esc(context)}${showDate?` · ${friendlyDate(t.local_date)}`:""}</span></span><span class="txn-end"><span class="txn-amt t-num ${t.type}">${sign} ${money(t.amount_minor)}</span><span class="txn-edit-icon">${icon("chevron",{size:16})}</span></span></button>`;
}
function rows(items,showDate=true){return items.map((t,i)=>transactionRow(t,showDate)+(i<items.length-1?'<div class="txn-sep"></div>':"")).join("")}
function sectionHeader(title,action="",label=""){return`<div class="section-header"><div class="t-sec">${esc(title)}</div>${action?`<button class="text-button press" data-action="${action}">${esc(label)}</button>`:""}</div>`}
function screenHeader(asOf=localDate()){return`<header class="page-header home-header"><div class="t-greet">${greeting()}</div><div class="home-date">${dateTitle(asOf)}</div></header>`}
function moneyDisplay(minor,className="money-display"){
  const formatted=money(minor),digits=formatted.replace(/^RM\s*/,"");
  return`<span class="${className} ${digits.length>11?"money-long":""} t-num" aria-label="${esc(formatted)}"><span class="money-currency" aria-hidden="true">RM</span><span class="money-digits" aria-hidden="true">${esc(digits)}</span></span>`;
}

async function renderRoute(){
  const nextRoute=route();if(nextRoute!==state.route)app.scrollTop=0;state.route=nextRoute;
  document.querySelectorAll(".navbtn").forEach(a=>{a.classList.toggle("active",a.dataset.route===state.route);a.toggleAttribute("aria-current",a.dataset.route===state.route)});
  if(state.route==="home")await renderHome();
  if(state.route==="history")await renderHistory();
  if(state.route==="settings")await renderSettings();
}
async function renderHome(){
  app.innerHTML=`<div class="screen-fade">${screenHeader(cache.home?.as_of_date||cache.home?.period?.as_of_date)}${cache.home?homeMarkup(cache.home,cache.recent||[]):homeLoading()}</div>`;bindCommon();
  try{
    const[home,recent]=await Promise.all([api("/api/home",{headers:{"X-Timezone":timezone()}}),api("/api/transactions?limit=5")]);
    cache.home=home;cache.recent=recent;
    if(state.route==="home"){app.innerHTML=`<div class="screen-fade">${screenHeader(home.as_of_date||home.period?.as_of_date)}${homeMarkup(home,recent)}</div>`;bindCommon()}
  }catch(error){
    console.error(error);
    if(state.route==="home"){
      const prior=cache.home?homeMarkup(cache.home,cache.recent||[]):"";
      app.innerHTML=`<div class="screen-fade">${screenHeader(cache.home?.as_of_date||cache.home?.period?.as_of_date)}${errorBox(cache.home?"Couldn't refresh — showing the last update.":"Pace can't reach the server.","retry-home")}${prior}</div>`;bindCommon();
    }
  }
}
function monthRows(items){return`<div class="month-ledger">${items.map(item=>`<div class="set-row"><span class="set-lbl">${item.label}</span><span class="set-val t-num ${item.className||""}">${item.value}</span></div>`).join("")}</div>`}
function homeMarkup(h,recent){
  const a=h.actual,p=h.period,pace=h.pace;
  if(!h.availability.plan){
    return`<section class="hero home-open">${moneyDisplay(a.spending_minor,"hero-money")}<div class="hero-label">spent this month</div><div class="daily-summary"><span class="t-num">${money(pace.spending_per_elapsed_day_minor)}/day</span><span>so far</span></div></section>${monthRows([{label:"Income",value:`+ ${money(a.income_minor)}`,className:"positive"}])}<section class="setup-card"><div class="setup-rule"></div><h2 class="t-h2">See your monthly plan</h2><p class="t-body">Add income, commitments and a savings target to see your pace.</p><button class="text-button setup-action press" data-action="setup">Set up Pace ${icon("chevron",{size:16})}</button></section>${recentMarkup(recent)}`;
  }
  const plan=h.plan,envelope=plan.discretionary_envelope_minor,spent=a.spending_minor,left=envelope-spent;
  const hasPace=envelope>0;
  const fill=envelope>0?Math.max(0,Math.min(100,spent/envelope*100)):0,marker=Math.max(.3,Math.min(99.7,p.days_elapsed/p.days_in_period*100));
  const dayWord=p.days_remaining===1?"day":"days",room=`${money(Math.abs(left))} ${left<0?"over":"left"}`;
  const ruler=hasPace?`<div class="track" role="img" aria-label="Spending pace ruler: actual spending is ${esc(money(spent))} of ${esc(money(envelope))} available; month progress is day ${p.days_elapsed} of ${p.days_in_period}"><div class="track-fill" style="width:${fill}%"></div><div class="spending-marker" style="left:${fill}%" aria-hidden="true"></div><div class="pace-marker" style="left:${marker}%" aria-hidden="true"></div></div><div class="spending-context ${left<0?"over":""}" aria-label="${esc(room)}, ${p.days_remaining} ${dayWord} remaining"><span class="t-num">${esc(room)}</span><span aria-hidden="true">·</span><span>${p.days_remaining} ${dayWord} remaining</span></div>`:`<div class="spending-context"><span>No discretionary amount available</span><span aria-hidden="true">·</span><span>${p.days_remaining} ${dayWord} remaining</span></div>`;
  const daily=hasPace?`<div class="daily-summary" aria-label="${esc(money(pace.spending_per_elapsed_day_minor))} per day so far; target ${esc(money(plan.planned_daily_discretionary_minor))} per day"><span class="t-num">${money(pace.spending_per_elapsed_day_minor)}/day</span><span aria-hidden="true">·</span><span>target <span class="t-num">${money(plan.planned_daily_discretionary_minor)}/day</span></span></div>`:`<div class="daily-summary"><span class="t-num">${money(pace.spending_per_elapsed_day_minor)}/day</span><span>so far</span></div>`;
  return`<section class="hero home-open">${moneyDisplay(spent,"hero-money")}<div class="hero-label">spent this month</div>${ruler}${daily}</section>${monthRows([
    {label:"Income",value:`+ ${money(plan.planning_income_minor)}`,className:"positive"},
    {label:"Savings target",value:money(plan.savings_target_minor)},
    {label:"Set aside",value:`↑ ${money(a.contributions_minor)}`},
    {label:"Left to set aside",value:money(Math.max(0,plan.remaining_to_set_aside_minor))},
  ])}${recentMarkup(recent)}`;
}
function recentMarkup(recent){return`<section class="recent-section">${sectionHeader("Recent","history","See all")}${recent.length?`<div class="txn-card">${rows(recent)}</div>`:emptyState("wallet2","Nothing yet","Use Capture to record your first transaction.","capture","Open Capture")}</section>`}

async function renderHistory(){
  const cached=cache.history.get(`${state.historyMonth}|${state.historyQ}`);
  app.innerHTML=`<div class="screen-fade">${historyShell(cached)}</div>`;bindHistory();await fetchHistory();
}
function historyShell(items,error=""){
  const label=new Date(`${state.historyMonth}-01T12:00`).toLocaleDateString("en-MY",{month:"long",year:"numeric"});
  const searchOpen=state.historySearchOpen||Boolean(state.historyQ);
  return`<header class="page-header history-head"><h1 class="t-h1">History</h1><button class="search-toggle press" id="search-toggle" type="button" aria-label="Search transactions">${icon("search",{size:21})}</button></header><div class="month-stepper"><button class="press" data-month="-1" aria-label="Previous month">${icon("back")}</button><strong>${label}</strong><button class="press" data-month="1" aria-label="Next month" ${state.historyMonth>=localMonth()?"disabled":""}>${icon("chevron")}</button></div><div class="history-tools"><div class="history-search" ${searchOpen?"":"hidden"}><input class="input" id="history-search" type="search" placeholder="Search transactions" aria-label="Search transactions" value="${esc(state.historyQ)}"></div><div class="seg">${[["all","All"],["spent","Spent"],["income","Earned"],["contribution","Set aside"]].map(([key,labelText])=>`<button type="button" data-filter="${key}" class="seg-btn press ${state.historyFilter===key?"active":""}">${labelText}</button>`).join("")}</div></div><div id="history-content" class="history-content">${error?errorBox(error,"retry-history"):items?historyGroups(items):historyLoading()}</div>`;
}
async function fetchHistory(){
  try{const data=await api(historyQuery(state.historyMonth,state.historyQ,100));cache.history.set(`${state.historyMonth}|${state.historyQ}`,data);if(state.route==="history"){const content=document.querySelector("#history-content");if(content){content.innerHTML=historyGroups(data);bindCommon()}}}
  catch(error){console.error(error);const content=document.querySelector("#history-content");if(content){content.innerHTML=errorBox("Couldn't load history.","retry-history");bindCommon()}}
}
function historyGroups(items){
  const filtered=items.filter(t=>state.historyFilter==="all"||(state.historyFilter==="spent"?["expense","refund"].includes(t.type):t.type===state.historyFilter));
  if(!filtered.length)return items.length?emptyState("tag","No matches","Try a different month or clear the filter.","clear-history","Clear"):emptyState("wallet2","Nothing recorded yet","Use Capture to record your first transaction.","capture","Open Capture");
  const groups=Object.groupBy?Object.groupBy(filtered,t=>t.local_date):filtered.reduce((result,t)=>((result[t.local_date]??=[]).push(t),result),{});
  return Object.entries(groups).map(([date,list])=>{
    const total=list.reduce((sum,t)=>sum+(t.type==="expense"?-t.amount_minor:t.type==="refund"?t.amount_minor:0),0);
    return`<section class="day-group"><div class="day-heading"><span>${friendlyDate(date)}</span><span class="day-total"><small>Net spent</small><span class="t-num">${total<0?"− ":total>0?"+ ":""}${money(Math.abs(total))}</span></span></div><div class="day-card">${rows(list,false)}</div></section>`;
  }).join("")+(items.length===100?'<button class="btn-secondary press load-more" data-action="load-more">Load more</button>':"");
}
function bindHistory(){
  bindCommon();
  document.querySelectorAll("[data-month]").forEach(button=>button.onclick=()=>{const date=new Date(`${state.historyMonth}-01T12:00`);date.setMonth(date.getMonth()+Number(button.dataset.month));state.historyMonth=localMonth(date);renderHistory()});
  document.querySelectorAll("[data-filter]").forEach(button=>button.onclick=()=>{state.historyFilter=button.dataset.filter;renderHistory()});
  document.querySelector("#search-toggle").onclick=()=>{state.historySearchOpen=!state.historySearchOpen;renderHistory();if(state.historySearchOpen)requestAnimationFrame(()=>document.querySelector("#history-search")?.focus())};
  const input=document.querySelector("#history-search");let timer;
  if(input)input.oninput=event=>{clearTimeout(timer);timer=setTimeout(()=>{state.historyQ=event.target.value;renderHistory()},300)};
}

async function renderSettings(){
  app.innerHTML=`<div class="screen-fade"><header class="page-header"><div class="settings-brand"><img class="settings-mark" src="/pace-mark.svg" alt=""><div><div class="t-greet">${state.setupIntent?"Four numbers. Change them any time.":"Pace · "+new Date().toLocaleDateString("en-MY",{month:"long",year:"numeric"})+" · RM"}</div><h1 class="t-h1">${state.setupIntent?"Set up Pace":"You"}</h1></div></div></header>${historyLoading()}</div>`;
  try{const data=await api("/api/profile");settingsForm(data.profile);bindSettings()}
  catch(error){app.innerHTML=`<header class="page-header"><h1 class="t-h1">${state.setupIntent?"Set up Pace":"You"}</h1></header>${errorBox("Couldn't load your settings.","retry-settings")}`;bindCommon()}
}
function budgetRow(id,label,minor){return`<div class="budget-row"><label class="set-lbl" for="${id}">${label}</label><span class="budget-pill"><span class="budget-currency">RM</span><input class="budget-input t-num" id="${id}" inputmode="decimal" type="number" min="0" step="0.01" required value="${minor==null?"":(minor/100).toFixed(2)}"></span></div>`}
function appearanceControl(){
  const appearance=localStorage.getItem("pace-theme")||"system";
  return`<div class="seg-sm" id="appearance-control">${[["light","Light"],["dark","Dark"],["system","Auto"]].map(([value,label])=>`<button type="button" data-theme-choice="${value}" class="seg-sm-btn press ${appearance===value?"active":""}">${label}</button>`).join("")}</div>`;
}
function settingsForm(profile){
  const p=profile||{},setup=state.setupIntent&&!profile;
  app.innerHTML=`<div class="settings-screen screen-fade"><header class="page-header"><div class="settings-brand"><img class="settings-mark" src="/pace-mark.svg" alt=""><div><div class="t-greet">${setup?"Set your monthly plan. You can change it any time.":"Pace · "+new Date().toLocaleDateString("en-MY",{month:"long",year:"numeric"})+" · RM"}</div><h1 class="t-h1">${setup?"Set up Pace":"You"}</h1></div></div></header><form id="profile-form" class="settings-screen"><div class="t-sec">Your money</div><div class="set-group">${budgetRow("income","Monthly income",p.income_amount_minor)}<div class="set-hint">Regular monthly salary. Earned entries add extra income.</div>${budgetRow("commitments","Fixed commitments",p.fixed_commitments_minor)}<div class="set-row"><label class="set-lbl" for="savings-mode">Savings mode</label><select class="mode-select" id="savings-mode"><option value="fixed" ${p.savings_mode!=="percentage"?"selected":""}>Fixed amount</option><option value="percentage" ${p.savings_mode==="percentage"?"selected":""}>Percentage of income</option></select></div><div id="fixed-savings-row">${budgetRow("savings","Savings target",p.savings_target_minor)}</div><div id="percentage-savings-row" class="budget-row"><label class="set-lbl" for="savings-percentage">Savings percentage</label><span class="budget-pill"><input class="budget-input t-num" id="savings-percentage" inputmode="decimal" type="number" min="0" max="100" step="0.01" value="${((p.savings_percentage_basis_points||0)/100).toFixed(2)}"><span class="budget-currency">%</span></span></div><div class="set-row"><label class="set-lbl" for="next-date">Next payday</label><input class="date-input" id="next-date" type="date" required value="${p.next_income_date||localDate()}"></div></div><div id="derived" class="derived"></div><div id="profile-error" class="field-error" role="status"></div><div class="profile-actions"><button id="profile-save" class="btn-primary press" type="submit">${setup?"Start using Pace":"Save changes"}</button></div></form>${setup?"":`<section class="app-settings"><div class="t-sec">App</div><div class="set-group"><div class="set-row"><span class="set-lbl">Appearance</span>${appearanceControl()}</div><div class="set-row"><span class="set-lbl">Time zone</span><span class="set-val">${esc(timezone())}</span></div></div><div class="settings-foot"><span>Stored locally by Pace</span><span>Version 0.1 · ${BUILD}</span></div></section>`}</div>`;
}
function bindSettings(){
  bindCommon();const form=document.querySelector("#profile-form");if(!form)return;
  const inputs=["income","commitments","savings"].map(id=>document.querySelector(`#${id}`));
  const save=document.querySelector("#profile-save"),error=document.querySelector("#profile-error"),derived=document.querySelector("#derived"),mode=document.querySelector("#savings-mode"),percentage=document.querySelector("#savings-percentage");
  const update=()=>{const income=amountMinor(inputs[0].value),fixed=amountMinor(inputs[1].value),basisPoints=amountMinor(percentage.value),percentageMode=mode.value==="percentage",savings=percentageMode?Math.floor((income*basisPoints+5000)/10000):amountMinor(inputs[2].value),left=income-fixed-savings,days=new Date(new Date().getFullYear(),new Date().getMonth()+1,0).getDate(),bad=!percentageMode&&fixed+savings>income,invalidPercentage=percentageMode&&(!percentage.value||!percentage.validity.valid||basisPoints>10000);document.querySelector("#fixed-savings-row").hidden=percentageMode;document.querySelector("#percentage-savings-row").hidden=!percentageMode;inputs[2].disabled=percentageMode;percentage.disabled=!percentageMode;inputs[2].required=!percentageMode;percentage.required=percentageMode;error.innerHTML=bad?`${icon("alert",{size:15})} Commitments and savings add up to more than your salary.`:invalidPercentage?`${icon("alert",{size:15})} Enter a percentage from 0 to 100.`:"";save.disabled=bad||invalidPercentage||!form.checkValidity();derived.innerHTML=`Based on salary, leaves <strong class="t-num">${money(Math.max(0,left))}</strong> to spend — about <strong class="t-num">${money(Math.max(0,Math.trunc(left/days)))}</strong> a day.`};
  [...inputs,percentage].forEach(input=>input.oninput=update);mode.onchange=update;update();
  form.onsubmit=async event=>{event.preventDefault();save.disabled=true;try{await api("/api/profile",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(profilePayload({income:inputs[0].value,nextDate:document.querySelector("#next-date").value,commitments:inputs[1].value,savings:inputs[2].value,savingsMode:mode.value,savingsPercentage:percentage.value}))});cache.home=null;showToast("Settings saved");if(state.setupIntent){state.setupIntent=false;location.hash="#/home"}else renderSettings()}catch(err){error.textContent=err.message;save.disabled=false}};
  bindAppearance();
}
function bindAppearance(){document.querySelectorAll("[data-theme-choice]").forEach(button=>button.onclick=()=>{setTheme(button.dataset.themeChoice);const host=document.querySelector("#appearance-control");if(host){host.outerHTML=appearanceControl();bindAppearance()}})}

function bindCommon(){
  document.querySelectorAll("[data-edit]").forEach(button=>button.onclick=()=>{const all=[...(cache.recent||[]),...Array.from(cache.history.values()).flat()],transaction=all.find(item=>String(item.id)===button.dataset.edit);if(transaction)openManual(transaction)});
  document.querySelectorAll("[data-action]").forEach(button=>button.onclick=()=>handleAction(button.dataset.action,button));
}
function handleAction(action,button){
  if(action==="setup"){state.setupIntent=true;location.hash="#/settings"}
  if(action==="history")location.hash="#/history";
  if(action==="capture")captureInput();
  if(action==="retry-home")renderHome();
  if(action==="retry-history")fetchHistory();
  if(action==="retry-settings")renderSettings();
  if(action==="clear-history"){state.historyQ="";state.historyFilter="all";state.historySearchOpen=false;renderHistory()}
  if(action==="load-more"){button.disabled=true;api(historyQuery(state.historyMonth,state.historyQ,200)).then(data=>{cache.history.set(`${state.historyMonth}|${state.historyQ}`,data);renderHistory()})}
}

function lockScroll(){state.scrollTop=app.scrollTop;app.classList.add("scroll-locked")}
function unlockScroll(){app.classList.remove("scroll-locked");app.scrollTop=state.scrollTop||0}
let sheetMotionId=0,sheetSettleId=0,sheetOpenFrame=0,viewportFrame=0,transactionTransitionId=0;
const reducedMotion=()=>matchMedia("(prefers-reduced-motion: reduce)").matches;
function syncSheetToKeyboard(){
  if(!window.visualViewport||!state.sheet)return;
  const vv=window.visualViewport,overlap=Math.max(0,window.innerHeight-vv.height-vv.offsetTop);
  if(sheet.classList.contains("show")){sheet.classList.add("viewport-sync");cancelAnimationFrame(viewportFrame)}
  document.documentElement.style.setProperty("--kb",`${overlap}px`);
  if(sheet.classList.contains("show"))viewportFrame=requestAnimationFrame(()=>{viewportFrame=requestAnimationFrame(()=>sheet.classList.remove("viewport-sync"))});
}
function setSheetLayout(kind="default"){
  const transaction=kind==="transaction";sheet.classList.toggle("transaction-sheet",transaction);sheetFooter.hidden=!transaction;
  if(!transaction)sheetFooter.replaceChildren();
}
function openSheet(title="Add transaction",push=true){
  if(!state.sheet){
    state.sheetOpener=document.activeElement;state.sheet=true;sheetMotionId++;sheetSettleId++;cancelAnimationFrame(sheetOpenFrame);lockScroll();app.inert=true;navbar.inert=true;captureButton.inert=true;document.documentElement.classList.add("sheet-open");sheet.setAttribute("aria-hidden","false");scrim.setAttribute("aria-hidden","false");
    sheet.classList.remove("closing","release-motion","settling","dragging");sheet.style.removeProperty("--sheet-duration");sheet.style.setProperty("--drag-y","0px");scrim.classList.remove("closing");scrim.style.removeProperty("--scrim-duration");
    if(push){history.pushState({sheet:true,view:"root"},"");state.sheetHistoryDepth=1}
    const reveal=()=>{if(!state.sheet)return;sheet.classList.add("show");scrim.classList.add("show");closeButton.focus()};
    if(reducedMotion())reveal();else sheetOpenFrame=requestAnimationFrame(()=>{sheetOpenFrame=requestAnimationFrame(reveal)});
  }
  sheetTitle.textContent=title;syncSheetToKeyboard();
}
function closeSheet(fromPop=false,release=null){
  if(state.busy)return;if(state.recording)stopRecording();
  const motionId=++sheetMotionId,duration=reducedMotion()?0:(release?.duration||340),depth=state.sheetHistoryDepth;sheetSettleId++;state.sheet=false;state.manual=null;state.sheetHistoryDepth=0;state.historyResetView=null;clearTimeout(state.resultTimer);state.resultViewId++;cancelAnimationFrame(sheetOpenFrame);cancelAnimationFrame(viewportFrame);
  sheet.style.setProperty("--sheet-duration",`${duration}ms`);sheet.classList.remove("dragging","settling","viewport-sync","show");sheet.classList.add("closing");sheet.classList.toggle("release-motion",Boolean(release));scrim.style.setProperty("--scrim-duration",`${Math.max(0,duration-40)}ms`);scrim.classList.add("closing");scrim.classList.remove("show");
  const finish=()=>{
    if(sheetMotionId!==motionId||state.sheet)return;
    sheet.classList.remove("closing","release-motion","settling","transaction-sheet");sheet.style.removeProperty("--sheet-duration");sheet.style.setProperty("--drag-y","0px");scrim.classList.remove("closing");scrim.style.removeProperty("--scrim-duration");sheetFooter.hidden=true;sheetFooter.replaceChildren();sheetBody.replaceChildren();backButton.hidden=true;sheet.setAttribute("aria-hidden","true");scrim.setAttribute("aria-hidden","true");app.inert=false;navbar.inert=false;captureButton.inert=false;document.documentElement.classList.remove("sheet-open");document.documentElement.style.setProperty("--kb","0px");unlockScroll();const opener=state.sheetOpener;state.sheetOpener=null;(opener?.isConnected?opener:captureButton).focus();
  };
  const ended=event=>{if(event.target===sheet&&event.propertyName==="transform"){sheet.removeEventListener("transitionend",ended);finish()}};
  if(duration){sheet.addEventListener("transitionend",ended);setTimeout(()=>{sheet.removeEventListener("transitionend",ended);finish()},duration+80)}else queueMicrotask(finish);
  if(!fromPop&&depth>0)history.go(-depth);
}
function settleSheet(duration){
  const settleId=++sheetSettleId,settleDuration=reducedMotion()?0:duration;sheet.style.setProperty("--sheet-duration",`${settleDuration}ms`);sheet.classList.remove("dragging");sheet.classList.add("settling");sheet.style.setProperty("--drag-y","0px");
  if(!settleDuration){sheet.classList.remove("settling");sheet.style.removeProperty("--sheet-duration");return}
  let done=false;const finish=()=>{if(done)return;done=true;sheet.removeEventListener("transitionend",settled);if(settleId!==sheetSettleId)return;sheet.classList.remove("settling");sheet.style.removeProperty("--sheet-duration")};const settled=event=>{if(event.target===sheet&&event.propertyName==="transform")finish()};sheet.addEventListener("transitionend",settled);setTimeout(finish,settleDuration+80);
}

function captureInput(){
  if(!state.sheet&&state.pendingManual){openSheet("Check save");state.manual=state.pendingManual;state.pendingManual=null;showManualScreen(state.manual.screen,false);return}
  openSheet("Record something");setSheetLayout();if(state.manual)state.manual.visible=false;sheetBody.inert=false;backButton.hidden=true;backButton.disabled=false;closeButton.disabled=false;
  sheetBody.innerHTML=`<div class="capture-input"><div class="mic-wrap"><span class="mic-level"></span><button id="mic" class="mic press" type="button" aria-label="Start recording">${icon("mic",{size:36})}</button></div><h3 class="capture-title t-h2">Hold to speak</h3><p id="capture-hint" class="capture-hint t-body">or tap to start recording</p><div class="capture-alternatives"><div class="typed-row"><input id="capture-text" class="input" type="text" autocomplete="off" placeholder="Spent RM18 on chicken rice." aria-label="Type a transaction"><button id="send-text" class="send-button press" type="button" aria-label="Send">${icon("chevron",{size:20,sw:2})}</button></div><button id="manual" class="capture-manual press" type="button">Enter manually <span>${icon("chevron",{size:16})}</span></button></div></div>`;
  const mic=document.querySelector("#mic");let holdTimer,holding=false,suppressClick=false;
  mic.onpointerdown=event=>{const pointerId=event.pointerId;holdTimer=setTimeout(async()=>{holding=true;state.holding=true;suppressClick=true;await startRecording();mic.setPointerCapture?.(pointerId)},300)};
  mic.onpointerup=()=>{clearTimeout(holdTimer);if(holding){holding=false;state.holding=false;stopRecording();setTimeout(()=>suppressClick=false,0)}};
  mic.onpointercancel=()=>{clearTimeout(holdTimer);if(holding){holding=false;state.holding=false;stopRecording()}};
  mic.onclick=()=>{if(suppressClick)return;state.holding=false;state.recording?stopRecording():startRecording()};
  document.querySelector("#send-text").onclick=submitText;document.querySelector("#capture-text").onkeydown=event=>{if(event.key==="Enter")submitText()};document.querySelector("#manual").onclick=()=>{if(state.pendingManual){state.manual=state.pendingManual;state.pendingManual=null;pushManualHistory(state.manual.screen);showManualScreen(state.manual.screen,false);return}state.manual?showManualScreen(state.manual.screen,true):openManual()};
}
async function startRecording(){
  if(protectExistingManual(()=>{captureInput();startRecording()}))return;
  if(!window.isSecureContext||!navigator.mediaDevices?.getUserMedia||!("AudioWorkletNode"in window))return captureFailure("Microphone access needs a secure HTTPS connection and a supported browser.");
  try{
    const context=new(window.AudioContext||window.webkitAudioContext)();await context.resume();
    const stream=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:false,noiseSuppression:false,autoGainControl:false},video:false});
    await context.audioWorklet.addModule("/pcm-capture-worklet.js");
    const source=context.createMediaStreamSource(stream),worklet=new AudioWorkletNode(context,"pcm-capture",{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1]}),chunks=[];
    worklet.port.onmessage=event=>{if(event.data?.type==="samples"){const samples=event.data.samples;chunks.push(samples);let sum=0;for(const value of samples)sum+=value*value;const level=Math.min(1,Math.sqrt(sum/samples.length)*5);document.querySelector(".mic-wrap")?.style.setProperty("--level",String(level))}};
    source.connect(worklet);worklet.connect(context.destination);
    state.recording={context,stream,source,worklet,chunks,startedAt:performance.now(),capturedAt:new Date().toISOString()};
    const input=document.querySelector(".capture-input"),mic=document.querySelector("#mic"),title=document.querySelector(".capture-title"),hint=document.querySelector("#capture-hint");
    input.classList.add("recording");mic.classList.add("recording");mic.setAttribute("aria-label","Stop recording");title.textContent="Listening…";
    hint.className="capture-timer t-num";hint.textContent="00:00";
    state.timer=setInterval(()=>{if(!state.recording)return;const seconds=(performance.now()-state.recording.startedAt)/1000;hint.textContent=`${Math.floor(seconds/60)}:${String(Math.floor(seconds%60)).padStart(2,"0")} · ${state.holding?"Release to send":"Tap to stop"}`},250);
  }catch(error){captureFailure(error.name==="NotAllowedError"?"Microphone permission was denied. Enable it for Pace, then try again.":"The microphone couldn't start. Try again.")}
}
async function stopRecording(){
  const current=state.recording;if(!current)return;state.recording=null;clearInterval(state.timer);
  await new Promise(resolve=>{const timeout=setTimeout(resolve,700),receive=current.worklet.port.onmessage;current.worklet.port.onmessage=event=>{if(event.data?.type==="samples")current.chunks.push(event.data.samples);if(event.data?.type==="stopped"){clearTimeout(timeout);resolve()}else receive?.(event)};current.worklet.port.postMessage("stop")});
  current.stream.getTracks().forEach(track=>track.stop());current.source.disconnect();current.worklet.disconnect();const inputRate=current.context.sampleRate;await current.context.close().catch(()=>{});
  const input=joinChunks(current.chunks),output=downsample(input,inputRate,16000),wav=encodeWav(output,16000),duration=output.length/16000;
  if(duration<.25)return captureFailure("Too short — hold a little longer.");if(duration>30)return captureFailure("That was over 30 seconds. Nothing was sent.");
  state.pending={kind:"voice",submission:newSubmission(wav,current.capturedAt)};await sendCapture(state.pending);
}
function submitText(){const input=document.querySelector("#capture-text"),text=input.value.trim();if(!text){input.focus();return}if(protectExistingManual(()=>{state.pending={kind:"text",words:text,submission:newSubmission(JSON.stringify({text}))};sendCapture(state.pending,text)}))return;state.pending={kind:"text",words:text,submission:newSubmission(JSON.stringify({text}))};sendCapture(state.pending,text)}
async function sendCapture(pending,words=pending.words||""){
  setSheetLayout();sheetTitle.textContent="Record something";backButton.hidden=true;state.busy=true;closeButton.hidden=true;
  sheetBody.innerHTML=`<div class="processing"><h3 class="t-h2">Understanding and saving…</h3><p class="processing-quote t-body">${words?`“${esc(words)}”`:"Listening to what you said…"}</p><div class="progress-line"></div><p class="t-body subtle">Don't close — saving.</p></div>`;
  try{const voice=pending.kind==="voice",result=await api(voice?"/api/transactions/voice":"/api/conversation/text",{method:"POST",headers:requestHeaders(pending.submission,voice?"audio/wav":"application/json"),body:pending.submission.body});state.busy=false;closeButton.hidden=false;renderCaptureResult(result)}
  catch(error){state.busy=false;closeButton.hidden=false;if(error.status===409){state.pending.submission.requestId=crypto.randomUUID();captureFailure("That looked like a repeat of something different. Nothing was saved.",true,true)}else captureFailure("Pace couldn't reach the server, so the save could not be confirmed.",true,false)}
}
function resultActions(primary="Try again"){return`<div class="actions"><button id="failure-back" class="btn-secondary press">Back</button><button id="try-again" class="btn-primary press">${primary}</button></div>`}
function renderCaptureResult(result){
  setSheetLayout();
  const kind=captureResultKind(result.state);
  if(kind==="committed")return committedCard(result);
  if(kind==="clarification"){
    const clarification=result.clarification||{};
    sheetBody.innerHTML=`<div class="result-card"><div class="result-heading question">${icon("alert",{size:20})}<h3 class="t-h2">I need one thing</h3></div><p class="t-body">${esc(clarification.question||"Please confirm the details.")}</p><div class="alt-grid">${(clarification.alternatives_minor||[]).map(value=>`<button class="btn-secondary press t-num" data-alt="${value}">${money(value)}</button>`).join("")}</div><p class="quote t-body">“${esc(result.transcript)}”</p><p class="subtle">Nothing was saved.</p><div class="actions"><button id="clarify-manual" class="btn-secondary press">Enter manually</button><button id="try-again" class="btn-primary press">Try again</button></div></div>`;
    document.querySelectorAll("[data-alt]").forEach(button=>button.onclick=()=>openManual(null,{amount:(Number(button.dataset.alt)/100).toFixed(2),description:result.transcript,rawTranscript:result.transcript}));document.querySelector("#clarify-manual").onclick=()=>openManual(null,{description:result.transcript,rawTranscript:result.transcript});document.querySelector("#try-again").onclick=captureInput;return;
  }
  if(kind==="not_understood"){
    sheetBody.innerHTML=`<div class="result-card"><div class="result-heading failure">${icon("alert",{size:20})}<h3 class="t-h2">I didn't catch that safely</h3></div><p class="t-body">Nothing was saved.</p><p class="quote t-body">“${esc(result.transcript)}”</p>${result.error_code==="unsupported_intent"?"<p class=\"t-body\">Editing and deleting by voice isn't available yet — use History.</p>":""}<div class="actions"><button id="failed-manual" class="btn-secondary press">Enter manually</button><button id="try-again" class="btn-primary press">Try again</button></div></div>`;
    document.querySelector("#failed-manual").onclick=()=>openManual(null,{description:result.transcript,rawTranscript:result.transcript});document.querySelector("#try-again").onclick=captureInput;return;
  }
  captureFailure("Pace couldn't understand that safely. Nothing was saved.",true);
}
function committedCard(result){
  clearTimeout(state.resultTimer);state.manual=null;state.pendingManual=null;sheetBody.inert=false;backButton.hidden=true;backButton.disabled=false;closeButton.disabled=false;const viewId=++state.resultViewId;
  if(state.sheetHistoryDepth>0){state.historyResetView="result";history.go(-state.sheetHistoryDepth)}
  setSheetLayout();
  const transaction=result.transaction,duplicate=result.state==="duplicate_ignored",meta=categoryFor(transaction),label=transaction.merchant||transaction.description||FLOW_LABELS[transaction.type];
  sheetBody.innerHTML=`<div class="result-card"><div class="result-heading saved">${icon("check",{size:20,sw:2})}<h3>${duplicate?"Already saved":"Saved"}</h3></div>${moneyDisplay(transaction.amount_minor,"result-amount")}<div class="result-meta"><span class="mini-cat">${icon(meta.icon,{size:20})}</span><span class="t-body">${esc(FLOW_LABELS[transaction.type])} · ${esc(label)} · ${esc(transaction.category||FLOW_LABELS[transaction.type])} · ${friendlyDate(transaction.local_date)}</span></div><p class="quote t-body">${duplicate?"This was recorded a moment ago — not added again.":`“${esc(result.transcript||transaction.raw_transcript||"")}”`}</p><div class="actions">${!duplicate&&result.undo_token?'<button id="undo" class="btn-secondary press">Undo</button>':""}<button id="result-edit" class="btn-secondary press">Edit</button><button id="done" class="btn-primary press">Done</button></div></div>`;
  let interacted=false;const cancel=()=>{interacted=true;clearTimeout(state.resultTimer)};sheetBody.onpointerdown=cancel;sheetBody.onfocusin=cancel;state.resultTimer=setTimeout(()=>{if(state.sheet&&!interacted&&state.resultViewId===viewId){invalidate();closeSheet()}},4000);
  if(!duplicate&&result.undo_token)document.querySelector("#undo").onclick=async()=>{await api(`/api/actions/${encodeURIComponent(result.undo_token)}/undo`,{method:"POST"});showToast("Undone");invalidate();closeSheet()};
  document.querySelector("#result-edit").onclick=()=>{cancel();openManual(transaction)};document.querySelector("#done").onclick=()=>{cancel();invalidate();closeSheet()};
}
function captureFailure(message,retry=false,knownNotSaved=true){
  setSheetLayout();
  sheetBody.innerHTML=`<div class="result-card"><div class="result-heading failure">${icon("alert",{size:20})}<h3 class="t-h2">${knownNotSaved?"Not saved":"Save unconfirmed"}</h3></div><p class="t-body">${esc(message)}</p>${knownNotSaved?'<p class="subtle">Nothing was saved.</p>':""}${resultActions(retry?"Retry":"Try again")}</div>`;
  document.querySelector("#try-again").onclick=()=>retry?sendCapture(state.pending):captureInput();document.querySelector("#failure-back").onclick=captureInput;
}

function typeClass(type){return{expense:"exp",income:"inc",refund:"ref",contribution:"con"}[type]}
function typeSelector(current){return`<div class="seg" role="group" aria-label="Transaction type">${PRIMARY_MANUAL_TYPES.map(([type,label])=>{const selected=primaryTypeSelected(current.type,type);return`<button type="button" data-type="${type}" class="seg-btn press ${typeClass(type)} ${selected?"active":""}" aria-pressed="${selected}">${label}</button>`}).join("")}</div><div class="type-support"><div class="type-helper">${current.type==="contribution"?"Money deliberately put aside.":current.checkType?"Check the type, then continue.":current.type==="income"?"Extra income on top of monthly salary.":""}</div>${refundOptionVisible(current.type)?`<button type="button" data-type="refund" class="refund-option press ${current.type==="refund"?"active":""}" aria-pressed="${current.type==="refund"}">Refund</button>`:""}</div>`}
function keypadMarkup(current){return`<div class="amount-display" aria-live="polite"><span class="amount-cur">RM</span><span id="tx-amount" class="amount-big t-num ${validManualAmount(current.amount)?"valid":""}">${esc(current.amount||"0")}</span></div><div class="amount-tools"><button id="clear-amount" class="clear-amount press" type="button" ${current.amount?"":"disabled"}>Clear</button></div><div class="keypad">${["1","2","3","4","5","6","7","8","9",".","0","del"].map(key=>`<button type="button" class="key press" data-key="${key}" aria-label="${key==="del"?"Delete last digit":key}">${key==="del"?icon("back",{size:22,sw:2.2}):key}</button>`).join("")}</div>`}
function categoryTiles(current){
  return manualCategoryChoices(current.type).map(category=>{const meta=CATEGORY_META[category],selected=current.category===category;return`<button type="button" class="category-tile press ${selected?"selected":""}" data-category="${esc(category)}" aria-pressed="${selected}"><span class="category-check" aria-hidden="true">${selected?icon("check",{size:12,sw:2}):""}</span><span class="category-icon">${icon(meta.icon,{size:22})}</span><span class="category-label">${esc(category)}</span></button>`}).join("");
}
function categoryPanel(current,editing=false){
  if(current.type==="income")return`<div class="static-category"><span>Category</span><strong>Income</strong></div>`;
  if(current.type==="contribution")return`<div class="saved-context"><strong>Money put aside</strong><span>For savings, investing or a financial goal.</span></div>`;
  const unusual=current.category&&!manualCategoryChoices(current.type).includes(current.category);
  return`<section class="category-section" aria-labelledby="category-heading"><div id="category-heading" class="field-lbl">Category</div>${unusual?`<div class="current-category">Current: ${esc(current.category)}</div>`:""}<div class="category-grid" role="group" aria-label="Category">${categoryTiles(current)}</div></section>`;
}
function amountView(current,editing=false){return`<form id="transaction-form" class="tx-view amount-stage">${typeSelector(current)}${editing?`<div class="category-effect">Category: ${esc(current.category||"No category")}</div>`:""}<div class="amount-region">${keypadMarkup(current)}</div></form>`}
function notePreview(current){const text=current.merchant&&current.description?`${current.merchant} · ${current.description}`:current.merchant||current.description||current.note;return text||((current.rawTranscript||"").length>500?"Original words kept":"Add note")}
function detailsView(current){return`<div class="tx-view details-stage"><button id="edit-amount-summary" class="amount-summary press" type="button" aria-label="Change amount and type, ${FLOW_LABELS[current.type]}, ${money(amountMinor(current.amount))}"><span>${FLOW_LABELS[current.type]}</span><strong class="t-num">${money(amountMinor(current.amount))}</strong>${icon("chevron",{size:16})}</button>${categoryPanel(current)}<div class="metadata-row"><label class="meta-control press"><span>Date</span><strong>${esc(validLocalDate(current.date)?friendlyDate(current.date):"Choose a date")}</strong><input id="tx-date" type="date" value="${esc(current.date)}" aria-label="Date, ${esc(validLocalDate(current.date)?friendlyDate(current.date):"Choose a date")}"></label><button id="edit-note" class="meta-control press" type="button" aria-label="Note, optional"><span>Note</span><strong>${esc(notePreview(current))}</strong></button></div></div>`}
function editSummaryView(current){
  const rows=[["amount","Amount",money(amountMinor(current.amount))],["type","Type",FLOW_LABELS[current.type]]];
  if(current.type==="income")rows.push([null,"Category",current.category||"Income"]);else if(current.type!=="contribution")rows.push(["category","Category",current.category||"Choose a category"]);
  rows.push(["date","Date",validLocalDate(current.date)?friendlyDate(current.date):"Choose a date"],["note","Note",notePreview(current)]);
  return`<div class="tx-view edit-summary">${rows.map(([field,label,value])=>field==="date"?`<label class="edit-row press"><span>${label}</span><strong>${esc(value)}</strong><input id="tx-date" type="date" value="${esc(current.date)}" aria-label="Date, ${esc(value)}"></label>`:field?`<button class="edit-row press" data-edit-field="${field}" type="button"><span>${label}</span><strong>${esc(value)}</strong>${icon("chevron",{size:16})}</button>`:`<div class="edit-row"><span>${label}</span><strong>${esc(value)}</strong></div>`).join("")}</div>`;
}
function noteView(manual){
  const c=manual.current,both=manual.textMode==="both",originalOnly=(c.rawTranscript||"").length>500;
  return`<div class="tx-view note-editor">${both?`<div class="field"><label class="field-lbl" for="tx-merchant">Merchant</label><input class="input" id="tx-merchant" maxlength="200" value="${esc(c.merchant)}"></div><div class="field"><label class="field-lbl" for="tx-description">Description</label><textarea class="input note-textarea" id="tx-description" maxlength="500">${esc(c.description)}</textarea></div>`:`<div class="field"><label class="field-lbl" for="tx-note">Note ${manual.original?"":"(optional)"}</label><textarea class="input note-textarea" id="tx-note" maxlength="${manual.textMode==="description"||manual.textMode==="recovery"?500:200}" placeholder="Chicken rice">${esc(manual.textMode==="merchant"?c.merchant:manual.textMode==="description"||manual.textMode==="recovery"?c.description:c.note)}</textarea></div>`}${originalOnly?`<div class="original-words"><span>Original words</span><p>${esc(c.rawTranscript)}</p></div>`:""}</div>`;
}
function manualDirty(manual){return manual.original?Object.keys(sparseTransactionPatch(manual.original,manual.current,manual.touched)).length>0:Boolean(manual.current.amount||manual.current.type!=="expense"||manual.current.category!=="Other"||manual.current.date!==manual.startedDate||manual.current.note||manual.current.merchant||manual.current.description||manual.current.rawTranscript)}
function manualValid(manual){const c=manual.current;return validManualAmount(c.amount)&&validLocalDate(c.date)&&(c.type==="contribution"?c.category==null:Boolean(c.category))&&c.merchant.length<=200&&c.description.length<=500&&String(c.note||"").length<=200}
function manualFooter(){
  const m=state.manual,c=m.current,error=`<div id="tx-error" class="field-error" role="status">${esc(m.error||"")}</div>`;
  if(m.discardPrompt)return`${error}<div class="inline-confirm"><strong>${m.original?"Discard changes?":"Discard this transaction?"}</strong><div><button id="keep-editing" class="btn-primary press" type="button">Keep editing</button><button id="discard-manual" class="btn-danger press" type="button">Discard</button></div></div>`;
  if(m.uncertain)return`${error}<div class="inline-confirm"><strong>Couldn't confirm the save.</strong><div><button id="close-pending" class="btn-secondary press" type="button">Close for now</button><button id="retry-save" class="btn-primary press" type="button">Retry save</button></div></div>`;
  if(m.conflict)return`${error}<button id="review-entry" class="btn-primary press" type="button">Review entry</button>`;
  if(m.deleteConfirm)return`${error}<div class="delete-confirm" role="alert"><span>Delete this transaction?${manualDirty(m)?" Unsaved changes will be discarded.":""}</span><span class="delete-confirm-actions"><button id="cancel-delete" type="button">Cancel</button><button id="confirm-delete" class="delete-confirm-primary" type="button">Delete</button></span></div>`;
  if(m.screen==="add-amount")return`${error}<button class="btn-primary press" id="transaction-continue" type="button" ${validManualAmount(c.amount)?"":"disabled"}>Continue</button>`;
  if(m.screen==="add-note")return`${error}<button class="btn-primary press" id="note-done" type="button">Done</button>`;
  const label=m.original?"Save changes":`Save · ${money(amountMinor(c.amount))}`,enabled=manualValid(m)&&(!m.original||manualDirty(m));
  return`${error}<button class="btn-primary press" id="transaction-save" type="button" ${enabled&&!m.saving?"":"disabled"}>${m.saving?"Saving…":label}</button>${m.screen==="edit-summary"?`<div class="transaction-delete-slot"><button id="delete-transaction" class="transaction-delete press" type="button">${icon("trash",{size:16})} Delete transaction</button></div>`:""}`;
}
function setManualHeader(){const m=state.manual,titles={"add-amount":"Amount","add-details":"Details","add-note":"Note","edit-summary":"Edit transaction","edit-amount":"Amount & type","edit-category":"Category","edit-note":"Note"};sheetTitle.textContent=titles[m.screen];sheet.setAttribute("aria-label",m.original?titles[m.screen]:`Add transaction — ${titles[m.screen]}`);backButton.hidden=m.screen==="edit-summary";backButton.disabled=false;closeButton.disabled=false;backButton.onclick=manualBack}
function pushManualHistory(screen){history.pushState({sheet:true,view:screen},"");state.sheetHistoryDepth++}
function transitionBody(markup,direction="forward"){
  const hadView=Boolean(sheetBody.querySelector(".tx-view")),scroll=sheetBody.scrollTop,id=++transactionTransitionId;
  sheetBody.innerHTML=markup;const incoming=sheetBody.querySelector(".tx-view");sheetBody.scrollTop=direction==="back"?Math.min(scroll,Math.max(0,sheetBody.scrollHeight-sheetBody.clientHeight)):0;
  if(reducedMotion()||!hadView||!incoming)return;
  incoming.classList.add("tx-stage-enter",`tx-${direction}`);
  requestAnimationFrame(()=>requestAnimationFrame(()=>{if(id===transactionTransitionId&&incoming.isConnected)incoming.classList.add("tx-active")}));
  const finish=()=>{if(id!==transactionTransitionId)return;incoming.classList.remove("tx-stage-enter","tx-active",`tx-${direction}`)};
  incoming.addEventListener("transitionend",finish,{once:true});setTimeout(finish,240);
}
function showManualScreen(screen,push=false,direction="forward"){
  const m=state.manual;if(!m)return;m.visible=true;m.scrolls[m.screen]=sheetBody.scrollTop;m.screen=screen;m.error="";m.discardPrompt=false;m.deleteConfirm=false;if(push)pushManualHistory(screen);setSheetLayout("transaction");setManualHeader();
  const markup=screen==="add-amount"?amountView(m.current):screen==="add-details"?detailsView(m.current):screen==="edit-summary"?editSummaryView(m.current):screen==="edit-amount"?amountView(m.current,true):screen==="edit-category"?`<div class="tx-view category-editor">${categoryPanel(m.current,true)}</div>`:noteView(m);
  sheetBody.inert=false;transitionBody(markup,direction);sheetFooter.innerHTML=manualFooter();sheetFooter.hidden=false;bindManual();requestAnimationFrame(()=>{sheetBody.scrollTop=m.scrolls[screen]||0;sheetTitle.setAttribute("tabindex","-1");if(screen.endsWith("note"))document.querySelector("#tx-note,#tx-merchant")?.focus({preventScroll:true});else sheetTitle.focus({preventScroll:true})});
}
function protectExistingManual(action){const m=state.manual;if(!m||!manualDirty(m)||m.replaceAction)return false;m.replaceAction=action;showManualScreen(m.screen,true);m.discardPrompt=true;sheetBody.inert=true;sheetFooter.innerHTML=manualFooter();bindFooter();return true}
function openManual(transaction=null,prefill={}){
  if(!transaction&&protectExistingManual(()=>openManual(null,prefill)))return;
  const existed=state.sheet;if(!state.sheet)openSheet(transaction?"Edit transaction":"Add transaction");setSheetLayout("transaction");clearTimeout(state.resultTimer);state.resultViewId++;
  const type=FLOW_LABELS[prefill.type]?prefill.type:transaction?.type||"expense",amount=transaction?(transaction.amount_minor/100).toFixed(2):validManualAmount(prefill.amount)?String(prefill.amount):prefill.amount||"",raw=transaction?.raw_transcript||prefill.rawTranscript||"",description=transaction?.description||(raw.length<=500?prefill.description||"":""),category=transaction?.category??(type==="income"?"Income":type==="contribution"?null:(prefill.category||"Other")),date=transaction?.local_date||(validLocalDate(prefill.date)?prefill.date:localDate());
  const current={type,amount,merchant:transaction?.merchant||"",description,note:"",category,date,rawTranscript:raw,lastSpendCategory:(category&&category!=="Income"?category:"Other"),checkType:Boolean(prefill.amount&&!prefill.typeConfirmed)};
  const textMode=transaction?.merchant&&transaction?.description?"both":transaction?.merchant?"merchant":transaction?.description?"description":description?"recovery":"new",screen=manualStartScreen({isEdit:Boolean(transaction),amount,type,typeConfirmed:Boolean(prefill.typeConfirmed)});
  state.manual={original:transaction,current,textMode,screen,touched:new Set(),scrolls:{},startedDate:localDate(),fromExistingSheet:existed,origin:existed?"capture":"direct",visible:true,error:"",submission:null,saving:false,uncertain:false,conflict:false,discardPrompt:false,deleteConfirm:false};
  if(existed){if(screen==="add-details"){pushManualHistory("add-amount");pushManualHistory("add-details")}else pushManualHistory(screen)}else history.replaceState({sheet:true,view:screen},"");
  showManualScreen(screen,false);
}
function updateAmountUi(){const m=state.manual,c=m.current,node=document.querySelector("#tx-amount");if(node){node.textContent=c.amount||"0";node.classList.toggle("valid",validManualAmount(c.amount))}const clear=document.querySelector("#clear-amount");if(clear)clear.disabled=!c.amount;const action=document.querySelector(m.screen==="add-amount"?"#transaction-continue":"#transaction-save");if(action)action.disabled=m.screen==="add-amount"?!validManualAmount(c.amount):!manualValid(m)||!manualDirty(m)}
function changeType(type){const m=state.manual,changed=changeTransactionType(m.current,type);if(changed===m.current){if(m.current.checkType){m.current.checkType=false;showManualScreen(m.screen,false)}return}m.current={...changed,checkType:false};m.touched.add("type");m.touched.add("category");showManualScreen(m.screen,false)}
function chooseCategory(button){const m=state.manual;m.current.category=button.dataset.category;m.current.lastSpendCategory=m.current.category;m.touched.add("category");document.querySelectorAll("[data-category]").forEach(tile=>{const selected=tile===button;tile.classList.toggle("selected",selected);tile.setAttribute("aria-pressed",String(selected));tile.querySelector(".category-check").innerHTML=selected?icon("check",{size:12,sw:2.5}):""});sheetFooter.innerHTML=manualFooter();bindFooter()}
function syncNote(){const m=state.manual,c=m.current;if(m.textMode==="both"){const merchant=document.querySelector("#tx-merchant"),description=document.querySelector("#tx-description");if(!merchant&&!description)return;if(merchant){c.merchant=merchant.value;m.touched.add("merchant")}if(description){c.description=description.value;m.touched.add("description")}return}const input=document.querySelector("#tx-note");if(!input)return;const value=input.value;if(m.textMode==="merchant"){c.merchant=value;m.touched.add("merchant")}else if(m.textMode==="description"||m.textMode==="recovery"){c.description=value;m.touched.add("description")}else if(m.original){Object.assign(c,noteFields(value));c.note=value;m.touched.add("merchant");m.touched.add("description")}else c.note=value}
function bindManual(){
  document.querySelectorAll("[data-type]").forEach(button=>button.onclick=()=>changeType(button.dataset.type));document.querySelectorAll("[data-key]").forEach(button=>button.onclick=()=>{const c=state.manual.current,next=keypadAmount(c.amount,button.dataset.key);if(next===c.amount&&button.dataset.key!=="del"){state.manual.error="Amount can use up to seven digits and two decimals.";sheetFooter.innerHTML=manualFooter();bindFooter();return}c.amount=next;state.manual.touched.add("amount");state.manual.error="";updateAmountUi()});
  document.querySelector("#clear-amount")?.addEventListener("click",()=>{state.manual.current.amount="";state.manual.touched.add("amount");updateAmountUi()});document.querySelectorAll("[data-category]").forEach(button=>button.onclick=()=>chooseCategory(button));
  document.querySelector("#edit-amount-summary")?.addEventListener("click",()=>showManualScreen("add-amount",true,"back"));document.querySelector("#edit-note")?.addEventListener("click",()=>showManualScreen("add-note",true));document.querySelectorAll("[data-edit-field]").forEach(button=>button.onclick=()=>showManualScreen(["amount","type"].includes(button.dataset.editField)?"edit-amount":button.dataset.editField==="category"?"edit-category":"edit-note",true));
  const date=document.querySelector("#tx-date");if(date)date.onchange=()=>{state.manual.current.date=date.value;state.manual.touched.add("date");state.manual.error="";if(state.manual.screen==="edit-summary")showManualScreen("edit-summary",false);else{const value=date.closest(".meta-control")?.querySelector("strong");if(value)value.textContent=validLocalDate(date.value)?friendlyDate(date.value):"Choose a date";sheetFooter.innerHTML=manualFooter();bindFooter()}};
  ["#tx-note","#tx-merchant","#tx-description"].forEach(selector=>{const input=document.querySelector(selector);if(input)input.oninput=()=>{syncNote();sheetFooter.innerHTML=manualFooter();bindFooter()}});bindFooter();
}
function bindFooter(){
  document.querySelector("#transaction-continue")?.addEventListener("click",()=>{if(!validManualAmount(state.manual.current.amount)){state.manual.error="Enter an amount greater than zero.";sheetFooter.innerHTML=manualFooter();bindFooter();return}showManualScreen("add-details",true)});
  document.querySelector("#note-done")?.addEventListener("click",()=>{syncNote();manualBack()});document.querySelector("#transaction-save")?.addEventListener("click",()=>saveManual());document.querySelector("#delete-transaction")?.addEventListener("click",()=>{state.manual.deleteConfirm=true;sheetBody.inert=true;sheetFooter.innerHTML=manualFooter();bindFooter()});
  document.querySelector("#cancel-delete")?.addEventListener("click",()=>{state.manual.deleteConfirm=false;sheetBody.inert=false;sheetFooter.innerHTML=manualFooter();bindFooter()});document.querySelector("#confirm-delete")?.addEventListener("click",deleteManual);
  document.querySelector("#keep-editing")?.addEventListener("click",()=>clearManualPrompt());document.querySelector("#discard-manual")?.addEventListener("click",()=>{const action=state.manual.replaceAction;state.pendingManual=null;if(action){state.manual=null;action()}else closeSheet()});document.querySelector("#retry-save")?.addEventListener("click",()=>saveManual(true));document.querySelector("#close-pending")?.addEventListener("click",()=>{state.pendingManual=state.manual;closeSheet()});document.querySelector("#review-entry")?.addEventListener("click",()=>{state.manual.conflict=false;state.manual.submission=null;showManualScreen(state.manual.original?"edit-summary":"add-details",false)});
}
function clearManualPrompt(){const m=state.manual;if(!m)return;m.replaceAction=null;m.discardPrompt=false;sheetBody.inert=false;if(m.visible){sheetFooter.innerHTML=manualFooter();bindFooter()}else setSheetLayout()}
function valuesForSave(m){const c={...m.current};if(!m.original&&m.textMode==="new")Object.assign(c,noteFields(c.note));return c}
async function saveManual(retry=false){
  const m=state.manual;if(!m||m.saving)return;syncNote();const values=valuesForSave(m);if(!manualValid({...m,current:values})){m.error=!validManualAmount(values.amount)?"Enter an amount greater than zero.":!validLocalDate(values.date)?"Choose a valid date.":"Check the transaction details.";sheetFooter.innerHTML=manualFooter();bindFooter();return}
  if(!m.original&&!retry){const body=JSON.stringify(manualPayload(values));m.submission={kind:"create",body,request:newSubmission(body)}}
  if(m.original&&!retry){const patch=sparseTransactionPatch(m.original,values,m.touched);if(!Object.keys(patch).length)return;m.submission={kind:"edit",body:JSON.stringify(patch)}}
  m.saving=true;m.uncertain=false;m.error="";state.busy=true;sheetBody.inert=true;backButton.disabled=true;closeButton.disabled=true;sheetFooter.innerHTML=manualFooter();bindFooter();
  try{const s=m.submission,transaction=s.kind==="create"?await api("/api/transactions",{method:"POST",headers:{"Content-Type":"application/json","X-Request-Id":s.request.requestId},body:s.body}):await api(`/api/transactions/${m.original.id}`,{method:"PATCH",headers:{"Content-Type":"application/json"},body:s.body});state.busy=false;state.pending=null;invalidate();committedCard({state:"committed",transaction,transcript:transaction.raw_transcript})}
  catch(error){state.busy=false;m.saving=false;sheetBody.inert=false;backButton.disabled=false;closeButton.disabled=false;if(!error.status){m.uncertain=true;m.error="The request may have reached Pace. Retry uses the same request."}else if(!m.original&&error.status===409){m.conflict=true;m.error="This entry wasn't saved because of a request conflict."}else if(m.original&&[404,409].includes(error.status)){closeSheet();invalidate();showToast("This transaction is no longer available","alert");return}else{m.submission=null;m.error=error.message;showManualScreen(m.original?"edit-summary":"add-details",false)}sheetFooter.innerHTML=manualFooter();bindFooter()}
}
async function deleteManual(){const m=state.manual;if(!m?.original||state.busy)return;state.busy=true;sheetBody.inert=true;backButton.disabled=true;closeButton.disabled=true;document.querySelectorAll("#sheet-footer button").forEach(button=>button.disabled=true);try{await api(`/api/transactions/${m.original.id}`,{method:"DELETE"});state.busy=false;invalidate();closeSheet();showToast("Transaction deleted","trash")}catch(error){state.busy=false;sheetBody.inert=false;backButton.disabled=false;closeButton.disabled=false;if([404,409].includes(error.status)){invalidate();closeSheet();showToast("This was already deleted","alert")}else{m.error="Couldn't delete. Try again.";sheetFooter.innerHTML=manualFooter();bindFooter()}}}
function manualBack(){const m=state.manual;if(!m||state.busy)return;if(m.discardPrompt){clearManualPrompt();return}if(m.deleteConfirm){m.deleteConfirm=false;sheetBody.inert=false;sheetFooter.innerHTML=manualFooter();bindFooter();return}history.back()}
function requestSheetClose(release=null){const m=state.manual;if(!m)return closeSheet(false,release);if(m.saving)return;if(m.discardPrompt){clearManualPrompt();return}if(m.uncertain){state.pendingManual=m;return closeSheet(false,release)}if(manualDirty(m)){if(sheet.classList.contains("dragging"))settleSheet(release?.duration||220);else sheet.style.setProperty("--drag-y","0px");m.discardPrompt=true;sheetBody.inert=true;sheetFooter.innerHTML=manualFooter();sheetFooter.hidden=false;bindFooter();return}closeSheet(false,release)}

function invalidate(){cache.home=null;cache.recent=null;cache.history.clear();renderRoute()}
function joinChunks(chunks){const output=new Float32Array(chunks.reduce((length,chunk)=>length+chunk.length,0));let offset=0;for(const chunk of chunks){output.set(chunk,offset);offset+=chunk.length}return output}
function downsample(input,inputRate,outputRate){if(inputRate===outputRate)return input;const output=new Float32Array(Math.floor(input.length*outputRate/inputRate)),ratio=inputRate/outputRate;for(let i=0;i<output.length;i++){const start=Math.floor(i*ratio),end=Math.max(start+1,Math.floor((i+1)*ratio));let sum=0,count=0;for(let j=start;j<end&&j<input.length;j++){sum+=input[j];count++}output[i]=count?sum/count:0}return output}
function encodeWav(samples,sampleRate){const buffer=new ArrayBuffer(44+samples.length*2),view=new DataView(buffer),text=(offset,value)=>[...value].forEach((char,index)=>view.setUint8(offset+index,char.charCodeAt(0)));text(0,"RIFF");view.setUint32(4,36+samples.length*2,true);text(8,"WAVEfmt ");view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,1,true);view.setUint32(24,sampleRate,true);view.setUint32(28,sampleRate*2,true);view.setUint16(32,2,true);view.setUint16(34,16,true);text(36,"data");view.setUint32(40,samples.length*2,true);samples.forEach((value,index)=>view.setInt16(44+index*2,Math.max(-1,Math.min(1,value))*(value<0?32768:32767),true));return new Blob([buffer],{type:"audio/wav"})}

function setupDragDismiss(){
  let startX=0,startY=0,lastY=0,active=false,axis="pending",dragFrame=0,samples=[];
  const paint=()=>{dragFrame=0;sheet.style.setProperty("--drag-y",`${Math.max(0,lastY-startY)}px`)};
  const start=event=>{if(state.busy||event.target.closest("button,input,textarea"))return;active=true;axis="pending";startX=event.clientX;startY=lastY=event.clientY;samples=[{y:lastY,t:performance.now()}]};
  const move=event=>{
    if(!active)return;const dx=event.clientX-startX,dy=event.clientY-startY;
    if(axis==="pending"){if(Math.max(Math.abs(dx),Math.abs(dy))<8)return;axis=Math.abs(dy)>Math.abs(dx)*1.2?"vertical":"cancelled";if(axis==="vertical"){sheet.classList.add("dragging");event.currentTarget.setPointerCapture?.(event.pointerId)}}
    if(axis!=="vertical")return;lastY=event.clientY;const now=performance.now();samples.push({y:lastY,t:now});samples=samples.filter(sample=>now-sample.t<=100);if(!dragFrame)dragFrame=requestAnimationFrame(paint);
  };
  const end=(event,cancelled=false)=>{
    if(!active)return;active=false;cancelAnimationFrame(dragFrame);dragFrame=0;if(axis!=="vertical"){axis="pending";return}paint();
    const delta=Math.max(0,lastY-startY),first=samples[0],last=samples.at(-1),velocity=cancelled||!first||!last?0:Math.max(0,(last.y-first.y)/Math.max(1,last.t-first.t));
    const release=sheetReleaseMotion(delta,velocity,sheet.clientHeight);axis="pending";
    if(release.dismiss){requestSheetClose(release);return}
    settleSheet(release.duration);
  };
  [sheet.querySelector(".sheet-grab"),sheet.querySelector(".sheet-header")].forEach(target=>{target.addEventListener("pointerdown",start);target.addEventListener("pointermove",move);target.addEventListener("pointerup",event=>end(event));target.addEventListener("pointercancel",event=>end(event,true))});
}
function guardScrollEdges(element){
  let startY=0;
  element.addEventListener("touchstart",event=>{if(event.touches.length===1)startY=event.touches[0].clientY},{passive:true});
  element.addEventListener("touchmove",event=>{if(event.touches.length!==1)return;const delta=event.touches[0].clientY-startY,atTop=element.scrollTop<=0,atBottom=Math.ceil(element.scrollTop+element.clientHeight)>=element.scrollHeight;if(element.scrollHeight<=element.clientHeight||(atTop&&delta>0)||(atBottom&&delta<0))event.preventDefault()},{passive:false});
}

setTheme();
matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change",()=>{if((localStorage.getItem("pace-theme")||"system")==="system")setTheme("system")});
backButton.innerHTML=icon("back",{size:20,sw:2});closeButton.innerHTML=icon("close",{size:18,sw:2});document.querySelectorAll("[data-icon]").forEach(node=>node.innerHTML=icon(node.dataset.icon));
captureButton.onclick=()=>state.sheet?requestSheetClose():captureInput();closeButton.onclick=()=>requestSheetClose();scrim.onclick=()=>{if(!state.busy)requestSheetClose()};
window.visualViewport?.addEventListener("resize",syncSheetToKeyboard);window.visualViewport?.addEventListener("scroll",syncSheetToKeyboard);
window.addEventListener("hashchange",renderRoute);window.addEventListener("popstate",event=>{
  if(!state.sheet)return;state.sheetHistoryDepth=Math.max(0,state.sheetHistoryDepth-1);
  if(state.historyResetView){const view=state.historyResetView;state.historyResetView=null;history.pushState({sheet:true,view},"");state.sheetHistoryDepth=1;return}
  if(state.manual&&(state.busy||state.manual.uncertain||state.manual.discardPrompt||state.manual.deleteConfirm)){
    history.pushState({sheet:true,view:state.manual.screen},"");state.sheetHistoryDepth++;
    if(state.manual.discardPrompt||state.manual.deleteConfirm)manualBack();return;
  }
  const view=event.state?.sheet&&event.state.view;
  const manualViews=new Set(["add-amount","add-details","add-note","edit-summary","edit-amount","edit-category","edit-note"]);
  if(state.manual&&manualViews.has(view)){showManualScreen(view,false,"back");return}
  if(state.manual&&view==="root"&&!state.manual.original){captureInput();return}
  if(state.manual&&manualDirty(state.manual)){history.pushState({sheet:true,view:state.manual.screen},"");state.sheetHistoryDepth++;state.manual.discardPrompt=true;sheetBody.inert=true;sheetFooter.innerHTML=manualFooter();sheetFooter.hidden=false;bindFooter();return}
  closeSheet(true);
});
document.addEventListener("keydown",event=>{
  if(!state.sheet||state.busy)return;
  if(event.key==="Tab"){const focusable=[...sheet.querySelectorAll("button:not([disabled]),input:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex='-1'])")].filter(node=>!node.closest("[inert]")&&getComputedStyle(node).visibility!=="hidden");if(focusable.length){const first=focusable[0],last=focusable.at(-1);if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus()}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus()}}return}
  if(event.key==="Escape"){if(state.manual&&state.manual.screen!=="add-amount"&&state.manual.screen!=="edit-summary")manualBack();else requestSheetClose();return}
  if(!state.manual?.visible||!["add-amount","edit-amount"].includes(state.manual.screen)||event.target.matches("input,textarea"))return;
  if(/^\d$/.test(event.key)||event.key==="."){event.preventDefault();const next=keypadAmount(state.manual.current.amount,event.key);if(next!==state.manual.current.amount){state.manual.current.amount=next;state.manual.touched.add("amount");updateAmountUi()}}
  if(event.key==="Backspace"){event.preventDefault();state.manual.current.amount=keypadAmount(state.manual.current.amount,"del");state.manual.touched.add("amount");updateAmountUi()}
  if(event.key==="Enter"){event.preventDefault();if(state.manual.screen==="add-amount"&&!validManualAmount(state.manual.current.amount)){state.manual.error="Enter an amount greater than zero.";sheetFooter.innerHTML=manualFooter();bindFooter()}else document.querySelector(state.manual.screen==="add-amount"?"#transaction-continue":"#transaction-save")?.click()}
});document.addEventListener("visibilitychange",()=>{if(document.hidden&&state.recording)stopRecording()});setupDragDismiss();guardScrollEdges(app);guardScrollEdges(sheetBody);
if(!location.hash)location.replace("#/home");else renderRoute();
if("serviceWorker"in navigator){let reloading=false;const refresh=build=>{if(reloading||build!==BUILD||state.busy||state.recording)return;const key=`pace-assets-reloaded-${build}`;if(sessionStorage.getItem(key))return;sessionStorage.setItem(key,"1");reloading=true;location.reload()};navigator.serviceWorker.addEventListener("message",event=>{if(event.data?.type==="NOTED_ASSETS_UPDATED")refresh(event.data.build)});navigator.serviceWorker.addEventListener("controllerchange",()=>refresh(BUILD));navigator.serviceWorker.register("/sw.js",{updateViaCache:"none"}).then(registration=>registration.update()).catch(console.error)}
