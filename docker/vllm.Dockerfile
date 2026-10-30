# ============================================================================
# vLLM inference image (rvocs-hcs-amd)
#
# Contents: ROCm userspace + pre-assembled venv (torch/triton/torchvision/vLLM)
#           + entrypoint script.
# Userspace only: the kernel driver and /dev/kfd, /dev/dri come from the host.
#
# Build context (assembled into work/image-ctx by scripts/05-image.sh):
#   dist/        ROCm install tree (including .kpack)
#   venv-torch/  Python environment assembled on the host (copied in as a whole)
#   wheelhouse/  archived wheels (at /opt/vllm-wheels, for offline reinstalls)
#   benchmarks/  vLLM benchmarks (may be empty)
#   patches/     image-time python patches (may be empty)
#   Dockerfile / entrypoint.sh
# ============================================================================
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG GFX_TARGET=gfx1201
ARG GFX_FAMILY=gfx120X-all
ARG ROCM_VERSION=unknown
ARG TARGET_ARCH=unknown
ARG STACK_VENV=/opt/venv-torch
ARG HOST_VENV_PREFIX=/work/venv-stack
ARG WITH_GCC=0
ARG RCCL_FIX=0
ARG VLLM_DEFAULT_MODEL=/models/Qwen3.5-9B
ARG VLLM_DEFAULT_PORT=8000

LABEL org.opencontainers.image.title="AMD ROCm + vLLM (rvocs-hcs-amd)" \
      org.opencontainers.image.description="vLLM inference image for ${GFX_TARGET} (${GFX_FAMILY}), ROCm ${ROCM_VERSION}, built from TheRock" \
      org.opencontainers.image.version="${ROCM_VERSION}" \
      amd.therock.gfx="${GFX_TARGET}" \
      amd.therock.family="${GFX_FAMILY}" \
      amd.therock.arch="${TARGET_ARCH}"

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Runtime dependencies: system libraries ROCm needs plus image decoding for
# vLLM/torchvision
#
# A few of these look like build-time dependencies but are actually required at
# runtime:
#   libgcc-15-dev : triton's AMD backend JIT-compiles hip_utils.c at import time
#                   with /opt/rocm/lib/llvm/bin/clang, and linking needs
#                   libgcc_s.so (the dev symlink; the runtime package libgcc-s1
#                   does not ship it). Without it the error is
#                   "ld.lld: unable to find library -lgcc_s", which shows up as a
#                   failing model-architecture inspect subprocess and a server
#                   that never starts.
#   libtiff6/libjpeg62-turbo/... : runtime dependencies of Pillow 13's _imaging
#   (On Ubuntu 26.04 libxml2 became libxml2-16 and libjpeg-turbo8 became
#    libjpeg62-turbo, hence installing package by package: a missing single name
#    does not break the whole command.)
# ---------------------------------------------------------------------------
RUN set -eux; \
    command -v apt-get >/dev/null 2>&1 || { echo "only apt-based base images are supported" >&2; exit 1; }; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        python3 python3-dev \
        libnuma1 libedit2 libelf1 libdrm2 libpciaccess0 libzstd1 zlib1g \
        libgomp1 libtinfo6 ca-certificates libstdc++6; \
    apt-get update; \
    for p in libxml2-16 libfabric1 \
             libtiff6 libjpeg62-turbo libjpeg-turbo8 libpng16-16 libwebp7 libwebpdemux2 \
             liblcms2-2 libopenjp2-7 libfreetype6 libdeflate0 libjbig0 libxcb1 \
             libgcc-15-dev libgcc-14-dev; do \
      apt-get install -y --no-install-recommends "$p" || echo "[apt] skip $p"; \
    done; \
    if [ "$WITH_GCC" = "1" ]; then apt-get install -y --no-install-recommends gcc g++; fi; \
    rm -rf /var/lib/apt/lists/*; \
    python3 -V

# torch's libtorch_cpu.so is built with USE_MPI=1 and lists libmpi.so.40 in
# DT_NEEDED; install it in a separate strict step so it cannot be swallowed by
# --ignore-missing together with the optional packages above
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libopenmpi40; \
    rm -rf /var/lib/apt/lists/*; \
    ldconfig; \
    ldconfig -p | grep -q libmpi.so.40

# ---------------------------------------------------------------------------
# ROCm userspace (including .kpack device code)
# ---------------------------------------------------------------------------
COPY dist/ /opt/rocm/
RUN set -eux; \
    test -d /opt/rocm/bin || { echo "invalid ROCm tree: /opt/rocm/bin missing" >&2; exit 1; }; \
    printf '%s\n' "$ROCM_VERSION" > /opt/rocm/.amd-therock-version; \
    printf '%s\n' "$GFX_TARGET"  > /opt/rocm/.amd-therock-gfx; \
    if [ -d /opt/rocm/.kpack ]; then \
      echo "kpack for ${GFX_TARGET}: $(ls /opt/rocm/.kpack | grep -c -- "$GFX_TARGET" || true)"; \
    fi

# ---------------------------------------------------------------------------
# Python environment: copy in as a whole and fix the console-script shebangs
# (the venv is assembled on the host, so the #! lines in bin/* point at host
# paths and must be rewritten)
#
# Also add a rocm_amdsmi.pth: TheRock ships the amdsmi python bindings under
# /opt/rocm/share/amd_smi (a source directory, not site-packages) and pip never
# installed them into the venv. Without this .pth, vLLM start-up warns
#   Failed to import from amdsmi with ModuleNotFoundError("No module named 'amdsmi'")
# and degrades to not knowing device/memory information.
# ---------------------------------------------------------------------------
COPY venv-torch/ ${STACK_VENV}/
RUN set -eux; \
    if [ "$HOST_VENV_PREFIX" != "$STACK_VENV" ]; then \
      grep -rlZ "^#!${HOST_VENV_PREFIX}" "${STACK_VENV}/bin" 2>/dev/null \
        | xargs -0 -r sed -i "1s|^#!${HOST_VENV_PREFIX}|#!${STACK_VENV}|" || true; \
    fi; \
    sp=$(ls -d "${STACK_VENV}"/lib/python3*/site-packages); \
    echo /opt/rocm/share/amd_smi > "$sp/rocm_amdsmi.pth"; \
    export LD_LIBRARY_PATH="/opt/rocm/lib:/opt/rocm/lib/llvm/lib:${LD_LIBRARY_PATH:-}"; \
    "${STACK_VENV}/bin/python" -c "import torch, triton, vllm, amdsmi; print('STACK_IMPORT_OK', torch.__version__, triton.__version__, vllm.__version__)"

