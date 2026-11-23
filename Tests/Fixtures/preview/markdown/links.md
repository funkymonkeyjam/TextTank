[inline](https://example.com) and [titled](https://example.com/a "A title") and [single](http://example.com 'single quoted').

[relative](docs/page.md) and [fragment](#top) and [mail](mailto:a@example.com) and [angle](<https://example.com/a b>).

[parens](https://example.com/a_(b)) and [empty]() and [*emphasis* in `link`](https://example.com).

[reference][ref] and [collapsed][] and [shortcut] and [Case Insensitive][REF] and [undefined][nope] and [nothing].

Autolinks: <https://example.com/?a=1&b=2> and <user@example.com> and <not a link> and <ftp://example.com/file>.

Images: ![alt text](images/pic.png) and ![titled *alt*](https://example.com/p.png "Picture") and ![ref image][ref].

Blocked: [script](javascript:alert(1)) and [data](data:text/html,x) and [file](file:///etc/passwd) and ![img](javascript:alert(1)) and [case](JaVaScRiPt:alert(1)) and [vb](vbscript:x) and <javascript:alert(1)>.

Entity tricks stay inert: [a](&#106;avascript:alert(1)) and [b](java&Tab;script:alert(1)).

[link with "quotes" & <angles>](https://example.com/?q="x"&y=<z>)

[outer [inner](https://inner.example) text](https://outer.example)

[image in link ![pic](p.png)](https://example.com)

Not links: [text] (https://example.com) and [unclosed](https://example.com and ]stray[.

[ref]: https://example.com/ref "Reference title"
[collapsed]: <https://example.com/collapsed>
[shortcut]: /shortcut
[ref]: https://example.com/duplicate-ignored
[bad]: javascript:alert(1)

[blocked reference][bad]
