/* Pure local-preview state and text rendering. No network or filesystem access. */
(function (root) {
  'use strict';
  const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const defaultInstructions='Keep my natural voice. Write clearly and concisely, using familiar words.\nPreserve my language, meaning and tone. Avoid canned phrases, inflated adjectives and invented content.';
  const instructionByteCount=text=>new TextEncoder().encode(text).length;
  function freshState(now = Date.now()) {
    return {
      version: 1, tab: 'Dot', draft: '', messages: [], conversations: [], runtime: 'Director',
      socialDrafts: [''], replyDrafts: {}, following: ['lin'], likes: [], reposts: [],
      posts: [
        {id:'sample-1', author:'lin', text:'The best part of keeping notes in Markdown: your ideas can outlive the app.\n\nSmall files. Long memory.', createdAt:now-12*60000, parent:null},
        {id:'sample-2', author:'ada', text:'A useful agent tells you what it did, what it learned, and where it stopped.\n\nThe last part deserves more attention.', createdAt:now-29*60000, parent:null},
        {id:'sample-3', author:'theo', text:'Working on a quieter workspace. One place to think, speak, write, and keep the thread.', createdAt:now-51*60000, parent:null},
        {id:'sample-4', author:'ada', text:'And plain text is remarkably good at surviving a product roadmap.', createdAt:now-8*60000, parent:'sample-1'}
      ],
      notes:[
        {id:'welcome', title:'A place to think', body:'# A place to think\n\nA few good ideas, with room between them.\n\n- Write in plain Markdown.\n- Connect a thought with [[Field notes]].\n- Make time for [[This week]].\n\n> Keep the file. Change the tool.\n\n#ideas #workspace'},
        {id:'field', title:'Field notes', body:'# Field notes\n\n**Observation:** the best systems leave you room to think.\n\nA note grows more useful when it connects to [[A place to think]].\n\n## Something to try\n\n- [ ] Write down the question before the answer.\n- [x] Keep the original wording.\n\n#ideas'},
        {id:'week', title:'This week', body:'# This week\n\n## One thing worth finishing\n\nBring the five spaces together: Dot, Speak, Social, .md, and Me.\n\nSee [[Field notes]] for the thinking behind it.\n\n#work #weekly'}
      ],
      activeNote:'welcome', noteMode:'preview', noteQuery:'', transcript:'', beforeCleanup:null, keyboardText:'',
      connections:[], speakInstructions:defaultInstructions, speakInstructionDraft:defaultInstructions, speakRewriteRoute:'localOnly', learning:'Ask Me', preference:'', learningProposal:true
    };
  }
  function restoreState(raw, now) {
    const base = freshState(now);
    if (!raw || raw.version !== 1) return base;
    const stringFields = ['draft','runtime','activeNote','noteQuery','transcript','keyboardText','preference','speakInstructionDraft'];
    for (const key of stringFields) if (typeof raw[key] === 'string') base[key] = raw[key];
    if (['Dot','Speak','Social','.md','Me'].includes(raw.tab)) base.tab = raw.tab;
    if (['edit','preview'].includes(raw.noteMode)) base.noteMode = raw.noteMode;
    if (typeof raw.speakInstructions==='string' && instructionByteCount(raw.speakInstructions)<=8192) base.speakInstructions=raw.speakInstructions;
    if (['localOnly','privateCloudOnly','localWithCloudFallback'].includes(raw.speakRewriteRoute)) base.speakRewriteRoute=raw.speakRewriteRoute;
    if (['Off','Ask Me','Automatic'].includes(raw.learning)) base.learning = raw.learning;
    if (typeof raw.learningProposal === 'boolean') base.learningProposal = raw.learningProposal;
    if (raw.beforeCleanup === null || typeof raw.beforeCleanup === 'string') base.beforeCleanup = raw.beforeCleanup;
    for (const key of ['following','likes','reposts']) if (Array.isArray(raw[key])) base[key] = raw[key].filter(v=>typeof v==='string');
    if (Array.isArray(raw.socialDrafts) && raw.socialDrafts.length) base.socialDrafts=raw.socialDrafts.filter(v=>typeof v==='string').slice(0,8);
    if (!base.socialDrafts.length) base.socialDrafts=[''];
    if (raw.replyDrafts && typeof raw.replyDrafts==='object') base.replyDrafts=Object.fromEntries(Object.entries(raw.replyDrafts).filter(([k,v])=>typeof v==='string'));
    if (Array.isArray(raw.messages)) base.messages=raw.messages.filter(m=>m && ['user','assistant'].includes(m.role) && typeof m.text==='string');
    if (Array.isArray(raw.conversations)) base.conversations=raw.conversations.filter(c=>c && typeof c.id==='string' && typeof c.title==='string' && Array.isArray(c.messages)).map(c=>({...c,messages:c.messages.filter(m=>m && ['user','assistant'].includes(m.role) && typeof m.text==='string')}));
    if (Array.isArray(raw.posts)) base.posts=raw.posts.filter(p=>p && typeof p.id==='string' && typeof p.author==='string' && typeof p.text==='string' && Number.isFinite(p.createdAt) && (p.parent===null || typeof p.parent==='string'));
    if (Array.isArray(raw.notes) && raw.notes.length) base.notes=raw.notes.filter(n=>n && typeof n.id==='string' && typeof n.title==='string' && typeof n.body==='string');
    if (!base.notes.length) base.notes=freshState(now).notes;
    if (!base.notes.some(n=>n.id===base.activeNote)) base.activeNote=base.notes[0].id;
    if (Array.isArray(raw.connections)) base.connections=raw.connections.filter(c=>c && typeof c.id==='string' && typeof c.name==='string' && typeof c.host==='string' && typeof c.user==='string' && Number.isInteger(c.port) && c.port>0 && c.port<65536);
    return base;
  }
  const links = body => [...body.matchAll(/\[\[([^\]\n]+)\]\]/g)].map(m=>m[1]);
  const tags = body => [...new Set([...body.matchAll(/(?:^|\s)#([\p{L}\p{N}_/-]+)/gu)].map(m=>m[1]))];
  const backlinks = (notes, title) => notes.filter(n=>links(n.body).some(link=>link.toLowerCase()===title.toLowerCase()));
  const filteredNotes = (notes, query) => notes.filter(n=>(n.title+'\n'+n.body).toLowerCase().includes(query.toLowerCase().trim()));
  function inline(text) {
    const token = /(`[^`]+`|\[\[[^\]\n]+\]\]|\[[^\]\n]+\]\([^\s)]+\)|\*\*[^*]+\*\*|\*[^*]+\*)/g;
    let out='', at=0;
    for (const m of text.matchAll(token)) {
      out+=esc(text.slice(at,m.index)); const t=m[0];
      if (t.startsWith('`')) out+='<code>'+esc(t.slice(1,-1))+'</code>';
      else if(t.startsWith('[[')) out+='<button class="wiki-link" data-wiki="'+esc(t.slice(2,-2))+'">'+esc(t.slice(2,-2))+'</button>';
      else if(t.startsWith('[')) { const v=t.match(/^\[([^\]]+)\]\((.+)\)$/); out+=/^https?:\/\//i.test(v[2])?'<a href="'+esc(v[2])+'" target="_blank" rel="noopener noreferrer">'+esc(v[1])+'</a>':esc(t); }
      else if(t.startsWith('**')) out+='<strong>'+esc(t.slice(2,-2))+'</strong>';
      else out+='<em>'+esc(t.slice(1,-1))+'</em>';
      at=m.index+t.length;
    }
    return out+esc(text.slice(at));
  }
  function markdown(source) {
    let out='', inCode=false, code=[], list=false;
    const closeList=()=>{if(list){out+='</ul>';list=false;}};
    for(const line of source.split('\n')) {
      if(line.startsWith('```')) {closeList();if(inCode){out+='<pre><code>'+esc(code.join('\n'))+'</code></pre>';code=[];}inCode=!inCode;continue;}
      if(inCode){code.push(line);continue;}
      const heading=line.match(/^(#{1,6})\s+(.+)$/), item=line.match(/^[-*]\s+(.*)$/);
      if(item){if(!list){out+='<ul>';list=true;}const task=item[1].match(/^\[([ xX])\]\s+(.*)$/);out+='<li'+(task?' class="task-item"':'')+'>'+(task?'<span aria-label="'+(task[1]===' '?'Incomplete':'Complete')+'">'+(task[1]===' '?'☐':'☑')+'</span> '+inline(task[2]):inline(item[1]))+'</li>';continue;}
      closeList();
      if(heading) out+='<h'+heading[1].length+'>'+inline(heading[2])+'</h'+heading[1].length+'>';
      else if(line.startsWith('> ')) out+='<blockquote>'+inline(line.slice(2))+'</blockquote>';
      else if(/^\s*---\s*$/.test(line)) out+='<hr>';
      else if(line.trim()) out+='<p>'+inline(line)+'</p>';
    }
    closeList();if(inCode)out+='<pre><code>'+esc(code.join('\n'))+'</code></pre>';return out;
  }
  function publishThread(state, parts, now=Date.now(), parent=null) {
    if (!parts.length || parts.length>8 || parts.some(t=>typeof t!=='string'||!t.trim()||t.length>500)) return false;
    let replyTo=parent;
    const nonce=Math.random().toString(36).slice(2,8);
    parts.forEach((text,i)=>{const id=`local-${now}-${nonce}-${i}`;state.posts.push({id,author:'you',text:text.trim(),createdAt:now+i,parent:replyTo});replyTo=id;});
    return true;
  }
  function timeline(state, followingOnly=false) { return state.posts.filter(p=>p.parent===null&&(!followingOnly||p.author==='you'||state.following.includes(p.author))).sort((a,b)=>b.createdAt-a.createdAt); }
  const api={defaultInstructions,instructionByteCount,esc,freshState,restoreState,links,tags,backlinks,filteredNotes,markdown,publishThread,timeline};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;
  else root.HarnessModel=api;
})(typeof globalThis!=='undefined'?globalThis:this);
