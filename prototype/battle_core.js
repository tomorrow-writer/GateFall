// Battle core: pure simulation, no drawing. Units live on a 480x240 field.
function makeCfg(o){return Object.assign({
  slimeHp:30, slimeAtk:5, slimeCd:1.0, slimeSpd:28,
  split:2, miniPct:26,               // pieces per split, mini strength as % of big slime
  knightHp:40, knightAtk:7, knightCd:1.1, knightSpd:24,
  mode:'charge',                       // charge | hold
  form:'line',                         // line | wedge | square | crescent
  auto:false,                          // auto-cast special (used by the batch test)
  waveDmg:3, mpCost:70
},o||{})}
const FORMS={
  line:{atk:1,take:1,spd:1},
  wedge:{atk:1.12,take:1.1,spd:1.1},
  square:{atk:1,take:0.86,spd:0.75},
  crescent:{atk:0.96,take:1.08,spd:1,flank:1.1}
};
function formSpots(form){
  const P=[];
  if(form==='wedge'){const cols=[[150,1],[126,2],[102,3],[78,4]];for(const [x,n] of cols)for(let i=0;i<n;i++)P.push([x,178+(i-(n-1)/2)*26])}
  else if(form==='square'){for(let r=0;r<4;r++)for(let c=0;c<3;c++)if(P.length<10)P.push([92+c*22,146+r*22+(r===3?0:0)]);P.push([114,234-2]);P.length=10}
  else if(form==='crescent'){for(let i=0;i<10;i++){const a=-1.25+i*(2.5/9);P.push([78+Math.abs(Math.sin(a))*58,178+Math.sin(a)*56])}}
  else{for(let i=0;i<10;i++)P.push([84+Math.floor(i/5)*26,128+(i%5)*24])}
  return P;
}
function newBattle(cfg,rng){
  rng=rng||Math.random;
  const U=[];let id=0;
  const spots=formSpots(cfg.form);
  for(let i=0;i<10;i++){
    const r=i%5,c=Math.floor(i/5);
    U.push({id:id++,side:'S',kind:'big',x:spots[i][0]+rng()*3,y:Math.max(118,Math.min(232,spots[i][1]+rng()*3)),hp:cfg.slimeHp,max:cfg.slimeHp,atk:cfg.slimeAtk,cd:cfg.slimeCd,spd:cfg.slimeSpd,reach:25,t:rng()*0.6,tg:null,re:0,fx:0,anim:rng()*6,alive:true});
    U.push({id:id++,side:'K',kind:'knight',x:396-c*26-rng()*4,y:128+r*24+rng()*4,hp:cfg.knightHp,max:cfg.knightHp,atk:cfg.knightAtk,cd:cfg.knightCd,spd:cfg.knightSpd,reach:25,t:rng()*0.6,tg:null,re:0,fx:0,anim:rng()*6,alive:true});
  }
  return {U,cfg,time:0,over:null,nextId:id,rng,events:[],mp:30,wave:null};
}
function count(B){let big=0,mini=0,k=0;for(const u of B.U)if(u.alive){if(u.side==='K')k++;else if(u.kind==='big')big++;else mini++}return {big,mini,k}}
function step(B,dt){
  if(B.over)return;
  const {cfg,rng}=B;B.time+=dt;
  const live=B.U.filter(u=>u.alive);
  const F=FORMS[cfg.form]||FORMS.line;
  B.mp=Math.min(100,B.mp+dt*(cfg.mode==='hold'?4.5:4));
  if(cfg.auto&&B.mp>=cfg.mpCost&&B.time>3&&!B.wave)cast(B);
  if(B.wave)stepWave(B,dt,live);
  const engaged={};for(const u of live)if(u.side==='S'&&u.tg&&u.tg.alive)engaged[u.tg.id]=(engaged[u.tg.id]||0)+1;
  for(const u of live){
    u.anim+=dt;u.fx=Math.max(0,u.fx-dt);u.t-=dt;u.re-=dt;
    if(!u.tg||!u.tg.alive||u.re<=0){
      let best=null,bd=1e9;
      for(const v of live)if(v.side!==u.side&&v.alive){const d=(v.x-u.x)**2+((v.y-u.y)*1.8)**2;if(d<bd){bd=d;best=v}}
      u.tg=best;u.re=0.3+rng()*0.2;
    }
    const v=u.tg;if(!v)continue;
    const dx=v.x-u.x,dy=v.y-u.y,d=Math.hypot(dx,dy)||1;
    const hold=u.side==='S'&&cfg.mode==='hold';
    if(d>u.reach){
      if(hold&&d>70){u.walking=false;continue}
      const sp=u.spd*(u.side==='S'?F.spd:1);const my=dy*0.6,dm=Math.hypot(dx,my)||1;u.x+=dx/dm*sp*dt;u.y+=my/dm*sp*dt;u.walking=true;
    }else{
      u.walking=false;
      if(u.t<=0){
        u.t=u.cd*(0.85+rng()*0.3);u.swing=0.25;
        let dmg=u.atk*(0.8+rng()*0.4);
        if(u.side==='S'&&cfg.mode==='charge')dmg*=1.15;
        if(v.side==='S'&&cfg.mode==='hold')dmg*=0.85;
        if(u.side==='S'){dmg*=F.atk;if(F.flank&&engaged[v.id]>=2)dmg*=F.flank}
        if(v.side==='S')dmg*=F.take;
        v.hp-=dmg;v.fx=0.15;
        B.events.push({type:'hit',x:v.x,y:v.y,side:v.side});
        if(v.hp<=0)kill(B,v);
      }
    }
    if(u.swing)u.swing=Math.max(0,u.swing-dt);
  }
  // separation
  for(let i=0;i<live.length;i++){const a=live[i];if(!a.alive)continue;
    for(let j=i+1;j<live.length;j++){const b=live[j];if(!b.alive)continue;
      const ra=a.kind==='mini'?7:a.side==='K'?10:11,rb=b.kind==='mini'?7:b.side==='K'?10:11,min=ra+rb;
      const dx=b.x-a.x,dy=b.y-a.y,d2=dx*dx+dy*dy;
      if(d2<min*min&&d2>0.0001){const d=Math.sqrt(d2),p=(min-d)/2;a.x-=dx/d*p;a.y-=dy/d*p;b.x+=dx/d*p;b.y+=dy/d*p}}
    a.y=Math.max(118,Math.min(232,a.y));a.x=Math.max(10,Math.min(470,a.x));}
  const c=count(B);
  if(c.k===0)B.over='S';else if(c.big+c.mini===0)B.over='K';else if(B.time>180)B.over='draw';
}
function cast(B){
  if(B.over||B.wave||B.mp<B.cfg.mpCost)return false;
  B.mp-=B.cfg.mpCost;B.wave={x:30,hit:new Set()};B.events.push({type:'cast'});return true;
}
function stepWave(B,dt,live){
  const w=B.wave;w.x+=340*dt;
  for(const u of live)if(u.side==='K'&&u.alive&&!w.hit.has(u.id)&&u.x<w.x&&u.x>w.x-40){
    w.hit.add(u.id);u.hp-=B.cfg.waveDmg;u.fx=0.3;
    B.events.push({type:'wavehit',x:u.x,y:u.y});
    if(u.hp<=0)kill(B,u);
  }
  if(w.x>520)B.wave=null;
}
function kill(B,v){
  v.alive=false;
  B.events.push({type:'die',x:v.x,y:v.y,side:v.side,kind:v.kind});
  if(v.side==='S'&&v.kind==='big'){
    const p=B.cfg.miniPct/100,n=B.cfg.split;
    for(let i=0;i<n;i++){
      const a=(i/n)*Math.PI*2+B.rng();
      B.U.push({id:B.nextId++,side:'S',kind:'mini',x:v.x+Math.cos(a)*10,y:v.y+Math.sin(a)*8,hp:B.cfg.slimeHp*p,max:B.cfg.slimeHp*p,
        atk:B.cfg.slimeAtk*p,cd:B.cfg.slimeCd*0.8,spd:B.cfg.slimeSpd*1.25,reach:19,t:0.5+B.rng()*0.4,tg:null,re:0,fx:0,anim:B.rng()*6,alive:true,born:0.4,
        bx:v.x,by:v.y});
    }
  }
}
function simulate(cfg,n,seed){
  let s=seed||1;const rng=()=>((s=(s*16807)%2147483647)/2147483647);
  let win=0,time=0,surv=0,sk=0;
  for(let i=0;i<n;i++){const B=newBattle(cfg,rng);while(!B.over){step(B,1/15);B.events.length=0}
    const c=count(B);if(B.over==='S'){win++;surv+=c.big+c.mini}else sk+=c.k;time+=B.time}
  return {win:win/n,time:time/n,survS:win?surv/win:0,survK:n-win?sk/(n-win):0};
}
if(typeof module!=='undefined')module.exports={makeCfg,newBattle,step,count,simulate,cast,formSpots};
