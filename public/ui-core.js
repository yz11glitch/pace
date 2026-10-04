export const CATEGORIES=["Food & Drink","Groceries","Transport","Shopping","Bills & Utilities","Health","Entertainment","Education","Services","Travel","Gifts & Donations","Income","Other"];
export const FLOW_LABELS={expense:"Spent",income:"Earned",refund:"Refund",contribution:"Set aside"};
export const PRIMARY_MANUAL_TYPES=[["expense","Spent"],["income","Earned"],["contribution","Set aside"]];
export const CATEGORY_META={
  "Food & Drink":{icon:"food",ink:"--ink",bg:"--bg-2"},
  Groceries:{icon:"groc",ink:"--ink",bg:"--bg-2"},
  Transport:{icon:"tpt",ink:"--ink",bg:"--bg-2"},
  Shopping:{icon:"shop",ink:"--ink",bg:"--bg-2"},
  "Bills & Utilities":{icon:"bill",ink:"--ink",bg:"--bg-2"},
  Health:{icon:"hlth",ink:"--ink",bg:"--bg-2"},
  Entertainment:{icon:"ent",ink:"--ink",bg:"--bg-2"},
  Education:{icon:"edu",ink:"--ink",bg:"--bg-2"},
  Services:{icon:"repeat",ink:"--ink",bg:"--bg-2"},
  Travel:{icon:"travel",ink:"--ink",bg:"--bg-2"},
  "Gifts & Donations":{icon:"gift",ink:"--ink",bg:"--bg-2"},
  Income:{icon:"inc",ink:"--ink",bg:"--bg-2"},
  Other:{icon:"misc",ink:"--ink",bg:"--bg-2"},
};
export function money(minor,currency="RM"){return `${currency} ${(Number(minor||0)/100).toLocaleString("en-MY",{minimumFractionDigits:2,maximumFractionDigits:2})}`}
export function amountMinor(value){const number=Number(value);return Number.isFinite(number)?Math.round(number*100):0}
export function keypadAmount(current,key){
  if(key==="del")return current.slice(0,-1);
  if(key===".")return current.includes(".")?current:(current||"0")+".";
  if(!/^\d$/.test(key))return current;
  const [whole,fraction=""]=current.split(".");
  if(current.includes(".")&&fraction.length>=2)return current;
  const digits=current.replace(/\D/g,"");
  if(digits.length>=7)return current;
  if(current==="0")return key;
  return current+key;
}

