const test = require('node:test');
const assert = require('node:assert/strict');
const {defaultInstructions,instructionByteCount,freshState,restoreState,links,tags,backlinks,filteredNotes,markdown,publishThread,timeline}=require('./model.js');

test('drafts, notes, and reply drafts survive a JSON storage round trip',()=>{
 const state=freshState(1000000);
 state.draft='Unfinished director request';
 state.socialDrafts=['The first thought','The second thought'];
 state.replyDrafts['sample-1']='A reply in progress';
 state.notes[0].body+='\nA private draft.';
 state.transcript='My transcript';
 state.speakInstructions='Keep my original wording.';
 state.speakInstructionDraft='Keep my original wording. Still editing.';
 state.speakRewriteRoute='localWithCloudFallback';
 const restored=restoreState(JSON.parse(JSON.stringify(state)),2000000);
 assert.equal(restored.draft,state.draft);
 assert.deepEqual(restored.socialDrafts,state.socialDrafts);
 assert.deepEqual(restored.replyDrafts,state.replyDrafts);
 assert.equal(restored.notes[0].body,state.notes[0].body);
 assert.equal(restored.transcript,state.transcript);
 assert.equal(restored.speakInstructions,state.speakInstructions);
 assert.equal(restored.speakInstructionDraft,state.speakInstructionDraft);
 assert.equal(restored.speakRewriteRoute,state.speakRewriteRoute);
});

test('restoration drops invalid shapes while preserving useful text',()=>{
 const restored=restoreState({version:1,tab:'unexpected',posts:[null,{id:5},{id:'ok',text:'text',author:'you',createdAt:10,parent:null}],notes:[null],socialDrafts:[null,7],connections:[{id:'a',name:'Mac',host:'host',user:'me',port:22},{id:'b',name:'Bad',host:'host',user:'me',port:70000}]},1000000);
 assert.equal(restored.tab,'Dot');
 assert.deepEqual(restored.posts.map(p=>p.id),['ok']);
 assert.ok(restored.notes.length);
 assert.deepEqual(restored.socialDrafts,['']);
 assert.equal(restored.connections.length,1);
});

test('posting a thread stores trimmed text with a traversable reply chain',()=>{
 const state=freshState(1000000);
 assert.equal(publishThread(state,['  First  ','Second','Third'],2000000),true);
 const added=state.posts.slice(-3);
 assert.equal(added[0].text,'First');
 assert.equal(added[0].parent,null);
 assert.equal(added[1].parent,added[0].id);
 assert.equal(added[2].parent,added[1].id);
 assert.equal(new Set(added.map(p=>p.id)).size,3);
 assert.equal(timeline(state)[0].id,added[0].id);
});

test('reply posting attaches to the intended post and stays out of the root timeline',()=>{
 const state=freshState(1000000),before=timeline(state).length;
 assert.equal(publishThread(state,['A direct reply'],2000000,'sample-1'),true);
 assert.equal(state.posts.at(-1).parent,'sample-1');
 assert.equal(timeline(state).length,before);
});

test('invalid posts leave persisted state untouched',()=>{
 const state=freshState(1000000),before=JSON.stringify(state.posts);
 for(const parts of [[],[''],[' \n '],['a'.repeat(501)],['valid',' '],Array(9).fill('part')])assert.equal(publishThread(state,parts),false);
 assert.equal(JSON.stringify(state.posts),before);
});

test('chronological following filter includes self and followed authors only',()=>{
 const state=freshState(1000000);
 publishThread(state,['My update'],2000000);
 assert.deepEqual(timeline(state,true).map(p=>p.author),['you','lin']);
 state.following.push('ada');
 assert.deepEqual(timeline(state,true).map(p=>p.author),['you','lin','ada']);
 assert.deepEqual(timeline(state).map(p=>p.createdAt),[2000000,280000,-740000,-2060000]);
});

test('wikilinks and backlinks are connected by case-insensitive title',()=>{
 const notes=[{id:'a',title:'Alpha',body:'See [[Beta]] and [[Gamma]].'},{id:'b',title:'Beta',body:'Return to [[alpha]].'},{id:'c',title:'Gamma',body:'No link here.'}];
 assert.deepEqual(links(notes[0].body),['Beta','Gamma']);
 assert.deepEqual(backlinks(notes,'Alpha').map(n=>n.id),['b']);
 assert.deepEqual(backlinks(notes,'Beta').map(n=>n.id),['a']);
});

test('note search includes title and content; tags are unique and support Unicode',()=>{
 const notes=[{id:'a',title:'Field notes',body:'A detail. #ideas #想法 #ideas'},{id:'b',title:'This week',body:'#weekly'}];
 assert.deepEqual(filteredNotes(notes,'FIELD').map(n=>n.id),['a']);
 assert.deepEqual(filteredNotes(notes,'#weekly').map(n=>n.id),['b']);
 assert.deepEqual(tags(notes[0].body),['ideas','想法']);
});

test('Markdown renders useful structures without allowing raw HTML',()=>{
 const html=markdown('# Heading\n\n**Bold** and *emphasis*.\n- [x] Done\n- [ ] Later\n> Quote\n```html\n<script>alert(1)</script>\n```\n<img src=x onerror=alert(1)>');
 assert.match(html,/<h1>Heading<\/h1>/);
 assert.match(html,/<strong>Bold<\/strong>/);
 assert.match(html,/<em>emphasis<\/em>/);
 assert.match(html,/aria-label="Complete"/);
 assert.match(html,/<blockquote>Quote<\/blockquote>/);
 assert.doesNotMatch(html,/<script|<img/i);
 assert.match(html,/&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
});

test('Markdown links allow HTTP(S), preserve unsafe schemes as text, and escape attributes',()=>{
 const html=markdown('[safe](https://example.com) [bad](javascript:alert(1)) [[<img onerror="x">]]');
 assert.match(html,/href="https:\/\/example.com"/);
 assert.doesNotMatch(html,/href="javascript/);
 assert.match(html,/javascript:alert/);
 assert.match(html,/data-wiki="&lt;img onerror=&quot;x&quot;&gt;"/);
 assert.doesNotMatch(html,/<img/);
});

test('inline code and unterminated fenced code remain escaped',()=>{
 const html=markdown('`<svg/onload=x>`\n```\n<img src=x>');
 assert.match(html,/<code>&lt;svg\/onload=x&gt;<\/code>/);
 assert.match(html,/<pre><code>&lt;img src=x&gt;<\/code><\/pre>/);
 assert.doesNotMatch(html,/<svg|<img/);
});


test('instruction limit counts UTF-8 bytes and preserves oversized drafts without applying them',()=>{
 const draft='馬'.repeat(2731);
 assert.equal(instructionByteCount(draft),8193);
 const restored=restoreState({version:1,speakInstructions:draft,speakInstructionDraft:draft,speakRewriteRoute:'unrecognized'});
 assert.equal(restored.speakInstructions,defaultInstructions);
 assert.equal(restored.speakInstructionDraft,draft);
 assert.equal(restored.speakRewriteRoute,'localOnly');
 const accepted=restoreState({version:1,speakInstructions:'a'.repeat(8192),speakRewriteRoute:'privateCloudOnly'});
 assert.equal(instructionByteCount(accepted.speakInstructions),8192);
 assert.equal(accepted.speakRewriteRoute,'privateCloudOnly');
});
