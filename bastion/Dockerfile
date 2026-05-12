FROM ubuntu:22.04

ARG KUBECTL_VERSION=v1.30.0
ARG YQ_VERSION=v4.44.3

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      jq \
      less \
      nano \
      openssh-client \
      tmux \
      vim \
    && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
    && chmod 0755 /usr/local/bin/kubectl /usr/local/bin/yq \
    && useradd --create-home --shell /bin/bash --uid 1000 cka \
    && mkdir -p /home/cka/.kube /home/cka/problems /home/cka/work \
    && chown -R cka:cka /home/cka \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER cka
WORKDIR /home/cka/work
ENV KUBECONFIG=/home/cka/.kube/config

CMD ["sleep", "infinity"]
