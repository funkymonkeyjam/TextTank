# Third-party materials

TextTank project code is GPL-3.0-or-later. LICENSE retains the upstream Notepad++ notice and GPL text. Notepad++ reference metadata and research are attributed in docs/research; TextTank is an independent project.

- Scintilla 5.6.9: copyright Neil Hodgson and contributors; permissive license in Resources/scintilla-License.txt. Dependencies.lock.json lists the local streamed-loader and Cocoa bidirectional-layout patches and the file hashes produced by each.
- Lexilla 5.5.5: copyright Neil Hodgson and contributors; permissive license in Resources/lexilla-License.txt.
- Boost.Regex 1.90.0 headers from the frozen official Notepad++ source: Boost Software License 1.0, retained in Resources/boost-License.txt and Sources/Search/Boost/LICENSE_1_0.txt; per-file hashes in Sources/Search/Boost/PROVENANCE.json.
- Notepad++ LexUser port and UDL constants: original GPL-2.0-or-later notice retained, distributed in the combined GPL-3.0-or-later application. Port changes and source hashes are in Sources/Languages/LexUserPort/PROVENANCE.json. The pinned upstream engines are unchanged.
- Notepad++ language keyword/style data: imported from pinned GPL-licensed source, per-input hashes in Resources/LanguageProfiles.json. Only data and audited lexer code are reused; no PadPlus or proprietary reference application implementation is included.
- Apple system zlib: used through the platform SDK for bounded raw-deflate SAML decoding; no zlib binary is redistributed.
- Carbon Caret wordmark uses outlined Space Grotesk; font notices are retained under Resources/Brand.

Dependency archive URLs/versions/SHA-256 values and the in-tree Boost/LexUser provenance registry are in Dependencies.lock.json; their per-file source/port hashes remain in the cited PROVENANCE.json files. The local review package includes exact dependency source archives and a corresponding project source archive. No Apple frameworks are redistributed outside the platform-provided runtime.
