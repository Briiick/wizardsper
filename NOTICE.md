# Third-party components

Wizardsper's own source is MIT licensed (see `LICENSE`). It depends on a speech
recognition model that is **not** MIT licensed and **is not distributed with
this repository**.

## The speech model

Wizardsper downloads NVIDIA's `nemotron-speech-streaming-en-0.6b`, in the CoreML
conversion published by FluidInference, on first run. The weights are fetched
from Hugging Face into `~/Library/Application Support/Wizardsper/Models/` and are
never redistributed by this project — no model file is committed here, bundled in
the app, or served from it.

| | |
|---|---|
| Model | [`nvidia/nemotron-speech-streaming-en-0.6b`](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) |
| CoreML conversion | [`FluidInference/nemotron-speech-streaming-en-0.6b-coreml`](https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml) |
| Licence | [NVIDIA Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/) |

**Read that licence before doing anything commercial with this.** It is not an
OSI-approved open source licence and it carries use restrictions. Note also that
the FluidInference README's footer says "Apache 2.0"; its own repository metadata
says `nvidia-open-model-license`, as does NVIDIA's upstream model. Trust the
metadata.

If you fork this and decide to bundle the weights rather than download them, the
licensing position changes completely and becomes yours to work out.

## Apple frameworks

Transcript clean-up uses Apple's on-device `FoundationModels`, which ships with
macOS. Nothing is downloaded and no text leaves the machine.
