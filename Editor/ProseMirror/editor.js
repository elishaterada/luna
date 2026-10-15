import { Slice } from "prosemirror-model";
import {
  EditorState,
  TextSelection,
  NodeSelection,
  Plugin,
} from "prosemirror-state";
import { EditorView, Decoration, DecorationSet } from "prosemirror-view";
import { exampleSetup } from "prosemirror-example-setup";
import {
  undo,
  redo,
  closeHistory,
  undoDepth,
  redoDepth,
} from "prosemirror-history";
import {
  toggleMark,
  selectAll,
  setBlockType,
  wrapIn,
  chainCommands,
  exitCode,
  joinBackward,
  joinForward,
  deleteSelection,
  baseKeymap,
} from "prosemirror-commands";
import {
  sinkListItem,
  liftListItem,
  wrapInList,
  splitListItem,
} from "prosemirror-schema-list";
import {
  inputRules,
  wrappingInputRule,
  InputRule,
} from "prosemirror-inputrules";
import { keymap } from "prosemirror-keymap";
import { schema, NoteModel, webURL } from "./note-model.js";
import { createLinks } from "./links.js";

let view,
  source = "",
  media = {},
  dismissedSlash = null,
  slashIndex = 0;
const links = createLinks(
  () => view,
  () => {},
  "note",
);
const toolbar = document.getElementById("selection-toolbar"),
  slashMenu = document.getElementById("slash-menu");
