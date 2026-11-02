# Third-party components and licenses

The app links the following Swift packages. Their license texts are reproduced
by the package managers in `.build/checkouts/`; this file records the audit.

| Component | Version / pin | License | Use |
|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.12.0 | MIT | SQLite access, migrations, keyed persistence |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | MIT | Reading DOCX (OOXML) packages |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | revision `e396cf7` | Apache-2.0 (includes third-party notices in `ThirdPartyLicenses`) | On-device Parakeet speech models |

System frameworks (PDFKit, Vision, Speech, AVFoundation, Security, SwiftUI,
AppKit) are provided by macOS.

## Models

Parakeet model weights are **not** bundled. They are downloaded on explicit
request from Hugging Face through FluidAudio and are governed by their own model
licenses and terms. Review the model card before redistributing a model or a
build that caches one.

WhisperKit is not linked in this build. Its engines are reported as unavailable
rather than offered as working.

## Design reference

[BetterWispr](https://github.com/opennookorg/betterwispr) (Apache-2.0) was
studied as a reference for native dictation and model management. No source code
from that project is included here. If code is ever reused, its Apache-2.0
license and NOTICE requirements apply.

## Bundled text

`Sources/StudyPrompts/Resources/AGENT.md` is original text written for this app.

## Distribution checklist

- [ ] Keep the Apache-2.0 notices from FluidAudio when shipping a binary.
- [ ] Include the MIT notices for GRDB and ZIPFoundation.
- [ ] Do not bundle downloaded model weights without checking their licenses.
- [ ] Sign with a Developer ID and notarize before distributing outside this Mac.
