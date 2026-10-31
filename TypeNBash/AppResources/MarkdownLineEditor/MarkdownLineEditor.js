/*
 * MarkdownLineEditor.js
 * TypeNBash
 *
 * A line-based Markdown editor. The document is an array of source lines and
 * every line is one `<div>`; a line's text content is always exactly its
 * source, markers included, so a caret position is a (line, column) pair in
 * the source. Each line is classified from its own text plus a small state
 * carried from the line above (open fence, list indents, table), and an edit
 * re-renders from the edited line only until that carried state matches what
 * it was before.
 *
 * Typing inside one line is left to WebKit (so input methods work) and read
 * back from the line's text; everything that crosses lines — Return, deleting
 * across a line break, multi-line selections, paste, cut, drop, undo — is done
 * here on the line array. Every change is posted to the host as a splice.
 */
'use strict';

(() => {
    const doc = document.getElementById('doc');

    const post = (message) => {
        try { window.webkit.messageHandlers.editor.postMessage(message); } catch (_) { /* no host */ }
    };

    // ── Model ──────────────────────────────────────────────────────────────

    let lines = [''];
    let outStates = [];     // state after each line
    let inKeys = [];        // key of the state each line was rendered with
    let metas = [];         // each line's classification
    let activeDiv = null;   // the caret's line, whose markers are shown
    let composing = false;
    let pendingBefore = null;

    const INIT = { fence: null, list: [], table: false, pipe: false, align: null };
    const stateKey = (state) => JSON.stringify(state);

    // ── Line grammar ───────────────────────────────────────────────────────

    const RE = {
        blank: /^[ \t]*$/,
        fence: /^( {0,3})(`{3,}|~{3,})(.*)$/,
        fenceClose: /^ {0,3}(`{3,}|~{3,})[ \t]*$/,
        atx: /^ {0,3}#{1,6}(?=[ \t]|$)[ \t]*/,
        hr: /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/,
        quote: /^ {0,3}>[ \t]?/,
        li: /^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+|$)(\[[ xX]\][ \t]+)?/,
        delim: /^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/,
        lead: /^[ \t]*/,
    };
    const BULLETS = ['•', '◦', '▪'];

    const width = (whitespace) => {
        let n = 0;
        for (const c of whitespace) n += c === '\t' ? 4 - (n % 4) : 1;
        return n;
    };
    const isPipeRow = (text) => /(^|[^\\])\|/.test(text);
    const isDelim = (text) => text.includes('|') && RE.delim.test(text);
    /** Column alignments from a delimiter row such as `|:--|--:|:-:|`. */
    const alignments = (delim) => delim.trim().replace(/^\||\|$/g, '').split('|').map((c) => {
        c = c.trim();
        return c.startsWith(':') && c.endsWith(':') ? 'center' : c.endsWith(':') ? 'right' : 'left';
    });

    /** Classifies line `i` given the state carried from the line above. */
    function lex(i, state) {
        const text = lines[i];
        const out = { fence: state.fence, list: state.list, table: false, pipe: false, align: null };
        let m;

        if (state.fence) {
            m = RE.fenceClose.exec(text);
            if (m && m[1][0] === state.fence.ch && m[1].length >= state.fence.n) {
                out.fence = null;
                return { kind: 'fence-close', out };
            }
            return { kind: 'code', out };
        }
        if (RE.blank.test(text)) return { kind: 'blank', out };

        m = RE.fence.exec(text);
        if (m && !(m[2][0] === '`' && m[3].includes('`'))) {
            out.fence = { ch: m[2][0], n: m[2].length };
            out.list = [];
            const lang = m[3].trim().split(/\s+/)[0].toLowerCase();
            return { kind: 'fence-open', out, markEnd: m[1].length + m[2].length, lang };
        }
        if ((m = RE.atx.exec(text))) {
            out.list = [];
            return { kind: 'h' + m[0].trim().length, out, hmEnd: m[0].length };
        }
        if (RE.hr.test(text)) {
            out.list = [];
            return { kind: 'hr', out };
        }
        if ((m = RE.quote.exec(text))) {
            out.list = [];
            return { kind: 'quote', out, hmEnd: m[0].length };
        }
        if ((m = RE.li.exec(text))) {
            const indent = width(m[1]);
            const stack = state.list.slice();
            while (stack.length && stack[stack.length - 1] > indent) stack.pop();
            if (!stack.length || stack[stack.length - 1] < indent) stack.push(indent);
            out.list = stack;
            const marker = m[2];
            const ordered = marker[0] >= '0' && marker[0] <= '9';
            return {
                kind: 'li', out,
                depth: stack.length - 1,
                indEnd: m[1].length,
                hmEnd: m[0].length,
                contentCol: m[1].length + m[2].length + m[3].length,
                indent, marker, ordered,
                task: m[4] ? (m[4][1] === ' ' ? 'todo' : 'done') : null,
            };
        }

        const pipe = isPipeRow(text);
        if (pipe && state.pipe && isDelim(text)) {
            Object.assign(out, { table: true, pipe: true, list: [], align: alignments(text) });
            return { kind: 'tdelim', out };
        }
        const next = lines[i + 1] ?? '';
        if (pipe && (state.table || isDelim(next))) {
            const align = state.table ? state.align : alignments(next);
            Object.assign(out, { table: true, pipe: true, list: [], align });
            return { kind: state.table ? 'tr' : 'th', out, align };
        }
        out.pipe = pipe;

        const lead = RE.lead.exec(text)[0];
        const indent = width(lead);
        if (state.list.length && indent > 0) {
            // A continuation line belongs to the deepest item indented less than it.
            let depth = state.list.length - 1;
            while (depth > 0 && state.list[depth] >= indent) depth--;
            return { kind: 'lc', out, depth, indEnd: lead.length };
        }
        out.list = [];
        return { kind: 'p', out };
    }

    // ── Rendering ──────────────────────────────────────────────────────────

    const span = (cls, text) => {
        const s = document.createElement('span');
        s.className = cls;
        s.textContent = text;
        return s;
    };

    function build(i, L) {
        const text = lines[i];
        const div = document.createElement('div');
        div.className = 'ln k-' + L.kind;
        if (L.task) div.classList.add('task-' + L.task);
        if (L.depth != null) div.style.setProperty('--depth', L.depth);
        if (!text.length) {
            div.appendChild(document.createElement('br'));
            return div;
        }

        switch (L.kind) {
        case 'code':
            div.appendChild(document.createTextNode(text));
            return div;
        case 'fence-open':
            div.appendChild(span('mk', text.slice(0, L.markEnd)));
            if (L.markEnd < text.length) div.appendChild(span('lang', text.slice(L.markEnd)));
            return div;
        case 'fence-close':
        case 'hr':
        case 'tdelim':
            div.appendChild(span('mk', text));
            return div;
        case 'th':
        case 'tr':
            mathSize = 15;
            buildRow(div, text, L.align);
            sizeMathLine(div);
            return div;
        }
        mathSize = MATH_SIZE[L.kind] ?? 15;

        let pos = 0;
        if (L.indEnd) {
            div.appendChild(span('ind', text.slice(0, L.indEnd)));
            pos = L.indEnd;
        }
        if (L.hmEnd) {
            const hm = span('hm', text.slice(pos, L.hmEnd));
            div.classList.add('hang');
            div.style.setProperty('--hang', `calc(${L.hmEnd - pos} * var(--mch) + 8px)`);
            if (L.kind === 'li') {
                hm.dataset.b = L.task ? (L.task === 'done' ? '☑' : '☐')
                    : L.ordered ? L.marker : BULLETS[L.depth % BULLETS.length];
            }
            div.appendChild(hm);
            pos = L.hmEnd;
        }
        inline(text, pos, text.length, div);
        sizeMathLine(div);
        return div;
    }

    function buildRow(div, text, align) {
        let column = 0;
        const lead = RE.lead.exec(text)[0].length;
        if (lead) div.appendChild(span('mk', text.slice(0, lead)));
        const pipes = [];
        for (let k = lead; k < text.length; k++) {
            if (text[k] === '\\') k++;
            else if (text[k] === '|') pipes.push(k);
        }
        const bounds = [lead - 1, ...pipes, text.length];
        for (let b = 0; b + 1 < bounds.length; b++) {
            const start = bounds[b] + 1;
            const end = bounds[b + 1];
            const last = b + 2 === bounds.length;
            if (start < end) {
                if (last && RE.blank.test(text.slice(start, end))) {
                    div.appendChild(span('mk', text.slice(start, end)));
                } else {
                    const cell = span('cell', '');
                    const side = align?.[column++];
                    if (side && side !== 'left') cell.style.textAlign = side;
                    inline(text, start, end, cell);
                    div.appendChild(cell);
                }
            }
            if (!last) div.appendChild(span('mk pipe', '|'));
        }
    }

    /**
     * Appends `text[a, b)` to `parent`. Each construct (emphasis, code, link,
     * math, an escape) sits in an `.iw` span carrying its source columns, so
     * only the one around the caret shows its `.mk` markers.
     */
    function inline(text, a, b, parent) {
        let i = a;
        let plain = a;
        const flush = (to) => {
            if (to > plain) parent.appendChild(document.createTextNode(text.slice(plain, to)));
        };
        const construct = (start, end) => {
            const iw = span('iw', '');
            iw.dataset.a = start;
            iw.dataset.b = end;
            parent.appendChild(iw);
            return iw;
        };
        while (i < b) {
            const c = text[i];
            let r = null;
            if (c === '\\' && i + 1 < b && /[!-\/:-@\[-`{-~]/.test(text[i + 1])) {
                flush(i);
                const iw = construct(i, i + 2);
                iw.appendChild(span('mk', '\\'));
                iw.appendChild(document.createTextNode(text[i + 1]));
                plain = i + 2;
                i += 2;
                continue;
            }
            if (c === '`') r = codeSpan(text, i, b);
            else if (c === '*' || c === '_') r = emphasis(text, i, b);
            else if (c === '~' && text[i + 1] === '~') r = strike(text, i, b);
            else if (c === '[' || (c === '!' && text[i + 1] === '[')) r = link(text, i, b);
            else if (c === '$') r = math(text, i, b);
            if (!r) { i++; continue; }
            if (r.emit) {
                flush(i);
                r.emit(construct(i, r.end));
                plain = r.end;
            }
            i = r.end;
        }
        flush(b);
    }

    const run = (text, i, ch) => {
        let n = 0;
        while (text[i + n] === ch) n++;
        return n;
    };

    function wrapped(text, i, open, close, end, cls, parent, recurse) {
        parent.appendChild(span('mk', text.slice(i, i + open)));
        const inner = span(cls, '');
        if (recurse) inline(text, i + open, end, inner);
        else inner.textContent = text.slice(i + open, end);
        parent.appendChild(inner);
        parent.appendChild(span('mk', text.slice(end, end + close)));
        return inner;
    }

    function codeSpan(text, i, b) {
        const n = run(text, i, '`');
        for (let j = text.indexOf('`', i + n); j !== -1 && j < b; j = text.indexOf('`', j + 1)) {
            const m = run(text, j, '`');
            if (m === n && j + m <= b) {
                return { end: j + n, emit: (p) => wrapped(text, i, n, n, j, 'code', p, false) };
            }
            j += m - 1;
        }
        return { end: i + n };
    }

    function emphasis(text, i, b) {
        const ch = text[i];
        const n = Math.min(run(text, i, ch), 3);
        const total = run(text, i, ch);
        const alnum = (c) => c != null && /[\p{L}\p{N}]/u.test(c);
        const after = text[i + total];
        if (after == null || /\s/.test(after) || (ch === '_' && alnum(text[i - 1]))) return { end: i + total };
        const delim = ch.repeat(n);
        for (let k = text.indexOf(delim, i + n + 1); k !== -1 && k + n <= b; k = text.indexOf(delim, k + 1)) {
            if (/\s/.test(text[k - 1]) || text[k - 1] === ch || text[k + n] === ch) continue;
            if (ch === '_' && alnum(text[k + n])) continue;
            const cls = n === 1 ? 'em' : n === 2 ? 'strong' : 'strong em';
            return { end: k + n, emit: (p) => wrapped(text, i, n, n, k, cls, p, true) };
        }
        return { end: i + total };
    }

    function strike(text, i, b) {
        const k = text.indexOf('~~', i + 3);
        if (k === -1 || k + 2 > b || /\s/.test(text[i + 2])) return { end: i + 2 };
        return { end: k + 2, emit: (p) => wrapped(text, i, 2, 2, k, 'strike', p, true) };
    }

    function link(text, i, b) {
        const open = text[i] === '!' ? i + 1 : i;
        let depth = 0;
        let close = -1;
        for (let k = open; k < b; k++) {
            if (text[k] === '\\') { k++; continue; }
            if (text[k] === '[') depth++;
            else if (text[k] === ']' && --depth === 0) { close = k; break; }
        }
        if (close === -1 || text[close + 1] !== '(') return { end: open + 1 };
        const paren = text.indexOf(')', close + 2);
        if (paren === -1 || paren >= b) return { end: open + 1 };
        const cls = open > i ? 'img' : 'link';
        return {
            end: paren + 1,
            emit: (p) => {
                p.appendChild(span('mk', text.slice(i, open + 1)));
                const label = span(cls, '');
                inline(text, open + 1, close, label);
                p.appendChild(label);
                p.appendChild(span('mk', text.slice(close, paren + 1)));
            },
        };
    }

    function math(text, i, b) {
        const n = text[i + 1] === '$' ? 2 : 1;
        const delim = '$'.repeat(n);
        if (/\s/.test(text[i + n] ?? ' ')) return { end: i + n };
        for (let k = text.indexOf(delim, i + n + 1); k !== -1 && k + n <= b; k = text.indexOf(delim, k + 1)) {
            if (text[k - 1] === '\\' || /\s/.test(text[k - 1])) continue;
            return {
                end: k + n,
                emit: (p) => attachMath(wrapped(text, i, n, n, k, 'math', p, false), text.slice(i + n, k), n === 2),
            };
        }
        return { end: i + n };
    }

    function renderAt(j) {
        const state = j ? outStates[j - 1] : INIT;
        const L = lex(j, state);
        outStates[j] = L.out;
        inKeys[j] = stateKey(state);
        metas[j] = L;
        const div = build(j, L);
        const old = doc.children[j];
        if (!old) {
            doc.appendChild(div);
            return;
        }
        // Updating the existing element, rather than swapping in a new one,
        // spares WebKit re-attaching every line below it.
        old.className = div.className;
        if (old === activeDiv) old.classList.add('active');
        const style = div.getAttribute('style');
        if (style) old.setAttribute('style', style);
        else old.removeAttribute('style');
        old.replaceChildren(...div.childNodes);
        highlighted.delete(old);
    }

    /**
     * Re-renders lines [from, end) and then onward until the carried state
     * settles; returns the line it stopped at.
     */
    function relex(from, end) {
        // A table's header row is known only from the line after it.
        if (from > 0 && isPipeRow(lines[from - 1])) renderAt(from - 1);
        let j = from;
        for (; j < lines.length; j++) {
            if (j >= end && inKeys[j] === stateKey(j ? outStates[j - 1] : INIT)) break;
            renderAt(j);
        }
        return j;
    }

    /** Re-renders after an edit to lines [from, end), then re-highlights code blocks it touched. */
    function refresh(from, end) {
        highlightAround(from, relex(from, end));
    }

    // ── Code highlighting ──────────────────────────────────────────────────
    // A fenced block is highlighted whole, so comments and strings that span
    // lines stay right, then split back into its lines. Only lines whose
    // markup changed are rewritten; the text, and so every caret position,
    // is the same either way.

    const highlighted = new WeakMap();  // code line → markup last written

    /** Splits highlighter HTML at newlines, closing and reopening spans across each break. */
    function splitMarkup(html) {
        const parts = [];
        const open = [];
        let current = '';
        const token = /(<span[^>]*>)|(<\/span>)|([^<]+)/g;
        let m;
        while ((m = token.exec(html))) {
            if (m[1]) {
                open.push(m[1]);
                current += m[1];
            } else if (m[2]) {
                open.pop();
                current += m[2];
            } else {
                const pieces = m[3].split('\n');
                for (let p = 0; p < pieces.length; p++) {
                    if (p > 0) {
                        parts.push(current + '</span>'.repeat(open.length));
                        current = open.join('');
                    }
                    current += pieces[p];
                }
            }
        }
        parts.push(current);
        return parts;
    }

    /** Highlights the block whose fence opens at `open`; returns the line after its code. */
    function highlightBlock(open, divAt) {
        let end = open + 1;
        while (end < lines.length && metas[end]?.kind === 'code') end++;
        const lang = metas[open].lang;
        const hl = window.hljs;
        const parts = lang && hl?.getLanguage(lang)
            ? splitMarkup(hl.highlight(lines.slice(open + 1, end).join('\n'), { language: lang, ignoreIllegals: true }).value)
            : null;
        for (let j = open + 1; j < end; j++) {
            const div = divAt(j);
            const markup = parts && lines[j] ? parts[j - open - 1] : '';
            if ((highlighted.get(div) ?? '') === markup) continue;
            if (markup) {
                div.innerHTML = markup;
                highlighted.set(div, markup);
            } else {
                if (lines[j]) div.textContent = lines[j];
                else div.replaceChildren(document.createElement('br'));
                highlighted.delete(div);
            }
        }
        return end;
    }

    function highlightAround(from, to) {
        const stop = Math.min(to + 1, lines.length);
        for (let j = Math.max(0, from - 1); j < stop; j++) {
            const kind = metas[j]?.kind;
            if (kind !== 'code' && kind !== 'fence-open') continue;
            let open = j;
            while (open > 0 && metas[open].kind === 'code') open--;
            if (metas[open].kind !== 'fence-open') continue;
            j = highlightBlock(open, (k) => doc.children[k]) - 1;
        }
    }

    // ── Math ───────────────────────────────────────────────────────────────
    // The host typesets LaTeX natively and returns a 2x image with its size
    // and baseline. The page uses it as a mask filled with the text color, so
    // a theme or appearance change needs no new images.

    const MATH_SIZE = { h1: 27.75, h2: 21.75, h3: 18, h4: 15.75, h5: 14.25, h6: 13.5 };
    const MATH_SCALE = 1.15;        // Latin Modern runs smaller than SF at the same size
    let mathSize = 15;              // font size of the line being built
    const mathIds = new Map();      // `size|display|tex` → id
    const mathImages = new Map();   // id → { url, w, h, d }; null while pending, false if it failed
    let mathQueue = [];

    function attachMath(el, tex, display) {
        const key = `${mathSize}|${display ? 1 : 0}|${tex}`;
        let id = mathIds.get(key);
        if (id == null) {
            id = mathIds.size;
            mathIds.set(key, id);
            mathImages.set(id, null);
            mathQueue.push({ id, tex, display, size: Math.round(mathSize * MATH_SCALE * 100) / 100 });
            if (mathQueue.length === 1) queueMicrotask(flushMath);
        }
        el.dataset.mid = id;
        applyMath(el, mathImages.get(id));
    }

    function flushMath() {
        const items = mathQueue;
        mathQueue = [];
        if (items.length) post({ type: 'math', items });
    }

    function applyMath(el, image) {
        if (!image) return;
        el.classList.add('ready');
        el.style.setProperty('--math', `url("${image.url}")`);
        el.style.setProperty('--mw', image.w + 'px');
        el.style.setProperty('--mh', image.h + 'px');
        el.style.setProperty('--md', image.d + 'px');
    }

    /** A line holding math keeps its tallest formula's height whether or not the caret is on it. */
    function sizeMathLine(div) {
        let tallest = 0;
        for (const el of div.querySelectorAll('.math.ready')) {
            tallest = Math.max(tallest, parseFloat(el.style.getPropertyValue('--mh')) || 0);
        }
        if (tallest) div.style.setProperty('--math-h', tallest + 4 + 'px');
        else div.style.removeProperty('--math-h');
    }

    function mathReady(results) {
        for (const r of results) {
            mathImages.set(r.id, r.url ? r : false);
            for (const el of doc.querySelectorAll(`.math[data-mid="${r.id}"]`)) {
                applyMath(el, mathImages.get(r.id));
                sizeMathLine(lineDivOf(el));
            }
        }
    }

    // ── Positions ──────────────────────────────────────────────────────────

    const lineDivOf = (node) => {
        let n = node && node.nodeType === Node.ELEMENT_NODE ? node : node && node.parentNode;
        while (n && n.parentNode !== doc) n = n.parentNode;
        return n;
    };
    const indexOfDiv = (div) => Array.prototype.indexOf.call(doc.children, div);

    /** The source (line, col) of a DOM point inside the editor. */
    function posFrom(node, offset) {
        if (node === doc) {
            if (offset >= lines.length) {
                const line = lines.length - 1;
                return { line, col: lines[line].length };
            }
            return { line: offset, col: 0 };
        }
        const div = lineDivOf(node);
        if (!div) return null;
        const range = document.createRange();
        range.setStart(div, 0);
        range.setEnd(node, offset);
        return { line: indexOfDiv(div), col: range.toString().length };
    }

    /** The DOM point for a source (line, col), avoiding always-hidden text. */
    function domPoint(pos) {
        const div = doc.children[pos.line];
        const walker = document.createTreeWalker(div, NodeFilter.SHOW_TEXT);
        let rest = pos.col;
        let node;
        while ((node = walker.nextNode())) {
            const hidden = node.parentNode.classList?.contains('ind');
            if (!hidden && rest <= node.length) return { node, offset: rest };
            rest = Math.max(0, rest - node.length);
        }
        return { node: div, offset: div.childNodes.length };
    }

    const compare = (a, b) => a.line - b.line || a.col - b.col;

    function selection() {
        const sel = getSelection();
        if (!sel.rangeCount || !doc.contains(sel.anchorNode)) return null;
        const a = posFrom(sel.anchorNode, sel.anchorOffset);
        const f = posFrom(sel.focusNode, sel.focusOffset);
        if (!a || !f) return null;
        return compare(a, f) <= 0 ? [a, f] : [f, a];
    }

    function select(anchor, focus = anchor, reveal = true) {
        const a = domPoint(anchor);
        const f = domPoint(focus);
        getSelection().setBaseAndExtent(a.node, a.offset, f.node, f.offset);
        updateActive();
        if (reveal) revealCaret();
    }

    function revealCaret() {
        const sel = getSelection();
        if (!sel.rangeCount) return;
        let rect = sel.getRangeAt(0).getBoundingClientRect();
        if (!rect.height) rect = lineDivOf(sel.focusNode)?.getBoundingClientRect() ?? rect;
        const margin = 48;
        if (rect.bottom > innerHeight - margin) scrollBy(0, rect.bottom - innerHeight + margin);
        else if (rect.top < margin) scrollBy(0, rect.top - margin);
    }

    function textBetween(a, b) {
        if (a.line === b.line) return lines[a.line].slice(a.col, b.col);
        return [lines[a.line].slice(a.col), ...lines.slice(a.line + 1, b.line), lines[b.line].slice(0, b.col)].join('\n');
    }

    function updateActive() {
        if (composing) return;
        const sel = getSelection();
        const div = sel.rangeCount && doc.contains(sel.focusNode) ? lineDivOf(sel.focusNode) : null;
        if (div !== activeDiv) {
            // Tracked by element, not index, so it stays right when splices move lines.
            activeDiv?.classList.remove('active');
            activeDiv = div;
            div?.classList.add('active');
        }
        updateReveal(sel);
    }

    let revealed = [];

    /**
     * Shows the markers of the inline constructs touching the caret, and no
     * others: revealing a whole line's markers could make it wrap, and a line
     * growing a row under the caret moves everything below it.
     */
    function updateReveal(sel) {
        const pos = activeDiv && sel.rangeCount ? posFrom(sel.focusNode, sel.focusOffset) : null;
        const next = [];
        if (pos) {
            for (const iw of activeDiv.querySelectorAll('.iw')) {
                if (+iw.dataset.a <= pos.col && pos.col <= +iw.dataset.b) next.push(iw);
            }
        }
        for (const iw of revealed) if (!next.includes(iw)) iw.classList.remove('reveal');
        for (const iw of next) iw.classList.add('reveal');
        revealed = next;
    }

    // ── Editing ────────────────────────────────────────────────────────────

    const undoStack = [];
    const redoStack = [];

    /**
     * Replaces lines [from, to) with `added`, re-renders, reports the splice,
     * and records it for undo unless `options.undo` is false.
     */
    function splice(from, to, added, options = {}) {
        const removed = lines.slice(from, to);
        const blanks = () => added.map(() => null);
        lines.splice(from, to - from, ...added);
        outStates.splice(from, to - from, ...blanks());
        inKeys.splice(from, to - from, ...blanks());
        metas.splice(from, to - from, ...blanks());

        // Reuse the lines' existing elements; only the difference in count is added or removed.
        const keep = Math.min(to - from, added.length);
        for (let k = keep; k < to - from; k++) doc.children[from + keep].remove();
        const before = doc.children[from + keep] ?? null;
        for (let k = keep; k < added.length; k++) doc.insertBefore(document.createElement('div'), before);
        refresh(from, from + added.length);

        post({ type: 'splice', from, to, lines: added });
        if (options.undo !== false) record(from, removed, added, options);
        if (options.caret && options.select !== false) {
            select(options.caret, options.focus ?? options.caret, options.reveal !== false);
        }
        if (!bar.hidden) scheduleSearch();
    }

    function record(from, removed, added, options) {
        redoStack.length = 0;
        const now = Date.now();
        const last = undoStack[undoStack.length - 1];
        if (options.coalesce && last?.coalesce && last.from === from && last.added.length === 1
            && removed.length === 1 && added.length === 1 && now - last.time < 1500) {
            last.added = added;
            last.after = options.caret;
            last.time = now;
            return;
        }
        undoStack.push({
            from, removed, added,
            before: options.before ?? options.caret,
            after: options.caret,
            coalesce: !!options.coalesce,
            time: now,
        });
        if (undoStack.length > 500) undoStack.shift();
    }

    function undo() {
        const entry = undoStack.pop();
        if (!entry) return;
        splice(entry.from, entry.from + entry.added.length, entry.removed, { undo: false, caret: entry.before });
        redoStack.push(entry);
    }

    function redo() {
        const entry = redoStack.pop();
        if (!entry) return;
        splice(entry.from, entry.from + entry.removed.length, entry.added, { undo: false, caret: entry.after });
        undoStack.push(entry);
    }

    /** Replaces the source between two positions with `text`. */
    function replace(a, b, text, options = {}) {
        text = text.replace(/\r\n?/g, '\n');
        const head = lines[a.line].slice(0, a.col);
        const tail = lines[b.line].slice(b.col);
        const added = (head + text + tail).split('\n');
        const last = added.length - 1;
        const caret = { line: a.line + last, col: added[last].length - tail.length };
        splice(a.line, b.line + 1, added, { before: a, caret, ...options });
    }

    /** Reads back the line WebKit just edited in place. */
    function syncFromDOM() {
        // Edits that cross lines never reach WebKit, so only the caret's line can have changed.
        if (doc.children.length !== lines.length) return resyncAll();
        const sel = getSelection();
        if (!sel.rangeCount) return;
        const div = lineDivOf(sel.focusNode);
        if (!div || div.querySelector('div')) return resyncAll();
        const line = indexOfDiv(div);
        const text = div.textContent;
        const caret = posFrom(sel.focusNode, sel.focusOffset);
        if (text === lines[line]) {
            // Same text but WebKit may have added markup (a <br>, a split span): redraw the line.
            renderAt(line);
            highlightAround(line, line + 1);
            select(caret, caret, false);
            return;
        }
        // WebKit already keeps the caret in view while typing.
        splice(line, line + 1, text.split('\n'), { before: pendingBefore ?? caret, caret, coalesce: true, reveal: false });
    }

    /** Last resort when WebKit restructured the lines: rebuild from the DOM. */
    function resyncAll() {
        const sel = selection();
        const all = [];
        for (const child of doc.childNodes) all.push(...(child.textContent ?? '').split('\n'));
        load(all.length ? all : ['']);
        post({ type: 'reset', lines: lines.slice() });
        if (sel) select(clamp(sel[1]));
    }

    const clamp = (pos) => {
        const line = Math.min(Math.max(pos.line, 0), lines.length - 1);
        return { line, col: Math.min(pos.col, lines[line].length) };
    };

    function newline(a, b) {
        const L = metas[a.line];
        const text = lines[a.line];
        if (a.line === b.line && L?.kind === 'li' && a.col >= L.contentCol) {
            if (RE.blank.test(text.slice(L.hmEnd))) {
                // Return on an empty item steps out a level, then ends the list.
                if (L.indent > 0) return indent(true);
                return replace({ line: a.line, col: 0 }, { line: a.line, col: text.length }, '');
            }
            const marker = L.ordered ? (parseInt(L.marker, 10) + 1) + L.marker.slice(-1) : L.marker;
            const task = L.task ? '[ ] ' : '';
            return replace(a, b, '\n' + text.slice(0, L.indEnd) + marker + ' ' + task);
        }
        if (a.line === b.line && L?.kind === 'quote' && a.col >= L.hmEnd) {
            if (RE.blank.test(text.slice(L.hmEnd))) {
                return replace({ line: a.line, col: 0 }, { line: a.line, col: text.length }, '');
            }
            return replace(a, b, '\n' + text.slice(0, L.hmEnd));
        }
        if (a.line === b.line && L?.kind === 'lc') {
            return replace(a, b, '\n' + text.slice(0, L.indEnd));
        }
        replace(a, b, '\n');
    }

    /** Tab and Shift-Tab move list items a level in or out. */
    function indent(outward) {
        const [a, b] = selection() ?? [];
        if (!a) return;
        const touched = [];
        for (let i = a.line; i <= b.line; i++) if (metas[i]?.kind === 'li') touched.push(i);
        if (!touched.length) {
            // Outside lists, Tab types a tab, but never over a multi-line selection.
            if (!outward && a.line === b.line) replace(a, b, '\t');
            return;
        }
        const updated = lines.slice(a.line, b.line + 1);
        const shift = {};
        for (const i of touched) {
            const L = metas[i];
            const parents = (i ? outStates[i - 1] : INIT).list;
            let target;
            if (outward) {
                target = [...parents].reverse().find((p) => p < L.indent) ?? 0;
            } else {
                let k = i - 1;
                while (k >= 0 && !(metas[k]?.kind === 'li' && metas[k].indent <= L.indent)) k--;
                target = k >= 0 ? metas[k].indent + (metas[k].contentCol - metas[k].indEnd) : L.indent;
                if (target <= L.indent) target = L.indent;
            }
            if (target === L.indent) continue;
            updated[i - a.line] = ' '.repeat(target) + lines[i].slice(L.indEnd);
            shift[i] = target - L.indEnd;
        }
        const moved = (pos) => ({ line: pos.line, col: Math.max(0, pos.col + (shift[pos.line] ?? 0)) });
        splice(a.line, b.line + 1, updated, { before: a, caret: moved(a), focus: moved(b) });
    }

    /** ⌘B / ⌘I wrap the selection, or unwrap it when already wrapped. */
    function toggleWrap(delim) {
        const [a, b] = selection() ?? [];
        if (!a || a.line !== b.line) return;
        const text = lines[a.line];
        const n = delim.length;
        if (text.slice(a.col - n, a.col) === delim && text.slice(b.col, b.col + n) === delim) {
            const updated = text.slice(0, a.col - n) + text.slice(a.col, b.col) + text.slice(b.col + n);
            splice(a.line, a.line + 1, [updated], {
                before: a, caret: { line: a.line, col: a.col - n }, focus: { line: a.line, col: b.col - n },
            });
            return;
        }
        const updated = text.slice(0, a.col) + delim + text.slice(a.col, b.col) + delim + text.slice(b.col);
        splice(a.line, a.line + 1, [updated], {
            before: a, caret: { line: a.line, col: a.col + n }, focus: { line: a.line, col: b.col + n },
        });
    }

    function toggleTask(line) {
        const L = metas[line];
        const at = lines[line].indexOf('[', L.contentCol);
        const mark = L.task === 'done' ? ' ' : 'x';
        const updated = lines[line].slice(0, at + 1) + mark + lines[line].slice(at + 2);
        const sel = selection();
        splice(line, line + 1, [updated], { before: sel?.[0] });
        if (sel) select(sel[0], sel[1]);
    }

    // ── Events ─────────────────────────────────────────────────────────────

    doc.addEventListener('beforeinput', (e) => {
        const type = e.inputType;
        if (type === 'historyUndo') { e.preventDefault(); undo(); return; }
        if (type === 'historyRedo') { e.preventDefault(); redo(); return; }
        if (type.startsWith('format')) { e.preventDefault(); return; }
        if (composing || e.isComposing || type === 'insertCompositionText') return;

        const range = selection();
        if (!range) { e.preventDefault(); return; }
        const [a, b] = range;
        pendingBefore = a;
        const across = a.line !== b.line;
        const collapsed = !across && a.col === b.col;

        if (type === 'insertParagraph' || type === 'insertLineBreak') {
            e.preventDefault();
            newline(a, b);
        } else if (type === 'insertFromPaste' || type === 'insertFromDrop' || type === 'insertFromYank') {
            e.preventDefault();
            replace(a, b, e.dataTransfer?.getData('text/plain') ?? e.data ?? '');
        } else if (type === 'insertText') {
            if (across || (e.data ?? '').includes('\n')) {
                e.preventDefault();
                replace(a, b, e.data ?? '');
            }
        } else if (type === 'deleteByCut' || type === 'deleteByDrag') {
            e.preventDefault();
            replace(a, b, '');
        } else if (type.startsWith('delete')) {
            const backward = type.includes('Backward');
            const L = metas[a.line];
            if (across) {
                e.preventDefault();
                replace(a, b, '');
            } else if (collapsed && backward && L?.kind === 'li' && L.indEnd && a.col <= L.indEnd) {
                // The indentation is hidden; deleting into it outdents instead.
                e.preventDefault();
                indent(true);
            } else if (collapsed && backward && a.col <= (L?.kind === 'lc' ? L.indEnd : 0)) {
                // At a line's start, Delete joins it to the line above.
                e.preventDefault();
                if (a.line > 0) replace({ line: a.line - 1, col: lines[a.line - 1].length }, a, '');
            } else if (collapsed && !backward && a.col === lines[a.line].length) {
                e.preventDefault();
                if (a.line < lines.length - 1) replace(a, { line: a.line + 1, col: 0 }, '');
            }
        }
    });

    doc.addEventListener('input', (e) => {
        if (composing || e.isComposing) return;
        syncFromDOM();
        pendingBefore = null;
    });

    doc.addEventListener('compositionstart', () => {
        composing = true;
        pendingBefore = selection()?.[0] ?? null;
    });
    doc.addEventListener('compositionend', () => {
        composing = false;
        syncFromDOM();
        pendingBefore = null;
    });

    doc.addEventListener('keydown', (e) => {
        if (e.isComposing || composing) return;
        const command = e.metaKey || e.ctrlKey;
        const key = e.key.toLowerCase();
        if (command && !e.altKey && key === 'z') {
            e.preventDefault();
            e.shiftKey ? redo() : undo();
        } else if (command && !e.altKey && !e.shiftKey && (key === 'b' || key === 'i')) {
            e.preventDefault();
            toggleWrap(key === 'b' ? '**' : '*');
        } else if (e.key === 'Tab' && !command && !e.altKey) {
            e.preventDefault();
            indent(e.shiftKey);
        }
    });

    doc.addEventListener('copy', (e) => {
        const range = selection();
        if (!range) return;
        e.preventDefault();
        e.clipboardData.setData('text/plain', textBetween(...range));
    });
    doc.addEventListener('cut', (e) => {
        const range = selection();
        if (!range) return;
        e.preventDefault();
        e.clipboardData.setData('text/plain', textBetween(...range));
        replace(range[0], range[1], '');
    });
    doc.addEventListener('paste', (e) => {
        const range = selection();
        if (!range) return;
        e.preventDefault();
        replace(range[0], range[1], e.clipboardData.getData('text/plain'));
    });

    // Dragging text moves it within the source; files and other drops are ignored.
    let dragSource = null;
    doc.addEventListener('dragstart', () => { dragSource = selection(); });
    doc.addEventListener('dragend', () => { dragSource = null; });
    doc.addEventListener('dragover', (e) => e.preventDefault());
    doc.addEventListener('drop', (e) => {
        e.preventDefault();
        const text = e.dataTransfer.getData('text/plain');
        const point = document.caretRangeFromPoint(e.clientX, e.clientY);
        const target = point && posFrom(point.startContainer, point.startOffset);
        if (!text || !target) return;
        const source = dragSource;
        dragSource = null;
        if (!source) return replace(target, target, text);
        if (compare(target, source[0]) >= 0 && compare(target, source[1]) <= 0) return;
        if (compare(target, source[1]) > 0) {
            replace(target, target, text);
            replace(source[0], source[1], '');
        } else {
            replace(source[0], source[1], '');
            replace(target, target, text);
        }
    });

    doc.addEventListener('mousedown', (e) => {
        const hm = e.target.closest?.('.hm');
        const div = hm && lineDivOf(hm);
        if (!div || div.classList.contains('active')) return;
        const line = indexOfDiv(div);
        if (metas[line]?.task) {
            e.preventDefault();
            toggleTask(line);
        }
    });

    document.addEventListener('selectionchange', updateActive);

    // ── Host API ───────────────────────────────────────────────────────────

    function load(newLines) {
        lines = newLines.length ? newLines.slice() : [''];
        outStates = [];
        inKeys = [];
        metas = [];
        activeDiv = null;
        // Built off-document in one pass, then attached once.
        const divs = [];
        let state = INIT;
        for (let j = 0; j < lines.length; j++) {
            const L = lex(j, state);
            outStates[j] = L.out;
            inKeys[j] = stateKey(state);
            metas[j] = L;
            divs.push(build(j, L));
            state = L.out;
        }
        for (let j = 0; j < lines.length; j++) {
            if (metas[j].kind === 'fence-open') j = highlightBlock(j, (k) => divs[k]) - 1;
        }
        doc.replaceChildren(...divs);
        if (!bar.hidden) scheduleSearch();
    }

    // ── Find ───────────────────────────────────────────────────────────────
    // Matches are painted with the CSS Custom Highlight API, so finding never
    // changes the document; replacing goes through the same splices as typing.

    const bar = document.getElementById('find');
    const query = document.getElementById('find-query');
    const replacement = document.getElementById('find-replace');
    const counter = document.getElementById('find-count');
    const MAX_PAINTED = 2000;
    let matches = [];
    let current = -1;
    let searchTimer = 0;

    function scheduleSearch() {
        clearTimeout(searchTimer);
        searchTimer = setTimeout(() => search(true), 120);
    }

    /** Finds every case-insensitive match; keeps the current index when `keep` is set. */
    function search(keep) {
        const needle = query.value.toLowerCase();
        matches = [];
        if (needle) {
            for (let line = 0; line < lines.length; line++) {
                const hay = lines[line].toLowerCase();
                for (let col = hay.indexOf(needle); col !== -1; col = hay.indexOf(needle, col + needle.length)) {
                    matches.push({ line, col, len: needle.length });
                }
            }
        }
        if (!keep || current >= matches.length) {
            const caret = selection()?.[0];
            const after = caret ? matches.findIndex((m) => compare(m, caret) >= 0) : 0;
            current = matches.length ? Math.max(after, 0) : -1;
        }
        paint();
    }

    function rangeFor(m) {
        const a = domPoint({ line: m.line, col: m.col });
        const b = domPoint({ line: m.line, col: m.col + m.len });
        const range = document.createRange();
        range.setStart(a.node, a.offset);
        range.setEnd(b.node, b.offset);
        return range;
    }

    function paint() {
        if (window.CSS?.highlights) {
            CSS.highlights.delete('find');
            CSS.highlights.delete('find-current');
            if (!bar.hidden && matches.length) {
                CSS.highlights.set('find', new Highlight(...matches.slice(0, MAX_PAINTED).map(rangeFor)));
                if (current >= 0) CSS.highlights.set('find-current', new Highlight(rangeFor(matches[current])));
            }
        }
        counter.textContent = !query.value ? ''
            : matches.length ? `${current + 1} of ${matches.length}` : 'Not found';
    }

    function showCurrent() {
        if (current < 0) return;
        const m = matches[current];
        let rect = rangeFor(m).getBoundingClientRect();
        if (!rect.height) rect = doc.children[m.line].getBoundingClientRect();
        if (rect.top < 64 || rect.bottom > innerHeight - 40) scrollBy(0, rect.top - innerHeight / 3);
    }

    function step(delta) {
        if (!matches.length) return;
        current = (current + delta + matches.length) % matches.length;
        paint();
        showCurrent();
    }

    function openFind() {
        const range = selection();
        if (range && range[0].line === range[1].line && range[0].col !== range[1].col) {
            query.value = textBetween(...range);
        }
        bar.hidden = false;
        query.focus();
        query.select();
        search(false);
        showCurrent();
    }

    /** Closes the bar; from the bar itself, the current match becomes the selection. */
    function closeFind() {
        const fromBar = bar.contains(document.activeElement);
        bar.hidden = true;
        paint();
        doc.focus();
        if (fromBar && current >= 0) {
            const m = matches[current];
            select({ line: m.line, col: m.col }, { line: m.line, col: m.col + m.len });
        }
    }

    function replaceCurrent() {
        if (current < 0) return;
        const m = matches[current];
        replace({ line: m.line, col: m.col }, { line: m.line, col: m.col + m.len }, replacement.value, { select: false });
        search(true);
        showCurrent();
    }

    function replaceAll() {
        if (!matches.length) return;
        const pattern = new RegExp(query.value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
        const touched = [...new Set(matches.map((m) => m.line))];
        const first = touched[0];
        const last = touched[touched.length - 1];
        const updated = lines.slice(first, last + 1).map((text) => text.replace(pattern, () => replacement.value));
        splice(first, last + 1, updated, { before: { line: first, col: 0 }, select: false });
        search(false);
    }

    document.addEventListener('keydown', (e) => {
        const command = e.metaKey || e.ctrlKey;
        const key = e.key.toLowerCase();
        if (command && !e.altKey && key === 'f') {
            e.preventDefault();
            openFind();
        } else if (command && !e.altKey && key === 'g') {
            e.preventDefault();
            if (bar.hidden) openFind();
            else step(e.shiftKey ? -1 : 1);
        } else if (e.key === 'Escape' && !bar.hidden) {
            e.preventDefault();
            closeFind();
        }
    }, true);
    query.addEventListener('input', () => {
        search(false);
        showCurrent();
    });
    query.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            step(e.shiftKey ? -1 : 1);
        }
    });
    replacement.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            replaceCurrent();
        }
    });
    document.getElementById('find-prev').addEventListener('click', () => step(-1));
    document.getElementById('find-next').addEventListener('click', () => step(1));
    document.getElementById('find-done').addEventListener('click', closeFind);
    document.getElementById('find-replace-one').addEventListener('click', replaceCurrent);
    document.getElementById('find-replace-all').addEventListener('click', replaceAll);

    /** Takes the host's colors per appearance (`fg-light`, `fg-dark`, …); CSS picks by color scheme. */
    function applyTheme(theme) {
        const root = document.documentElement.style;
        for (const [name, value] of Object.entries(theme ?? {})) {
            if (value) root.setProperty('--theme-' + name, value);
        }
    }

    function measureMarkerFont() {
        const probe = span('hm', '0'.repeat(40));
        probe.style.cssText = 'position:absolute;visibility:hidden;width:auto;padding:0';
        document.body.appendChild(probe);
        const mch = probe.getBoundingClientRect().width / 40;
        probe.remove();
        if (mch > 0) document.documentElement.style.setProperty('--mch', mch + 'px');
    }

    window.editor = {
        load(newLines, theme) {
            applyTheme(theme);
            load(newLines);
            undoStack.length = 0;
            redoStack.length = 0;
        },
        lines: () => lines.slice(),
        text: () => lines.join('\n'),
        focus: () => doc.focus(),
        mathReady,
        find: openFind,
    };

    measureMarkerFont();
    load(['']);
    post({ type: 'ready' });
})();
