Golden corpus generated 2026-10-16 from <High Five client>/system (Lineage2Ver413, l2encdec RSA pair)
with open-l2encdec (decode) and the original l2disasm.exe/l2asm.exe 1.4.1 under CrossOver, ddf set DAT_defs/CT2_6.
`enc/`, `dec/` and `txt/` hold NCSoft game data and are gitignored; only the exported ddf schemas and the results table are committed. Supply your own client files to run the golden tests.
- enc/  original encrypted files        - dec/  decrypted (plain dat)
- txt/  l2disasm output (tab-separated) - ddf/  l2disasm -e exported ddf (with SOFT limits)
- RESULTS.tsv: per-file decode / disasm / l2asm-roundtrip status
