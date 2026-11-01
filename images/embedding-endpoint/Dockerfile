# Embedding service: the pinned llama.cpp runtime with EmbeddingGemma 2 (Q8_0) baked in.
# The build fails if the model hash does not match models/models.lock.yaml, so a bad file cannot ship.
ARG RUNTIME_DIGEST=sha256:8052c13edd987de8858f8150031e025ac3d66823f09cf3ec8220899c4abce220
FROM ghcr.io/ggml-org/llama.cpp:server@${RUNTIME_DIGEST}

ARG MODEL_FILE
ARG MODEL_SHA256

COPY models/cache/${MODEL_FILE} /models/${MODEL_FILE}

RUN echo "${MODEL_SHA256}  /models/${MODEL_FILE}" | sha256sum -c - \
 && chmod 0444 /models/${MODEL_FILE} \
 && chmod 0555 /models
