import { busy, route } from './state';
type View={node:HTMLElement;classes:string;title:string;styles:string[];scroll:number};
const views=new Map<string,View>();
const loads=new Map<string,Promise<View>>();
const scripts=new Set<string>();
let active='',sequence=0,started=false;
const key=(url:URL)=>url.pathname==='/' || url.pathname==='/index.html'?'home':url.pathname==='/catalog' || url.pathname==='/catalog.html'?'games':url.pathname==='/studio'?'studio':null;
function capture(doc:Document,id:string):View {
  const node=document.createElement('div');node.dataset.appView=id;
  for(const child of [...doc.body.children]){
    if(child.id==='site-shell' || child.tagName==='SCRIPT')continue;
    node.append(child);
  }
  return {node,classes:doc.body.className,title:doc.title,styles:[...doc.querySelectorAll<HTMLLinkElement>('link[rel="stylesheet"]')].map(l=>new URL(l.getAttribute('href')!,location.origin).href),scroll:0};
}
async function load(url:URL,id:string):Promise<View>{
  if(views.has(id))return views.get(id)!;
  if(loads.has(id))return loads.get(id)!;
  const promise=(async()=>{
    const response=await fetch(url.pathname+url.search,{credentials:'same-origin'});
    const destination=new URL(response.url);
    if(destination.origin===location.origin && destination.pathname.startsWith('/auth/')){
      location.assign(destination.href);
      throw Error('Opening sign in…');
    }
    if(!response.ok)throw Error('Could not open this page. Try again.');
    const doc=new DOMParser().parseFromString(await response.text(),'text/html');
    const view=capture(doc,id);
    if(doc.body.dataset.cloud==='true')document.body.dataset.cloud='true';
    if(doc.body.dataset.local==='true')document.body.dataset.local='true';
    // Keep stylesheet order stable: shared shell rules always win.
    await Promise.all(view.styles.map(href=>{
      if([...document.querySelectorAll<HTMLLinkElement>('link[rel="stylesheet"]')].some(l=>l.href===href))return;
      return new Promise<void>((resolve,reject)=>{
        const link=document.createElement('link');link.rel='stylesheet';link.href=href;
        link.onload=()=>resolve();link.onerror=()=>reject(Error('Could not load this page.'));
        const shared=document.querySelector('link[href="/web/site.css"]');
        document.head.insertBefore(link,shared);
      });
    }));
    view.node.hidden=true;document.body.append(view.node);views.set(id,view);
    // Existing canvas/catalog controllers are mounted once, never replayed on
    // tab switches. This preserves strokes, undo history, filters and listeners.
    for(const old of doc.querySelectorAll<HTMLScriptElement>('script[src]')){
      const src=new URL(old.getAttribute('src')!,location.origin).href;
      if(scripts.has(src))continue;
      scripts.add(src);
      await new Promise<void>((resolve,reject)=>{
        const script=document.createElement('script');script.src=src;
        if(old.type)script.type=old.type;
        script.onload=()=>resolve();script.onerror=()=>reject(Error('Could not start this page.'));
        document.body.append(script);
      });
    }
    return view;
  })();
  loads.set(id,promise);
  try{return await promise;}catch(error){loads.delete(id);throw error;}
}
export async function navigate(href:string,replace=false):Promise<void>{
  const url=new URL(href,location.href),id=key(url);
  if(!started || !id || url.origin!==location.origin){location.assign(url);return;}
  const turn=++sequence;
  busy.set(true);
  try{
    const view=await load(url,id);
    if(turn!==sequence)return;
    const previous=views.get(active);if(previous)previous.scroll=window.scrollY;
    for(const [name,v] of views)v.node.hidden=name!==id;
    document.body.className=view.classes;
    for(const link of document.querySelectorAll<HTMLLinkElement>('link[rel="stylesheet"]'))link.disabled=!link.href.endsWith('/web/site.css') && !view.styles.includes(link.href);
    document.title=view.title;
    if(replace)history.replaceState(null,'',url);else if(url.href!==location.href)history.pushState(null,'',url);
    const moved=active!==id;active=id;route.set(url.pathname+url.hash);
    window.dispatchEvent(new HashChangeEvent('hashchange'));
    window.dispatchEvent(new CustomEvent('gamenight-page-change',{detail:{page:id}}));
    if(moved)window.scrollTo({top:view.scroll,behavior:'instant'});
  }catch(error){
    window.showToast(error instanceof Error?error.message:'Could not open this page. Try again.');
  }finally{if(turn===sequence)busy.set(false);}
}
export function startRouter(){
  const id=key(new URL(location.href));if(!id)return;
  started=true;
  for(const script of document.querySelectorAll<HTMLScriptElement>('script[src]'))scripts.add(script.src);
  const initial=capture(document,id);document.body.append(initial.node);views.set(id,initial);active=id;
  document.addEventListener('click',event=>{
    const anchor=(event.target as Element).closest?.('a');
    if(!anchor || event.defaultPrevented || event.button!==0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || anchor.download || (anchor.target && anchor.target!=='_self'))return;
    const url=new URL(anchor.href,location.href);
    if(url.origin!==location.origin || !key(url))return;
    // QR claims carry fresh credentials and deliberately reload the adapter.
    if(url.searchParams.has('claim') || url.searchParams.has('seat'))return;
    event.preventDefault();void navigate(url.href);
  });
  window.addEventListener('popstate',()=>void navigate(location.href,true));
  window.gamenightNavigate=navigate;
}
