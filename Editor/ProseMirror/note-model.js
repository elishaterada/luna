import { Schema } from "prosemirror-model";
import {
  schema as base,
  defaultMarkdownParser,
  defaultMarkdownSerializer,
  MarkdownParser,
  MarkdownSerializer,
} from "prosemirror-markdown";

let nextID = 0;
export const itemID = () => `link-${++nextID}`;
export function webURL(value) {
  if (typeof value !== "string" || /\s/.test(value) || value.length > 8192)
    return null;
  try {
    const url = new URL(value);
    return /^https?:$/.test(url.protocol) &&
      url.host &&
      !url.username &&
      !url.password
      ? url.href
      : null;
  } catch {
    return null;
  }
}
export const markdownURL = (url) =>
  url.replaceAll("(", "%28").replaceAll(")", "%29");
export function pastedURL(text, html = "") {
  const plain = text.trim(),
    url = webURL(plain);
  if (url) return url;
  if (!/^<iframe\b/i.test(plain) && !(!plain && /<iframe\b/i.test(html)))
    return null;
  const fragment = new DOMParser().parseFromString(plain || html, "text/html");
  return webURL(fragment.querySelector("iframe")?.getAttribute("src"));
}
export const schema = new Schema({
  nodes: base.spec.nodes
    .update("heading", {
      ...base.spec.nodes.get("heading"),
      content: "inline*",
    })
    .update("ordered_list", {
      ...base.spec.nodes.get("ordered_list"),
      attrs: { order: { default: 1 }, tight: { default: true } },
    })
    .update("bullet_list", {
      ...base.spec.nodes.get("bullet_list"),
      attrs: { tight: { default: true }, bullet: { default: "-" } },
    })
    .update("list_item", {
      ...base.spec.nodes.get("list_item"),
      attrs: { checked: { default: null }, taskStyle: { default: "markdown" } },
      toDOM: (node) => [
        "li",
        node.attrs.checked === null
          ? {}
          : { "data-checked": String(node.attrs.checked) },
        0,
      ],
    })
    .addBefore("paragraph", "luna_media", {
      group: "block",
      atom: true,
      attrs: { src: {}, alt: { default: "" }, title: { default: null } },
      parseDOM: [
        {
          tag: "figure[data-luna-media]",
          getAttrs: (dom) => ({
            src: dom.dataset.lunaMedia,
            alt: dom.dataset.alt || "",
          }),
        },
      ],
      toDOM: (node) => [
        "figure",
        { "data-luna-media": node.attrs.src, contenteditable: "false" },
        node.attrs.alt || "Attachment",
      ],
    })
    .addBefore("text", "luna_mention", {
      inline: true,
      group: "inline",
      atom: true,
      selectable: true,
      attrs: { url: {}, id: { default: null } },
      leafText: (node) => node.attrs.url,
      parseDOM: [
        {
          tag: "span[data-luna-mention]",
          getAttrs: (dom) => {
            const url = webURL(dom.dataset.lunaMention);
            return url ? { url, id: itemID() } : false;
          },
        },
      ],
      toDOM: (node) => [
        "span",
        {
          "data-luna-mention": node.attrs.url,
          contenteditable: "false",
          class: "luna-mention",
        },
        node.attrs.url,
      ],
    })
    .addBefore("paragraph", "luna_card", {
      group: "block",
      atom: true,
      selectable: true,
      attrs: { url: {}, kind: { default: "Bookmark" }, id: { default: null } },
      leafText: (node) => node.attrs.url,
      parseDOM: [
        {
          tag: "figure[data-luna-url]",
          getAttrs: (dom) => {
            const url = webURL(dom.dataset.lunaUrl);
            return url
              ? {
                  url,
                  kind: dom.dataset.lunaKind === "Embed" ? "Embed" : "Bookmark",
                  id: itemID(),
                }
              : false;
          },
        },
      ],
      toDOM: (node) => [
        "figure",
        {
          "data-luna-url": node.attrs.url,
          "data-luna-kind": node.attrs.kind,
          contenteditable: "false",
        },
        node.attrs.kind + " · " + node.attrs.url,
      ],
    }),
  marks: base.spec.marks
    .addToEnd("strike", {
      parseDOM: [{ tag: "s" }, { tag: "del" }],
      toDOM: () => ["s", 0],
    })
    .update("link", {
      ...base.spec.marks.get("link"),
      toDOM: (mark) => [
        "a",
        {
          href: mark.attrs.href,
          title: mark.attrs.title,
          "data-prototype-link": "true",
        },
        0,
      ],
    }),
});
const tokenizer = defaultMarkdownParser.tokenizer;
tokenizer.enable("strikethrough");
// Luna treats soft line breaks as visible writing lines.
tokenizer.core.ruler.after("inline", "luna_task_items", (state) => {
  for (let i = 0; i < state.tokens.length; i++) {
    const token = state.tokens[i];
    if (
      token.type === "bullet_list_open" &&
      /^\s*• /.test(state.env.lunaLines?.[token.map?.[0]] || "")
    )
      token.markup = "•";
    if (token.type === "list_item_open") {
      const inline = state.tokens[i + 2];
      const match =
        inline?.type === "inline" && inline.content.match(/^\[([ xX])\] /);
      if (match) {
        token.meta = {
          checked: match[1] !== " ",
          taskStyle: /^[ \t]*[☐☑] /.test(
            state.env.lunaLines?.[token.map?.[0]] || "",
          )
            ? "literal"
            : "markdown",
        };
        inline.content = inline.content.slice(4);
        const first = inline.children?.[0];
        if (first?.type === "text") first.content = first.content.slice(4);
      }
    }
  }
});
tokenizer.core.ruler.after("inline", "luna_cards", (state) => {
  for (let i = 0; i < state.tokens.length - 2; i++) {
    const [open, inline, close] = state.tokens.slice(i, i + 3);
    if (
      open.type !== "paragraph_open" ||
      inline.type !== "inline" ||
      close.type !== "paragraph_close"
    )
      continue;
    const match = inline.content.match(
      /^\[(Bookmark|Preview|Embed)\]\((https?:\/\/[^\s]+)\)$/,
    );
    const url = match && webURL(match[2]);
    if (!url) continue;
    const token = new open.constructor("luna_card", "figure", 0);
    token.map = [open.map[0], close.map?.[1] || open.map[1]];
    token.level = open.level;
    token.meta = {
      url,
      kind: match[1] === "Embed" ? "Embed" : "Bookmark",
      id: itemID(),
    };
    state.tokens.splice(i, 3, token);
  }
});
const parser = new MarkdownParser(schema, tokenizer, {
  ...defaultMarkdownParser.tokens,
  luna_card: { node: "luna_card", getAttrs: (token) => token.meta },
  bullet_list: {
    block: "bullet_list",
    getAttrs: (token) => ({ tight: true, bullet: token.markup || "-" }),
  },
  list_item: {
    block: "list_item",
    getAttrs: (token) => ({
      checked: token.meta?.checked ?? null,
      taskStyle: token.meta?.taskStyle || "markdown",
    }),
  },
  s: { mark: "strike" },
  softbreak: { node: "hard_break" },
});
const serializer = new MarkdownSerializer(
  {
    ...defaultMarkdownSerializer.nodes,
    hard_break(state) {
      state.write("\n");
    },
    bullet_list(state, node) {
      state.renderList(node, "  ", (index) =>
        node.child(index).attrs.taskStyle === "literal"
          ? ""
          : (node.attrs.bullet || "-") + " ",
      );
    },
    list_item(state, node) {
      const task = node.attrs.checked;
      if (task !== null)
        state.write(
          node.attrs.taskStyle === "literal"
            ? task
              ? "☑ "
              : "☐ "
            : task
              ? "[x] "
              : "[ ] ",
        );
      state.renderContent(node);
    },
    luna_media(state, node) {
      state.write(
        "![" +
          state.esc(node.attrs.alt) +
          "](" +
          markdownURL(node.attrs.src) +
          ")",
      );
      state.closeBlock(node);
    },
    luna_mention(state, node) {
      state.write("[Mention](" + markdownURL(node.attrs.url) + ")");
    },
    luna_card(state, node) {
      state.write(
        "[" + node.attrs.kind + "](" + markdownURL(node.attrs.url) + ")",
      );
      state.closeBlock(node);
    },
  },
  {
    ...defaultMarkdownSerializer.marks,
    strike: {
      open: "~~",
      close: "~~",
      mixable: true,
      expelEnclosingWhitespace: true,
    },
  },
);
function mapTree(node, convert) {
  if (node.isText || node.isLeaf) return convert(node);
  const children = [];
  node.forEach((child) => children.push(mapTree(child, convert)));
  return convert(node.type.create(node.attrs, children, node.marks));
}
// Preserve exact source for opening, Undo, and untouched top-level blocks. No source
// metadata is put into the editable document or exposed in copied content.
const originalDocuments = new WeakMap(),
  originalBlocks = new WeakMap();
