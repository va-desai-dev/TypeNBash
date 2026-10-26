<div align="center">
  
<h1 align="center">TypeNBash</h1>

<h3 align="center">A native Mac workspace for code, commands, and data.</h3>

<h4 align="center"><i>Research. Code. Build. Preview. Test. Analyze. Audit.</i></h4>

<p align="center">
  <a href="#download"><strong>Download</strong></a> &nbsp;·&nbsp;
  <a href="#workspace">Projects</a> &nbsp;·&nbsp;
  <a href="#privacy">Privacy</a> &nbsp;·&nbsp;
  <a href="#feedback">Feedback</a> &nbsp;·&nbsp;
  <a href="#acknowledgements">Acknowledgements</a> &nbsp;·&nbsp;
</p>

<span align="center">
<img src="https://img.shields.io/badge/macOS-26%20Tahoe%2B-151515?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="Requires macOS 26 Tahoe or later">
<img src="https://img.shields.io/badge/Architecture-Apple%20silicon%20%2B%20Intel-B8975E?style=flat-square" alt="Apple silicon and Intel">
<img src="https://img.shields.io/badge/Distribution-DMG-151515?style=flat-square" alt="DMG distribution">
</span>
</div>

---

TypeNBash brings a text editor, terminal, file browser, web browser for previews, citation management, and an analytics notebook into a single native macOS application. Move from a script to its output, from a CSV to an analysis, or from your Mac to a remote host without leaving your workspace. All the while, you can monitor telemetry and device performance from the gorgeous inspector.

<a id="download"></a>

## Download & install

[**Download TypeNBash for MacOS from the latest page.**](https://github.com/va-desai-dev/TypeNBash/releases/tag/v1.0.0-beta) If you’re viewing the repository home page, open **Releases** first.

1. Open the downloaded disk image.
2. Drag **TypeNBash.app** into **Applications**.
3. Launch **TypeNBash** from Applications.

| Compatibility | Requirement |
| :--- | :--- |
| Operating system | macOS **26 Tahoe or later** |
| Mac | **Apple silicon or Intel** |
| Native CSV analysis | No Python or R installation required |
| Optional workflows | An SSH host for remote work; R to execute R scripts |

<a id="workspace"></a>
## Many Options, One Workspace

<table>
<tr>
<td width="50%" valign="top">
<h3>⌨️ Editor + terminal</h3>
<p>Browse files, edit with syntax highlighting, and find or replace text. Keep a project console beside your editor and send selected code or the current <code># %%</code> cell to it.</p>
</td>
<td width="50%" valign="top">
<h3>🌐 Local + SSH</h3>
<p>Work on your Mac or connect to another host. Browse and edit remote files alongside a remote terminal, with saved connection profiles and key/agent or password authentication.</p>
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>📂 Portable projects</h3>
<p>Create a project, initialize an existing folder, or open a folder as it is. Managed project settings travel with the folder, keeping its name and output location together.</p>
</td>
<td width="50%" valign="top">
<h3>⑂ Git Tools</h3>
<p>Inspect saved changes, stage and unstage files, commit, fetch, and push in local projects. Connect a GitHub account for supported GitHub workflows.</p>
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>📊 Quant Tools</h3>
<p>Run statistical tests ranging from linear models, Chi-Squares, distribution analytics, descriptives, and mean comparisons through a simplified button-based interface or R & Python notebooks if you fancy it.</p>
</td>
<td width="50%" valign="top">
<h3>📝 Research & Revise</h3>
<p>Markdown? Embedded Markdown previews help you write long documents and manuscripts. Harness the power of the CiteTex extension to also retrieve citations from an open Safari tab straight to your BibTeX library. Simply run a pandoc or LaTeX script yourself to convert to a formatted manuscript.</p>
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>📐 Telemetries</h3>
<p>System views put processor, memory, storage, network, and process activity within reach while you work. Never leave your workspace to figure out why your system is running slowly.</p>
</td>
<td width="50%" valign="top">
<h3>🤖 YOUR Agents</h3>
<p>Secure, safe, and private. TypeNBash aims to embrace a future of agentic LLMs while giving users the agency to select their agents. Hook your BYOK LLM and let TypeNBash be the amazing harness.</p>
</td>
</tr>
</table>

>[!CAUTION]
>TypeNBash requires a project workspace for accessing the notebook, GitHub, citation management, and agentic features. Home directory access lets you work on broader things; however, it lacks project-scoped features.

<a id="privacy"></a>

## Storage & Security
*Managed* projects use small, project-relative files:
| File | Contains |
| :-- | :-- |
| `.typenbash.json` | Project name and output-directory setting |
| `.typenbash-notebook.json` | Analysis steps and missing-value definitions |

Opening an ordinary folder does not require adding project metadata. Notebook steps are saved, while results are recalculated on demand. Export a Markdown report to preserve a result.

**TypeNBash ensures a scope-limited, sandboxed** workflow for any features that involve writing directories and repositories. Agentic workflows are fully restricted to working directories, with you having complete control over permissions.

The developer or a back-end server (which doesn't exist!) can't access any of your in-app credentials, including GitHub access. Your LLM agents, keys, passwords in the app-browser, and files are fully scoped to your device and/or repository of choosing. 
>[!CAUTION]
>**TypeNBash** AppStore version coming soon will inherently lack `home/freemode` workflows due to sandboxing mandates. This will also limit your ability to perform Terminal commands outside your project repository. If full access and Terminal freedom are what you seek, please download the DMG version, or work on remote SSH hosts.

<a id="feedback"></a>

## Feedback
Found a problem? Include your **TypeNBash version**, **macOS version**, whether you’re working **locally or over SSH**, and the steps to reproduce it. For CSV or editor issues, a small sample file helps—remove private information before sharing. Report the aforementioned bugs and issues within either:
- The repositories Discussions & Issues page.
- Contact the developer directly via email at: vd@vadesai.com

<a id="acknowledgements"></a>

## License
The source code for TypeNBash is licensed under the terms of the Affero General Public License v3.0 (GNU, 2007). The notarized TypeNBash.app and its image bundle resources are licensed under the Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International License. See [LICENSE](https://github.com/va-desai-dev/TypeNBash?tab=License-1-ov-file) for details.
### Acknowledgements
TypeNBash includes third-party source code and frameworks. A comprehensive list of the third-party sources and their associated authors are listed in [THIRDPARTYNOTICES.md](THIRDPARTYNOTICES.md)
<div align="center">
  <sub>TypeNBash © 2026 by Vedant A. Desai · Built for macOS</sub>
</div>