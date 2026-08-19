import {makeFCPXML} from './timeline.js'

const $ = id => document.getElementById(id)
const state = {file:null, url:'', duration:0, segments:[], issues:[], currentIssue:0, removeBreaths:true}
const demoText = ['大家好，今天我们来聊一个更高效的视频工作流。','首先导入素材，然后让程序自动识别语音。','呃，我刚才说错了，应该是自动生成字幕。','字幕会完整覆盖每一句语音的时长。','接着我们逐条确认口误，决定删除还是保留。','最后清理过长气口，并导出到达芬奇可用的时间线。']

function formatTime(seconds, frames = false){
  const safe = Math.max(0, Number(seconds)||0), h=Math.floor(safe/3600), m=Math.floor(safe%3600/60), s=Math.floor(safe%60)
  return frames ? [h,m,s,Math.floor(safe%1*25)].map(n=>String(n).padStart(2,'0')).join(':') : `${String(m+h*60).padStart(2,'0')}:${String(s).padStart(2,'0')}`
}

function importFile(file){
  if(!file?.type.startsWith('video/')) return toast('请选择视频文件')
  if(state.url) URL.revokeObjectURL(state.url)
  state.file=file; state.url=URL.createObjectURL(file)
  $('video').src=state.url; $('fileName').textContent=file.name; $('emptyState').hidden=true; $('workspace').hidden=false
  $('video').onloadedmetadata=()=>{state.duration=$('video').duration||30; $('durationBadge').textContent=formatTime(state.duration); $('exportButton').disabled=false; buildWaveform(); analyze()}
}

function analyze(){
  $('processing').hidden=false; $('reviewContent').hidden=true
  setTimeout(()=>{
    const usable=Math.max(12,state.duration), unit=usable/demoText.length
    state.segments=demoText.map((text,i)=>({id:crypto.randomUUID(),start:i*unit+.18,end:Math.min(usable,(i+1)*unit-.35),text,decision:'pending'}))
    state.issues=[state.segments[2]]; state.currentIssue=0
    $('processing').hidden=true; $('reviewContent').hidden=false; $('issueCount').textContent=state.issues.length
    renderAll(); toast('字幕分析完成；当前为可编辑演示转写')
  },900)
}

function buildWaveform(){
  $('waveform').innerHTML=Array.from({length:120},(_,i)=>`<i style="height:${9+Math.abs(Math.sin(i*.72))*31+Math.random()*8}px"></i>`).join('')
}

function renderAll(){renderIssue();renderTranscript();renderTrack()}
function renderIssue(){
  const issue=state.issues[state.currentIssue], decided=state.issues.filter(x=>x.decision!=='pending').length
  $('progressBadge').textContent=`${decided} / ${state.issues.length}`
  if(!issue){$('issueCard').innerHTML='<div class="done">✓ 所有疑似口误已确认<br><small>现在可以检查字幕并导出</small></div>'; $('keepButton').disabled=$('deleteButton').disabled=true;return}
  $('keepButton').disabled=$('deleteButton').disabled=false
  $('issueCard').innerHTML=`<div class="issue-time"><span>${formatTime(issue.start)} — ${formatTime(issue.end)}</span><button id="previewIssue">▶ 播放上下文</button></div><blockquote>${issue.text.replace('呃，我刚才说错了','<mark>呃，我刚才说错了</mark>')}</blockquote><span class="reason">检测原因：自我纠正词与无效语气词</span>`
  $('previewIssue').onclick=()=>{$('video').currentTime=Math.max(0,issue.start-1);$('video').play();setTimeout(()=>$('video').pause(),Math.max(1500,(issue.end-issue.start+2)*1000))}
}

function decide(decision){const issue=state.issues[state.currentIssue];if(!issue)return;issue.decision=decision;state.currentIssue++;renderAll();toast(decision==='delete'?'已标记删除':'已保留')}
function renderTranscript(){
  $('transcript').innerHTML=state.segments.map(s=>`<div class="caption-row ${s.decision==='delete'?'deleted':''}" data-id="${s.id}"><time>${formatTime(s.start)}</time><textarea aria-label="字幕内容">${s.text}</textarea><button title="删除字幕">×</button></div>`).join('')
  document.querySelectorAll('.caption-row').forEach(row=>{
    const segment=state.segments.find(s=>s.id===row.dataset.id)
    row.querySelector('textarea').onchange=e=>segment.text=e.target.value
    row.querySelector('time').onclick=()=>{$('video').currentTime=segment.start}
    row.querySelector('button').onclick=()=>{segment.decision=segment.decision==='delete'?'keep':'delete';renderAll()}
  })
}

function renderTrack(){
  $('clipTrack').innerHTML=state.segments.map(s=>`<span class="${s.decision==='delete'?'cut':''}" style="flex:${Math.max(.1,s.end-s.start)}" title="${s.text}"></span>`).join('')
}

function exportXML(){
  const xml=makeFCPXML({name:state.file.name,sourceUrl:new URL(state.file.name,location.href).href,duration:state.duration,segments:state.segments,removeBreaths:state.removeBreaths})
  const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([xml],{type:'application/xml'}));a.download=`${state.file.name.replace(/\.[^.]+$/,'')}-CutFlow.fcpxml`;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);toast('FCPXML 已导出')
}

let toastTimer
function toast(message){$('toast').textContent=message;$('toast').classList.add('show');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').classList.remove('show'),2200)}

$('fileInput').onchange=e=>importFile(e.target.files[0]);$('dropZone').ondragover=e=>{e.preventDefault();$('dropZone').classList.add('dragging')};$('dropZone').ondragleave=()=>$('dropZone').classList.remove('dragging');$('dropZone').ondrop=e=>{e.preventDefault();$('dropZone').classList.remove('dragging');importFile(e.dataTransfer.files[0])}
$('playButton').onclick=()=> $('video').paused?$('video').play():$('video').pause();$('backButton').onclick=()=>$('video').currentTime-=5;$('forwardButton').onclick=()=>$('video').currentTime+=5
$('video').ontimeupdate=()=>{$('timecode').textContent=`${formatTime($('video').currentTime,true)} / ${formatTime(state.duration,true)}`;$('playButton').textContent=$('video').paused?'▶':'❚❚'};$('video').onpause=$('video').onplay=()=>$('playButton').textContent=$('video').paused?'▶':'❚❚'
$('keepButton').onclick=()=>decide('keep');$('deleteButton').onclick=()=>decide('delete');$('breathToggle').onchange=e=>{state.removeBreaths=e.target.checked;toast(e.target.checked?'已开启删气口':'已保留原始停顿')};$('exportButton').onclick=exportXML
$('addCaption').onclick=()=>{const start=Math.min(state.duration,$('video').currentTime);state.segments.push({id:crypto.randomUUID(),start,end:Math.min(state.duration,start+2),text:'新字幕',decision:'keep'});renderAll()}
document.onkeydown=e=>{if(e.target.matches('textarea,input'))return;if(e.key.toLowerCase()==='k')decide('keep');if(e.key.toLowerCase()==='d')decide('delete')}
