# Third-party notices

## open-l2encdec (bundled helper)

`upstream/ritsuwastaken_open-l2encdec/` is vendored from
[ritsuwastaken/open-l2encdec](https://github.com/ritsuwastaken/open-l2encdec) @ 870fc5b and built as the
`l2encdec` helper that ships inside the apps. MIT License, Copyright (c) 2024 ritsuwastaken; the full text is in
[`upstream/ritsuwastaken_open-l2encdec/LICENSE`](upstream/ritsuwastaken_open-l2encdec/LICENSE). Its CLI includes a
getopt implementation under its own license
([`cli/extern/getopt/LICENSE`](upstream/ritsuwastaken_open-l2encdec/cli/extern/getopt/LICENSE)).

## DDF schema definitions

`Sources/L2FileEditorApp/Resources/DAT_defs/` and `fixtures/high5/ddf/` are `.ddf` table schemas for the
l2asm/l2disasm format by DStuff, as distributed with *L2 File Editor* by Miko and maintained by the Lineage II
modding community. They describe file layouts and are included for interoperability. No license was stated by
their authors; if you hold rights to them and want them removed or credited differently, please open an issue.

## Prior art (not included)

This project re-implements the behaviour of *L2 File Editor* by Miko (2009–2015) and DStuff's l2asm/l2disasm.
None of their binaries are included. The following projects were consulted as references only, and no code from
them is included:

- [L2Miko/L2FileEdit](https://github.com/L2Miko/L2FileEdit)
- [ellysh/L2FileEdit](https://github.com/ellysh/L2FileEdit)
- [acmi/L2crypt](https://github.com/acmi/L2crypt) (MIT)
- [MobiusDevelopment/L2ClientDat](https://github.com/MobiusDevelopment/L2ClientDat) (GPL-3)

## Trademarks

Lineage II and NCSoft are trademarks of NCSoft Corporation. This project is not affiliated with, endorsed by or
sponsored by NCSoft. The names are used only to describe which files the tool works with.
