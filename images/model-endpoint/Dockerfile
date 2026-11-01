# Model-serving image: pinned llama.cpp runtime + the pinned GGUF model baked in.
# Baking the weights means no runtime download and no writable model volume. The build fails if
# the model hash does not match models/models.lock.yaml, so a bad file cannot ship.
# Default is the reviewed index digest from models/models.lock.yaml; build script passes it explicitly.
ARG RUNTIME_DIGEST=sha256:8052c13edd987de8858f8150031e025ac3d66823f09cf3ec8220899c4abce220
FROM ghcr.io/ggml-org/llama.cpp:server@${RUNTIME_DIGEST}

ARG MODEL_FILE
ARG MODEL_SHA256

COPY models/cache/${MODEL_FILE} /models/${MODEL_FILE}

RUN echo "${MODEL_SHA256}  /models/${MODEL_FILE}" | sha256sum -c - \
 && chmod 0444 /models/${MODEL_FILE} \
 && chmod 0555 /models

# Same flags and entrypoint as the runtime image. Pod args select the model path.
