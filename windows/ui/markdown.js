// Small, safe Markdown renderer for chat bubbles. Everything is HTML-escaped
// first; only the constructs below are turned back into markup.
(function () {
  const esc = (s) =>
    s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

  const emph = (s) =>
    s
      .replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^*\w])\*([^*\n]+)\*(?!\w)/g, "$1<em>$2</em>")
      .replace(/~~([^~\n]+)~~/g, "<del>$1</del>");

  function inline(s) {
    // s is already escaped. Protect code spans first.
    const codes = [];
    s = s.replace(/`([^`\n]+)`/g, (_, c) => {
      codes.push(c);
      return `\u0000${codes.length - 1}\u0000`;
    });
    // Links become placeholders too, so later passes (bare-URL autolink,
    // bold/em) can't rewrite text inside an anchor's attributes. Without this,
    // "[t](https://a/(https://b)" nested an <a> inside data-href="...".
    const links = [];
    const link = (u, t) => {
      links.push({ u, t });
      return `\u0001${links.length - 1}\u0001`;
    };
    s = s
      .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)<]+)\)/g, (_, t, u) => link(u, t))
      .replace(/(^|[\s(])(https?:\/\/[^\s<)\u0001]+)/g, (_, p, u) => {
        // Trailing punctuation and an escaped closing quote are not part of the URL.
        const m = u.match(/^(.*?)((?:[.,;:!?'*_~]|&quot;|&gt;)*)$/);
        return `${p}${link(m[1], m[1])}${m[2]}`;
      })
    ;
    s = emph(s);
    const restoreCodes = (x) => x.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${codes[+i]}</code>`);
    s = s.replace(/\u0001(\d+)\u0001/g, (_, i) => {
      const { u, t } = links[+i];
      return `<a class="link" data-href="${u}" title="${u}">${restoreCodes(emph(t))}</a>`;
    });
    return restoreCodes(s);
  }

  function render(src) {
    // \u0000/\u0001 are the placeholder delimiters used by inline(); strip any
    // the model emitted so they can't forge a placeholder.
    const lines = esc(String(src || "").replace(/[\u0000\u0001]/g, "")).split("\n");
    const out = [];
    let i = 0;
    let para = [];
    const flush = () => {
      if (para.length) out.push(`<p>${inline(para.join("<br>"))}</p>`);
      para = [];
    };
    while (i < lines.length) {
      const line = lines[i];
      const fence = line.match(/^\s*```\s*([\w+-]*)/);
      if (fence) {
        flush();
        const lang = fence[1];
        const body = [];
        i++;
        while (i < lines.length && !/^\s*```/.test(lines[i])) body.push(lines[i++]);
        i++;
        out.push(
          `<div class="code"><div class="code-head"><span>${lang || "code"}</span><button class="copy" data-copy>Copy</button></div><pre><code>${body.join("\n")}</code></pre></div>`
        );
        continue;
      }
      const h = line.match(/^(#{1,4})\s+(.*)$/);
      if (h) {
        flush();
        out.push(`<h${h[1].length + 2}>${inline(h[2])}</h${h[1].length + 2}>`);
        i++;
        continue;
      }
      if (/^\s*([-*_])\s*\1\s*\1[\s\-*_]*$/.test(line)) {
        flush();
        out.push("<hr>");
        i++;
        continue;
      }
      if (/^\s*&gt;\s?/.test(line)) {
        flush();
        const q = [];
        while (i < lines.length && /^\s*&gt;\s?/.test(lines[i])) q.push(lines[i++].replace(/^\s*&gt;\s?/, ""));
        out.push(`<blockquote>${inline(q.join("<br>"))}</blockquote>`);
        continue;
      }
      const li = line.match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
      if (li) {
        flush();
        const ordered = /\d/.test(li[2]);
        const items = [];
        while (i < lines.length) {
          const m = lines[i].match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
          if (m) {
            const box = m[3].match(/^\[( |x|X)\]\s+(.*)$/);
            const indent = m[1].length >= 2 ? ' class="sub"' : "";
            items.push(
              box
                ? `<li${indent}><span class="check">${box[1] === " " ? "☐" : "☑"}</span> ${inline(box[2])}</li>`
                : `<li${indent}>${inline(m[3])}</li>`
            );
            i++;
          } else if (/^\s{2,}\S/.test(lines[i]) && items.length) {
            items[items.length - 1] = items[items.length - 1].replace(/<\/li>$/, ` ${inline(lines[i].trim())}</li>`);
            i++;
          } else break;
        }
        out.push(ordered ? `<ol>${items.join("")}</ol>` : `<ul>${items.join("")}</ul>`);
        continue;
      }
      if (/^\s*\|.*\|\s*$/.test(line)) {
        flush();
        const rows = [];
        while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) rows.push(lines[i++]);
        const cells = (r) => r.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
        const body = rows.filter((r) => !/^\s*\|[\s:|-]+\|\s*$/.test(r));
        const [head, ...rest] = body;
        out.push(
          `<div class="table"><table><thead><tr>${cells(head).map((c) => `<th>${inline(c)}</th>`).join("")}</tr></thead><tbody>${rest
            .map((r) => `<tr>${cells(r).map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`)
            .join("")}</tbody></table></div>`
        );
        continue;
      }
      if (!line.trim()) {
        flush();
        i++;
        continue;
      }
      para.push(line);
      i++;
    }
    flush();
    return out.join("");
  }

  window.renderMarkdown = render;
  window.escapeHtml = esc;
})();
