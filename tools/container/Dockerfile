FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash bc bison build-essential busybox-static ca-certificates cpio curl device-tree-compiler \
    file flex git kmod kpartx libelf-dev libssl-dev lz4 lzop patch pkg-config \
    python3 python3-venv rsync sudo unzip xz-utils zstd \
    android-sdk-libsparse-utils mkbootimg \
    && rm -rf /var/lib/apt/lists/*

# pmbootstrap runs as a normal user and uses sudo for its Linux chroots.
RUN useradd -m -u 12345 -s /bin/bash builder \
    && printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder \
    && mkdir /work && chown builder:builder /work
USER builder
WORKDIR /work
CMD ["sleep", "infinity"]
