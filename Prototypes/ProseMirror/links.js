import {Plugin,PluginKey,TextSelection,Selection,NodeSelection} from 'prosemirror-state';
import {closeHistory} from 'prosemirror-history';
import {schema,webURL,pastedURL,itemID,NoteModel,markdownURL} from './note-model.js';

const menuKey=new PluginKey('luna-link-display');
const styles=[['mention','Mention'],['linked','Linked Text'],['plain','Plain Text'],['bookmark','Bookmark'],['embed','Embed Site']];
export function linkAt(doc,pos) {
  const $pos=doc.resolve(Math.max(0,Math.min(pos,doc.content.size)));
  const node=$pos.nodeAfter;
  if(node?.type===schema.nodes.luna_mention||node?.type===schema.nodes.luna_card)
    return {from:$pos.pos,to:$pos.pos+node.nodeSize,url:node.attrs.url,display:node.type===schema.nodes.luna_mention?'mention':node.attrs.kind.toLowerCase()};
  let target=null;
  $pos.parent.forEach((child,offset)=>{
    const from=$pos.start()+offset,to=from+child.nodeSize,mark=schema.marks.link.isInSet(child.marks);
    if(mark&&from<=pos&&to>=pos)target={from,to,url:mark.attrs.href,display:'linked',label:child.textContent};
  });
  if(!target&&pos>0&&doc.nodeAt(pos-1)?.type===schema.nodes.luna_mention)return linkAt(doc,pos-1);
  if(!target)return null;
  // Marks can span text nodes with different bold/italic formatting.
  const siblings=[];$pos.parent.forEach((child,offset)=>siblings.push({child,from:$pos.start()+offset,to:$pos.start()+offset+child.nodeSize}));
  const index=siblings.findIndex(item=>item.from===target.from);
  for(let i=index-1;i>=0&&schema.marks.link.isInSet(siblings[i].child.marks)?.attrs.href===target.url;i--)target.from=siblings[i].from;
  for(let i=index+1;i<siblings.length&&schema.marks.link.isInSet(siblings[i].child.marks)?.attrs.href===target.url;i++)target.to=siblings[i].to;
  target.label=doc.textBetween(target.from,target.to);return target;
}

