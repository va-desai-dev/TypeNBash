import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../CiteTex/Resources/popup.js', import.meta.url), 'utf8');

async function capture(results, readError = false) {
    let click;
    const queries = [], reads = [], saves = [];
    const status = {};
    const button = { disabled: false, addEventListener: (_, handler) => { click = handler; } };
    const context = {
        document: { getElementById: id => id === 'save' ? button : status },
        browser: {
            tabs: {
                query: async query => { queries.push(query); return results[queries.length - 1] ?? []; },
                sendMessage: async id => {
                    reads.push(id);
                    if (readError) throw new Error('Receiving end does not exist');
                    return { title: 'PubMed article', url: 'https://pubmed.ncbi.nlm.nih.gov/123/' };
                }
            },
            runtime: { sendNativeMessage: async (id, message) => {
                saves.push({ id, message });
                return { ok: true, summary: 'Saved.' };
            } }
        }
    };
    vm.runInNewContext(source, context);
    await click();
    assert.equal(button.disabled, false);
    return { queries, reads, saves, status };
}

const direct = await capture([[{ id: 1 }]]);
assert.equal(direct.queries.length, 1);
assert.deepEqual(direct.reads, [1]);
assert.equal(direct.saves[0].id, 'VD.TypeNBash.CiteTex');
assert.equal(direct.saves[0].message.citations[0].title, 'PubMed article');

const fallback = await capture([[], [{ id: 2 }]]);
assert.equal(fallback.queries[1].lastFocusedWindow, true);
assert.deepEqual(fallback.reads, [2]);
assert.equal(fallback.status.textContent, 'Saved.');

const zeroID = await capture([[{ id: 0 }]]);
assert.deepEqual(zeroID.reads, [0]);

const missing = await capture([[], []]);
assert.equal(missing.reads.length, 0);
assert.equal(missing.saves.length, 0);
assert.match(missing.status.textContent, /Allow CiteTex on this website/);
assert.equal(missing.queries.length, 2);

const unreadable = await capture([[{ id: 3 }]], true);
assert.equal(unreadable.saves.length, 0);
assert.match(unreadable.status.textContent, /reload the article/);
console.log('CiteTex popup checks passed: current/focused tab, zero ID, unavailable tab, page access, and native capture.');
