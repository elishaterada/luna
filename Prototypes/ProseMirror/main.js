// Throwaway experiment. No storage, recovery bridge, custom caret, or arrow repair.
import {Schema} from 'prosemirror-model';
import {EditorState, TextSelection, NodeSelection} from 'prosemirror-state';
import {EditorView} from 'prosemirror-view';
import {schema as markdownSchema, defaultMarkdownParser, defaultMarkdownSerializer, MarkdownParser, MarkdownSerializer} from 'prosemirror-markdown';
import {exampleSetup} from 'prosemirror-example-setup';
import {undo, redo, undoDepth, redoDepth, closeHistory} from 'prosemirror-history';
import {toggleMark, selectAll} from 'prosemirror-commands';
import {sinkListItem, liftListItem, wrapInList, splitListItem} from 'prosemirror-schema-list';
import {keymap} from 'prosemirror-keymap';

// The document and Markdown conversion are independent of the playground UI.
const schema = new Schema({nodes:markdownSchema.spec.nodes
  .update('image', {...markdownSchema.spec.nodes.get('image'), toDOM(node) {
    return ['span', {class:'prototype-image',contenteditable:'false'}, 'Image: '+(node.attrs.alt||node.attrs.src)];
  }})
  .addBefore('paragraph', 'luna_card', {
    group:'block', atom:true, selectable:true,
    attrs:{source:{},kind:{},url:{}},
    toDOM(node) {
      let host=node.attrs.url;
      try {host=new URL(host).host;} catch {}
      return ['figure', {class:'prototype-attachment',contenteditable:'false'},
        ['strong',{},node.attrs.kind+' · '+host],['small',{},'Preview placeholder in this trial']];
    }
  }), marks:markdownSchema.spec.marks});
const tokenizer=defaultMarkdownParser.tokenizer;
tokenizer.core.ruler.after('inline','luna_cards',state=>{
  for(let i=0;i<state.tokens.length-2;i++) {
    const [open,inline,close]=state.tokens.slice(i,i+3);
    if(open.type!=='paragraph_open'||inline.type!=='inline'||close.type!=='paragraph_close')continue;
    const match=inline.content.match(/^\[(Bookmark|Preview|Embed)\]\((https?:\/\/[^\s]+)\)$/);
    if(!match)continue;
    const token=new open.constructor('luna_card','figure',0);
    token.meta={source:inline.content,kind:match[1]==='Preview'?'Bookmark':match[1],url:match[2]};
    state.tokens.splice(i,3,token);
  }
});
const parser=new MarkdownParser(schema,tokenizer,{...defaultMarkdownParser.tokens,luna_card:{node:'luna_card',getAttrs:token=>token.meta}});
const serializer=new MarkdownSerializer({...defaultMarkdownSerializer.nodes,luna_card(state,node) {
  state.write(node.attrs.source);state.closeBlock(node);
}},defaultMarkdownSerializer.marks);
const NoteModel={
  parse:source=>parser.parse(source),
  markdown:doc=>serializer.serialize(doc),
  describe(state) {
    const selection=state.selection,counts={};
    state.doc.descendants(node=>{if(!node.isText)counts[node.type.name]=(counts[node.type.name]||0)+1;});
    return {document:state.doc.toJSON(),selection:selection.toJSON(),counts,
      paragraph:selection.$from.parent.type.name,offset:selection.$from.parentOffset,
      selected:state.doc.textBetween(selection.from,selection.to,'\n')};
  }
};
const examples={
  bullets:{title:'Try the original issue',source:'Updates:\n- Filipino dish\n- ',
    instructions:'Place the caret on the empty bullet, then press Left once. It should land after “Filipino dish.” Type a letter and Undo.',
    steps:[['Place on empty bullet',()=>placeInLastItem()],['Undo',()=>command('undo')]]},
  nested:{title:'Write through a nested list',source:'- First item\n  - Nested item\n- Last item',
    instructions:'Continue an item with Return. Use Tab and Shift–Tab to indent and outdent. Try Backspace at the start, then Undo.',
    steps:[['Place in last item',()=>placeInLastItem(true)],['Continue item',()=>command('continue')],['Indent',()=>command('indent')],['Outdent',()=>command('outdent')]]},
  rich:{title:'Select across a rich block',source:'Before the bookmark\n\n[Bookmark](https://example.com)\n\n- After the bookmark\n\n**Bold text**, *italic text*, and `inline code`.',
    instructions:'Select text across the bookmark and replace it. Undo should restore the text and bookmark together. Cards are placeholders in this trial.',
    steps:[['Select the whole copy',()=>command('selectAll')],['Undo',()=>command('undo')],['Redo',()=>command('redo')]]}
};
let view,activeExample='bullets';
const commands={bold:toggleMark(schema.marks.strong),italic:toggleMark(schema.marks.em),code:toggleMark(schema.marks.code),
  bullets:wrapInList(schema.nodes.bullet_list),numbers:wrapInList(schema.nodes.ordered_list),
  indent:sinkListItem(schema.nodes.list_item),outdent:liftListItem(schema.nodes.list_item),continue:splitListItem(schema.nodes.list_item),
  undo,redo,selectAll};
