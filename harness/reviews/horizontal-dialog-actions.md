# Horizontal dialog actions — 2026-11-15

All app-owned NSAlert() call sites now use a shared horizontal action row. Original action response indices remain unchanged; the primary action is on the right. Accessory controls retain their values and focus. Repeated presentation replaces the owned size constraints. Cancel always retains Escape, including when it is the first action.

Validation: native automation UI suite passed 66 assertions, including all three action responses, side-by-side geometry and accessory preservation across repeated presentation of one alert. Settings was visually inspected: Reset Defaults, Cancel, Save in one row. Save, Escape cancellation, reopening and Quit observed in the preview application.

Independent read-only review found no blocking defect. Its isolated native test confirmed first/third/second responses and stable dimensions on repeated presentation. Review identified Cancel-first losing Escape; repaired by prioritizing its Escape shortcut.

Scope: app-owned dialog actions; existing horizontal custom windows remain horizontal. System file panels and one-button NSAlert(error:) retain native presentation. Full Notepad++ capability coverage remains incomplete and is tracked separately.
