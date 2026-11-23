// SX Helper DEMO: a pretend laptop inside the page. Every call the phone page makes is answered here,
// with a made-up show (10 movers), so every tab can be tried with no laptop, no ShowXpress and no lights.
(function(){
const nowS=()=>new Date().toISOString().slice(0,19);
const heads=[];for(let i=1;i<=10;i++)heads.push({id:String(i),num:i<=8?i:i-8,is140:i<=8,label:i<=8?'140 #'+i:'251 #'+(i-8)});
const st={sxOpen:false,hung:new Set(['1','2','3','4','5','6','9','10']),skip:new Set(['1','2','3','4','5','6','9','10']),
 color:{hex:'f4a6b8',name:'Blush'},assign:{'tl-l':'1','tl-r':'2','tr-l':'3','tr-r':'4','bl-l':'5','bl-r':'6'},extra:false,gd:nowS(),gi:'',
 auto:{bpm:124,order:'order',stop:'keep',clean:false,looks:[
  {id:'a1b2c3d4',name:'Floor sweep',bars:8,on:true,titles:['DF SWEEP','TONIGHTS COLOR','UPLIGHTS SLOW']},
  {id:'b1b2c3d4',name:'Around room',bars:16,on:true,titles:['AROUND ROOM','COLOR CHASE']},
  {id:'c1b2c3d4',name:'Grand entrance',bars:8,on:true,titles:['GRAND ENTRANCE','UPLIGHTS SLOW']}]},
 run:null,pressed:[],usbFixed:false,aims:{}};
const looks=[['white','ffffff'],['deep red','c00000'],['light green','8cff8c'],['yellow','ffee00'],['green','00c040'],['sky blue','6ec8ff'],['blue','1f3fff'],['purple','8a2be2']];
const slots=[];[['tl','Top left'],['tm','Top middle'],['tr','Top right'],['bl','Bottom left'],['bm','Bottom middle'],['br','Bottom right']].forEach(([t,n])=>['L','R'].forEach(s=>slots.push({key:t+'-'+s.toLowerCase(),tower:t,towerName:n,side:s,extra:t[1]==='m'})));
const btns=['DF SWEEP','DF CIRCLE','AROUND ROOM','AROUND ROOM SLOW','GRAND ENTRANCE','CHASE','SKIP AROUND','SKIP FLASH','BEAT 1','BEAT 2','TONIGHTS COLOR','COLOR CHASE','UPLIGHTS SLOW','UPLIGHTS FAST','STROBE','BLINDERS'];
const page=t=>/COLOR/.test(t)?'MOVER COLORS':/UPLIGHT/.test(t)?'UPLIGHTS':/STROBE|BLINDER/.test(t)?'STROBES':/CHASE|SKIP|BEAT/.test(t)?'CHASES':'MOVEMENTS';
const steps=(n,lit)=>Array.from({length:n},(_,i)=>({lit:lit[i%lit.length],other:false}));
function autoStatus(){const r=st.run;if(!r)return null;const L=st.auto.looks.filter(l=>l.on&&l.titles.length);if(!L.length)return null;
 const beat=60000/st.auto.bpm;let i=r.i,t0=r.t0;
 if(!r.held){for(;;){const len=L[i%L.length].bars*4*beat;if(Date.now()-t0<len)break;t0+=len;i++;}r.i=i%L.length;r.t0=t0;}
 const l=L[r.i],len=l.bars*4*beat,el=r.held?r.heldAt:Date.now()-r.t0,nx=L[(r.i+1)%L.length];
 return {running:true,name:l.name,lookId:l.id,next:nx.name,bars:l.bars,bar:Math.floor(el/(4*beat))+1,beat:Math.floor(el/beat)%4+1,bpm:st.auto.bpm,
  msLeft:Math.max(0,len-el),at:new Date().toISOString(),held:!!r.held,missing:[],error:''};}
const liveHeads=heads.slice(0,8).map((h,i)=>({id:h.id,label:h.label,is140:true,c:(st.aims[h.id]||[32768,20000]).slice(),k:[30000,18000],kSet:false,home:[32768,20000],dk:[-3000,-2500],
 deg:[540,270],addr:1+20*i,look:[[5,255]],dimI:5,shutI:6,order:i,tower:['Top left','Top right','Bottom left','Bottom right'][i>>1],side:'LR'[i%2],partner:heads[i^1].id,free:true,hung:true}));
const sets=()=>{let v={};try{v=JSON.parse(localStorage.getItem('sxh_demo_set')||'{}');}catch(e){}return Object.assign({tabOrder:[],tabHidden:[],reopen:true,autoUpd:true,driveFolder:''},v);};
const ok=(out,extra)=>Object.assign({ok:true,out:'  (demo) '+out,error:''},extra||{});
function route(p,b){b=b||{};
 switch(p){
 case '/api/sx':return {open:st.sxOpen,q:{items:[],reopen:true,done:null},live:false,auto:autoStatus(),pend:false,rem:null};
 case '/api/sx/launch':st.sxOpen=true;return ok('ShowXpress is starting');
 case '/api/sx/close':st.sxOpen=false;return ok('ShowXpress was asked to close');
 case '/api/update':return {ok:true,current:'1.6.0 (demo)',latest:'1.6.0',newer:false};
 case '/api/gdrive':return {ok:true,found:true,here:true,show:'Demo Show',target:'Google Drive > AWAAZ > Lighting > Demo Show',last:st.gd,srcFound:true,srcTime:st.gd,lastImport:st.gi,appFound:true,account:'',my:'',override:''};
 case '/api/gdrive/sync':st.gd=nowS();return ok('Copied 3 changed files to Google Drive');
 case '/api/gdrive/import':st.gi=nowS();return ok('Imported the show from Google Drive (the old one is kept as a backup)');
 case '/api/settings':return {ok:true,settings:sets(),ver:'demo'};
 case '/api/settings/set':{const v=sets();if(b.tabOrder)v.tabOrder=b.tabOrder;if(b.tabHidden)v.tabHidden=b.tabHidden;try{localStorage.setItem('sxh_demo_set',JSON.stringify(v));}catch(e){}return {ok:true,settings:v};}
 case '/api/remote':return {ok:true,ready:true,open:st.sxOpen,connected:st.sxOpen,pressed:st.pressed.map(t=>({title:t,page:page(t)})),titles:btns,setup:{}};
 case '/api/remote/press':st.pressed=b.solo?(b.titles||[]).slice():[...new Set(st.pressed.concat(b.titles||[]))];return {ok:true,ready:true,open:true,connected:true,pressed:st.pressed.map(t=>({title:t,page:page(t)}))};
 case '/api/remote/off':st.pressed=[];return {ok:true,ready:true,open:true,connected:true,pressed:[]};
 case '/api/remote/enable':return ok('Remote control is on');
 case '/api/rig':return {ok:true,show:'Demo Show',heads:heads.map(h=>Object.assign({},h,{on:st.hung.has(h.id)})),scenes:[
   {name:'CHASE',page:'CHASES',steps:steps(8,[['1'],['2'],['3'],['4'],['5'],['6'],['7'],['8']]),groups:[[0],[1],[2],[3],[4],[5],[6],[7]]},
   {name:'SKIP AROUND',page:'CHASES',steps:steps(6,[['1','3'],['2','4'],['5','7'],['6','8'],['9'],['10']]),groups:[[0],[1],[2],[3],[4],[5]]},
   {name:'BEAT 1',page:'CHASES',steps:steps(4,[['1','2'],['3','4'],['5','6'],['7','8']]),groups:[[0],[1],[2],[3]]}]};
 case '/api/rig/apply':st.hung=new Set(b.heads||[]);st.skip=new Set(b.heads||[]);return ok('Tonight\'s rig saved: '+st.hung.size+' heads hung\n  SKIP FLASH now flashes '+st.hung.size+' heads');
 case '/api/skip':return {ok:true,show:'Demo Show',heads:heads.map(h=>Object.assign({},h,{on:st.skip.has(h.id)})),order140:[1,3,5,7,2,4,6,8],order251:[1,2],stepCs:12};
 case '/api/skip/apply':st.skip=new Set(b.heads||[]);return ok('SKIP FLASH now flashes '+st.skip.size+' heads');
 case '/api/rt':return {ok:true,show:'Demo Show',install:{scene:true,button:true},heads:heads.slice(0,8).map((h,i)=>({id:h.id,num:h.num,look:looks[i][0],hex:looks[i][1],flash:false})),slots,assign:Object.assign({},st.assign),extra:st.extra};
 case '/api/rt/install':return ok('RIG ID added to the SETUP page');
 case '/api/rt/apply':{st.assign={};for(const k in (b.assign||{}))st.assign[k]=b.assign[k];st.extra=!!b.extra;const ids=Object.values(st.assign);
   if(b.rig){st.hung=new Set(ids.concat(['9','10']));st.skip=new Set(st.hung);}return ok('2D view saved: '+ids.length+' movers on trusses'+(b.rig?'\n  Tonight\'s Rig and SKIP FLASH updated':''));}
 case '/api/preview':return {ok:true,show:'Demo Show',targets:b.mode==='room'?['AROUND ROOM','AROUND ROOM SLOW']:[],install:{aim:true,check:true},
   heads:heads.map(h=>{const a=st.aims[h.id];return Object.assign({},h,{op:a?Math.round((a[0]-32768)/650):0,ot:a?Math.round((a[1]-20000)/650):0,sized:false,kp:100,kt:100,warn:'',copyFrom:''});})};
 case '/api/apply':return ok('Aims applied to 9 dancefloor movement scenes + CENTER SPOT');
 case '/api/home':st.aims={};return ok('Every head is back to its normal center and size');
 case '/api/aim/install':return ok('ROOM buttons added');
 case '/api/live/start':return {ok:true,iface:'DEMO - no lights move',test:true,info:{aimTitle:b.mode==='room'?'ROOM AIM (ADJUST)':'DF AIM (ADJUST)',heads:liveHeads.map(h=>Object.assign({},h,{c:(st.aims[h.id]||h.home).slice()}))}};
 case '/api/live/out':case '/api/live/stop':return {ok:true};
 case '/api/live/save':{let n=0;for(const id in (b.aims||{})){st.aims[id]=b.aims[id].c;n++;}return {ok:true,saved:true,applied:true,out:'  (demo) '+n+' aim(s) saved and applied',error:'',applyError:'',reopened:!!b.reopen};}
 case '/api/color':return {ok:true,hex:st.color.hex,name:st.color.name,washes:['Ovation'],
   wheel140:[['White','ffffff'],['Red','ff0000'],['Orange','ff8000'],['Yellow','ffff00'],['Green','00ff00'],['Light blue','80c0ff'],['Blue','0000ff'],['Pink','ff80c0'],['Magenta','ff00ff']].map(([name,hex])=>({name,hex})),
   wheel251:[['White','ffffff'],['Red','ff0000'],['Green','00ff00'],['Blue','0000ff'],['Magenta','ff00ff'],['Amber','ffb000']].map(([name,hex])=>({name,hex}))};
 case '/api/color/apply':st.color={hex:String(b.hex||'').replace('#','').toLowerCase(),name:b.name||''};return ok('TONIGHTS COLOR saved on MOVER COLORS and UPLIGHTS (#'+st.color.hex+')');
 case '/api/pre':return {ok:true,items:[
   {group:'Show',level:'ok',title:'Show found: Demo Show',detail:'',advice:''},
   {group:'Gear',level:'ok',title:'DMX interface connected (D512S)',detail:'',advice:''},
   {group:'Gear',level:'error',title:'APC mini not found',detail:'The pads and speed faders won’t work.',advice:'Plug in the APC mini (try another USB port), then restart ShowXpress so it picks it up.'},
   st.usbFixed?{group:'Laptop',level:'ok',title:'USB power saving is off',detail:'',advice:''}:
   {group:'Laptop',level:'warn',title:'USB power saving is on',detail:'Windows can switch off an idle USB port - the DMX interface or APC can drop out.',advice:'Turn it off.',fix:{key:'usb',label:'Turn USB power saving off'}},
   {group:'Laptop',level:'ok',title:'Plugged in, battery 100%',detail:'',advice:''}]};
 case '/api/pre/fix':st.usbFixed=true;return ok('USB power saving turned off');
 case '/api/health':return {ok:true,buttons:212,scenes:180,applied:[],issues:[{level:'warn',title:'BEAT 2 follows speed fader 7, which doesn’t exist',detail:'The fader on the APC does nothing for it.',advice:'Use CHASES (fader 4) like the other BEAT buttons.'}]};
 case '/api/health/fix':case '/api/health/revert':case '/api/health/keep':return ok('Done');
 case '/api/auto':return {ok:true,show:'Demo Show',ready:true,open:st.sxOpen,config:JSON.parse(JSON.stringify(st.auto)),
   buttons:btns.map(t=>({title:t,page:page(t),dup:false,reach:true,swap:page(t)==='MOVEMENTS'})),status:autoStatus()};
 case '/api/auto/save':st.auto=JSON.parse(JSON.stringify(b.config));return {ok:true,out:'',error:'',config:JSON.parse(JSON.stringify(st.auto))};
 case '/api/auto/status':return {ok:true,status:autoStatus()};
 case '/api/auto/start':{const L=st.auto.looks.filter(l=>l.on&&l.titles.length);const i=Math.max(0,L.findIndex(l=>l.id===b.look));st.run={i,t0:Date.now(),held:false};return {ok:true,status:autoStatus()};}
 case '/api/auto/stop':st.run=null;return {ok:true,status:{running:false,error:''}};
 case '/api/auto/cmd':{const r=st.run;if(!r)return {ok:false,error:'The Auto Show isn’t playing.'};const L=st.auto.looks.filter(l=>l.on&&l.titles.length);
   if(b.cmd==='next'){r.i=(r.i+1)%L.length;r.t0=Date.now();}else if(b.cmd==='prev'){r.i=(r.i+L.length-1)%L.length;r.t0=Date.now();}
   else if(b.cmd==='hold'){r.held=true;r.heldAt=Date.now()-r.t0;}else if(b.cmd==='resume'){r.held=false;r.t0=Date.now()-(r.heldAt||0);}
   else if(b.cmd==='sync'){r.t0=Date.now();}else if(b.cmd==='bpm'){st.auto.bpm=+b.v;}else if(b.cmd==='go'){const j=L.findIndex(l=>l.id===b.v);if(j>=0){r.i=j;r.t0=Date.now();}}
   return {ok:true,error:'',status:autoStatus()};}
 case '/api/apc':return {ok:false,error:'The APC mini tab isn’t in the demo - try it on the laptop.'};
 case '/api/speed':return {ok:false,error:'The Speed Faders tab isn’t in the demo - try it on the laptop.'};
 case '/api/queue/cancel':case '/api/queue/reopen':return {ok:true,q:{items:[],reopen:true,done:null}};
 case '/api/queue/seen':return {ok:true};
 }
 return {ok:false,error:'Not in the demo.'};}
const realFetch=window.fetch.bind(window);
window.fetch=async function(u,o){const url=new URL(String(u),location.href);if(!url.pathname.startsWith('/api/'))return realFetch(u,o);
 let b=null;try{b=o&&o.body?JSON.parse(o.body):null;}catch(e){}
 if(!b)b=Object.fromEntries(url.searchParams);
 await new Promise(r=>setTimeout(r,b&&b.l?5:180));
 return new Response(JSON.stringify(route(url.pathname,b)),{status:200,headers:{'Content-Type':'application/json'}});};
try{navigator.sendBeacon=()=>true;}catch(e){}
})();
