# syntax=docker/dockerfile:1
FROM arm64v8/ros:jazzy-ros-base

ARG UBUNTU_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports
ARG ROS_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN set -eux; \
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then \
        sed -i "s#http://ports.ubuntu.com/ubuntu-ports#${UBUNTU_MIRROR}#g" /etc/apt/sources.list.d/ubuntu.sources; \
    fi; \
    if [ -f /etc/apt/sources.list ]; then \
        sed -i "s#http://ports.ubuntu.com/ubuntu-ports#${UBUNTU_MIRROR}#g" /etc/apt/sources.list; \
        sed -i '/packages\.ros\.org/d' /etc/apt/sources.list; \
    fi; \
    rm -f /etc/apt/sources.list.d/ros2.sources /etc/apt/sources.list.d/ros2-latest.list; \
    find /etc/apt/sources.list.d -maxdepth 1 \( -type f -o -type l \) \
        \( -name 'ros2*' -o -name 'ros-latest*' \) ! -name 'ros2.list' -delete; \
    echo "deb [arch=arm64 signed-by=/usr/share/keyrings/ros2-archive-keyring.gpg] ${ROS_MIRROR} noble main" \
        > /etc/apt/sources.list.d/ros2.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        libpcl-dev \
        ros-jazzy-pcl-conversions \
        ros-jazzy-pcl-ros \
        ros-jazzy-visualization-msgs \
        ros-jazzy-geometry-msgs \
        ros-jazzy-rosidl-default-generators \
        ros-jazzy-rosidl-default-runtime; \
    rm -rf /var/lib/apt/lists/*

RUN rosdep init 2>/dev/null || true

WORKDIR /ws

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