// The engine owns all content/selection changes. The popover and preview cache are views.
export function createLinks(getView,onStatus) {
  const cache=new Map(),subscribers=new Map(),requested=new Set();
  const session=globalThis.crypto?.randomUUID?.()||String(Date.now())+Math.random();
  const popover=document.getElementById('link-popover');
  let renderedTarget=null,editing=false;
  function send(kind,url,extra={}) {
    const bridge=window.webkit?.messageHandlers?.prototypeLinks;
    if(bridge)bridge.postMessage({session,kind,url,...extra});
    else if(kind==='open')window.open(url,'_blank','noopener');
    else if(kind==='copy')navigator.clipboard?.writeText(url);
  }
  function request(url,kind='metadata') {
    const key=kind+'|'+url;if(requested.has(key))return;requested.add(key);send(kind,url);
  }
  function details(url){return cache.get(url)||{};}
  function title(url){return details(url).title||new URL(url).hostname;}
  function active(){return getView()&&menuKey.getState(getView().state);}
  function close(focus=false) {
    const view=getView();if(active())view.dispatch(view.state.tr.setMeta(menuKey,null).setMeta('addToHistory',false));
    if(focus)view.focus();
  }
  function open(target) {
    if(!target||!webURL(target.url))return;
    editing=false;getView().dispatch(getView().state.tr.setMeta(menuKey,target).setMeta('addToHistory',false));request(target.url);
  }
  function position() {
    const target=active(),view=getView();if(!target||popover.hidden)return;
    const node=view.nodeDOM(target.from);
    const rect=node?.nodeType===1&&node.matches('.luna-card,.luna-mention')?node.getBoundingClientRect():view.coordsAtPos(target.to);
    const margin=10,width=popover.offsetWidth,height=popover.offsetHeight;
    popover.style.left=Math.max(margin,Math.min(rect.left,innerWidth-width-margin))+'px';
    popover.style.top=Math.max(margin,Math.min(rect.bottom+7,innerHeight-height-margin))+'px';
  }
  function renderMenu(target) {
    popover.hidden=!target;
    if(!target){renderedTarget=null;editing=false;return;}
    const identity=target.from+'|'+target.to+'|'+target.url+'|'+target.display;
    if(identity===renderedTarget)return;
    renderedTarget=identity;editing=false;popover.replaceChildren();
    const heading=document.createElement('p');heading.className='popover-label';heading.textContent='Display as';popover.append(heading);
    for(const [kind,label] of styles) {
      const button=document.createElement('button');button.type='button';button.dataset.display=kind;
      button.textContent=label;button.setAttribute('aria-pressed',String(target.display===kind));
      button.onclick=()=>convert(kind);popover.append(button);
    }
    const actions=document.createElement('div');actions.className='link-actions';
    for(const [label,action] of [['Edit link',edit],['Open original',()=>send('open',target.url)],['Copy URL',()=>{send('copy',target.url);onStatus('URL copied');}],['Remove link',remove]]) {
      const button=document.createElement('button');button.textContent=label;button.onclick=action;actions.append(button);
    }
    popover.append(actions);position();
  }
  function historyStep(tr) {
    const view=getView();view.dispatch(closeHistory(tr).setMeta(menuKey,null).scrollIntoView());
    view.dispatch(closeHistory(view.state.tr));view.focus();
  }
  function caretAfterCard(tr,id) {
    let position=null,node;
    tr.doc.descendants((value,pos)=>{if(value.type===schema.nodes.luna_card&&value.attrs.id===id){position=pos;node=value;return false;}});
    if(position===null)return tr;
    const after=position+node.nodeSize,$after=tr.doc.resolve(after),next=$after.nodeAfter;
    if(next?.isTextblock)tr.setSelection(TextSelection.near(tr.doc.resolve(after+1)));
    else {tr.insert(after,schema.nodes.paragraph.create());tr.setSelection(TextSelection.create(tr.doc,after+1));}
    return tr;
  }
  function convert(kind,options={}) {
    const view=getView(),target=active();if(!view||!target)return false;
    const url=webURL(options.url||target.url);if(!url)return false;
    if(kind===target.display&&!options.url&&!options.label){close(true);return true;}
    const block=target.display==='bookmark'||target.display==='embed';
    const marks=(view.state.doc.nodeAt(target.from)?.marks||[]).filter(mark=>mark.type!==schema.marks.link);
    let tr=view.state.tr;
    if(kind==='bookmark'||kind==='embed') {
      const id=itemID(),node=schema.nodes.luna_card.create({id,url,kind:kind==='embed'?'Embed':'Bookmark'});
      if(block)tr.replaceWith(target.from,target.to,node);else tr.replaceRangeWith(target.from,target.to,node);
      caretAfterCard(tr,id);
    } else {
      const inline=kind==='mention'?schema.nodes.luna_mention.create({url,id:itemID()},null,marks):
        schema.text(kind==='plain'?url:(options.label||url),kind==='plain'?marks:[...marks,schema.marks.link.create({href:url})]);
      if(block)tr.replaceWith(target.from,target.to,schema.nodes.paragraph.create(null,inline));
      else tr.replaceWith(target.from,target.to,inline);
      const end=target.from+(block?1:0)+inline.nodeSize;
      tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(end,tr.doc.content.size))));
    }
    tr.setStoredMarks([]);historyStep(tr);onStatus('Changed to '+(styles.find(style=>style[0]===kind)?.[1]||kind));return true;
  }
  function remove() {
    const target=active(),view=getView();if(!target)return;
    if(target.display==='bookmark'||target.display==='embed') {
      let tr=view.state.tr.delete(target.from,target.to);
      tr.setSelection(Selection.near(tr.doc.resolve(Math.min(target.from,tr.doc.content.size))));historyStep(tr);
    } else convert('plain');
  }
  function edit() {
    const target=active();if(!target)return;editing=true;popover.replaceChildren();
    const form=document.createElement('form');
    const isBlock=target.display==='bookmark'||target.display==='embed';
    const heading=document.createElement('p');heading.textContent='Edit link';heading.className='popover-label';form.append(heading);
    let labelInput;
    if(!isBlock) {
      const label=document.createElement('label');label.textContent='Link title';labelInput=document.createElement('input');
      labelInput.value=target.display==='mention'?title(target.url):target.label||target.url;labelInput.required=true;label.append(labelInput);form.append(label);
    }
    const label=document.createElement('label');label.textContent='Link URL';
    const input=document.createElement('input');input.type='url';input.required=true;input.value=target.url;label.append(input);form.append(label);
    const save=document.createElement('button');save.type='submit';save.textContent='Save link';
    const cancel=document.createElement('button');cancel.type='button';cancel.textContent='Cancel';cancel.onclick=()=>close(true);
    form.append(save,cancel);form.onsubmit=event=>{
      event.preventDefault();const url=webURL(input.value.trim());
      input.setCustomValidity(url?'':'Enter an http or https URL without a username or password.');
      if(!form.reportValidity())return;
      convert(isBlock?target.display:'linked',{url,label:labelInput?.value.trim()||url});
    };
    input.oninput=()=>input.setCustomValidity('');popover.append(form);position();(labelInput||input).focus();
  }
  function paste(value,html='') {
    const url=pastedURL(value,html),view=getView();if(!url||!view)return false;
    // Preserve literal paste in code blocks and inline code.
    if(view.state.selection.$from.parent.type===schema.nodes.code_block||schema.marks.code.isInSet(view.state.storedMarks||view.state.selection.$from.marks()))return false;
    const tr=view.state.tr.replaceSelectionWith(schema.text(url,[schema.marks.link.create({href:url})]),false).setStoredMarks([]);
    const target={from:tr.selection.from-url.length,to:tr.selection.from,url,display:'linked',label:url};
    view.dispatch(closeHistory(tr).setMeta(menuKey,target).scrollIntoView());view.dispatch(closeHistory(view.state.tr));
    view.focus();request(url);onStatus('URL pasted · choose a display');return true;
  }
  function nodeView(initialNode,view,getPos) {
    let node=initialNode;
    const inline=node.type===schema.nodes.luna_mention;
    const dom=document.createElement(inline?'span':'figure');dom.contentEditable='false';dom.className=inline?'luna-mention':'luna-card';
    let listeningURL=node.attrs.url,lastFrameURL=null;
    const icon=document.createElement('img');icon.className='link-icon';icon.alt='';icon.referrerPolicy='no-referrer';
    const text=document.createElement(inline?'span':'div'),name=document.createElement(inline?'span':'strong'),description=document.createElement('small');
    text.className='link-copy';text.append(name);if(!inline)text.append(description);
    dom.append(icon,text);
    const preview=document.createElement('img');preview.className='link-preview';preview.alt='';preview.referrerPolicy='no-referrer';preview.hidden=true;
    let frame,caption;
    if(!inline) {
      dom.prepend(preview);
      const controls=document.createElement('div');controls.className='card-controls';
      const display=document.createElement('button');display.textContent='Display as…';display.setAttribute('aria-label','Change link display');
      display.onclick=()=>openTarget();
      const original=document.createElement('button');original.textContent='Open original';original.onclick=()=>send('open',node.attrs.url);
      controls.append(display,original);dom.append(controls);
    }
    function openTarget() {const pos=getPos();if(typeof pos==='number')open({from:pos,to:pos+node.nodeSize,url:node.attrs.url,display:inline?'mention':node.attrs.kind.toLowerCase()});}
    if(inline){dom.tabIndex=0;dom.setAttribute('role','button');dom.onclick=event=>{event.preventDefault();openTarget();};dom.onkeydown=event=>{if(event.key==='Enter'||event.key===' '){event.preventDefault();openTarget();}};}
    function render() {
      const data=details(node.attrs.url);name.textContent=data.title||new URL(node.attrs.url).hostname;
      dom.title=data.description||node.attrs.url;
      if(data.favicon&&icon.getAttribute('src')!==data.favicon){icon.hidden=false;icon.src=data.favicon;}
      else if(!data.favicon)icon.hidden=true;
      icon.onerror=()=>{icon.hidden=true;};
      if(!inline) {
        const embedded=node.attrs.kind==='Embed';dom.classList.toggle('is-embed',embedded);
        description.textContent=data.description||node.attrs.url;
        preview.hidden=embedded||!data.image;
        if(!embedded&&data.image&&preview.getAttribute('src')!==data.image)preview.src=data.image;
        preview.onerror=()=>{preview.hidden=true;dom.classList.remove('has-image');};
        dom.classList.toggle('has-image',!embedded&&!!data.image&&!preview.hidden);
        if(embedded) {
          request(node.attrs.url,'embed');
          const url=data.embedURL||node.attrs.url;
          if(!frame) {
            frame=document.createElement('iframe');frame.title='Embedded '+new URL(node.attrs.url).hostname;
            frame.setAttribute('sandbox','allow-scripts allow-same-origin allow-presentation');
            frame.setAttribute('allow','fullscreen; autoplay; encrypted-media; picture-in-picture');frame.referrerPolicy='strict-origin-when-cross-origin';
            caption=document.createElement('small');caption.className='embed-caption';caption.textContent='If this site blocks embedding, use Open original.';
            dom.prepend(frame);dom.append(caption);
          }
          if(lastFrameURL!==url){frame.src=url;lastFrameURL=url;}
        } else if(frame){frame.remove();caption.remove();frame=null;lastFrameURL=null;}
      }
    }
    function subscribe(url) {if(!subscribers.has(url))subscribers.set(url,new Set());subscribers.get(url).add(render);request(url);}
    subscribe(listeningURL);render();
    return {dom,
      update(next) {
        if(next.type!==node.type)return false;node=next;
        if(listeningURL!==node.attrs.url){subscribers.get(listeningURL)?.delete(render);listeningURL=node.attrs.url;subscribe(listeningURL);}
        render();return true;
      },
      selectNode(){dom.classList.add('ProseMirror-selectednode');},deselectNode(){dom.classList.remove('ProseMirror-selectednode');},
      stopEvent:event=>!!event.target.closest('button,iframe')||inline,
      ignoreMutation:()=>true,
      destroy(){subscribers.get(listeningURL)?.delete(render);}
    };
  }
  const plugin=new Plugin({key:menuKey,
    state:{init:()=>null,apply(tr,previous) {
      const value=tr.getMeta(menuKey);if(value!==undefined)return value;
      if(!previous)return null;
      if(tr.docChanged||tr.selectionSet)return null;
      return previous;
    }},
    view:()=>({update(view){renderMenu(menuKey.getState(view.state));},destroy(){popover.hidden=true;}}),
    props:{
      handlePaste:(_view,event)=>paste(event.clipboardData.getData('text/plain'),event.clipboardData.getData('text/html')),
      handleClick(view,pos,event) {
        const anchor=event.target.closest('a[data-prototype-link]');if(!anchor)return false;
        const target=linkAt(view.state.doc,view.posAtDOM(anchor,0));if(!target)return false;
        event.preventDefault();open(target);return true;
      },
      clipboardTextSerializer:slice=>{
        // Preserve portable link display syntax instead of rendered metadata labels.
        const doc=schema.nodes.doc.createAndFill(null,slice.content);
        return doc?NoteModel.markdown(doc):slice.content.textBetween(0,slice.content.size,'\n',node=>
          node.type===schema.nodes.luna_mention?'[Mention]('+markdownURL(node.attrs.url)+')':
            node.type===schema.nodes.luna_card?'['+node.attrs.kind+']('+markdownURL(node.attrs.url)+')':node.attrs.alt||'');
      }
    }
  });
  document.addEventListener('pointerdown',event=>{
    if(popover.hidden||popover.contains(event.target)||event.target.closest('.luna-mention,.luna-card,a[data-prototype-link]'))return;
    close();
  });
  document.addEventListener('keydown',event=>{
    if(popover.hidden||event.isComposing)return;
    if(event.key==='Escape'){event.preventDefault();close(true);return;}
    if(event.target.matches('input,textarea')||editing)return;
    if(!['ArrowUp','ArrowDown','Enter'].includes(event.key)||event.metaKey||event.altKey||event.ctrlKey||event.shiftKey)return;
    const buttons=[...popover.querySelectorAll('button[data-display]')],index=buttons.indexOf(document.activeElement);
    if(event.key==='Enter'&&index<0)return;
    event.preventDefault();event.stopPropagation();
    if(event.key==='Enter')buttons[index].click();
    else buttons[(index+(event.key==='ArrowDown'?1:buttons.length-1)+buttons.length)%buttons.length].focus();
  },true);
  document.addEventListener('scroll',event=>{if(!popover.contains(event.target))position();},true);
  window.addEventListener('resize',position);
  function reportFocus() {send('focus','',{editing:document.activeElement?.tagName!=='IFRAME'});}
  document.addEventListener('focusin',reportFocus);window.addEventListener('blur',()=>setTimeout(reportFocus,0));
  return {plugin,nodeViews:{luna_mention:nodeView,luna_card:nodeView},paste,close,
    showSelected(){
      const view=getView(),selection=view.state.selection;
      let target=linkAt(view.state.doc,selection.from)||linkAt(view.state.doc,selection.from-1);
      if(!target&&!selection.empty){const url=webURL(view.state.doc.textBetween(selection.from,selection.to));if(url)target={from:selection.from,to:selection.to,url,display:'plain'};}
      if(!target&&selection.empty) {
        const $pos=selection.$from;
        for(const match of $pos.parent.textContent.matchAll(/https?:\/\/[^\s]+/g)) {
          if(match.index<=$pos.parentOffset&&match.index+match[0].length>=$pos.parentOffset&&webURL(match[0]))
            target={from:$pos.start()+match.index,to:$pos.start()+match.index+match[0].length,url:webURL(match[0]),display:'plain'};
        }
      }
      if(target)open(target);else onStatus('Select a URL or click a link to change its display.');
    },
    resolve(token,url,payload) {
      if(token!==session||!webURL(url))return;
      const clean={...details(url)};
      for(const key of ['title','description'])if(typeof payload[key]==='string'&&payload[key])clean[key]=payload[key].slice(0,1000);
      for(const key of ['favicon','image','embedURL'])if(webURL(payload[key]))clean[key]=payload[key];
      cache.set(url,clean);subscribers.get(url)?.forEach(update=>update());position();
    },
    native(kind,extra={}) {send(kind,'',extra);},
    get session(){return session;},get metadata(){return Object.fromEntries(cache);}
  };
}
