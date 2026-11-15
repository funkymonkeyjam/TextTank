# Empty viewport line numbers — 2026-11-15

The native ruler now continues line numbers below the end of the document, including a new empty document. Labels are presentation only: no text, blank lines, undo entries or saved bytes are added. Existing explicit View line-number visibility control remains available.

Implementation uses an input-transparent ruler overlay, reads the Scintilla display-line mapping for wrapping/folding, and follows the line-number font, color and zoom. Pinned Scintilla sources are unchanged.

Validation: local application build passed; all 69 existing bridge checks passed. Running application visually showed sequential labels through the unused viewport for a one-character document and a fresh empty document. No claim of full parity or comprehensive zoom/folding visual coverage.

Independent review found a fixed font-name buffer; repaired with queried-length allocation before delivery. Reviewer found no ownership cycle, hit-testing interference or document mutation.