let baseline = null;
function canonical(doc) {
  return serializer.serialize(
    mapTree(doc, (node) => {
      const link = node.isText && schema.marks.link.isInSet(node.marks);
      return link && node.text === link.attrs.href
        ? schema.text("URL", node.marks)
        : node;
    }),
  );
}
export const NoteModel = {
  parse(source, remember = true) {
    const lines = source.split("\n"),
      prepared = [],
      lineMap = [];
    let listIndent = null,
      fence = null;
    lines.forEach((line, index) => {
      const code = line.match(/^ {0,3}(`{3,}|~{3,})/),
        indent = line.match(/^[ \t]*/)[0].replaceAll("\t", "    ").length;
      const item =
        !fence && line.match(/^([ \t]*)(?:[-*+•]|\d+[.)]|[☐☑])(?: |$)/);
      // Luna's unindented writing line after a list is prose, rather than a
      // CommonMark lazy list continuation. Virtual separators never enter source.
      if (
        !fence &&
        line.trim() &&
        listIndent !== null &&
        !item &&
        indent <= listIndent
      ) {
        prepared.push("");
        lineMap.push(index);
        listIndent = null;
      }
      if (
        !fence &&
        item &&
        /^\s*(?:[2-9]|\d{2,})[.)] /.test(line) &&
        index &&
        lines[index - 1].trim() &&
        listIndent === null
      ) {
        prepared.push("");
        lineMap.push(index);
      }
      const richLine =
        !fence &&
        (/^ {0,3}\[(?:Bookmark|Preview|Embed)\]\(https?:\/\/.+\)\s*$/.test(
          line,
        ) ||
          /^ {0,3}!\[.*\]\(.+\)\s*$/.test(line));
      if (richLine && prepared.length && prepared.at(-1) !== "") {
        prepared.push("");
        lineMap.push(index);
      }
      let value = line;
      if (!fence)
        value = value
          .replace(
            /^([ \t]*)[☐☑] /,
            (_, prefix) =>
              prefix +
              "- [" +
              (line.trimStart()[0] === "☑" ? "x" : " ") +
              "] ",
          )
          .replace(/^([ \t]*)• /, "$1- ");
      prepared.push(value);
      lineMap.push(index);
      if (richLine) {
        prepared.push("");
        lineMap.push(index + 1);
      }
      if (item) listIndent = indent;
      if (!line.trim()) listIndent = null;
      if (code) {
        if (!fence) fence = code[1][0];
        else if (code[1][0] === fence) fence = null;
      }
    });
    const normalized = prepared.join("\n"),
      environment = { lunaLines: lineMap.map((index) => lines[index]) };
    const tokens = tokenizer.parse(normalized, environment);
    const ranges = tokens
      .filter((token) => token.level === 0 && token.map && token.nesting !== -1)
      .map((token) => [
        lineMap[token.map[0]],
        lineMap[token.map[1]] ?? lines.length,
      ]);
    let doc = mapTree(parser.parse(normalized, environment), (node) => {
      const link = node.isText && schema.marks.link.isInSet(node.marks),
        url = link && webURL(link.attrs.href);
      if (!url) return node;
      if (node.text === "Mention")
        return schema.nodes.luna_mention.create(
          { url, id: itemID() },
          null,
          node.marks.filter((mark) => mark !== link),
        );
      if (node.text === "URL")
        return schema.text(
          url,
          node.marks.map((mark) =>
            mark === link
              ? schema.marks.link.create({ ...link.attrs, href: url })
              : mark,
          ),
        );
      return node;
    });
    // Literal task glyphs from previous Luna versions remain portable.
    const children = [];
    let end = 0;
    function preserveLine(line) {
      const value = lines[line],
        node = schema.nodes.paragraph.create(
          null,
          value ? schema.text(value) : null,
        );
      originalBlocks.set(node, value);
      children.push(node);
    }
    doc.forEach((node, _, index) => {
      const range = ranges[index];
      if (!ranges.length) return;
      if (
        node.type === schema.nodes.paragraph &&
        node.childCount === 1 &&
        node.firstChild.type === schema.nodes.image
      )
        node = schema.nodes.luna_media.create(node.firstChild.attrs);
      if (range) {
        // Markdown-it includes trailing blank lines in list/container maps.
        // Keep those as writing rows rather than hiding them in cached source.
        if (node.type !== schema.nodes.code_block)
          while (range[1] > range[0] && lines[range[1] - 1]?.trim() === "")
            range[1]--;
        // Empty writing rows are real paragraphs, including trailing rows.
        for (let line = end; line < range[0]; line++) preserveLine(line);
        originalBlocks.set(node, lines.slice(range[0], range[1]).join("\n"));
        end = range[1];
      }
      children.push(node);
    });
    if (ranges.length || source.length)
      for (let line = end; line < lines.length; line++) preserveLine(line);
    doc = schema.nodes.doc.create(
      null,
      children.length ? children : schema.nodes.paragraph.create(),
    );
    originalDocuments.set(doc, source);
    if (remember) baseline = { doc, source };
    return doc;
  },
  markdown(doc) {
    if (originalDocuments.has(doc)) return originalDocuments.get(doc);
    if (baseline?.doc.eq(doc)) return baseline.source;
    const chunks = [];
    doc.forEach((node) => {
      let raw = originalBlocks.get(node);
      if (raw === undefined)
        baseline?.doc.forEach((original) => {
          if (raw === undefined && original.eq(node))
            raw = originalBlocks.get(original);
        });
      chunks.push(raw ?? canonical(schema.nodes.doc.create(null, node)));
    });
    return chunks.join("\n");
  },
  describe(state) {
    const selection = state.selection,
      counts = {};
    state.doc.descendants((node) => {
      if (!node.isText)
        counts[node.type.name] = (counts[node.type.name] || 0) + 1;
    });
    return {
      document: state.doc.toJSON(),
      selection: selection.toJSON(),
      counts,
      paragraph: selection.$from.parent.type.name,
      offset: selection.$from.parentOffset,
      selected: state.doc.textBetween(selection.from, selection.to, "\n"),
    };
  },
};
