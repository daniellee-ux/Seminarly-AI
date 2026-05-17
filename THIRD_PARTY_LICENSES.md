# Third-party licenses

Seminarly depends on the following open-source packages, declared in `project.yml`. Each is included unmodified via Swift Package Manager.

## Direct dependencies

| Package | License | Source |
|---|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT | argmax, inc. — on-device Whisper transcription |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache 2.0 | FluidInference — neural speaker diarization |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 | Apple — CLI argument parsing for `seminarly-cli` |

## Transitive dependencies

Pulled in via WhisperKit and ArgumentParser. Versions resolved by SwiftPM.

| Package | License | Source |
|---|---|---|
| [swift-transformers](https://github.com/huggingface/swift-transformers) | Apache 2.0 | Hugging Face |
| [swift-jinja](https://github.com/maiqingqiang/swift-jinja) | MIT | maiqingqiang |
| [swift-collections](https://github.com/apple/swift-collections) | Apache 2.0 | Apple |

## License compatibility

All dependencies are MIT or Apache 2.0, both of which are compatible with the project's Apache 2.0 license (see [LICENSE](LICENSE)).
