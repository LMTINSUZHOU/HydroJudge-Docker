ARG GOJUDGE_VERSION=v1.12.1
FROM criyle/go-judge:${GOJUDGE_VERSION} AS gojudge

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG HYDROJUDGE_VERSION=4.0.5
ARG UBUNTU_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu
ARG NPM_REGISTRY=https://registry.npmmirror.com

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV TZ=Asia/Kuala_Lumpur
ENV VJ4_LANGS=/opt/langs.yaml

# 默认使用国内镜像；海外或内网环境可通过 UBUNTU_MIRROR 覆盖。
RUN test -n "${UBUNTU_MIRROR}" \
    && sed -i "s|http://archive.ubuntu.com/ubuntu|${UBUNTU_MIRROR%/}|g" /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i "s|http://security.ubuntu.com/ubuntu|${UBUNTU_MIRROR%/}|g" /etc/apt/sources.list.d/ubuntu.sources

# APT 包随 Ubuntu 24.04 与工具链 PPA 获取安全更新，因此不固定完整 deb 版本；
# Node 校验脚本中的单引号用于阻止 Shell 展开 JavaScript 模板字符串。
# hadolint ignore=DL3008,SC2016
RUN apt-get update \
    && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository -y ppa:ubuntu-toolchain-r/test \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        gettext-base \
        tini \
        procps \
        psmisc \
        gcc-15 \
        g++-15 \
        pypy3 \
        make \
        python3 \
        python3.12 \
        python3-pip \
        python-is-python3 \
        openjdk-21-jdk \
        git \
        time \
    && update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-15 100 \
    && update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-15 100 \
    && update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-15 100 \
    && update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++-15 100 \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm config set registry "${NPM_REGISTRY}" \
    && npm install -g "@hydrooj/hydrojudge@${HYDROJUDGE_VERSION}" \
    && node -e 'if (+process.versions.node.split(".")[0] !== 22) process.exit(1)' \
    && node -e 'if (require(`${process.argv[1]}/@hydrooj/hydrojudge/package.json`).version !== process.argv[2]) process.exit(1)' "$(npm root -g)" "${HYDROJUDGE_VERSION}" \
    && gcc-15 -dumpversion | grep -q '^15' \
    && g++-15 -dumpversion | grep -q '^15' \
    && python3.12 -c 'import sys; assert sys.version_info[:2] == (3, 12)' \
    && ! command -v go \
    && npm cache clean --force \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


WORKDIR /opt

COPY --from=gojudge /opt/go-judge /opt/mount.yaml /opt/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY judge.template.yaml /etc/hydro/judge.template.yaml
COPY langs.yaml /opt/langs.yaml

RUN chmod +x /usr/local/bin/entrypoint.sh /opt/go-judge \
    && mkdir -p /root/.hydro /data/cache /data/tmp

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
