FROM ubuntu:22.04

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    unzip \
    build-essential \
    cmake \
    libssl-dev \
    pkg-config \
    libpq-dev \
    libbsd-dev \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Android NDK r26b (LLVM 17 — same major version as Rust stable, avoids LLD bitcode mismatches)
RUN wget https://dl.google.com/android/repository/android-ndk-r26b-linux.zip -O /tmp/ndk.zip && \
    unzip /tmp/ndk.zip -d /opt && \
    rm /tmp/ndk.zip && \
    ln -s /opt/android-ndk-r26b /opt/android-ndk

# Install Rust and Android cross-compilation targets
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"
# Only 64-bit targets — avoids stint 32-bit compilation bug (StUint[32] index out of bounds)
RUN rustup target add aarch64-linux-android x86_64-linux-android

# Install Nim 2.2.4 via choosenim
RUN curl https://nim-lang.org/choosenim/init.sh -sSf > init.sh && \
    sh init.sh -y && \
    rm init.sh
ENV PATH="/root/.nimble/bin:${PATH}"
RUN choosenim 2.2.4

WORKDIR /app

# Copy build script — the nwaku source is expected to be mounted at /app/nwaku-src
COPY build_all.sh /app/build_all.sh
RUN chmod +x /app/build_all.sh

# Output is expected at /out (mount a host directory here)
CMD ["/app/build_all.sh"]
