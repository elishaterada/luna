import Foundation
import JavaScriptCore

/// Render only portable inline styles. Delimiter metadata keeps existing source
/// spellings intact while edits serialize the current content, not stale HTML.
enum InlineFormatting {
    private static let lock = NSLock()
    private static let context: JSContext? = {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Luna_Luna.bundle").path
        let resources = packaged.flatMap { Bundle(path: $0) } ?? Bundle.module
        guard let url = resources.url(forResource: "marked", withExtension: "js", subdirectory: "Resources"),
              let context = JSContext(), let script = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        context.evaluateScript(script)
        let host: @convention(block) (String) -> String = { NoteEmbeds.webURL($0)?.host ?? "" }
        context.setObject(host, forKeyedSubscript: "inlineLinkHost" as NSString)
        context.evaluateScript(#"""
        function escapeInline(s) {return s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
        // The bundled tokenizer rejects an unmatched backtick inside a link
        // label. Preserve Luna's literal titles while still parsing paired code.
        marked.use({tokenizer:{link(source) {
          const match=source.match(/^\[((?:\\.|[^\]\\\n])+)]\((https?:\/\/[^\s)]+)\)/);
          if(this.lexer.state.inLink||!match||!match[1].includes('`'))return false;
          this.lexer.state.inLink=true;
          let tokens;
          try {tokens=this.lexer.inlineTokens(match[1]);} finally {this.lexer.state.inLink=false;}
          return {type:'link',raw:match[0],href:match[2],text:match[1],tokens};
        }}});
        function inlineStyles(source) {
          function render(tokens) {return tokens.map((token,index)=>{
            let tag,delimiter;
            if(token.type==='strong'){tag='strong';delimiter=token.raw.startsWith('__')?'__':'**';}
            else if(token.type==='em'){tag='em';delimiter=token.raw.startsWith('_')?'_':'*';}
            else if(token.type==='del'){tag='s';delimiter='~~';}
            else if(token.type==='codespan') {
              delimiter=token.raw.match(/^`+/)[0];
              return '<code data-inline-delimiter="'+delimiter+'">'+escapeInline(token.raw.slice(delimiter.length,-delimiter.length))+'</code>';
            } else if(token.type==='link'&&token.raw.startsWith('[')) {
              const match=token.raw.match(/^\[((?:\\.|[^\]\\\n])+)]\((https?:\/\/[^\s)]+)\)/);
              const hostname=inlineLinkHost(match?.[2]||'');
              if(!match||!hostname)return escapeInline(token.raw);
              const label=match[1].replaceAll('\\]',']').replaceAll('\\\\','\\'),value=escapeInline(match[2]);
              if(label==='Mention') {
                const host=escapeInline(hostname);
                return '<a class="inline-link mention-link" contenteditable="false" data-url="'+value+'" href="'+value+'" aria-label="Mention: '+host+'"><img class="link-favicon" alt="" hidden><span class="mention-title">'+host+'</span><span class="mention-tooltip"><strong>'+host+'</strong><small>'+value+'</small></span></a>'+(index===tokens.length-1?'\u200B':'');
              }
              return '<a class="inline-link" data-url="'+value+'" href="'+value+'">'+(label==='URL'?value:render(token.tokens))+'</a>';
            } else return escapeInline(token.raw);
            return '<'+tag+' data-inline-delimiter="'+delimiter+'">'+render(token.tokens)+'</'+tag+'>';
          }).join('');}
          return render(marked.Lexer.lexInline(source,{...marked.defaults,gfm:true}));
        }
        """#)
        return context
    }()

    static func html(_ source: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return context?.objectForKeyedSubscript("inlineStyles")?.call(withArguments: [source])?.toString()
            ?? NoteEmbeds.escape(source)
    }

}
