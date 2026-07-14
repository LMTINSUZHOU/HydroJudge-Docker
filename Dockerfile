ARG GOJUDGE_VERSION=v1.12.1
FROM criyle/go-judge:${GOJUDGE_VERSION} AS gojudge

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG HYDROJUDGE_VERSION=4.0.5

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV TZ=Asia/Kuala_Lumpur
ENV VJ4_LANGS=/opt/langs.yaml

# Ubuntu apt 镜像加速
RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's|http://security.ubuntu.com/ubuntu/|http://mirrors.tuna.tsinghua.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources

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
    && npm config set registry https://registry.npmmirror.com \
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
