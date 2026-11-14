# Explicit Run and text extensions

Run configurations are versioned data with stable UUID, user-chosen name, an absolute executable path and separate arguments. Reading/importing configuration never launches it. The user selects a saved entry in Run to execute it. `{file}`, `{directory}` and `{selection}` expand only when each is an entire argument; spaces, quotes, substitutions and metacharacters remain argument bytes.

Intentional shell mode is an explicit checkbox and uses `/bin/zsh -c`. Document variables are not interpolated into shell code. Shell mode is not used by extensions.

Version 1 text extensions receive UTF-8 selected text, or the document when no selection exists, through stdin. They return UTF-8 on stdout, diagnostics on stderr, and exit zero for success. The result is previewed, then applied only by a separate explicit button while document revision, selection and writable lifetime still match. Applying is one Undo. A newer preview invalidates older Apply controls. Invalid UTF-8, nonzero exit, cancellation and truncated output cannot be applied.

The included sample uses the system `/usr/bin/tr a-z A-Z` to uppercase ASCII. It is an actual process/stdio integration, not a Unicode case-conversion promise. The user can save the sample from Run and invoke it on synthetic text. Windows DLL binary compatibility and the complete Notepad++ plugin message/event API are not implemented by this limited interface.

Runs use an isolated process group, 4 MiB input/output bounds and a 30-second default timeout. Cancel signals that group, escalates termination, closes bounded nonblocking pipe readers and leaves document contents unchanged. Descendants are cleaned up when the scoped run finishes, including those that redirect output; daemonization is not a supported run mode. External programs can perform their own filesystem/network effects, so only explicitly configured, trusted programs should be invoked. No program is run by opening a document, macro, workflow, session or settings file.
