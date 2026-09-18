// Copyright (c) 2026 Tristan Conner <tristan@conner.house>
// SPDX-License-Identifier: MIT
const SEV_CLASS = ["s-emerg","s-emerg","s-err","s-err","s-warn","s-notice","s-info","s-debug"];
const SEV_COLOR = ["--s-emerg","--s-emerg","--s-err","--s-err","--s-warn","--s-notice","--s-info","--s-debug"];
const SEV_NAMES = ["Emergency","Alert","Critical","Error","Warning","Notice","Informational","Debug"];
let CURRENT = []; // last fetched messages

const $ = id => document.getElementById(id);
function fmtBytes(n){ if(n<1024)return n+" B"; const u=["KB","MB","GB","TB"]; let i=-1;
  do{ n/=1024; i++; }while(n>=1024 && i<u.length-1); return n.toFixed(1)+" "+u[i]; }

async function loadFiles(){
  const files = await fetch("/api/files").then(r=>r.json()).catch(()=>[]);
  const sel = $("file"); const keep = sel.value;
  sel.textContent = "";
  files.forEach(f=>{ const o=document.createElement("option"); o.value=f; o.textContent=f; sel.appendChild(o); });
  if (files.includes(keep)) sel.value = keep;
}

async function loadStats(){
  let ok = true;
  const [s,c] = await Promise.all([
    fetch("/api/stats").then(r=>r.json()).catch(()=>{ ok=false; return {}; }),
    fetch("/api/config").then(r=>r.json()).catch(()=>({})),
  ]);
  $("offline").hidden = ok;   // show the banner only while a stats fetch is failing
  $("st-msgs").textContent = s.total_messages ?? "0";
  $("st-files").textContent = s.file_count ?? "0";
  $("st-size").textContent = fmtBytes(s.total_bytes ?? 0);
  $("st-cur").textContent = s.current_file || "—";
  $("st-dir").textContent = c.log_dir || "—";
  if (s.version) $("ver").textContent = "v"+s.version;
  lastReceivedIso = s.last_received || "";
  renderLastReceived();
}

let lastReceivedIso = "";
function ago(iso){
  const t = Date.parse(iso); if (isNaN(t)) return "—";
  const s = Math.max(0, Math.floor((Date.now()-t)/1000));
  if (s < 1)     return "just now";
  if (s < 60)    return s+"s ago";
  if (s < 3600)  return Math.floor(s/60)+"m ago";
  if (s < 86400) return Math.floor(s/3600)+"h ago";
  return Math.floor(s/86400)+"d ago";
}
function renderLastReceived(){ $("st-last").textContent = lastReceivedIso ? ago(lastReceivedIso) : "never"; }
setInterval(renderLastReceived, 1000);  // keep the "N s ago" ticking (runtime only, not stored)

let seenKeys = new Set(), flashKeys = new Set(), firstLoad = true;
function keyOf(m){ return m.received+"|"+m.source_ip+"|"+m.raw; }

async function loadMessages(){
  const file = $("file").value;
  const limit = $("limit").value;
  const q = "/api/messages?limit="+encodeURIComponent(limit)+(file?"&file="+encodeURIComponent(file):"");
  CURRENT = await fetch(q).then(r=>r.json()).catch(()=>[]);
  // Flag rows new since the last load so render() flashes them once (skip first load).
  const cur = new Set(); flashKeys = new Set();
  for (const m of CURRENT){ const k=keyOf(m); cur.add(k); if(!firstLoad && !seenKeys.has(k)) flashKeys.add(k); }
  seenKeys = cur; firstLoad = false;
  populateSources();
  render();
}

function matchesText(m, term){
  if (!term) return true;
  return (m.hostname+" "+m.app+" "+m.message+" "+m.source_ip).toLowerCase().includes(term);
}

function render(){
  const term = $("filter").value.toLowerCase();
  const sev = $("sev").value;
  const source = $("source").value;
  const rows = $("rows"); rows.textContent = "";
  let shown = 0;
  // newest first
  for (let i=CURRENT.length-1; i>=0; i--){
    const m = CURRENT[i];
    if (sev !== "" && String(m.severity) !== sev) continue;
    if (source !== "" && m.source_ip !== source) continue;
    if (!matchesText(m, term)) continue;
    rows.appendChild(rowEl(m, term));
    shown++;
  }
  flashKeys = new Set();   // consume: only the render right after a load flashes new rows
  $("empty").style.display = shown ? "none" : "block";
  $("count").textContent = CURRENT.length
    ? (shown === CURRENT.length ? shown+" messages" : "Showing "+shown+" of "+CURRENT.length)
    : "";
  renderSummary();
}

