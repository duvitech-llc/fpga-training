FROM ubuntu:24.04

# Pinned so everyone gets identical tools. To upgrade, change the version and
# take the matching sha256 from the project's GitHub release page. The RISC-V
# GCC is pinned further down, beside its own step, so that adding it did not
# throw away the cached layers above.
ARG OSS_CAD_SUITE_DATE=2026-10-31
ARG OSS_CAD_SUITE_SHA256=e0349f66547ca1ac9a24b5e06287d4719aa0213d431e1168eb319915340dc665
ARG CODE_SERVER_VERSION=4.144.0
ARG CODE_SERVER_SHA256=710f749c40a0f3d0ab3be09c0de65314e5c2907cc50646f5fbc0f24c0e8fba2d
ARG VAPORVIEW_VERSION=1.6.0

# Verilator needs g++ and make to build the models it generates.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        g++ \
        git \
        make \
    && rm -rf /var/lib/apt/lists/*

RUN archive="oss-cad-suite-linux-x64-$(echo "$OSS_CAD_SUITE_DATE" | tr -d -).tgz" \
    && curl -fsSL -o /tmp/suite.tgz \
        "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/$OSS_CAD_SUITE_DATE/$archive" \
    && echo "$OSS_CAD_SUITE_SHA256  /tmp/suite.tgz" | sha256sum -c - \
    && tar -xzf /tmp/suite.tgz -C /opt \
    && rm /tmp/suite.tgz

RUN curl -fsSL -o /tmp/code-server.tgz \
        "https://github.com/coder/code-server/releases/download/v$CODE_SERVER_VERSION/code-server-$CODE_SERVER_VERSION-linux-amd64.tar.gz" \
    && echo "$CODE_SERVER_SHA256  /tmp/code-server.tgz" | sha256sum -c - \
    && mkdir /opt/code-server \
    && tar -xzf /tmp/code-server.tgz -C /opt/code-server --strip-components=1 \
    && rm /tmp/code-server.tgz

# Same settings as the suite's own "environment" script. Verilator and cocotb
# need its python3.
ENV PATH=/opt/oss-cad-suite/bin:/opt/oss-cad-suite/py3bin:/opt/code-server/bin:$PATH
ENV VIRTUAL_ENV=/opt/oss-cad-suite
ENV VERILATOR_ROOT=/opt/oss-cad-suite/share/verilator

# The suite only ships a template, and without a config the labels in Yosys
# schematics render as empty boxes.
ENV FONTCONFIG_FILE=/opt/oss-cad-suite/etc/fonts/fonts.conf
RUN sed 's|TARGET_DIR|/opt/oss-cad-suite|g' "$FONTCONFIG_FILE.template" > "$FONTCONFIG_FILE"

# Extensions live outside HOME so they are available to any container user.
ENV EXTENSIONS_DIR=/opt/code-server-extensions
RUN code-server --extensions-dir "$EXTENSIONS_DIR" \
        --install-extension "lramseyer.vaporview@$VAPORVIEW_VERSION" \
    && chmod -R a+rwX "$EXTENSIONS_DIR"

# A RISC-V compiler, from Tutorial 27 on, for programs in C and for the RISC-V
# architecture tests. The xPack build is a plain archive with no dependencies.
ARG RISCV_GCC_VERSION=15.2.0-1
ARG RISCV_GCC_SHA256=aaaa8060c914851a3e5ee1ba82cc3d6f80972f90638a05c6e823a37557a33758
RUN curl -fsSL -o /tmp/riscv-gcc.tgz \
        "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v$RISCV_GCC_VERSION/xpack-riscv-none-elf-gcc-$RISCV_GCC_VERSION-linux-x64.tar.gz" \
    && echo "$RISCV_GCC_SHA256  /tmp/riscv-gcc.tgz" | sha256sum -c - \
    && mkdir /opt/riscv-gcc \
    && tar -xzf /tmp/riscv-gcc.tgz -C /opt/riscv-gcc --strip-components=1 \
    && rm /tmp/riscv-gcc.tgz
ENV PATH=$PATH:/opt/riscv-gcc/bin

# The container runs as the host user (see compose.yaml), which may have no
# passwd entry here, so HOME must point somewhere that any user can write to.
ENV HOME=/tmp

WORKDIR /work

CMD ["bash"]
