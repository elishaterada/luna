// Throwaway experiment. No storage, recovery bridge, custom caret, or arrow repair.
import {EditorState, TextSelection, NodeSelection} from 'prosemirror-state';
import {EditorView} from 'prosemirror-view';
import {exampleSetup} from 'prosemirror-example-setup';
import {undo, redo, undoDepth, redoDepth, closeHistory} from 'prosemirror-history';
import {toggleMark, selectAll} from 'prosemirror-commands';
import {sinkListItem, liftListItem, wrapInList, splitListItem} from 'prosemirror-schema-list';
import {keymap} from 'prosemirror-keymap';

import {schema,NoteModel} from './note-model.js';
import {createLinks} from './links.js';

const status=text=>document.getElementById('workflow-status').textContent=text;
const links=createLinks(()=>view,status);
const examples={
  urls:{title:'Paste and change a URL',source:'',
    instructions:'Paste a URL, choose Mention, Bookmark, or Embed Site, then keep typing. Try Undo/Redo and Reopen Markdown. Embedded sites can also be opened in your browser.',
    steps:[['Insert example URL',()=>links.paste('https://en.wikipedia.org/wiki/Karaoke')],['Reopen Markdown',()=>reopenMarkdown()]]},
  bullets:{title:'Try the original issue',source:'Updates:\n- Filipino dish\n- ',
    instructions:'Place the caret on the empty bullet, then press Left once. It should land after “Filipino dish.” Type a letter and Undo.',
    steps:[['Place on empty bullet',()=>placeInLastItem()],['Undo',()=>command('undo')]]},
  nested:{title:'Write through a nested list',source:'- First item\n  - Nested item\n- Last item',
    instructions:'Continue an item with Return. Use Tab and Shift–Tab to indent and outdent. Try Backspace at the start, then Undo.',
    steps:[['Place in last item',()=>placeInLastItem(true)],['Continue item',()=>command('continue')],['Indent',()=>command('indent')],['Outdent',()=>command('outdent')]]},
  rich:{title:'Select across a rich block',source:'Before the bookmark\n\n[Bookmark](https://example.com)\n\n- After the bookmark\n\n**Bold text**, *italic text*, and `inline code`.',
    instructions:'Select text across the bookmark and replace it. Undo should restore the text and bookmark together. Try each display using the card’s Display as menu.',
    steps:[['Select the whole copy',()=>command('selectAll')],['Undo',()=>command('undo')],['Redo',()=>command('redo')]]}
};
let view,activeExample='bullets';
const commands={bold:toggleMark(schema.marks.strong),italic:toggleMark(schema.marks.em),code:toggleMark(schema.marks.code),
  bullets:wrapInList(schema.nodes.bullet_list),numbers:wrapInList(schema.nodes.ordered_list),
  indent:sinkListItem(schema.nodes.list_item),outdent:liftListItem(schema.nodes.list_item),continue:splitListItem(schema.nodes.list_item),
  undo,redo,selectAll};
function plugins() {
  return [links.plugin,keymap({'Tab':commands.indent,'Shift-Tab':commands.outdent}),...exampleSetup({schema,menuBar:false})];
}
function refresh() {
  const state=view.state,info=NoteModel.describe(state);
  let location=info.paragraph.replaceAll('_',' ');
  for(let depth=state.selection.$from.depth;depth>0;depth--) {
    if(state.selection.$from.node(depth).type===schema.nodes.list_item){location='list item';break;}
  }
  document.getElementById('selection').textContent=state.selection instanceof NodeSelection?'Link item selected':
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
    state,nodeViews:links.nodeViews,attributes:{'aria-label':'ProseMirror writing playground',spellcheck:'false'},
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
  if(name==='urls')view.dispatch(view.state.tr.setSelection(TextSelection.atEnd(view.state.doc)));
  status('');
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
  const field=document.activeElement;
  if(field?.matches('input,textarea')) {
    if(name==='selectAll'){field.select();return true;}
    if(name==='pastePlainText')return document.execCommand('insertText',false,text);
    if(name==='undo'||name==='redo')return document.execCommand(name);
    return false;
  }
  if(field?.tagName==='IFRAME')return false;
  if(name==='showLink'){links.showSelected();return true;}
  if(name==='reopenMarkdown'){reopenMarkdown();return true;}
  if(name==='exportMarkdown'){links.native('export',{source:NoteModel.markdown(view.state.doc)});return true;}
  if(name==='importMarkdown'){links.native('import');return true;}
  links.close();view.focus();
  if(name==='pastePlainText'){view.dispatch(closeHistory(view.state.tr.insertText(text).scrollIntoView()));return true;}
  const handled=commands[name]?.(view.state,view.dispatch,view)||false;refresh();return handled;
}
document.querySelector('.toolbar').addEventListener('mousedown',event=>event.preventDefault());
document.addEventListener('click',event=>{
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
function reopenMarkdown() {
  const source=NoteModel.markdown(view.state.doc);
  view.updateState(EditorState.create({doc:NoteModel.parse(source),plugins:plugins()}));
  refresh();view.focus();status('Reopened the Markdown in a fresh editor state');
}
window.lunaPrototype={
  command,resolve:links.resolve,
  openMarkdown(source) {
    examples.import={title:'Try imported Markdown',source,instructions:'This is an in-memory copy of the file you chose. Export Markdown writes a separate file.',steps:[['Reopen Markdown',reopenMarkdown]]};
    let tab=document.getElementById('tab-import');
    if(!tab){tab=document.createElement('button');tab.id='tab-import';tab.role='tab';tab.dataset.scenario='import';tab.textContent='Imported Markdown';tab.setAttribute('aria-controls','walkthrough');document.querySelector('.scenarios').append(tab);}
    loadExample('import');
  },
  get metadata(){return links.metadata;},
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
    loadExample('urls');
  }
};
loadExample('urls');