const commands = {
  bold: toggleMark(schema.marks.strong),
  italic: toggleMark(schema.marks.em),
  code: toggleMark(schema.marks.code),
  strike: toggleMark(schema.marks.strike),
  undo,
  redo,
  selectAll,
  indent: sinkListItem(schema.nodes.list_item),
  outdent: liftListItem(schema.nodes.list_item),
  continue: (state, dispatch, view) => {
    const $pos = state.selection.$from,
      attrs =
        $pos.depth >= 2 &&
        $pos.node(-1).type === schema.nodes.list_item &&
        $pos.node(-1).attrs;
    return splitListItem(
      schema.nodes.list_item,
      attrs?.checked !== null && attrs
        ? { ...attrs, checked: false }
        : undefined,
    )(state, dispatch, view);
  },
  text: setBlockType(schema.nodes.paragraph),
  h1: setBlockType(schema.nodes.heading, { level: 1 }),
  h2: setBlockType(schema.nodes.heading, { level: 2 }),
  quote: wrapIn(schema.nodes.blockquote),
  bullets: wrapInList(schema.nodes.bullet_list, { bullet: "-" }),
  numbers: wrapInList(schema.nodes.ordered_list),
  task: wrapInList(schema.nodes.bullet_list, { bullet: "-" }),
  codeblock: setBlockType(schema.nodes.code_block),
};
const slashCommands = [
  ["Text", "text", "paragraph"],
  ["Heading 1", "h1", "h1 heading"],
  ["Heading 2", "h2", "h2 heading"],
  ["Quote", "quote", "quote"],
  ["Bulleted list", "bullets", "bullet list"],
  ["Numbered list", "numbers", "number list"],
  ["To-do list", "task", "todo check list"],
  ["Code block", "codeblock", "code"],
  ["Divider", "divider", "rule"],
];
function post(kind, extra = {}) {
  window.webkit?.messageHandlers?.note.postMessage({
    page: window.lunaPage,
    kind,
    ...extra,
  });
}
function step(tr) {
  view.dispatch(closeHistory(tr).scrollIntoView());
  view.dispatch(closeHistory(view.state.tr));
}
function slashContext() {
  const { selection } = view.state;
  if (
    !selection.empty ||
    selection.$from.parent.type !== schema.nodes.paragraph
  )
    return null;
  const prefix = selection.$from.parent.textBetween(
      0,
      selection.$from.parentOffset,
    ),
    match = prefix.match(/^\/([^\n]*)$/);
  return match
    ? {
        from: selection.$from.start(),
        to: selection.from,
        query: match[1].toLowerCase(),
      }
    : null;
}
function applySlash(name) {
  const context = slashContext();
  if (!context) return false;
  const tr = closeHistory(view.state.tr.delete(context.from, context.to));
  view.dispatch(tr);
  if (name === "divider")
    view.dispatch(
      view.state.tr
        .replaceSelectionWith(schema.nodes.horizontal_rule.create())
        .scrollIntoView(),
    );
  else commands[name]?.(view.state, view.dispatch, view);
  if (name === "task") {
    const $pos = view.state.selection.$from;
    for (let depth = $pos.depth; depth > 0; depth--)
      if ($pos.node(depth).type === schema.nodes.list_item) {
        view.dispatch(
          view.state.tr.setNodeMarkup($pos.before(depth), null, {
            checked: false,
          }),
        );
        break;
      }
  }
  view.dispatch(closeHistory(view.state.tr));
  dismissedSlash = null;
  slashMenu.hidden = true;
  view.focus();
  return true;
}
function position(element, pos) {
  const rect = view.coordsAtPos(pos),
    margin = 8;
  element.style.left =
    Math.max(
      margin,
      Math.min(rect.left, innerWidth - element.offsetWidth - margin),
    ) + "px";
  element.style.top =
    Math.max(
      margin,
      Math.min(rect.bottom + 7, innerHeight - element.offsetHeight - margin),
    ) + "px";
}
function refresh() {
  const selection = view.state.selection,
    context = slashContext();
  if (context && context.query !== dismissedSlash && !view.composing) {
    const matches = slashCommands.filter((command) =>
      (command[0] + " " + command[2]).toLowerCase().includes(context.query),
    );
    slashMenu.replaceChildren();
    slashIndex = Math.min(slashIndex, Math.max(0, matches.length - 1));
    matches.forEach(([label, name], index) => {
      const button = document.createElement("button");
      button.textContent = label;
      button.dataset.command = name;
      button.setAttribute("aria-selected", String(index === slashIndex));
      button.onmousedown = (event) => event.preventDefault();
      button.onclick = () => applySlash(name);
      slashMenu.append(button);
    });
    slashMenu.hidden = !matches.length;
    if (matches.length) position(slashMenu, selection.from);
  } else {
    slashMenu.hidden = true;
    if (!context) dismissedSlash = null;
  }
  const field = document.activeElement?.closest("#selection-toolbar");
  toolbar.hidden =
    selection.empty ||
    selection instanceof NodeSelection ||
    (!view.hasFocus() && !field);
  if (!toolbar.hidden) {
    for (const button of toolbar.querySelectorAll("[data-format]")) {
      const mark = {
        bold: "strong",
        italic: "em",
        code: "code",
        strike: "strike",
      }[button.dataset.format];
      if (mark)
        button.setAttribute(
          "aria-pressed",
          String(
            view.state.doc.rangeHasMark(
              selection.from,
              selection.to,
              schema.marks[mark],
            ),
          ),
        );
    }
    position(toolbar, selection.to);
  }
}
function backward(state, dispatch, editor) {
  const { $from, empty } = state.selection;
  if (!empty || $from.parentOffset !== 0) return false;
  // Empty list items become an ordinary writing line in one model transaction.
  if ($from.depth >= 2 && $from.node(-1).type === schema.nodes.list_item)
    return liftListItem(schema.nodes.list_item)(state, dispatch, editor);
  return false;
}
function mediaView(node) {
  const dom = document.createElement(node.isInline ? "span" : "figure");
  dom.className = "luna-media";
  dom.contentEditable = "false";
  const attachment = media[node.attrs.src],
    src =
      attachment?.url ||
      (/^(https?:)/.test(node.attrs.src) ? node.attrs.src : null);
  const mime = attachment?.type || "",
    name = attachment?.name || node.attrs.alt || "Attachment";
  let element;
  if (mime.startsWith("video/")) {
    element = document.createElement("video");
    element.controls = true;
    element.preload = "metadata";
  } else if (mime.startsWith("audio/")) {
    element = document.createElement("audio");
    element.controls = true;
    element.preload = "metadata";
  } else if (!attachment || mime.startsWith("image/")) {
    element = document.createElement("img");
    element.alt = name;
    element.loading = "lazy";
  } else {
    element = document.createElement("button");
    element.textContent = "Open " + name;
    element.onclick = () => post("openMedia", { reference: node.attrs.src });
  }
  if (src && element.tagName !== "BUTTON") element.src = src;
  if (!src) {
    element = document.createElement("span");
    element.textContent = "Missing attachment: " + name;
  }
  dom.append(element);
  return {
    dom,
    stopEvent: (event) => !!event.target.closest("video,audio,button"),
    ignoreMutation: () => true,
  };
}
function clipboardText(slice) {
  const doc = schema.nodes.doc.createAndFill(null, slice.content);
  return doc
    ? NoteModel.markdown(doc)
    : slice.content.textBetween(0, slice.content.size, "\n");
}
const writing = new Plugin({
  props: {
    decorations(state) {
      const decorations = [];
      state.doc.descendants((node, pos) => {
        if (
          node.type === schema.nodes.list_item &&
          node.attrs.checked !== null
        ) {
          const checkbox = document.createElement("input");
          checkbox.type = "checkbox";
          checkbox.checked = node.attrs.checked;
          checkbox.setAttribute(
            "aria-label",
            "Mark task " + (node.attrs.checked ? "incomplete" : "complete"),
          );
          checkbox.contentEditable = "false";
          checkbox.onmousedown = (event) => event.preventDefault();
          checkbox.onclick = (event) => {
            event.preventDefault();
            const current = view.state.doc.nodeAt(pos);
            if (current?.type === schema.nodes.list_item)
              step(
                view.state.tr.setNodeMarkup(pos, null, {
                  ...current.attrs,
                  checked: !current.attrs.checked,
                }),
              );
          };
          decorations.push(
            Decoration.widget(pos + 2, checkbox, {
              side: -1,
              key: "task-" + pos + "-" + node.attrs.checked,
              stopEvent: () => true,
            }),
          );
        }
      });
      return DecorationSet.create(state.doc, decorations);
    },
    handleKeyDown(_view, event) {
      if (event.isComposing || view.composing) return false;
      if (
        !slashMenu.hidden &&
        ["ArrowDown", "ArrowUp", "Enter", "Escape"].includes(event.key)
      ) {
        event.preventDefault();
        if (event.key === "Escape") {
          dismissedSlash = slashContext()?.query;
          slashMenu.hidden = true;
        } else if (event.key === "Enter")
          slashMenu.children[slashIndex]?.click();
        else {
          slashIndex =
            (slashIndex +
              (event.key === "ArrowDown" ? 1 : slashMenu.children.length - 1)) %
            slashMenu.children.length;
          refresh();
        }
        return true;
      }
      return false;
    },
    handlePaste(_view, event) {
      if (
        links.paste(
          event.clipboardData.getData("text/plain"),
          event.clipboardData.getData("text/html"),
        )
      )
        return true;
      const text = event.clipboardData.getData("text/plain");
      if (!text) return false;
      insertSnippet(text);
      return true;
    },
    clipboardTextSerializer: clipboardText,
  },
});
const listRules = inputRules({
  rules: [
    wrappingInputRule(
      /^([*+•-])\s$/,
      schema.nodes.bullet_list,
      (match) => ({ bullet: match[1], tight: true }),
      (match, node) => node.attrs.bullet === match[1],
    ),
    new InputRule(/^\[([ xX])\] $/, (state, match, start, end) => {
      const $pos = state.doc.resolve(start);
      if ($pos.depth < 2 || $pos.node(-1).type !== schema.nodes.list_item)
        return null;
      return state.tr
        .delete(start, end)
        .setNodeMarkup($pos.before($pos.depth - 1), null, {
          ...$pos.node(-1).attrs,
          checked: match[1] !== " ",
        });
    }),
  ],
});
function plugins() {
  return [
    writing,
    links.plugin,
    listRules,
    keymap({
      Tab: chainCommands(commands.indent, (state, dispatch) => {
        if (dispatch) dispatch(state.tr.insertText("    "));
        return true;
      }),
      Enter: commands.continue,
      "Shift-Tab": commands.outdent,
      Backspace: backward,
      "Mod-k": () => {
        addLink();
        return true;
      },
    }),
    ...exampleSetup({ schema, menuBar: false }),
  ];
}
function insertSnippet(text, showMenu = false) {
  if (showMenu && links.paste(text)) return;
  if (view.state.selection.$from.parent.type === schema.nodes.code_block) {
    view.dispatch(closeHistory(view.state.tr.insertText(text)));
    return;
  }
  const doc = NoteModel.parse(text, false);
  // Open slices let ProseMirror fit blocks into the current paragraph/list.
  const slice = Slice.maxOpen(doc.content);
  step(view.state.tr.replaceSelection(slice).setStoredMarks([]));
  view.focus();
}
function addLink() {
  links.close();
  const selection = view.state.selection;
  if (selection.empty) {
    links.showSelected();
    return;
  }
  const bookmark = selection.getBookmark();
  toolbar.hidden = false;
  const form = document.createElement("form"),
    input = document.createElement("input");
  input.type = "url";
  input.placeholder = "https://";
  input.required = true;
  input.setAttribute("aria-label", "Link URL");
  const save = document.createElement("button");
  save.textContent = "Save link";
  save.type = "submit";
  const cancel = document.createElement("button");
  cancel.textContent = "Cancel";
  cancel.type = "button";
  function restore() {
    view.dispatch(view.state.tr.setSelection(bookmark.resolve(view.state.doc)));
    resetToolbar();
    view.focus();
  }
  cancel.onclick = restore;
  form.onkeydown = (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      restore();
    }
  };
  form.onsubmit = (event) => {
    event.preventDefault();
    const url = webURL(input.value);
    input.setCustomValidity(url ? "" : "Enter an http or https URL.");
    if (!url) {
      input.reportValidity();
      return;
    }
    const selected = bookmark.resolve(view.state.doc),
      tr = view.state.tr.addMark(
        selected.from,
        selected.to,
        schema.marks.link.create({ href: url }),
      );
    step(
      tr
        .setSelection(TextSelection.near(tr.doc.resolve(selected.to)))
        .setStoredMarks([]),
    );
    resetToolbar();
    view.focus();
  };
  input.oninput = () => input.setCustomValidity("");
  form.append(input, save, cancel);
  toolbar.replaceChildren(form);
  position(toolbar, selection.to);
  input.focus();
}
function resetToolbar() {
  toolbar.replaceChildren();
  for (const [name, label] of [
    ["bold", "Bold"],
    ["italic", "Italic"],
    ["strike", "Strikethrough"],
    ["code", "Code"],
    ["link", "Link"],
  ]) {
    const button = document.createElement("button");
    button.dataset.format = name;
    button.textContent = label;
    button.onmousedown = (event) => event.preventDefault();
    button.onclick = () => (name === "link" ? addLink() : command(name));
    toolbar.append(button);
  }
}
function command(name, text = "") {
  if (!view) return false;
  const field = document.activeElement;
  if (field?.matches("input:not([type=checkbox]),textarea")) {
    if (name === "selectAll") {
      field.select();
      return true;
    }
    if (["undo", "redo", "pastePlainText", "paste"].includes(name))
      return document.execCommand(
        name === "pastePlainText" || name === "paste" ? "insertText" : name,
        false,
        text,
      );
    return false;
  }
  if (field?.tagName === "IFRAME") return false;
  if (name === "showURL") {
    window.lunaEditor.showURL(text);
    return true;
  }
  if (name === "selectAll") view.dispatch(closeHistory(view.state.tr));
  if (name === "showLink") {
    links.showSelected();
    return true;
  }
  if (name === "link") {
    addLink();
    return true;
  }
  links.close();
  view.focus();
  if (name === "paste") {
    insertSnippet(text, true);
    return true;
  }
  if (name === "pastePlainText") {
    if (view.state.selection.$from.parent.type === schema.nodes.code_block) {
      step(view.state.tr.insertText(text));
      return true;
    }
    const rows = text.split("\n"),
      nodes = [];
    rows.forEach((row, index) => {
      if (index) nodes.push(schema.nodes.hard_break.create());
      if (row) nodes.push(schema.text(row));
    });
    step(
      view.state.tr
        .replaceSelection(
          new Slice(schema.nodes.paragraph.create(null, nodes).content, 0, 0),
        )
        .setStoredMarks([]),
    );
    return true;
  }
  return commands[name]?.(view.state, view.dispatch, view) || false;
}
window.lunaEditor = {
  boot(config) {
    window.lunaPage = config.page;
    media = config.media || {};
    source = config.source;
    this.theme(config.dark, config.size);
    view?.destroy();
    view = new EditorView(document.getElementById("editor"), {
      state: EditorState.create({
        doc: NoteModel.parse(source),
        plugins: plugins(),
      }),
      nodeViews: {
        ...links.nodeViews,
        luna_media: mediaView,
        image: mediaView,
      },
      attributes: { "aria-label": "Note editor", spellcheck: "false" },
      dispatchTransaction(tr) {
        view.updateState(view.state.apply(tr));
        if (tr.docChanged) {
          source = NoteModel.markdown(view.state.doc);
          post("input", { source });
        }
        refresh();
      },
      handleDOMEvents: {
        compositionend: () => {
          setTimeout(refresh, 30);
          return false;
        },
        focus: () => {
          refresh();
          return false;
        },
        blur: () => {
          setTimeout(refresh, 0);
          return false;
        },
      },
    });
    resetToolbar();
    refresh();
    return true;
  },
  theme(dark, size) {
    document.documentElement.dataset.theme = dark ? "dark" : "light";
    document.documentElement.style.setProperty("--editor-size", size + "px");
  },
  focus(input = []) {
    if (!view) return false;
    if (
      !input.length ||
      !document.activeElement?.matches("input:not([type=checkbox]),textarea")
    )
      view.focus();
    for (const item of input) {
      const state = view.state;
      if (item.key === "command") {
        command(item.name, item.text);
        continue;
      }
      if (item.key === "snippet") {
        insertSnippet(item.text, item.menu === "true");
        continue;
      }
      const field = document.activeElement;
      if (
        field?.matches("input:not([type=checkbox]),textarea") &&
        item.key !== "text"
      ) {
        if (item.key === "Enter") field.form?.requestSubmit();
        else
          document.execCommand(
            item.key === "Backspace" ? "delete" : "forwardDelete",
          );
        continue;
      }
      if (item.key === "text") {
        if (
          document.activeElement?.matches("input:not([type=checkbox]),textarea")
        )
          document.execCommand("insertText", false, item.text);
        else view.dispatch(state.tr.insertText(item.text));
      } else if (item.key === "Enter")
        chainCommands(commands.continue, baseKeymap.Enter)(
          state,
          view.dispatch,
          view,
        );
      else {
        const backwardKey = item.key === "Backspace";
        if (
          chainCommands(
            deleteSelection,
            backwardKey ? backward : () => false,
            backwardKey ? joinBackward : joinForward,
          )(state, view.dispatch, view)
        )
          continue;
        const { $from, from } = state.selection,
          offset = $from.parentOffset,
          text = $from.parent.textContent;
        const segments = [
          ...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(
            text,
          ),
        ];
        const start = backwardKey
          ? [...segments].reverse().find((part) => part.index < offset)?.index
          : offset;
        const end = backwardKey
          ? offset
          : segments.find((part) => part.index >= offset)?.index +
            (segments.find((part) => part.index >= offset)?.segment.length ||
              0);
        if (Number.isFinite(start) && Number.isFinite(end) && end > start)
          view.dispatch(
            state.tr.delete(from - offset + start, from - offset + end),
          );
      }
    }
    return true;
  },
  command,
  insertSnippet,
  resolve: links.resolve,
  get session() {
    return links.session;
  },
  showURL(url) {
    let found = null;
    view.state.doc.descendants((node, pos) => {
      if (
        node.attrs.url === url ||
        schema.marks.link.isInSet(node.marks)?.attrs.href === url
      )
        found = pos;
    });
    if (found !== null) {
      this.select(found);
      links.showSelected();
    }
  },
  select(from, to = from) {
    view.dispatch(
      view.state.tr.setSelection(
        TextSelection.create(view.state.doc, from, to),
      ),
    );
  },
  setMedia(value) {
    media = value;
    view.setProps({
      nodeViews: {
        ...links.nodeViews,
        luna_media: mediaView,
        image: mediaView,
      },
    });
  },
  get view() {
    return view;
  },
  get source() {
    return source;
  },
  get state() {
    return NoteModel.describe(view.state);
  },
  get history() {
    return { undo: undoDepth(view.state), redo: redoDepth(view.state) };
  },
};
window.source = () => source;
document.addEventListener(
  "scroll",
  () => {
    if (!toolbar.contains(document.activeElement)) {
      toolbar.hidden = true;
    }
    slashMenu.hidden = true;
  },
  true,
);
window.addEventListener("resize", refresh);
