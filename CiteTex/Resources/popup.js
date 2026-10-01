//
//  popup.js
//  CiteTex
//
//  Drives one capture: ask the page's content script for metadata, turn it into
//  CSL-JSON (enriching by DOI through Crossref when possible), and hand it to
//  the native handler, which queues it for TypeNBash to add to the active .bib.
//

// Must match the extension target's bundle identifier. Safari routes native
// messages to this extension's own handler regardless, but keep it accurate.
const APP_ID = "VD.TypeNBash.CiteTex";

const saveButton = document.getElementById("save");
const statusEl = document.getElementById("status");

function setStatus(text, kind) {
    statusEl.textContent = text;
    statusEl.className = kind || "";
}

saveButton.addEventListener("click", async () => {
    saveButton.disabled = true;
    setStatus("Reading page…");
    try {
        const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
        if (!tab) throw new Error("No active tab.");

        const scraped = await browser.tabs.sendMessage(tab.id, { action: "scrape" });
        if (!scraped || (!scraped.title && !scraped.doi)) {
            throw new Error("No citation metadata found on this page.");
        }

        let csl = null;
        if (scraped.doi) {
            setStatus("Fetching CSL-JSON…");
            csl = await fetchCSLByDOI(scraped.doi);
        }
        if (!csl) csl = buildCSL(scraped);

        setStatus("Saving…");
        const reply = await browser.runtime.sendNativeMessage(APP_ID, { citations: [csl] });

        if (reply && reply.ok) setStatus(reply.summary || "Saved.", "ok");
        else setStatus((reply && reply.error) || "Could not save.", "error");
    } catch (e) {
        setStatus(e && e.message ? e.message : String(e), "error");
    } finally {
        saveButton.disabled = false;
    }
});

// Crossref content negotiation returns a single CSL-JSON record for a DOI.
async function fetchCSLByDOI(doi) {
    const url = "https://api.crossref.org/works/"
        + encodeURIComponent(doi)
        + "/transform/application/vnd.citationstyles.csl+json";
    try {
        const res = await fetch(url, {
            headers: { "Accept": "application/vnd.citationstyles.csl+json" }
        });
        if (!res.ok) return null;
        return await res.json();
    } catch {
        return null;
    }
}

// Assemble CSL-JSON from scraped tags. The Swift normaliser mints the citation
// key, so we deliberately omit `id` here.
function buildCSL(m) {
    const csl = { type: m.type || "webpage" };
    if (m.title) csl.title = m.title;
    if (m.doi) csl.DOI = m.doi;
    if (m.url) csl.URL = m.url;
    if (m.containerTitle) csl["container-title"] = m.containerTitle;
    if (m.publisher) csl.publisher = m.publisher;
    if (m.volume) csl.volume = m.volume;
    if (m.issue) csl.issue = m.issue;
    if (m.page) csl.page = m.page;
    if (m.authors && m.authors.length) csl.author = m.authors.map(splitName);

    const parts = parseDateParts(m.date);
    if (parts) csl.issued = { "date-parts": [parts] };

    return csl;
}

// Accept "Family, Given" or "Given Family"; keep single tokens literal so a
// corporate author is not split into a bogus given name.
function splitName(name) {
    const s = String(name).trim();
    if (s.includes(",")) {
        const [family, given] = s.split(",");
        return { family: family.trim(), given: (given || "").trim() };
    }
    const bits = s.split(/\s+/);
    if (bits.length === 1) return { literal: s };
    const family = bits.pop();
    return { family, given: bits.join(" ") };
}

function parseDateParts(s) {
    if (!s) return null;
    const m = String(s).match(/(\d{4})(?:[-/](\d{1,2}))?(?:[-/](\d{1,2}))?/);
    if (!m) return null;
    const parts = [parseInt(m[1], 10)];
    if (m[2]) parts.push(parseInt(m[2], 10));
    if (m[3]) parts.push(parseInt(m[3], 10));
    return parts;
}
