import Foundation

enum MobileUploadPage {
    static func html(expiresAt: Date, targetName: String) -> String {
        let formatter = ISO8601DateFormatter()
        let expires = formatter.string(from: expiresAt)
        let escapedTarget = escapeHTML(targetName)
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
          <title>Codex Phone Upload</title>
          <style>
            :root{color-scheme:light;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#172033;background:#fff}
            *{box-sizing:border-box}
            body{margin:0;background:#fff}
            button,select{font:inherit}
            main{width:min(100%,560px);margin:0 auto;padding:calc(18px + env(safe-area-inset-top)) 22px calc(22px + env(safe-area-inset-bottom))}
            header{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:24px}
            h1{margin:0;font-size:24px;line-height:1.2;letter-spacing:-.02em;white-space:nowrap}
            .language{min-height:44px;border:0;background:transparent;color:#273247;padding:0 4px;font-weight:600}
            .eyebrow{margin:0 0 10px;color:#616b7a;font-size:14px;font-weight:650}
            .target{display:flex;align-items:center;min-height:58px;padding:10px 14px;border:1px solid #d9dee8;border-radius:12px;background:#fff}
            .target-name{min-width:0;flex:1;font-size:16px;font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
            .selection-head{display:flex;align-items:center;justify-content:space-between;gap:14px;margin-top:24px;padding-bottom:10px;border-bottom:1px solid #e1e5ec}
            #selectionCount{font-size:18px;font-weight:650}
            .link-button{min-height:44px;border:0;background:transparent;color:#1769e0;font-weight:650;padding:0}
            #images{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}
            #queue{list-style:none;padding:0;margin:0}
            .empty{padding:34px 8px;text-align:center;color:#697384;line-height:1.55;border-bottom:1px solid #e1e5ec}
            .file-row{display:grid;grid-template-columns:48px minmax(0,1fr) auto;align-items:center;gap:10px;min-height:66px;border-bottom:1px solid #e1e5ec}
            .thumb{width:48px;height:48px;border-radius:8px;object-fit:cover;background:#f0f3f8;border:1px solid #e1e5ec}
            .file-main{min-width:0}
            .file-name{font-size:15px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
            .file-meta{margin-top:5px;color:#727c8b;font-size:13px}
            .row-actions{display:flex;align-items:center;gap:7px;color:#5c6675}
            .ready{font-size:13px;color:#16834b;white-space:nowrap}
            .remove{min-width:44px;min-height:44px;border:0;background:transparent;color:#5c6675;font-size:13px;font-weight:600}
            .notice{display:flex;gap:9px;align-items:flex-start;margin:18px 0 10px;color:#697384;font-size:14px;line-height:1.45}
            .network-notice{margin:0 0 12px;padding:10px 12px;border-radius:10px;background:#fff7e6;color:#805500;font-size:13px;line-height:1.45}
            #status{margin:0;color:#1769e0;font-size:14px;line-height:1.5}
            #status:not(:empty){min-height:24px;margin-bottom:10px}
            #status.error{color:#b42318}
            #status.success{color:#16834b}
            #submit{width:100%;min-height:52px;border:0;border-radius:13px;background:#1769e0;color:#fff;font-size:17px;font-weight:700}
            #submit:disabled{opacity:.45}
            .limits{margin-top:12px;color:#747e8d;font-size:13px;line-height:1.5}
            @media(max-width:380px){main{padding-left:18px;padding-right:18px}.ready{display:none}}
          </style>
        </head>
        <body>
        <main>
          <header>
            <h1 data-i18n="title">Send images to Codex</h1>
            <select id="language" class="language" aria-label="Language">
              <option value="zh-Hans">中文</option>
              <option value="en">English</option>
            </select>
          </header>
          <section aria-labelledby="targetLabel">
            <p id="targetLabel" class="eyebrow" data-i18n="targetLabel">Target task</p>
            <div class="target">
              <span class="target-name" title="\(escapedTarget)">\(escapedTarget)</span>
            </div>
          </section>
          <form id="form" method="post" enctype="multipart/form-data">
            <input id="images" name="images" type="file" accept="image/*,.heic,.heif" multiple required>
            <div class="selection-head">
              <span id="selectionCount" data-i18n="noSelection">No images selected</span>
              <button id="choose" class="link-button" type="button" data-i18n="choose">Choose images</button>
            </div>
            <ul id="queue"><li class="empty" data-i18n="empty">Choose screenshots or photos from your phone.</li></ul>
            <div class="notice"><span data-i18n="notice">Images are placed in the composer and are not sent automatically.</span></div>
            <div class="network-notice" data-i18n="networkNotice">Local transfer uses unencrypted HTTP. Use only on a trusted Wi-Fi network.</div>
            <div id="status" role="status" aria-live="polite"></div>
            <button id="submit" type="submit" disabled data-i18n="submit">Upload to Codex</button>
          </form>
          <div class="limits">
            <div data-i18n="limits">Up to 12 images · 25 MB each · 100 MB total</div>
            <div><span data-i18n="expires">Link expires at</span> <time id="expiry" datetime="\(expires)"></time></div>
          </div>
        </main>
        <script>
        const MAX_FILES=12,MAX_FILE_BYTES=25*1024*1024,MAX_TOTAL_BYTES=100*1024*1024,PREVIEW_QUEUE=new URLSearchParams(location.search).get('preview')==='queue';
        const expiresAt=new Date('\(expires)');
        const copy={
          en:{title:'Send images to Codex',targetLabel:'Target task',noSelection:'Select at least one image.',unsupported:'Only PNG, JPEG, GIF, WebP, HEIC, and HEIF images are supported.',selected:n=>`${n} image${n===1?'':'s'} selected`,choose:'Choose images',more:'Choose more',empty:'Choose screenshots or photos from your phone.',ready:'Ready',notice:'Images are placed in the composer and are not sent automatically.',networkNotice:'Local transfer uses unencrypted HTTP. Use only on a trusted Wi-Fi network.',submit:'Upload to Codex',uploading:p=>`Uploading… ${p}%`,attaching:'Upload complete. Attaching images to Codex…',success:n=>`${n} image${n===1?' was':'s were'} attached. You can choose another batch.`,partial:(a,r)=>`${a} attached. Continue with the remaining ${r}.`,failure:'Upload failed. Try again.',tooMany:`Choose up to ${MAX_FILES} images.`,tooLarge:'Each image must be 25 MB or smaller.',totalTooLarge:'The selected images must total 100 MB or less.',limits:'Up to 12 images · 25 MB each · 100 MB total',expires:'Link expires at',remove:'Remove'},
          'zh-Hans':{title:'传图片到 Codex',targetLabel:'目标任务',noSelection:'请至少选择一张图片。',unsupported:'只支持 PNG、JPEG、GIF、WebP、HEIC 和 HEIF 图片。',selected:n=>`已选择 ${n} 张`,choose:'选择图片',more:'继续选择',empty:'从手机中选择截图或照片。',ready:'已就绪',notice:'图片只会放入输入框，不会自动发送。',networkNotice:'局域网传输使用未加密的 HTTP，请仅在可信 Wi-Fi 下使用。',submit:'上传到 Codex',uploading:p=>`正在上传… ${p}%`,attaching:'上传完成，正在放入 Codex…',success:n=>`已放入 ${n} 张，可以继续选择下一批。`,partial:(a,r)=>`已放入 ${a} 张，请继续上传剩余 ${r} 张。`,failure:'上传失败，请重试。',tooMany:`一次最多选择 ${MAX_FILES} 张图片。`,tooLarge:'单张图片不能超过 25 MB。',totalTooLarge:'所选图片总计不能超过 100 MB。',limits:'最多 12 张 · 每张 25 MB · 总计 100 MB',expires:'链接失效时间',remove:'移除'}
        };
        const form=document.getElementById('form'),input=document.getElementById('images'),choose=document.getElementById('choose'),queue=document.getElementById('queue'),count=document.getElementById('selectionCount'),submit=document.getElementById('submit'),status=document.getElementById('status'),language=document.getElementById('language'),expiry=document.getElementById('expiry');
        let files=[],urls=[],lang=localStorage.getItem('codex-phone-upload-language')||(navigator.language.toLowerCase().startsWith('zh')?'zh-Hans':'en');
        if(!copy[lang])lang='en';language.value=lang;
        const text=()=>copy[lang];
        const formatSize=bytes=>bytes<1024*1024?`${Math.max(1,Math.round(bytes/1024))} KB`:`${(bytes/1024/1024).toFixed(1)} MB`;
        const supported=file=>['image/png','image/jpeg','image/gif','image/webp','image/heic','image/heif'].includes((file.type||'').toLowerCase())||/\\.(png|jpe?g|gif|webp|heic|heif)$/i.test(file.name||'');
        const setStatus=(message,type='')=>{status.textContent=message;status.className=type};
        function translate(){document.documentElement.lang=lang==='zh-Hans'?'zh-CN':'en';document.querySelectorAll('[data-i18n]').forEach(node=>{const value=text()[node.dataset.i18n];if(typeof value==='string')node.textContent=value});expiry.textContent=new Intl.DateTimeFormat(lang==='zh-Hans'?'zh-CN':'en',{hour:'2-digit',minute:'2-digit'}).format(expiresAt);render()}
        function render(){urls.forEach(URL.revokeObjectURL);urls=[];count.textContent=files.length?text().selected(files.length):text().noSelection;choose.textContent=files.length?text().more:text().choose;submit.disabled=!files.length||PREVIEW_QUEUE;choose.disabled=PREVIEW_QUEUE;queue.innerHTML='';if(!files.length){const item=document.createElement('li');item.className='empty';item.textContent=text().empty;queue.append(item);return}files.forEach((file,index)=>{const item=document.createElement('li');item.className='file-row';const image=document.createElement('img');image.className='thumb';image.alt='';if(PREVIEW_QUEUE){image.src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAACXBIWXMAAAABAAAAAQBPJcTWAAAAEUlEQVR4nGO4+fIPVsQwtCQAigSvgao0JOYAAAAASUVORK5CYII='}else{try{const url=URL.createObjectURL(file);urls.push(url);image.src=url}catch{image.hidden=true}}const main=document.createElement('div');main.className='file-main';const name=document.createElement('div');name.className='file-name';name.textContent=file.name||`image-${index+1}`;const meta=document.createElement('div');meta.className='file-meta';meta.textContent=formatSize(file.size);main.append(name,meta);const actions=document.createElement('div');actions.className='row-actions';const ready=document.createElement('span');ready.className='ready';ready.textContent=text().ready;const remove=document.createElement('button');remove.type='button';remove.className='remove';remove.setAttribute('aria-label',`${text().remove} ${name.textContent}`);remove.textContent=text().remove;remove.disabled=PREVIEW_QUEUE;remove.addEventListener('click',()=>{files.splice(index,1);setStatus('');render()});actions.append(ready,remove);item.append(image,main,actions);queue.append(item)})}
        function addFiles(next){const combined=[...files,...next];if(combined.length>MAX_FILES){setStatus(text().tooMany,'error');return}if(combined.some(file=>!supported(file))){setStatus(text().unsupported,'error');return}if(combined.some(file=>file.size>MAX_FILE_BYTES)){setStatus(text().tooLarge,'error');return}if(combined.reduce((sum,file)=>sum+file.size,0)>MAX_TOTAL_BYTES){setStatus(text().totalTooLarge,'error');return}files=combined;setStatus('');render()}
        choose.addEventListener('click',()=>input.click());input.addEventListener('change',()=>addFiles([...input.files]));language.addEventListener('change',()=>{lang=language.value;localStorage.setItem('codex-phone-upload-language',lang);translate()});
        form.addEventListener('submit',event=>{event.preventDefault();if(!files.length)return;submit.disabled=true;choose.disabled=true;const data=new FormData();files.forEach(file=>data.append('images',file,file.name));const request=new XMLHttpRequest();request.open('POST',location.pathname);request.setRequestHeader('Accept-Language',lang);request.upload.onprogress=event=>{if(event.lengthComputable)setStatus(text().uploading(Math.round(event.loaded/event.total*100)))};request.upload.onload=()=>setStatus(text().attaching);request.onload=()=>{let result={};try{result=JSON.parse(request.responseText)}catch{}if(request.status>=200&&request.status<300){const uploaded=Number(result.count||files.length);files=[];input.value='';render();setStatus(text().success(uploaded),'success');return}const attached=Number(result.attached||0);if(attached>0){files=files.slice(attached);render();setStatus(text().partial(attached,files.length),'error')}else{const localized=result.code&&text()[result.code];setStatus(typeof localized==='string'?localized:(result.error||text().failure),'error')}submit.disabled=!files.length;choose.disabled=false};request.onerror=()=>{setStatus(text().failure,'error');submit.disabled=false;choose.disabled=false};request.send(data)});
        translate();
        if(PREVIEW_QUEUE){const raw=atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z3iUAAAAASUVORK5CYII=');const png=Uint8Array.from(raw,char=>char.charCodeAt(0));const sizes=[1887436,2411725,1677721,2097152,1572864,1782579];addFiles(sizes.map((size,index)=>new File([png,new Uint8Array(size-png.length)],`android-feedback-${index+1}.png`,{type:'image/png'})))}
        </script>
        </body></html>
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

}
