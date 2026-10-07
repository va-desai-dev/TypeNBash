// Progressive enhancement: commands remain selectable without JavaScript.
const status = document.querySelector('.copy-status');
for (const button of document.querySelectorAll('[data-copy]')) {
  button.hidden = false;
  button.addEventListener('click', async () => {
    const code = document.getElementById(button.dataset.copy);
    const label = button.dataset.copy === 'git-command' ? 'Git' : 'curl';
    try {
      await navigator.clipboard.writeText(code.textContent.trim());
      status.textContent = `${label} command copied.`;
    } catch {
      // Clipboard permission can be unavailable on file:// or plain HTTP.
      const selection = window.getSelection();
      const range = document.createRange();
      range.selectNodeContents(code);
      selection.removeAllRanges();
      selection.addRange(range);
      status.textContent = `Copy unavailable. ${label} command selected; press Command+C or Ctrl+C to copy.`;
    }
  });
}
