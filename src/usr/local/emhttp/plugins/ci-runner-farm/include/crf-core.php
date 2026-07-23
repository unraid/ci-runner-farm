<?php
/* Shared CI Runner Farm web core — the crf* JS helpers, the @unraid/ui force-loader,
   and the shared .crf-* styles used by ALL three RunnerFarm tabs (Fleet/Image/
   Settings). include_once'd from the top of each tab so the dependency is EXPLICIT
   and load-order-independent, instead of living inside the Fleet tab and being
   relied on by document order (renaming crfPost or reordering the tab ordinals used
   to silently break the other tabs). Emitted once per document via include_once.
   Runs in the tab's scope, so $var (the CSRF token) is available. */
$crf_csrf = $var['csrf_token'] ?? '';
$crf_uui_base = '/plugins/dynamix.my.servers/unraid-components/uui/';
$crf_util_css = '';
foreach (glob('/usr/local/emhttp/plugins/dynamix.my.servers/unraid-components/standalone/standalone-apps-*.css') ?: [] as $f) {
  $crf_util_css = '/plugins/dynamix.my.servers/unraid-components/standalone/' . basename($f);
  break;
}
?>
<style>
  :root{--crf-ok:#4caf50;--crf-busy:var(--brand-orange,#ff8c2f);--crf-err:var(--brand-red,#e22828);--crf-info:var(--link-text-color,#29b6f6)}
  .crf-muted{color:var(--alt-text-color)}
  .crf-banner{margin:6px 0 8px;padding:10px 12px;border-radius:6px;font-size:13px;line-height:1.4}
  .crf-banner-sec{border:1px solid var(--crf-busy);background:color-mix(in srgb,var(--crf-busy) 12%,var(--background-color));color:var(--text-color);font-weight:bold}
  .crf-banner-warn{border:1px solid var(--crf-err);background:color-mix(in srgb,var(--crf-err) 12%,var(--background-color));color:var(--text-color)}
  .crf-banner-info{border:1px solid var(--crf-info);background:color-mix(in srgb,var(--crf-info) 10%,var(--background-color));color:var(--text-color)}
  uui-button:not(:defined),uui-brand-button:not(:defined){cursor:pointer;border:1px solid var(--border-color);border-radius:6px;padding:5px 12px;font-size:13px;color:var(--text-color)}
  .crf-toast{position:fixed;right:18px;bottom:48px;z-index:9999;background:var(--inverse-background-color,#222);color:var(--inverse-text-color,#fff);border:1px solid var(--border-color);border-radius:6px;padding:9px 16px;font-size:13px;opacity:0;transform:translateY(6px);transition:opacity .2s,transform .2s;pointer-events:none}
  .crf-toast-show{opacity:1;transform:none}
  .crf-ball{width:12px;height:12px;border-radius:50%;background:var(--disabled-text-color,#888);display:inline-block}
  .crf-ball-idle{background:var(--crf-ok)}
  .crf-ball-busy{background:var(--crf-busy);animation:crf-pulse 1.6s ease-in-out infinite}
  .crf-ball-error{background:var(--crf-err)}
  .crf-ball-starting{animation:crf-pulse 1.1s ease-in-out infinite}
  .crf-phase uui-badge:not(:defined){font-size:11px;color:var(--alt-text-color)}
  .crf-console{border:1px solid var(--border-color);border-radius:6px;overflow:hidden;margin:0 0 8px}
  .crf-console-head{display:flex;align-items:center;justify-content:space-between;padding:3px 6px 3px 12px;min-height:30px;box-sizing:border-box;background:var(--table-header-background-color);font-size:11px;color:var(--alt-text-color)}
  .crf-lg-dim{color:var(--alt-text-color)}
  .crf-lg-ok{color:var(--crf-ok)}
  .crf-lg-warn{color:var(--crf-busy)}
  .crf-lg-err{color:var(--crf-err)}
  .crf-console-body{white-space:pre-wrap;font-family:bitstream,monospace;font-size:12px;line-height:1.5;min-height:90px;max-height:200px;overflow:auto;background:var(--shade-bg-color,var(--background-color));color:var(--text-color);padding:6px 10px}
  .crf-builder-wrap textarea{width:100%;font-family:bitstream,monospace;font-size:12px;background:var(--input-bg-color);color:var(--text-color);border:1px solid var(--textarea-border-color,var(--input-border-color))}
  @keyframes crf-pulse{0%,100%{opacity:1}50%{opacity:.35}}
  @media (prefers-reduced-motion:reduce){.crf-ball-busy,.crf-ball-starting{animation:none}}
</style>
<script>
const CRF_CSRF = "<?=$crf_csrf?>";
const CRF_URL  = "/plugins/ci-runner-farm/include/exec.php";
const CRF_UUI_BASE = "<?=$crf_uui_base?>";
const CRF_UTIL_CSS = "<?=$crf_util_css?>";
function crfDark(){ return /Theme--(black|gray)\b/.test(document.documentElement.className); }
/* Force-register @unraid/ui (see header comment). Resolves both hashed asset
   names at runtime; merges the standalone Tailwind utilities (which the uui
   bundle ships without) with the uui tokens, rescoped for shadow DOM. */
window.CRF_UUI = (async () => {
  try {
    // Fetch the manifest and the standalone utility CSS concurrently: the util CSS URL is
    // resolved server-side (PHP glob) and doesn't depend on the manifest, so there's no
    // reason to await one before starting the other. Cuts a round-trip off first paint.
    const [man, utilCss] = await Promise.all([
      fetch(CRF_UUI_BASE + 'ui.manifest.json').then(r => r.json()),
      CRF_UTIL_CSS ? fetch(CRF_UTIL_CSS).then(r => r.text()) : Promise.resolve('')
    ]);
    // Distinguish a manifest SHAPE change (bundle updated, entries renamed) from an
    // absent bundle (fetch throws -> outer catch), so a future @unraid/ui update logs
    // an actionable message rather than a generic "unavailable".
    if (!(man['style.css'] && man['style.css'].file && man['src/register.ts'] && man['src/register.ts'].file)) {
      console.warn('ci-runner-farm: @unraid/ui manifest shape changed (style.css/register.ts entries missing) — bundle updated; using fallback. Update the crf-core.php loader.');
      return false;
    }
    // The uui stylesheet and the register.ts module are independent — fetch the CSS and
    // import the module concurrently, then merge + rescope for shadow DOM and register.
    const [uuiCss, mod] = await Promise.all([
      fetch(CRF_UUI_BASE + man['style.css'].file).then(r => r.text()),
      import(CRF_UUI_BASE + man['src/register.ts'].file)
    ]);
    const css = [utilCss, uuiCss].filter(Boolean).join('\n')
      .replace(/\.unapi\.dark\b/g, ':host(.dark)')
      .replace(/\.unapi\b/g, ':host')
      .replace(/:root\b/g, ':host')
      .replace(/\.dark\b/g, ':host(.dark)')
      + '\n:host([size="xs"]) .inline-flex{font-size:12px;line-height:1.2;padding:3px 10px;gap:4px}'
      + '\n:host(.crf-stat) [class~="p-4"]{padding:8px 14px}';
    mod.registerAllComponents({ sharedCssContent: css });
    if (crfDark()) document.querySelectorAll('uui-button,uui-brand-button,uui-badge,uui-card-wrapper').forEach(e => e.classList.add('dark'));
    return true;
  } catch (e) { console.warn('ci-runner-farm: @unraid/ui unavailable, using fallback styling', e); return false; }
})();
function crfPost(p){
  p.csrf_token = CRF_CSRF;
  return fetch(CRF_URL,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
    body:Object.entries(p).map(([k,v])=>encodeURIComponent(k)+'='+encodeURIComponent(v)).join('&')})
    .then(r=>r.text().then(t=>{
      // fetch() only rejects on network failure, not on 4xx/5xx — so an expired
      // CSRF token (403 after a reboot/array restart) or a backend 500 arrives
      // here with a JSON body that would otherwise parse and resolve as if it were
      // real data, making the fleet look empty and buttons silently no-op. Reject
      // instead, so callers' .catch paints "connection lost / reload".
      if(!r.ok) throw new Error('http '+r.status+(r.status===403?' — session expired, reload the page':'')+': '+t.slice(0,100));
      try{ return JSON.parse(t); }catch(e){ throw new Error('bad response for '+p.action+': '+t.slice(0,120)); }
    }));
}
/* Copy text to the clipboard, feature-detecting the async Clipboard API (absent
   in insecure contexts — Unraid's LAN webGUI is often plain HTTP, where
   navigator.clipboard is undefined and .writeText would throw synchronously) and
   falling back to execCommand('copy'). Shared by every tab (one document). */
function crfCopyText(t){
  const legacy=()=>new Promise((res,rej)=>{ try{ const ta=document.createElement('textarea'); ta.value=t; ta.setAttribute('readonly',''); ta.style.position='fixed'; ta.style.top='-1000px'; ta.style.opacity='0'; document.body.appendChild(ta); ta.select(); const ok=document.execCommand('copy'); document.body.removeChild(ta); ok?res():rej(new Error('copy rejected')); }catch(e){ rej(e); } });
  // Some browsers EXPOSE navigator.clipboard on a plain-HTTP LAN page but then REJECT
  // writeText (insecure/unfocused context) — so .catch the promise and fall through to
  // the execCommand textarea, rather than surfacing the rejection as "Copy failed".
  if(navigator.clipboard&&navigator.clipboard.writeText) return navigator.clipboard.writeText(t).catch(legacy);
  return legacy();
}
/* Copy the text content of an element to the clipboard, with button feedback. */
function crfCopyFrom(id, btn){
  const t=(document.getElementById(id)||{}).textContent||'';
  crfCopyText(t).then(()=>{ const o=btn.textContent; btn.textContent='Copied'; setTimeout(()=>btn.textContent=o,1500); }).catch(()=>{ const o=btn.textContent; btn.textContent='Copy failed'; setTimeout(()=>btn.textContent=o,1500); });
}
function crfEsc(s){ return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
/* Semantic log tinting: escape first, then dim structural prefixes and tint
   error/warn lines and known lifecycle phrases. Applies to both consoles. */
function crfColorize(t){
  return String(t||'').split('\n').map(line=>{
    let l=crfEsc(line);
    l=l.replace(/^(\[ci-runner-farm\]|\d{4}-\d{2}-\d{2}[T ][\d:.]+Z?|#\d+\s)/,'<span class="crf-lg-dim">$1</span>');
    if(/error|fatal|failed|failure/i.test(line)) return '<span class="crf-lg-err">'+l+'</span>';
    if(/warn/i.test(line)) return '<span class="crf-lg-warn">'+l+'</span>';
    l=l.replace(/\b(shrink by \d+|removing idle [\w-]+|deregistered [\w-]+|reaping [\w-]+|stopping|stopped)\b/gi,'<span class="crf-lg-warn">$1</span>');
    l=l.replace(/\b(grow to \d+|daemon up|started|registered|Listening for Jobs|successfully|DONE|CACHED|FINISHED|build complete)\b/gi,'<span class="crf-lg-ok">$1</span>');
    return l;
  }).join('\n');
}
function crfToast(msg){
  let t=document.getElementById('crf-toast');
  if(!t){ t=document.createElement('div'); t.id='crf-toast'; t.className='crf-toast'; document.body.appendChild(t); }
  t.textContent=msg; t.classList.add('crf-toast-show');
  clearTimeout(t._h); t._h=setTimeout(()=>t.classList.remove('crf-toast-show'),2600);
}
</script>
