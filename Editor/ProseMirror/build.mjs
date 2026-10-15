// Bundle the saved editor and its diagnostic trial from one pinned dependency set.
import { build } from "esbuild";
import { readFile, writeFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const nodePaths = [fileURLToPath(new URL("node_modules", import.meta.url))];
const result = await build({
  nodePaths,
  entryPoints: [
    fileURLToPath(
      new URL("../../Prototypes/ProseMirror/main.js", import.meta.url),
    ),
  ],
  bundle: true,
  write: false,
  format: "iife",
  target: "safari17",
  minify: true,
  legalComments: "inline",
});
const template = await readFile(
  new URL("../../Prototypes/ProseMirror/shell.html", import.meta.url),
  "utf8",
);
const editorCSS = await readFile(
  new URL(
    "node_modules/prosemirror-view/style/prosemirror.css",
    import.meta.url,
  ),
  "utf8",
);
const css = await readFile(
  new URL("../../Prototypes/ProseMirror/style.css", import.meta.url),
  "utf8",
);
const html = template
  .replace("/* STYLES */", editorCSS + "\n" + css)
  .replace(
    "/* SCRIPT */",
    result.outputFiles[0].text.replaceAll("</script", "<\\/script"),
  );
await writeFile(
  new URL(
    "../../Sources/Luna/Resources/ProseMirrorPrototype.html",
    import.meta.url,
  ),
  html,
);

// Preserve every bundled runtime dependency's notice, including transitive packages.
const lock = JSON.parse(
  await readFile(new URL("package-lock.json", import.meta.url), "utf8"),
);
let notices = "Luna ProseMirror prototype — bundled runtime licenses\n";
for (const [name, pkg] of Object.entries(lock.packages)) {
  if (!name || pkg.dev) continue;
  const directory = new URL(name + "/", import.meta.url);
  const filename = (await readdir(directory)).find((file) =>
    /^licen[cs]e(?:[-.]|$)/i.test(file),
  );
  if (!filename) throw new Error("Missing license for " + name);
  const license = await readFile(new URL(filename, directory), "utf8");
  notices +=
    "\n\n" +
    name.replace("node_modules/", "") +
    " " +
    pkg.version +
    "\n" +
    license;
}
await writeFile(
  new URL(
    "../../Sources/Luna/Resources/ProseMirrorPrototype-LICENSES.txt",
    import.meta.url,
  ),
  notices,
);
console.log(
  "Built offline ProseMirrorPrototype.html (" +
    Math.round(Buffer.byteLength(html) / 1024) +
    " KB)",
);

const production = await build({
  entryPoints: [fileURLToPath(new URL("editor.js", import.meta.url))],
  nodePaths,
  bundle: true,
  write: false,
  format: "iife",
  target: "safari17",
  minify: true,
  legalComments: "inline",
});
const productionTemplate = await readFile(
  new URL("shell.html", import.meta.url),
  "utf8",
);
const productionCSS = await readFile(
  new URL("style.css", import.meta.url),
  "utf8",
);
await writeFile(
  new URL(
    "../../Sources/Luna/Resources/ProseMirrorEditor.html",
    import.meta.url,
  ),
  productionTemplate
    .replace("/* STYLES */", editorCSS + "\n" + productionCSS)
    .replace(
      "/* SCRIPT */",
      production.outputFiles[0].text.replaceAll("</script", "<\\/script"),
    ),
);
await writeFile(
  new URL(
    "../../Sources/Luna/Resources/ProseMirrorEditor-LICENSES.txt",
    import.meta.url,
  ),
  notices.replace("prototype", "editor"),
);