function plugins() {
  return [keymap({'Tab':commands.indent,'Shift-Tab':commands.outdent}),...exampleSetup({schema,menuBar:false})];
}
function refresh() {
  const state=view.state,info=NoteModel.describe(state);
  let location=info.paragraph.replaceAll('_',' ');
  for(let depth=state.selection.$from.depth;depth>0;depth--) {
    if(state.selection.$from.node(depth).type===schema.nodes.list_item){location='list item';break;}
  }
  document.getElementById('selection').textContent=state.selection instanceof NodeSelection?'Bookmark selected':
    state.selection.empty?'Caret in '+location+' · character '+info.offset:
      'Selected '+info.selected.length+' characters';
  document.getElementById('history-state').textContent=undoDepth(state)+' undo steps · '+redoDepth(state)+' redo steps';
  document.getElementById('markdown').textContent=NoteModel.markdown(state.doc);
  document.getElementById('structure').textContent=JSON.stringify(info,null,2);
  for(const name of ['undo','redo'])document.querySelector('[data-command="'+name+'"]').disabled=!commands[name](state);
  for(const [name,mark] of [['bold','strong'],['italic','em'],['code','code']]) {
    const selected=state.selection.empty?schema.marks[mark].isInSet(state.storedMarks||state.selection.$from.marks()):
      state.doc.rangeHasMark(state.selection.from,state.selection.to,schema.marks[mark]);
    document.querySelector('[data-command="'+name+'"]').setAttribute('aria-pressed',String(!!selected));
  }
}
function loadExample(name) {
  activeExample=name;const example=examples[name];
  const state=EditorState.create({doc:NoteModel.parse(example.source),plugins:plugins()});
  if(view)view.updateState(state);
  else view=new EditorView(document.getElementById('editor'),{
    state,attributes:{'aria-label':'ProseMirror writing playground',spellcheck:'false'},
    dispatchTransaction(transaction) {view.updateState(view.state.apply(transaction));refresh();},
    handleDOMEvents:{blur:()=>{refresh();return false;}}
  });
  for(const tab of document.querySelectorAll('[role="tab"]')) {
    const selected=tab.dataset.scenario===name;tab.setAttribute('aria-selected',String(selected));tab.tabIndex=selected?0:-1;
  }
  document.getElementById('walkthrough').setAttribute('aria-labelledby','tab-'+name);
  document.querySelector('#walkthrough h2').textContent=example.title;
  document.getElementById('instructions').textContent=example.instructions;
  const steps=document.getElementById('steps');steps.replaceChildren();
  for(const [label,action] of [...example.steps,['Reset example',()=>loadExample(activeExample)]]) {
    const button=document.createElement('button');button.textContent=label;button.onclick=action;steps.append(button);
  }
  refresh();view.focus();
  if(name==='bullets')placeInLastItem();
}
function placeInLastItem(atEnd=false) {
  let position=1;
  view.state.doc.descendants((node,pos)=>{
    if(node.type===schema.nodes.list_item)position=pos+2+(atEnd?node.firstChild.content.size:0);
  });
  view.dispatch(closeHistory(view.state.tr.setSelection(TextSelection.create(view.state.doc,position)).scrollIntoView()));view.focus();
}
function command(name,text) {
  if(!view)return false;
  view.focus();
  if(name==='pastePlainText'){view.dispatch(view.state.tr.insertText(text).scrollIntoView());return true;}
  const handled=commands[name]?.(view.state,view.dispatch,view)||false;refresh();return handled;
}
document.querySelector('.toolbar').addEventListener('mousedown',event=>event.preventDefault());
document.querySelector('.toolbar').addEventListener('click',event=>{
  const name=event.target.closest('[data-command]')?.dataset.command;if(name)command(name);
});
document.querySelector('.scenarios').addEventListener('click',event=>{
  const tab=event.target.closest('[data-scenario]');if(tab)loadExample(tab.dataset.scenario);
});
document.querySelector('.scenarios').addEventListener('keydown',event=>{
  if(!['ArrowLeft','ArrowRight','Home','End'].includes(event.key))return;
  const tabs=[...document.querySelectorAll('[role="tab"]:not([hidden])')],index=tabs.indexOf(document.activeElement);
  if(index<0)return;event.preventDefault();
  const next=event.key==='Home'?tabs[0]:event.key==='End'?tabs.at(-1):tabs[(index+(event.key==='ArrowRight'?1:tabs.length-1))%tabs.length];
  loadExample(next.dataset.scenario);next.focus();
});
window.lunaPrototype={
  command,
  get view(){return view;},
  get state(){return NoteModel.describe(view.state);},
  get markdown(){return NoteModel.markdown(view.state.doc);},
  boot(source,dark,size,build) {
    document.documentElement.dataset.theme=dark?'dark':'light';
    document.documentElement.style.setProperty('--editor-size',size+'px');
    document.getElementById('build').textContent=build?'Build '+build:'';
    examples.copy={title:'Try your own writing',source,
      instructions:'This is an editable copy of your current note. Try a normal writing sequence, then compare the Markdown. Your original stays in Luna’s main window.',
      steps:[['Select the whole copy',()=>command('selectAll')],['Undo',()=>command('undo')]]};
    document.getElementById('tab-copy').hidden=false;
    loadExample('bullets');
  }
};
loadExample('bullets');
