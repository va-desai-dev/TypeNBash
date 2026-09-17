# Agent Directives & Project Rules

## 1. System Environment & Tooling
- **UI Framework:** Bespoke layouts, strictly avoid '.ultraThinMaterial' and older UI methods from pre MacOS Tahoe. Ensure to utilize existing App primitives and components over creating large private files.
- **Data Persistence:** SwiftData, UserDefaults
- **Target Platform:** macOS 26 Native Desktop Application (.dmg distribution via notary)

## 2. Architecture & Directory Mapping
- `/TypeNBash`: Actual binary data for the app as a whole. DO NOT put backups, agent configs, and cache in here. ONLY compiling files and/or public facing markdowns shall exist in here.

## 3. Strict Coding Constraints: ENSURE TO FOLLOW ONLY FOR NEW CODE YOU ADD (PRE-EXISTING WORK CAN STAY CLUTTERED IN THE MEANTIME)
- **UI Logic Separation:** Keep UI views decoupled from backend operational logic. The UI acts as a non-logical shell window.
- **Redundancy Management:** Nuke redundancy immediately. Do not add extra helper functions or heavy migration scripts. Focus on direct, lean code patterns.
- **Components:** Prioritize standard native components for core operations (e.g., native confirmation buttons for delete actions) to maintain universal compliance.

## 4. Development Workflow & Commands
- **Primary IDE:** Xcode (Automatic code signing enabled)