export function sheetReleaseMotion(distance,velocity,sheetHeight){
  const y=Math.max(0,Number(distance)||0),v=Math.max(0,Number(velocity)||0),height=Math.max(1,Number(sheetHeight)||1);
  const threshold=Math.min(150,Math.max(96,height*.2)),projected=y+v*180;
  const dismiss=y>=threshold||(y>16&&v>.55&&projected>=threshold);
  if(dismiss){
    const remaining=Math.max(0,height-y),exitSpeed=Math.max(1.9,v*1.6);
    return{dismiss:true,duration:Math.round(Math.max(190,Math.min(320,remaining/exitSpeed)))};
  }
  return{dismiss:false,duration:Math.round(Math.max(180,Math.min(300,180+y*.65-v*55)))};
}
export function noteFields(note){
  const text=String(note||"").trim();
  if(!text)return{merchant:"",description:""};
  return text.length<=60&&!/[.!?]\s*$/.test(text)?{merchant:text,description:""}:{merchant:"",description:text};
}
export function captureResultKind(state){
  if(state==="committed"||state==="duplicate_ignored")return"committed";
  if(state==="needs_clarification")return"clarification";
  if(state==="not_understood")return"not_understood";
  return"failure";
}
export function primaryTypeSelected(currentType,primaryType){return currentType===primaryType||(currentType==="refund"&&primaryType==="income")}
export function refundOptionVisible(type){return primaryTypeSelected(type,"income")}
export function manualCategoryChoices(type){
  if(type==="contribution")return[];
  if(type==="income")return["Income"];
  return CATEGORIES.filter(category=>category!=="Income");
}
export function transactionCategory(type,selected="Other",remembered="Other"){
  if(type==="income")return"Income";
  if(type==="contribution")return null;
  return selected&&selected!=="Income"?selected:(remembered&&remembered!=="Income"?remembered:"Other");
}
export function changeTransactionType(draft,type){
  const previous=draft.type;
  if(type===previous)return draft;
  const remembered=(previous==="expense"||previous==="refund")&&draft.category?draft.category:draft.lastSpendCategory||"Other";
  return{...draft,type,lastSpendCategory:remembered,category:transactionCategory(type,draft.category,remembered)};
}
export function validManualAmount(value){const minor=amountMinor(value);return minor>0&&minor<=10_000_000_000}
export function validLocalDate(value){
  const match=/^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value||""));if(!match)return false;
  const date=new Date(Number(match[1]),Number(match[2])-1,Number(match[3]));
  return date.getFullYear()===Number(match[1])&&date.getMonth()===Number(match[2])-1&&date.getDate()===Number(match[3]);
}
export function manualStartScreen({isEdit=false,amount="",type="expense",typeConfirmed=false}={}){return isEdit?"edit-summary":(validManualAmount(amount)&&typeConfirmed&&FLOW_LABELS[type]?"add-details":"add-amount")}
export function timezone(){return Intl.DateTimeFormat().resolvedOptions().timeZone||"Asia/Kuala_Lumpur"}
export function offsetDateTime(date){const d=new Date(`${date}T12:00:00`);return `${date}T12:00:00${offsetSuffix(d)}`}
function offsetSuffix(d){const mins=-d.getTimezoneOffset(),sign=mins>=0?"+":"-",n=Math.abs(mins);return `${sign}${String(Math.floor(n/60)).padStart(2,"0")}:${String(n%60).padStart(2,"0")}`}
export function newSubmission(body,capturedAt=new Date().toISOString()){return{requestId:crypto.randomUUID(),capturedAt,body}}
export function requestHeaders(submission,contentType){return{"Content-Type":contentType,"X-Request-Id":submission.requestId,"X-Captured-At":submission.capturedAt,"X-Timezone":timezone(),"X-Session-Id":sessionId()}}
export function sessionId(){let value=localStorage.getItem("pace-session-id");if(!value){value=`pace-${crypto.randomUUID()}`;localStorage.setItem("pace-session-id",value)}return value}
export function manualPayload(values){const contribution=values.type==="contribution";return{type:values.type,amount_minor:amountMinor(values.amount),currency:"MYR",merchant:values.merchant.trim()||null,description:values.description.trim()||null,category:contribution?null:(values.category||"Other"),subcategory:null,occurred_at:offsetDateTime(values.date),local_date:values.date,raw_transcript:values.rawTranscript||values.description.trim()||"manual entry"}}
export function historyQuery(month,q="",limit=100){const start=`${month}-01`,date=new Date(`${start}T12:00:00`),last=new Date(date.getFullYear(),date.getMonth()+1,0).getDate();let end=`${month}-${String(last).padStart(2,"0")}`;const now=new Date(),current=`${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,"0")}`;if(month===current)end=`${current}-${String(now.getDate()).padStart(2,"0")}`;const params=new URLSearchParams({start_date:start,end_date:end,limit:String(limit)});if(q.trim())params.set("q",q.trim());return `/api/transactions?${params}`}
export function profilePayload(values){return{income_amount_minor:amountMinor(values.income),income_frequency:"monthly",next_income_date:values.nextDate,fixed_commitments_minor:amountMinor(values.commitments),savings_target_minor:amountMinor(values.savings),savings_mode:values.savingsMode||"fixed",savings_percentage_basis_points:amountMinor(values.savingsPercentage||0)}}
export function sparseTransactionPatch(original,next,touched=null){
  const fields=touched?new Set(touched):new Set(["type","amount","merchant","description","category","date"]),patch={};
  const put=(key,value)=>{if(JSON.stringify(original[key]??null)!==JSON.stringify(value??null))patch[key]=value};
  if(fields.has("type"))put("type",next.type);
  if(fields.has("amount"))put("amount_minor",amountMinor(next.amount));
  if(fields.has("merchant"))put("merchant",String(next.merchant||"").trim()||null);
  if(fields.has("description"))put("description",String(next.description||"").trim()||null);
  if(fields.has("category")||fields.has("type"))put("category",transactionCategory(next.type,next.category,next.lastSpendCategory));
  if(fields.has("date")){
    if(next.date!==original.local_date){put("local_date",next.date);put("occurred_at",offsetDateTime(next.date))}
  }
  return patch;
}