// Severity breakdown of the text-filtered view (ignores the severity filter, so
// every level stays visible); each chip narrows the table to that level.
function renderSummary(){
  const term = $("filter").value.toLowerCase();
  const source = $("source").value;
  const counts = {}; let total = 0;
  for (const m of CURRENT){
    if (source !== "" && m.source_ip !== source) continue;
    if (!matchesText(m, term)) continue;
    counts[m.severity] = (counts[m.severity]||0) + 1; total++;
  }
  const bar = $("sevbar"); bar.textContent = "";
  const cur = $("sev").value;
  bar.appendChild(chip("All", total, "", cur===""));
  for (let s=0; s<=7; s++){
    if (counts[s]) bar.appendChild(chip(SEV_NAMES[s], counts[s], String(s), cur===String(s), SEV_COLOR[s]));
  }
  bar.style.display = total ? "flex" : "none";
}

function chip(label, count, sevValue, active, colorVar){
  const c = document.createElement("button");
  c.className = "sevchip" + (active ? " active" : "");
  if (colorVar){
    const dot = document.createElement("span"); dot.className = "dot";
    dot.style.background = "var("+colorVar+")"; c.appendChild(dot);
  }
  const t = document.createElement("span"); t.textContent = label; c.appendChild(t);
  const n = document.createElement("span"); n.className = "n"; n.textContent = count; c.appendChild(n);
  c.addEventListener("click", ()=>{
    $("sev").value = (active && sevValue !== "") ? "" : sevValue;  // toggle off if re-clicked
    render();
  });
  return c;
}

// Populate the Source dropdown from the loaded data (sender IPs + counts, most
// active first), preserving the current selection.
function populateSources(){
  const counts = {};
  for (const m of CURRENT) counts[m.source_ip] = (counts[m.source_ip]||0) + 1;
  const sel = $("source"); const keep = sel.value;
  sel.textContent = "";
  const all = document.createElement("option");
  all.value = ""; all.textContent = "all ("+CURRENT.length+")"; sel.appendChild(all);
  for (const [ip,n] of Object.entries(counts).sort((a,b)=>b[1]-a[1])){
    const o = document.createElement("option"); o.value = ip; o.textContent = ip+" ("+n+")"; sel.appendChild(o);
  }
  sel.value = [...sel.options].some(o=>o.value===keep) ? keep : "";
}

