# G0 legacy screenshot interpreter baseline

Corpus: 867 generated screens (600 across eight transaction layout families, 67 checkout/pending/failed, 200 non-transaction negatives), 24 blind fixtures, four synthetic held-out fixtures modelled on real bank-app layouts (all values fictional). No real Capture Lab JSON dump was available in the repository. Seed: `0x2026092860`. Output digest: `feb8a3f587a00706`.

Each field is `correct/missing/wrong/wrong-and-trusted`. For negative screens, a correctly absent field counts as correct. Dates compare parsed instants, not string spelling. Accuracy is measured only; the later release gate is disabled.

G3 corrected the B17 blind ground truth: a value under bare `ID` has no resolved transaction-reference role. This changes only the blind reference scoreboard below; the frozen legacy-output digest and OCR fixture are unchanged.

| Split / family | Classification | Amount | Merchant | Date/time | Reference |
|---|---:|---:|---:|---:|---:|
| blind/blind | class:12/0/12/0 | amount:11/13/0/0 | merchant:10/14/0/0 | date:13/10/1/0 | reference:12/12/0/0 |
| dev/A-hero | class:75/0/0/0 | amount:61/14/0/0 | merchant:63/12/0/0 | date:35/40/0/0 | reference:75/0/0/0 |
| dev/B-columns | class:0/0/75/0 | amount:0/75/0/0 | merchant:0/75/0/0 | date:0/75/0/0 | reference:0/75/0/0 |
| dev/C-stacked | class:0/0/75/0 | amount:0/75/0/0 | merchant:0/75/0/0 | date:0/75/0/0 | reference:0/75/0/0 |
| dev/D-alert | class:0/0/75/0 | amount:0/75/0/0 | merchant:0/75/0/0 | date:0/75/0/0 | reference:0/75/0/0 |
| dev/E-title | class:0/0/75/0 | amount:0/75/0/0 | merchant:0/75/0/0 | date:0/75/0/0 | reference:0/75/0/0 |
| dev/checkout | class:0/0/34/0 | amount:0/34/0/0 | merchant:34/0/0/0 | date:34/0/0/0 | reference:34/0/0/0 |
| dev/list | class:0/0/34/0 | amount:34/0/0/0 | merchant:34/0/0/0 | date:34/0/0/0 | reference:34/0/0/0 |
| dev/pending | class:33/0/0/0 | amount:0/33/0/0 | merchant:33/0/0/0 | date:33/0/0/0 | reference:33/0/0/0 |
| dev/product | class:33/0/0/0 | amount:33/0/0/0 | merchant:33/0/0/0 | date:33/0/0/0 | reference:33/0/0/0 |
| dev/promo | class:33/0/0/0 | amount:33/0/0/0 | merchant:33/0/0/0 | date:33/0/0/0 | reference:33/0/0/0 |
| dev/weather | class:33/0/0/0 | amount:33/0/0/0 | merchant:33/0/0/0 | date:33/0/0/0 | reference:33/0/0/0 |
| holdout/F-receipt | class:0/0/75/0 | amount:0/75/0/0 | merchant:0/75/0/0 | date:0/75/0/0 | reference:0/75/0/0 |
| holdout/G-malay | class:75/0/0/0 | amount:25/50/0/0 | merchant:0/75/0/0 | date:39/36/0/0 | reference:0/75/0/0 |
| holdout/H-mixed | class:0/0/75/0 | amount:0/75/0/0 | merchant:0/75/0/0 | date:0/75/0/0 | reference:0/75/0/0 |
| holdout/chat | class:33/0/0/0 | amount:33/0/0/0 | merchant:33/0/0/0 | date:33/0/0/0 | reference:33/0/0/0 |
| holdout/overview | class:34/0/0/0 | amount:34/0/0/0 | merchant:34/0/0/0 | date:34/0/0/0 | reference:34/0/0/0 |
| physical-holdout/synthetic-historical | class:3/0/1/0 | amount:3/1/0/0 | merchant:2/2/0/0 | date:3/1/0/0 | reference:3/1/0/0 |
