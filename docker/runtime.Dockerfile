# syntax=docker/dockerfile:1.7
# ============================================================================
# ROCm runtime image (rvocs-hcs-amd)
#
# Userspace only: the kernel driver (amdgpu) and /dev/kfd, /dev/dri come from
# the host.
#
# Build context (injected by scripts/04-image.sh via --build-context):
#   rocm-dist  : ROCm install tree (source mode = build/dist/rocm;
#                prebuilt mode = the unpacked official tarball)
#   wheelhouse : local wheel directory (may be empty; the script drops a .keep)
# ============================================================================
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG GFX_TARGET=gfx1201
ARG GFX_FAMILY=gfx120X-all
ARG ROCM_VERSION=unknown
ARG TARGET_ARCH=unknown
ARG PYTHON_MODE=none
ARG PYTHON_PACKAGES="torch torchvision torchaudio"
ARG PYTHON_INDEX_URL=https://stable.repo.amd.com/rocm/whl-next/

LABEL org.opencontainers.image.title="AMD ROCm runtime (rvocs-hcs-amd)" \
      org.opencontainers.image.description="ROCm userspace runtime built from TheRock for ${GFX_TARGET} (${GFX_FAMILY})" \
      org.opencontainers.image.version="${ROCM_VERSION}" \
      amd.therock.gfx="${GFX_TARGET}" \
      amd.therock.family="${GFX_FAMILY}" \
      amd.therock.arch="${TARGET_ARCH}"

# ---------------------------------------------------------------------------
# Runtime system dependencies (ROCm's own sysdeps are bundled privately, so
# only a minimal set is needed here)
# ---------------------------------------------------------------------------
RUN set -eux; \
    command -v apt-get >/dev/null 2>&1 || { echo "only apt-based base images are supported" >&2; exit 1; }; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libelf1 libnuma1 libdrm2 libpciaccess0 libzstd1 zlib1g \
        libxml2 libgomp1 libtinfo6 python3-minimal ca-certificates; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# ROCm userspace (including .kpack device code)
# ---------------------------------------------------------------------------
COPY --from=rocm-dist / /opt/rocm/

RUN set -eux; \
    test -d /opt/rocm/bin || { echo "invalid ROCm tree: /opt/rocm/bin missing" >&2; exit 1; }; \
    test -d /opt/rocm/lib || { echo "invalid ROCm tree: /opt/rocm/lib missing" >&2; exit 1; }; \
    printf '%s\n' "$ROCM_VERSION" > /opt/rocm/.amd-therock-version; \
    printf '%s\n' "$GFX_TARGET"  > /opt/rocm/.amd-therock-gfx; \
    if [ -d /opt/rocm/.kpack ]; then \
      echo "kpack for ${GFX_TARGET}: $(ls /opt/rocm/.kpack | grep -c -- "$GFX_TARGET" || true)"; \
    else \
      echo "no .kpack directory (device code may be inlined)"; \
    fi

ENV ROCM_PATH=/opt/rocm \
    PATH=/opt/rocm/bin:/opt/venv/bin:$PATH \
    LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib/rocm_sysdeps/lib:

# ---------------------------------------------------------------------------
# Optional PyTorch
#   none      : ROCm only (smallest image)
#   pip       : install from the official TheRock wheel index (works on x86_64)
#   wheelhouse: install offline from a local wheel directory (riscv64, where no
#               official wheels exist)
# ---------------------------------------------------------------------------
COPY --from=wheelhouse / /opt/wheelhouse/

RUN set -eux; \
    if [ "$PYTHON_MODE" = "none" ]; then \
      echo "skip python packages"; \
    elif [ "$PYTHON_MODE" = "pip" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends python3-venv python3-pip; \
      rm -rf /var/lib/apt/lists/*; \
      python3 -m venv /opt/venv; \
      /opt/venv/bin/pip install -q -U pip; \
      set -- ; \
      for p in $PYTHON_PACKAGES; do \
        case "$p" in \
          torch|torchvision) set -- "$@" "${p}[device-${GFX_TARGET}]" ;; \
          *) set -- "$@" "$p" ;; \
        esac; \
      done; \
      /opt/venv/bin/pip install --index-url "$PYTHON_INDEX_URL" "$@"; \
    elif [ "$PYTHON_MODE" = "wheelhouse" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends python3-venv python3-pip; \
      rm -rf /var/lib/apt/lists/*; \
      python3 -m venv /opt/venv; \
      /opt/venv/bin/pip install -q -U pip; \
      if [ -f /opt/wheelhouse/requirements.txt ]; then \
        /opt/venv/bin/pip install --no-index --find-links=/opt/wheelhouse -r /opt/wheelhouse/requirements.txt; \
      else \
        /opt/venv/bin/pip install --no-index --find-links=/opt/wheelhouse $PYTHON_PACKAGES; \
      fi; \
    else \
      echo "unknown PYTHON_MODE=$PYTHON_MODE" >&2; exit 1; \
    fi

WORKDIR /workspace
CMD ["/bin/bash"]
