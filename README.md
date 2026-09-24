<div align="center">
  
# TypeNBash

### A native Mac workspace for code, commands, and data.

Edit a file. Run a command. Explore a dataset.<br>
Keep your editor, terminal, and analysis together—locally or over SSH.

<p>
  <img src="https://img.shields.io/badge/macOS-26%20Tahoe%2B-151515?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="Requires macOS 26 Tahoe or later">
  <img src="https://img.shields.io/badge/Architecture-Apple%20silicon%20%2B%20Intel-B8975E?style=flat-square" alt="Apple silicon and Intel">
  <img src="https://img.shields.io/badge/Distribution-DMG-151515?style=flat-square" alt="DMG distribution">
</p>

<p>
  <a href="#download"><strong>Download &amp; Install</strong></a> &nbsp;·&nbsp;
  <a href="#workspace">Projects</a> &nbsp;·&nbsp;
  <a href="#analysis">Data Analysis</a> &nbsp;·&nbsp; 
  <a href="#getting-started">Getting started</a>
</p>

</div>

---

TypeNBash brings a text editor, terminal, file browser, and statistical notebook into one native macOS application. Move from a script to its output, from a CSV to an analysis, or from your Mac to a remote host without leaving your workspace.

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

## Your workspace, connected

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
<h3>⑂ Git tools</h3>
<p>Inspect saved changes, stage and unstage files, commit, fetch, and push in local projects. Connect a GitHub account for supported GitHub workflows.</p>
</td>
</tr>
</table>

System views put processor, memory, storage, network, and process activity within reach while you work.

<a id="analysis"></a>

## From CSV to Results

Open a CSV in an editable grid. Sort and filter columns, copy the full dataset or filtered rows, then open **Notebook** to build an analysis one step at a time.

**The statistics run natively. No Python or R environment to configure.**

| Explore | Available analyses |
| :--- | :--- |
| **Describe your data** | Descriptive statistics, frequencies, cross-tabulations |
| **Compare means** | One-sample, independent-samples, and paired t-tests; one-way ANOVA |
| **Find relationships** | Pearson and Spearman correlations; linear regression with numeric and categorical predictors |
| **Test categorical associations** | Chi-square test of independence and Cramér’s V |

Choose your missing-value policy, inspect each result’s notes, and see which dataset and capture produced it. Export results as **Markdown** to the project’s output directory when you’re ready to share them.

### Take the next step in R

**New R Notebook** turns your analysis steps into an editable `.R` script with `# %%` cells. Start R in the project console, then run selections or cells from the editor to continue exploring.

### Execution requirements and current scope

- R must be installed on the machine running the console. Script output remains in the console; it is not imported into the native notebook.
- Terminal commands use the runtimes and packages available on the active machine.
- The built-in **Source Control** and **Changes** views support local projects. Use Git in the SSH terminal for remote repositories.

<a id="getting-started"></a>
## Getting Started

| From the welcome window | You can… |
| :--- | :--- |
| **Work Locally** | Open a workspace on your Mac |
| **Connect over SSH** | Work with files and a terminal on another host |
| **New Project…** | Create a project folder or initialize an existing one |
| **Open Selected Project** | Return to a saved project |

**Try a first analysis:** open a project containing a CSV → select the file → open **Notebook** → add and run an analysis step → export your results.

### How project and notebook files are stored

Managed projects use small, project-relative files:
| File | Contains |
| :-- | :-- |
| `.typenbash.json` | Project name and output-directory setting |
| `.typenbash-notebook.json` | Analysis steps and missing-value definitions |

Opening an ordinary folder does not require adding project metadata. Notebook steps are saved, while results are recalculated on demand. Export a Markdown report to preserve a result.

## Feedback
Found a problem? Include your **TypeNBash version**, **macOS version**, whether you’re working **locally or over SSH**, and the steps to reproduce it. For CSV or editor issues, a small sample file helps—remove private information before sharing. Report the aforementioned bugs and issues within either:
- The repositories Discussions & Issues page.
- Contact the developer directl via email at: vd@vadesai.com
---

## License
The source code for TypeNBash is licensed under the terms of the Apache License, Version 2.0. The notarized TypeNBash.app and its image bundle resources are licensed under the Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International License. See [LICENSE](https://github.com/va-desai-dev/TypeNBash?tab=License-1-ov-file) for details.
### Acknowledgements
TypeNBash includes third party source code from [CotEditor](https://github.com/coteditor/CotEditor) and [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) projects licensed under Apache Public v2.0 and MIT Licenses for the syntax editor. Additional libraries also include [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and [SwiftGitX](https://github.com/ibrahimcetin/SwiftGitX) also under the MIT Open Source Licenses. Third-party license notices and documentations are included within TypeNBash's binary.
<div align="center">
  <sub>TypeNBash © 2026 by Vedant A. Desai · Built for macOS</sub>
</div>