// Download the filtered view (all active filters) as CSV, oldest first.
function exportCsv(){
  const term = $("filter").value.toLowerCase();
  const sev = $("sev").value, source = $("source").value;
  const cols = ["received","source_ip","hostname","severity_name","facility_name","app","procid","msgid","message"];
  const esc = v => {
    let s = String(v==null?"":v);
    // Neutralize spreadsheet formula injection: a cell starting with =,+,-,@ (or
    // tab/CR) is evaluated as a formula by Excel/Sheets. Values are attacker-
    // controlled syslog, so prefix a quote to force text.
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
    return '"' + s.replace(/"/g,'""') + '"';
  };
  const lines = [cols.join(",")];
  for (const m of CURRENT){
    if (sev !== "" && String(m.severity) !== sev) continue;
    if (source !== "" && m.source_ip !== source) continue;
    if (!matchesText(m, term)) continue;
    lines.push(cols.map(c=>esc(m[c])).join(","));
  }
  const blob = new Blob([lines.join("\r\n")], {type:"text/csv"});
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "syslog-export-" + new Date().toISOString().replace(/[:.]/g,"-").slice(0,19) + ".csv";
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(()=>URL.revokeObjectURL(url), 1000);
}

function td(text, cls){ const d=document.createElement("td"); if(cls)d.className=cls; d.textContent=text??""; return d; }

// Message cell with case-insensitive highlight of the filter term. Builds text
// nodes + <mark> elements (never innerHTML) so message content stays inert.
function msgCell(text, term){
  const d=document.createElement("td"); d.className="msg";
  const s = text ?? "";
  if(!term){ d.textContent=s; return d; }
  const low=s.toLowerCase(); let i=0, idx;
  while((idx=low.indexOf(term,i)) !== -1){
    if(idx>i) d.appendChild(document.createTextNode(s.slice(i,idx)));
    const mk=document.createElement("mark"); mk.textContent=s.slice(idx,idx+term.length);
    d.appendChild(mk);
    i=idx+term.length;
  }
  if(i<s.length) d.appendChild(document.createTextNode(s.slice(i)));
  return d;
}

function rowEl(m, term){
  const tr = document.createElement("tr");
  if(flashKeys.has(keyOf(m))) tr.className="flash";
  tr.appendChild(td(m.received));
  tr.appendChild(td(m.source_ip));
  tr.appendChild(td(m.hostname || "—"));
  const sd = document.createElement("td");
  const badge = document.createElement("span");
  badge.className = "sev";
  badge.textContent = m.severity_name || m.severity;
  badge.style.background = "var("+(SEV_COLOR[m.severity]||"--s-info")+")";
  sd.appendChild(badge); tr.appendChild(sd);
  tr.appendChild(td(m.facility_name));
  tr.appendChild(td(m.app || "—"));
  tr.appendChild(msgCell(m.message, term));
  tr.addEventListener("click", ()=>openDetail(m));
  return tr;
}

function openDetail(m){
  const dl = $("detail"); dl.textContent = "";
  const fields = [
    ["Received", m.received],["Source IP", m.source_ip],["Timestamp", m.timestamp],
    ["Host", m.hostname],["App / Tag", m.app],["Process ID", m.procid],
    ["Message ID", m.msgid],["Facility", m.facility_name+" ("+m.facility+")"],
    ["Severity", m.severity_name+" ("+m.severity+")"],["Message", m.message],
  ];
  for (const [k,v] of fields){
    const dt=document.createElement("dt"); dt.textContent=k;
    const dd=document.createElement("dd"); dd.textContent=(v===""||v==null)?"—":v;
    if (k==="Message") dd.className="mono";
    dl.appendChild(dt); dl.appendChild(dd);
  }
  $("raw").textContent = m.raw || "";
  $("modal").classList.add("open");
}

async function refreshAll(){ await loadFiles(); await Promise.all([loadStats(), loadMessages()]); }

// wiring
$("refresh").addEventListener("click", refreshAll);
$("file").addEventListener("change", ()=>{ loadMessages(); loadStats(); });
$("limit").addEventListener("change", loadMessages);
$("sev").addEventListener("change", render);
$("source").addEventListener("change", render);
$("filter").addEventListener("input", render);
$("export").addEventListener("click", exportCsv);
function copied(){ const b=$("copyraw"); b.textContent="Copied"; setTimeout(()=>{ b.textContent="Copy"; }, 1200); }
function fallbackCopy(text){
  const ta=document.createElement("textarea");
  ta.value=text; ta.style.position="fixed"; ta.style.opacity="0";
  document.body.appendChild(ta); ta.focus(); ta.select();
  let ok=false; try { ok=document.execCommand("copy"); } catch(e){}
  ta.remove(); return ok;
}
$("copyraw").addEventListener("click", ()=>{
  const text = $("raw").textContent;
  if (navigator.clipboard && navigator.clipboard.writeText){
    navigator.clipboard.writeText(text).then(copied, ()=>{ if (fallbackCopy(text)) copied(); });
  } else if (fallbackCopy(text)) { copied(); }
});
$("close").addEventListener("click", ()=>$("modal").classList.remove("open"));
$("modal").addEventListener("click", e=>{ if(e.target===$("modal")) $("modal").classList.remove("open"); });
document.addEventListener("keydown", e=>{
  if(e.key==="Escape") $("modal").classList.remove("open");
  // "/" jumps to the filter box, unless you're already typing in a field.
  if(e.key==="/" && !/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName)){
    e.preventDefault(); $("filter").focus();
  }
});
$("cleanup").addEventListener("click", async ()=>{
  if(!confirm("Delete log files older than the retention period, and trim oldest files if over the size cap?")) return;
  const r = await fetch("/api/cleanup",{method:"POST"}).then(r=>r.json()).catch(()=>({}));
  alert("Cleanup done.\nFiles deleted: "+(r.files_deleted??0)+"\nFreed: "+fmtBytes(r.bytes_freed??0));
  refreshAll();
});

let timer=null;
function syncAutoRefresh(){
  clearInterval(timer); timer=null;
  if($("auto").checked){
    loadStats(); loadMessages();            // fire now, don't wait for the first interval
    timer=setInterval(()=>{ loadStats(); loadMessages(); }, parseInt($("interval").value,10)||5000);
  }
}
$("auto").addEventListener("change", syncAutoRefresh);
$("interval").addEventListener("change", syncAutoRefresh);   // re-arm at the new interval

// Theme: follows the OS by default; this toggle overrides for the session only
// (data-theme on <html>) — nothing is stored, so a full reload reverts to the OS.
function isDark(){
  const t = document.documentElement.dataset.theme;
  return t === "dark" || (t !== "light" && matchMedia("(prefers-color-scheme: dark)").matches);
}
function updateThemeBtn(){ $("theme").textContent = isDark() ? "☀ Light" : "☾ Dark"; }
$("theme").addEventListener("click", ()=>{
  document.documentElement.dataset.theme = isDark() ? "light" : "dark";
  updateThemeBtn();
});
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", updateThemeBtn);
updateThemeBtn();

refreshAll();
syncAutoRefresh();   // honor a browser-restored checked state on reload (no "flap" needed)
