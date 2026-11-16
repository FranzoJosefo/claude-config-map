// Tiny, safe Markdown renderer (no dependencies). Everything is HTML-escaped first.
(function () {
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  function inline(text) {
    const codes = [];
    let s = text.replace(/`([^`]+)`/g, (_, c) => { codes.push(c); return '\u0000' + (codes.length - 1) + '\u0000'; });
    s = esc(s);
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, t, u) =>
      /^(https?:|mailto:)/i.test(u.replace(/&amp;/g, '&')) ? `<a href="${u}">${t}</a>` : `${t} <span class="muted">(${u})</span>`);
    s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/(^|[\s(])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>');
    s = s.replace(/(^|[\s(])_([^_\s][^_]*)_(?=[\s).,;:!?]|$)/g, '$1<em>$2</em>');
    s = s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${esc(codes[+i])}</code>`);
    return s;
  }

  function table(lines) {
    const rows = lines.map(l => l.trim().replace(/^\||\|$/g, '').split('|').map(c => c.trim()));
    const isSep = r => r.every(c => /^:?-{1,}:?$/.test(c));
    let head = null, body = rows;
    if (rows.length > 1 && isSep(rows[1])) { head = rows[0]; body = rows.slice(2); }
    let h = '<div class="tablewrap"><table>';
    if (head) h += '<thead><tr>' + head.map(c => `<th>${inline(c)}</th>`).join('') + '</tr></thead>';
    h += '<tbody>' + body.map(r => '<tr>' + r.map(c => `<td>${inline(c)}</td>`).join('') + '</tr>').join('') + '</tbody></table></div>';
    return h;
  }

  function render(src) {
    let lines = src.replace(/\r\n?/g, '\n').split('\n');
    let out = '';
    // Frontmatter
    if (lines[0] === '---') {
      const end = lines.indexOf('---', 1);
      if (end > 0) {
        out += `<div class="frontmatter"><div class="fm-label">frontmatter</div><pre>${esc(lines.slice(1, end).join('\n'))}</pre></div>`;
        lines = lines.slice(end + 1);
      }
    }
    let i = 0, para = [];
    const flush = () => { if (para.length) { out += `<p>${inline(para.join(' '))}</p>`; para = []; } };
    while (i < lines.length) {
      const l = lines[i];
      const fence = l.match(/^\s*(```|~~~)(.*)$/);
      if (fence) {
        flush();
        const buf = []; i++;
        while (i < lines.length && !lines[i].trim().startsWith(fence[1])) buf.push(lines[i++]);
        i++;
        out += `<pre><code>${esc(buf.join('\n'))}</code></pre>`;
        continue;
      }
      if (/^<!--/.test(l.trim())) { // HTML comments are stripped by Claude Code; show them dimmed
        flush(); const buf = [l];
        while (!lines[i].includes('-->') && i + 1 < lines.length) buf.push(lines[++i]);
        i++; out += `<pre class="comment">${esc(buf.join('\n'))}</pre>`; continue;
      }
      const h = l.match(/^(#{1,6})\s+(.*)$/);
      if (h) { flush(); out += `<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`; i++; continue; }
      if (/^\s*([-*_])\s*\1\s*\1[\s\1]*$/.test(l)) { flush(); out += '<hr>'; i++; continue; }
      if (/^\s*\|/.test(l)) {
        flush(); const buf = [];
        while (i < lines.length && /^\s*\|/.test(lines[i])) buf.push(lines[i++]);
        out += table(buf); continue;
      }
      if (/^\s*>/.test(l)) {
        flush(); const buf = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) buf.push(lines[i++].replace(/^\s*>\s?/, ''));
        out += `<blockquote>${render(buf.join('\n'))}</blockquote>`; continue;
      }
      if (/^\s*([-*+]|\d+[.)])\s+/.test(l)) {
        flush();
        const stack = []; // {type, indent}
        while (i < lines.length && (/^\s*([-*+]|\d+[.)])\s+/.test(lines[i]) || (/^\s{2,}\S/.test(lines[i]) && stack.length))) {
          const m = lines[i].match(/^(\s*)([-*+]|\d+[.)])\s+(.*)$/);
          if (!m) { out += ' ' + inline(lines[i].trim()); i++; continue; }
          const indent = m[1].length, type = /\d/.test(m[2]) ? 'ol' : 'ul';
          while (stack.length && indent < stack[stack.length - 1].indent) { out += `</li></${stack.pop().type}>`; }
          if (!stack.length || indent > stack[stack.length - 1].indent) { out += `<${type}>`; stack.push({ type, indent }); }
          else out += '</li>';
          let item = m[3];
          const task = item.match(/^\[([ xX])\]\s+(.*)$/);
          if (task) item = `<input type="checkbox" disabled ${task[1] !== ' ' ? 'checked' : ''}> ` + inline(task[2]);
          else item = inline(item);
          out += `<li>${item}`; i++;
        }
        while (stack.length) out += `</li></${stack.pop().type}>`;
        continue;
      }
      if (!l.trim()) { flush(); i++; continue; }
      para.push(l.trim()); i++;
    }
    flush();
    return out;
  }
  window.renderMarkdown = render;
  window.escapeHTML = esc;
})();
