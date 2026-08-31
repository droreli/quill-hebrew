# Third-party notices

## Quill upstream

This project is derived from [digimata/quill](https://github.com/digimata/quill).
The upstream code is licensed under the MIT License. The upstream `LICENSE`
file and its copyright notice must remain in copies and substantial portions of
the code.

## FluidAudio and ArgumentParser

The Swift package manifest fetches FluidAudio and Apple's swift-argument-parser
at build time. FluidAudio is Apache-2.0 licensed. Review and include the
licenses for all resolved dependencies when distributing a compiled binary.

## Optional Hebrew model

The optional local Hebrew engine downloads
`mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx`, a conversion of
`ivrit-ai/whisper-large-v3-turbo`. The ivrit-ai source model is Apache-2.0
licensed. Model weights are **not** included in this repository or its source
releases.

If you distribute model weights or a binary that bundles them, retain the
applicable Apache-2.0 license text and all required attribution/NOTICE material
from the exact model artifact you distribute. Do not imply that ivrit.ai or MLX
Community endorses this project.

## Your releases

Before publishing binaries, review the exact dependency and model versions you
ship, retain their license texts and notices, and add your own copyright notice
for your modifications. This file is an attribution guide, not legal advice.
