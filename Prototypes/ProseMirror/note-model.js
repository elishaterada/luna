import {Schema} from 'prosemirror-model';
import {schema as base, defaultMarkdownParser, defaultMarkdownSerializer, MarkdownParser, MarkdownSerializer} from 'prosemirror-markdown';

let nextID=0;
export const itemID=()=>`link-${++nextID}`;
export function webURL(value) {
  if(typeof value!=='string'||/\s/.test(value)||value.length>8192)return null;
  try {const url=new URL(value);return /^https?:$/.test(url.protocol)&&url.host&&!url.username&&!url.password?url.href:null;}catch{return null;}
}
export const markdownURL=url=>url.replaceAll('(','%28').replaceAll(')','%29');
export function pastedURL(text,html='') {
  const plain=text.trim(),url=webURL(plain);if(url)return url;
  if(!/^<iframe\b/i.test(plain)&&!(!plain&&/<iframe\b/i.test(html)))return null;
  const fragment=new DOMParser().parseFromString(plain||html,'text/html');
  return webURL(fragment.querySelector('iframe')?.getAttribute('src'));
}
export const schema=new Schema({
  nodes:base.spec.nodes
    .update('heading',{...base.spec.nodes.get('heading'),content:'inline*'})
    .update('image',{...base.spec.nodes.get('image'),toDOM(node) {
      return ['span',{class:'prototype-image',contenteditable:'false'},'Image: '+(node.attrs.alt||node.attrs.src)];
    }})
    .addBefore('text','luna_mention',{
      inline:true,group:'inline',atom:true,selectable:true,
      attrs:{url:{},id:{default:null}},
      leafText:node=>node.attrs.url,
      parseDOM:[{tag:'span[data-luna-mention]',getAttrs:dom=>{
        const url=webURL(dom.dataset.lunaMention);return url?{url,id:itemID()}:false;
      }}],
      toDOM:node=>['span',{'data-luna-mention':node.attrs.url,contenteditable:'false',class:'luna-mention'},node.attrs.url]
    })
    .addBefore('paragraph','luna_card',{
      group:'block',atom:true,selectable:true,
      attrs:{url:{},kind:{default:'Bookmark'},id:{default:null}},
      leafText:node=>node.attrs.url,
      parseDOM:[{tag:'figure[data-luna-url]',getAttrs:dom=>{
        const url=webURL(dom.dataset.lunaUrl);return url?{url,kind:dom.dataset.lunaKind==='Embed'?'Embed':'Bookmark',id:itemID()}:false;
      }}],
      toDOM:node=>['figure',{'data-luna-url':node.attrs.url,'data-luna-kind':node.attrs.kind,contenteditable:'false'},node.attrs.kind+' · '+node.attrs.url]
    }),
  marks:base.spec.marks.update('link',{...base.spec.marks.get('link'),toDOM:mark=>[
    'a',{href:mark.attrs.href,title:mark.attrs.title,'data-prototype-link':'true'},0]})
});
const tokenizer=defaultMarkdownParser.tokenizer;
tokenizer.core.ruler.after('inline','luna_cards',state=>{
  for(let i=0;i<state.tokens.length-2;i++) {
    const [open,inline,close]=state.tokens.slice(i,i+3);
    if(open.type!=='paragraph_open'||inline.type!=='inline'||close.type!=='paragraph_close')continue;
    const match=inline.content.match(/^\[(Bookmark|Preview|Embed)\]\((https?:\/\/[^\s]+)\)$/);
    const url=match&&webURL(match[2]);if(!url)continue;
    const token=new open.constructor('luna_card','figure',0);
    token.meta={url,kind:match[1]==='Embed'?'Embed':'Bookmark',id:itemID()};state.tokens.splice(i,3,token);
  }
});
const parser=new MarkdownParser(schema,tokenizer,{...defaultMarkdownParser.tokens,
  luna_card:{node:'luna_card',getAttrs:token=>token.meta}});
const serializer=new MarkdownSerializer({...defaultMarkdownSerializer.nodes,
  luna_mention(state,node){state.write('[Mention]('+markdownURL(node.attrs.url)+')');},
  luna_card(state,node){state.write('['+node.attrs.kind+']('+markdownURL(node.attrs.url)+')');state.closeBlock(node);}
},defaultMarkdownSerializer.marks);
function mapTree(node,convert) {
  if(node.isText||node.isLeaf)return convert(node);
  const children=[];node.forEach(child=>children.push(mapTree(child,convert)));
  return node.type.create(node.attrs,children,node.marks);
}
export const NoteModel={
  parse(source) {
    return mapTree(parser.parse(source),node=>{
      const link=node.isText&&schema.marks.link.isInSet(node.marks),url=link&&webURL(link.attrs.href);
      if(!url)return node;
      if(node.text==='Mention')return schema.nodes.luna_mention.create({url,id:itemID()},null,node.marks.filter(mark=>mark!==link));
      if(node.text==='URL')return schema.text(url,node.marks);
      return node;
    });
  },
  markdown(doc) {
    // Retain Luna's portable [URL]/[Mention]/[Bookmark]/[Embed] conventions.
    return serializer.serialize(mapTree(doc,node=>{
      const link=node.isText&&schema.marks.link.isInSet(node.marks);
      return link&&node.text===link.attrs.href?schema.text('URL',node.marks):node;
    }));
  },
  describe(state) {
    const selection=state.selection,counts={};
    state.doc.descendants(node=>{if(!node.isText)counts[node.type.name]=(counts[node.type.name]||0)+1;});
    return {document:state.doc.toJSON(),selection:selection.toJSON(),counts,
      paragraph:selection.$from.parent.type.name,offset:selection.$from.parentOffset,
      selected:state.doc.textBetween(selection.from,selection.to,'\n')};
  }
};
