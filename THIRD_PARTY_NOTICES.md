# Third-party notices

Dictator is MIT licensed (see `LICENSE`). The app ships the following third-party pieces,
all under licenses compatible with that. This file is bundled in `Dictator.app/Contents/Resources`.

| Component | Used for | License | Source |
| --- | --- | --- | --- |
| WhisperKit 1.1.1 | On-device speech recognition (Swift code linked into the app) | MIT, © 2024 argmax, inc. | https://github.com/argmaxinc/WhisperKit |
| WhisperKit Core ML model `openai_whisper-large-v3-v20240930_turbo` | Bundled speech model (Core ML conversion) | MIT (argmax, inc.) | https://huggingface.co/argmaxinc/whisperkit-coreml |
| Whisper Large v3 Turbo weights and tokenizer | The original model the conversion is made from; the tokenizer files are bundled as is | MIT, © 2022 OpenAI | https://huggingface.co/openai/whisper-large-v3-turbo, https://github.com/openai/whisper |
| DictationCore 0.1.0 | Shared dictation logic | MIT, © 2026 Nicki Skipper Otte | https://github.com/captains-chest/DictationCore |

`swift-argument-parser` (Apache 2.0) appears in `Package.resolved` because WhisperKit's command-line
tool needs it; the app doesn't link or ship it.

The full MIT license text applies to each MIT component, with that component's copyright notice:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction,
> including without limitation the rights to use, copy, modify, merge, publish, distribute,
> sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions: The above copyright notice and this
> permission notice shall be included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
> BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
> NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
> OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