ENV STACK_VENV=${STACK_VENV} \
    ROCM_PATH=/opt/rocm \
    LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib/llvm/lib:/opt/rocm/lib/rocm_sysdeps/lib \
    PATH=/opt/rocm/bin:/opt/rocm/lib/llvm/bin:${STACK_VENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Performance-related defaults, aligned with the official vLLM Dockerfile.rocm
ENV SAFETENSORS_FAST_GPU=1 \
    HIP_FORCE_DEV_KERNARG=1 \
    TOKENIZERS_PARALLELISM=false \
    HSA_ENABLE_IPC_MODE_LEGACY=1

# ---------------------------------------------------------------------------
# Multi-GPU (RCCL) compatibility defaults: some platforms need legacy IPC or
# symmetric VA disabled
# ---------------------------------------------------------------------------
RUN set -eux; \
    mkdir -p /opt/stack; \
    if [ "$RCCL_FIX" = "1" ]; then \
      printf '%s\n' 'export NCCL_CUMEM_ENABLE="${NCCL_CUMEM_ENABLE:-1}"' \
                    'export NCCL_WIN_ENABLE="${NCCL_WIN_ENABLE:-0}"' > /opt/stack/rccl_fix.env; \
      echo "rccl fix enabled"; \
    else \
      : > /opt/stack/rccl_fix.env; \
    fi

# ---------------------------------------------------------------------------
# Wheel archive + benchmarks + image-time patches
# ---------------------------------------------------------------------------
COPY wheelhouse/ /opt/vllm-wheels/
COPY benchmarks/ /opt/vllm/benchmarks/
COPY patches/ /opt/patches/
RUN set -eux; \
    for p in /opt/patches/*.py; do \
      [ -e "$p" ] || continue; \
      echo "applying image patch: $p"; \
      "${STACK_VENV}/bin/python" "$p"; \
    done; \
    rm -rf /opt/patches

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV MODEL_PATH=${VLLM_DEFAULT_MODEL} \
    PORT=${VLLM_DEFAULT_PORT}

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
